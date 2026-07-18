# Workload Identity Federation: let GitHub Actions authenticate to GCP WITHOUT a long-lived key
# (no service-account JSON in a GitHub secret). Used by the billing-catalog workflow to reach the
# GCS-backed Terraform state for infra/billing. Keyless + short-lived (OIDC), scoped to exactly one
# repo and one least-privilege service account.

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-actions"
  display_name              = "GitHub Actions"
  description               = "OIDC federation for hopmesh/monorepo GitHub Actions workflows."
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

  # Only tokens from THIS repo may exchange for a GCP credential. A fork's OIDC token carries the
  # fork's repository claim and fails here, so a fork PR can never assume the service account.
  attribute_condition = "assertion.repository == \"hopmesh/monorepo\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# The identity the billing-catalog workflow assumes. It needs GCS state access only: the catalog
# itself is all Stripe resources (created via the Stripe provider + the GitHub STRIPE_API_KEY
# secret), so this SA gets NO Stripe access and NO other GCP permissions.
resource "google_service_account" "billing_catalog_apply" {
  account_id   = "billing-catalog-apply"
  display_name = "GitHub Actions: apply the Stripe billing catalog (TF state only)"
}

# Only workflows from hopmesh/monorepo can impersonate the SA (the repo-scoped principalSet).
resource "google_service_account_iam_member" "billing_catalog_wif" {
  service_account_id = google_service_account.billing_catalog_apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/hopmesh/monorepo"
}

# Least privilege: read/write ONLY the billing/ prefix of the shared state bucket (an IAM condition
# on the object name), so this identity can never touch the relay-fleet state alongside it.
resource "google_storage_bucket_iam_member" "billing_catalog_state" {
  bucket = "hop-mesh-tfstate"
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.billing_catalog_apply.email}"

  condition {
    title       = "billing-state-prefix-only"
    description = "Only objects under the billing/ state prefix."
    expression  = "resource.name.startsWith(\"projects/_/buckets/hop-mesh-tfstate/objects/billing/\")"
  }
}

output "github_wif_provider" {
  description = "workload_identity_provider for the GitHub Actions google-github-actions/auth step."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "github_wif_service_account" {
  description = "service_account email the billing-catalog workflow impersonates."
  value       = google_service_account.billing_catalog_apply.email
}
