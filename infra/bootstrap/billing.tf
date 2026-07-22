# Administrator-owned control plane for billing. The automatically applied runtime root owns only
# billing data-plane resources, such as the BigQuery usage dataset.

# OpenTofu creates only the Stripe key containers. Seed restricted keys out of band after bootstrap
# has been applied; secret bytes never enter OpenTofu state.
resource "google_secret_manager_secret" "stripe_api_key" {
  secret_id = "stripe-api-key"

  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.this["secretmanager.googleapis.com"]]
}

# Separate account-backend key for invoices, customers, subscriptions, setup intents, and read-only
# payment history. It must not grant catalog or meter-event writes. The consuming service receives a
# secret IAM binding only when that service lands.
resource "google_secret_manager_secret" "stripe_account_key" {
  secret_id = "stripe-account-key"

  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.this["secretmanager.googleapis.com"]]
}

# Container for the Stripe webhook signing secret hop-accountd consumes as STRIPE_WEBHOOK_SECRET. The
# VALUE is written by the isolated billing root (infra/billing/webhook_secret.tf), which owns the
# stripe_webhook_endpoint whose computed `secret` attribute this is; that root already holds the value
# in its own state, so writing it here costs no new exposure and removes the last manual seeding step.
# Bootstrap owns the container so the accountd secretAccessor grant (console.tf) stays in one place.
# Apply order: bootstrap first (the container must exist), then infra/billing.
#
# Posture, stated plainly: this signing secret DOES live in OpenTofu state (the billing state, where
# the endpoint's computed attribute has always put it). That is a deliberate, owner-approved tradeoff,
# machine-generated credentials in state in exchange for zero manual seeding steps. The access
# controlled hop-mesh-tfstate bucket is the boundary protecting those bytes.
resource "google_secret_manager_secret" "stripe_webhook_secret" {
  secret_id = "stripe-webhook-secret"

  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.this["secretmanager.googleapis.com"]]
}

# Dedicated reconciler identity. It can read billing inputs and append usage history, but it cannot
# mutate the relay bundle store or administer any billing control-plane resource.
resource "google_service_account" "billingd" {
  account_id   = "hop-billingd"
  display_name = "Hop billing reconciler (Cloud Run)"

  depends_on = [google_project_service.this["iam.googleapis.com"]]
}

resource "google_secret_manager_secret_iam_member" "billingd_stripe" {
  secret_id = google_secret_manager_secret.stripe_api_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.billingd.email}"
}

resource "google_project_iam_member" "billingd_firestore_read" {
  project = var.project_id
  role    = "roles/datastore.viewer"
  member  = "serviceAccount:${google_service_account.billingd.email}"
}

resource "google_project_iam_member" "billingd_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.billingd.email}"
}

resource "google_project_iam_member" "billingd_bigquery" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.billingd.email}"
}

# GitHub Actions exchanges repository-scoped OIDC tokens for short-lived credentials. The catalog
# identity can mutate only objects under the billing/ state prefix and has no Stripe or project role.
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-actions"
  display_name              = "GitHub Actions"
  description               = "OIDC federation for ${var.github_repository} GitHub Actions workflows."

  depends_on = [google_project_service.this["iam.googleapis.com"]]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  attribute_condition = "assertion.repository == \"${var.github_repository}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "billing_catalog_apply" {
  account_id   = "billing-catalog-apply"
  display_name = "GitHub Actions: apply the Stripe billing catalog (TF state only)"

  depends_on = [google_project_service.this["iam.googleapis.com"]]
}

resource "google_service_account_iam_member" "billing_catalog_wif" {
  service_account_id = google_service_account.billing_catalog_apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

# The catalog identity writes ONE secret: the Stripe webhook signing secret it just created
# (infra/billing/webhook_secret.tf). versionAdder lets the apply write it; secretAccessor lets the next
# plan refresh the version it owns without a permission error. Both are scoped to that single
# container, so this identity still cannot read any other secret in the project.
resource "google_secret_manager_secret_iam_member" "billing_catalog_webhook_secret" {
  for_each = toset([
    "roles/secretmanager.secretVersionAdder",
    "roles/secretmanager.secretAccessor",
  ])
  secret_id = google_secret_manager_secret.stripe_webhook_secret.secret_id
  role      = each.value
  member    = "serviceAccount:${google_service_account.billing_catalog_apply.email}"
}

resource "google_storage_bucket_iam_member" "billing_catalog_state" {
  bucket = var.runtime_state_bucket
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.billing_catalog_apply.email}"

  condition {
    title       = "billing-state-prefix-only"
    description = "Only objects under the billing/ state prefix."
    expression  = "resource.name == \"projects/_/buckets/${var.runtime_state_bucket}\" || resource.name.startsWith(\"projects/_/buckets/${var.runtime_state_bucket}/objects/billing/\")"
  }

  # Setting this member requires bootstrap-apply's bucket-policy grant (ci_apply.tf).
  depends_on = [
    google_project_service.this["storage.googleapis.com"],
    google_storage_bucket_iam_member.bootstrap_apply_state_bucket_iam,
  ]
}

output "github_wif_provider" {
  description = "Bootstrap-owned workload identity provider for the billing catalog workflow."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "github_wif_service_account" {
  description = "Bootstrap-owned service account impersonated by the billing catalog workflow."
  value       = google_service_account.billing_catalog_apply.email
}
