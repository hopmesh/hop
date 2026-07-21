# Keyless identity for the automatic runtime deploy (.github/workflows/runtime-deploy.yml).
#
# GitHub is change management: a merge to main that goes green triggers the runtime-deploy workflow,
# which authenticates as hop-deploy over Workload Identity Federation (no key, no JSON) and applies the
# runtime root. GCP is plumbing: it runs what GitHub blessed and verifies nothing about the change.
#
# The OIDC subject is exact: only a push-driven run on refs/heads/main can mint a token for hop-deploy.
# A pull request ref, a tag, or any other branch mints no credentials at all. The WIF pool + provider
# are the shared bootstrap-owned github-actions pool declared in billing.tf.
resource "google_service_account_iam_member" "deploy_runtime_wif" {
  service_account_id = google_service_account.deploy.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/subject/repo:${var.github_repository}:ref:refs/heads/main"
}

output "runtime_wif_provider" {
  description = "Workload identity provider for the runtime-deploy workflow (repo variable GCP_RUNTIME_WIF_PROVIDER)."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "runtime_wif_service_account" {
  description = "Service account impersonated by the runtime-deploy workflow (repo variable GCP_RUNTIME_SERVICE_ACCOUNT)."
  value       = google_service_account.deploy.email
}
