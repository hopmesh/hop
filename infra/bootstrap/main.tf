# Bootstrap: let Spacelift run the infra/ Terraform against GCP via OIDC, with no
# static keys. Spacelift presents an OIDC token; GCP's Workload Identity Pool trusts
# it and lets it impersonate a dedicated service account (chosen mode: SA
# impersonation). Apply this ONCE, locally, as a human.

data "google_project" "this" {
  project_id = var.project_id
}

# APIs needed for the STS token exchange + impersonation at run time.
resource "google_project_service" "this" {
  for_each = toset([
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# The pool that trusts Spacelift-issued OIDC tokens.
resource "google_iam_workload_identity_pool" "spacelift" {
  workload_identity_pool_id = var.pool_id
  display_name              = "Spacelift"
  description               = "OIDC federation for Spacelift runs"
  depends_on                = [google_project_service.this]
}

# The OIDC provider: issuer + audience identify our Spacelift account, and the
# attribute mapping exposes the run's space as attribute.space for scoping.
resource "google_iam_workload_identity_pool_provider" "spacelift" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.spacelift.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = "Spacelift OIDC"

  attribute_mapping = {
    "google.subject"  = "assertion.sub"
    "attribute.space" = "assertion.spaceId"
  }

  oidc {
    issuer_uri        = "https://${var.spacelift_hostname}"
    allowed_audiences = [var.spacelift_hostname]
  }
}

# The automation identity Spacelift impersonates. OIDC-only: it has no keys.
resource "google_service_account" "spacelift" {
  account_id   = var.sa_account_id
  display_name = "Spacelift (OIDC automation)"
  description  = "Impersonated by Spacelift runs in space '${var.spacelift_space_id}' to manage infra/."
}

# What the SA may do in the project (broad — it owns the whole infra/ module).
resource "google_project_iam_member" "spacelift" {
  for_each = toset(var.sa_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.spacelift.email}"
}

# Only Spacelift runs in space '<spacelift_space_id>' may impersonate the SA.
resource "google_service_account_iam_member" "impersonate" {
  service_account_id = google_service_account.spacelift.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.spacelift.name}/attribute.space/${var.spacelift_space_id}"
}

# The credential-config Spacelift mounts (GOOGLE_APPLICATION_CREDENTIALS points here).
# Contains no secrets — only federation wiring (the real secret is the per-run OIDC
# token Spacelift drops at credential_source.file). It's gitignored anyway: the copy
# the stack uses is mounted into the stack env via `spacectl stack environment mount`,
# and this resource regenerates it locally on demand.
locals {
  credential_config = {
    type               = "external_account"
    audience           = "//iam.googleapis.com/${google_iam_workload_identity_pool_provider.spacelift.name}"
    subject_token_type = "urn:ietf:params:oauth:token-type:jwt"
    token_url          = "https://sts.googleapis.com/v1/token"
    credential_source = {
      file = "/mnt/workspace/spacelift.oidc"
    }
    service_account_impersonation_url = "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${google_service_account.spacelift.email}:generateAccessToken"
    service_account_impersonation = {
      token_lifetime_seconds = 3600
    }
  }
}

resource "local_file" "credential_config" {
  filename        = "${path.module}/../spacelift-gcp-credentials.json"
  content         = jsonencode(local.credential_config)
  file_permission = "0644"
}
