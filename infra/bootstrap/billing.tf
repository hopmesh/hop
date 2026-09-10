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

# The private billing apply publishes only the three public Stripe price identifiers into this
# container. Runtime deploy reads one pinned numeric version instead of reading billing state, whose
# object also contains provider-managed secret material.
resource "google_secret_manager_secret" "billing_price_ids" {
  secret_id = "hop-billing-price-ids"

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

# Deployment authority is a closed state machine. Normal plans use terminal hop-only authority. An
# explicit rollback dispatched FROM hop may temporarily re-admit platform main; no phase admits the
# retired monorepo, a branch, or a pull-request ref.
locals {
  github_platform_repository = "hopmesh/platform"
  github_hop_repository      = "hopmesh/hop"
  github_repository_conditions = {
    handoff = "assertion.repository == \"${local.github_platform_repository}\" || assertion.repository == \"${local.github_hop_repository}\""
    hop     = "assertion.repository == \"${local.github_hop_repository}\""
  }
  github_workflow_members = {
    runtime   = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.workflow/${local.github_hop_repository}/.github/workflows/runtime-deploy.yml@refs/heads/main"
    bootstrap = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.workflow/${local.github_hop_repository}/.github/workflows/bootstrap-apply.yml@refs/heads/main"
    billing   = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.workflow/${local.github_hop_repository}/.github/workflows/billing-catalog.yml@refs/heads/main"
    drift     = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.workflow/${local.github_hop_repository}/.github/workflows/infra-drift.yml@refs/heads/main"
  }
  platform_rollback_workflow_members = {
    runtime   = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.workflow/${local.github_platform_repository}/.github/workflows/runtime-deploy.yml@refs/heads/main"
    bootstrap = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.workflow/${local.github_platform_repository}/.github/workflows/handoff-deploy-authority.yml@refs/heads/main"
    billing   = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.workflow/${local.github_platform_repository}/.github/workflows/billing-catalog.yml@refs/heads/main"
  }
}

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-actions"
  display_name              = "GitHub Actions"
  description               = "GitHub Actions OIDC federation for Hop deployment workflows."

  lifecycle {
    ignore_changes = [description]
  }

  depends_on = [google_project_service.this["iam.googleapis.com"]]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub OIDC"
  disabled                           = false

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
    "attribute.workflow"   = "assertion.workflow_ref"
  }

  attribute_condition = local.github_repository_conditions[var.github_authority_phase]

  oidc {
    issuer_uri        = "https://token.actions.githubusercontent.com"
    allowed_audiences = []
  }
}

resource "google_service_account" "billing_catalog_apply" {
  account_id   = "billing-catalog-apply"
  display_name = "GitHub Actions: apply the Stripe billing catalog (TF state only)"

  depends_on = [google_project_service.this["iam.googleapis.com"]]
}

# Billing PR validation is credential-free. The catalog identity accepts only the exact canonical
# billing workflow on main. Explicit rollback temporarily restores the exact platform workflow.
resource "google_service_account_iam_member" "billing_catalog_wif_main" {
  service_account_id = google_service_account.billing_catalog_apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.github_workflow_members.billing
}

resource "google_service_account_iam_member" "billing_catalog_wif_platform_rollback" {
  count              = var.github_authority_phase == "handoff" ? 1 : 0
  service_account_id = google_service_account.billing_catalog_apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.platform_rollback_workflow_members.billing
}

resource "google_secret_manager_secret_iam_member" "billing_catalog_price_ids_writer" {
  secret_id = google_secret_manager_secret.billing_price_ids.secret_id
  role      = "roles/secretmanager.secretVersionAdder"
  member    = "serviceAccount:${google_service_account.billing_catalog_apply.email}"
}

# The catalog apply reads the two vendor credentials it passes to the private providers. These are
# container-scoped read grants; it cannot read any other project secret.
resource "google_secret_manager_secret_iam_member" "billing_catalog_stripe_api_key_reader" {
  secret_id = google_secret_manager_secret.stripe_api_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.billing_catalog_apply.email}"
}

resource "google_secret_manager_secret_iam_member" "billing_catalog_resend_api_key_reader" {
  secret_id = "hop-resend-apikey"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.billing_catalog_apply.email}"

  depends_on = [google_project_service.this["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret_iam_member" "deploy_billing_price_ids_accessor" {
  secret_id = google_secret_manager_secret.billing_price_ids.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.deploy.email}"
}

resource "google_secret_manager_secret_iam_member" "deploy_billing_price_ids_viewer" {
  secret_id = google_secret_manager_secret.billing_price_ids.secret_id
  role      = "roles/secretmanager.viewer"
  member    = "serviceAccount:${google_service_account.deploy.email}"
}

# Explicit rollback restores the one read-only grant the pinned platform runtime still needs. The
# terminal hop phase removes it again and reads only the narrowed billing price secret.
resource "google_storage_bucket_iam_member" "deploy_billing_state_reader" {
  count  = var.github_authority_phase == "handoff" ? 1 : 0
  bucket = var.runtime_state_bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.deploy.email}"

  condition {
    title       = "billing-state-read-only"
    description = "The deployer may read (never write) the isolated billing state for price ids."
    expression  = "resource.name.startsWith(\"projects/_/buckets/${var.runtime_state_bucket}/objects/billing/\")"
  }
}

# The catalog identity writes ONE secret: the Stripe webhook signing secret it just created
# (infra/billing/webhook_secret.tf).
#
# secretVersionManager, not secretVersionAdder. Writing a version is three API calls, not one: the
# provider adds the version, then explicitly enables it, then refreshes it on the next plan. Those
# need versions.add, versions.enable, and versions.get respectively. secretVersionAdder carries only
# versions.add, and secretAccessor carries only versions.access (NOT versions.get, despite the name),
# so the first apply wrote the secret and then died 403 on enable. secretVersionManager covers all
# three and still carries NO versions.access, so the write path cannot read a payload; secretAccessor
# below remains the separate, deliberate read grant. Both stay scoped to that single container, so
# this identity still cannot touch any other secret in the project.
resource "google_secret_manager_secret_iam_member" "billing_catalog_webhook_secret" {
  for_each = toset([
    "roles/secretmanager.secretVersionManager",
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
