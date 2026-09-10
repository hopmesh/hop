locals {
  # hop-deploy is the runtime applier. GitHub Actions authenticates as it over WIF (runtime_deploy.tf)
  # and it holds ONLY the project roles the runtime root needs. It has no administrative authority: no
  # project/service-account/secret IAM admin, no API enablement, no role mutation.
  deploy_project_roles = toset([
    "roles/bigquery.dataEditor",
    "roles/certificatemanager.editor",
    "roles/compute.loadBalancerAdmin",
    "roles/dns.admin",
    "roles/logging.configWriter",
    "roles/logging.logWriter",
    "roles/monitoring.editor",
    "roles/run.developer",
    "roles/serviceusage.serviceUsageConsumer",
  ])
  relay_project_roles = toset([
    "roles/datastore.user",
    "roles/logging.logWriter",
  ])
  example_project_roles = toset([
    "roles/logging.logWriter",
  ])
}

# hop-cloudbuild was the low-privilege Cloud Build source builder. Cloud Build is deleted (images now
# build in GitHub Actions, which applies the runtime root via WIF), so this identity is no longer
# managed here. It is still live in the project, so it is dropped from management WITHOUT a destroy and
# torn down out of band once the legacy trigger and its Cloud Build repository are removed. Never plan a
# destroy on it from this reviewed apply.
removed {
  from = google_service_account.build

  lifecycle {
    destroy = false
  }
}

resource "google_service_account" "deploy" {
  account_id   = "hop-deploy"
  display_name = "Hop runtime deployer (GitHub Actions via WIF)"

  depends_on = [google_project_service.this["iam.googleapis.com"]]
}

resource "google_service_account" "relay" {
  account_id   = "hop-relay"
  display_name = "Hop relay runtime"

  depends_on = [google_project_service.this["iam.googleapis.com"]]
}

resource "google_service_account" "example" {
  account_id   = "hop-example"
  display_name = "Hop public example runtime"

  depends_on = [google_project_service.this["iam.googleapis.com"]]
}

resource "google_project_iam_member" "deploy" {
  for_each = local.deploy_project_roles
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.deploy.email}"
}

resource "google_project_iam_member" "relay" {
  for_each = local.relay_project_roles
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.relay.email}"
}

resource "google_project_iam_member" "example" {
  for_each = local.example_project_roles
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.example.email}"
}

# The deployer may attach only the two pre-created runtime identities to Cloud Run.
resource "google_service_account_iam_member" "deploy_uses_relay" {
  service_account_id = google_service_account.relay.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.deploy.email}"
}

resource "google_service_account_iam_member" "deploy_uses_example" {
  service_account_id = google_service_account.example.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.deploy.email}"
}

# hop-deploy builds and pushes the relay + example images from the GitHub Actions runtime-deploy
# workflow, then applies the runtime root, so it needs write on the hop repository (build/push) and
# read (the Cloud Run apply resolves the pushed digests).
resource "google_artifact_registry_repository_iam_member" "deploy_writer" {
  project    = var.project_id
  location   = google_artifact_registry_repository.hop.location
  repository = google_artifact_registry_repository.hop.repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.deploy.email}"
}

resource "google_artifact_registry_repository_iam_member" "deploy_reader" {
  project    = var.project_id
  location   = google_artifact_registry_repository.hop.location
  repository = google_artifact_registry_repository.hop.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.deploy.email}"
}

resource "google_secret_manager_secret_iam_member" "relay_identity" {
  secret_id = google_secret_manager_secret.relay_identity.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.relay.email}"
}

resource "google_secret_manager_secret_iam_member" "example_identity" {
  secret_id = google_secret_manager_secret.example_identity.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.example.email}"
}

# The only storage authority the deployer has: list the backend bucket and mutate objects under the
# runtime state prefix. It cannot reach the bootstrap or billing state prefixes.
resource "google_storage_bucket_iam_member" "deploy_state" {
  bucket = var.runtime_state_bucket
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.deploy.email}"

  condition {
    title       = "runtime-state-only"
    description = "The deployer can list the backend bucket and mutate only runtime state objects."
    expression  = "resource.name == 'projects/_/buckets/${var.runtime_state_bucket}' || resource.name.startsWith('projects/_/buckets/${var.runtime_state_bucket}/objects/${var.runtime_state_prefix}/')"
  }

  # Setting this member requires bootstrap-apply's bucket-policy grant (ci_apply.tf).
  depends_on = [google_storage_bucket_iam_member.bootstrap_apply_state_bucket_iam]
}

# Retain the legacy role id so bootstrap can remove its old setIamPolicy permission
# without deleting an applied custom role. It is not granted to any runtime identity.
resource "google_project_iam_custom_role" "build_secrets" {
  role_id     = "hopCloudBuildSecrets"
  title       = "Hop bootstrap secret metadata"
  description = "Legacy bootstrap-only secret metadata role. No policy or version-data access."
  permissions = [
    "secretmanager.secrets.create",
    "secretmanager.secrets.delete",
    "secretmanager.secrets.get",
    "secretmanager.secrets.getIamPolicy",
    "secretmanager.secrets.list",
    "secretmanager.secrets.update",
    "secretmanager.versions.get",
    "secretmanager.versions.list",
  ]
}

# The relay seed is protected by the allow-side restriction alone: the accessor binding
# below grants secretmanager.secretAccessor on hop-relay-identity to the relay runtime
# identity and to nothing else, and the runtime authority guard asserts that (including
# that the deploy identity never gets it).
#
# A google_iam_deny_policy hard-deny used to sit here as defense in depth. It is removed
# because GCP will not let this project's applier hold the permission to manage it:
# roles/iam.denyAdmin is rejected at the project level ("not supported for this
# resource"), and iam.denypolicies.create cannot be carried by a custom role. The only
# way to enable it is granting the project-scoped applier ORG-level deny admin, which is
# a wider privilege than the control it buys. The policy was never applied (absent from
# bootstrap state), so nothing live changes.
