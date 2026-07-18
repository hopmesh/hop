locals {
  build_project_roles = toset([
    "roles/logging.logWriter",
  ])
  deploy_project_roles = toset([
    "roles/certificatemanager.editor",
    "roles/cloudbuild.builds.viewer",
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

resource "google_service_account" "build" {
  account_id   = "hop-cloudbuild"
  display_name = "Hop untrusted source builder"

  depends_on = [google_project_service.this["iam.googleapis.com"]]
}

resource "google_service_account" "deploy" {
  account_id   = "hop-deploy"
  display_name = "Hop trusted runtime deployer"

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

resource "google_project_iam_member" "build" {
  for_each = local.build_project_roles
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.build.email}"
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

resource "google_project_iam_member" "deploy_approver" {
  project = var.project_id
  role    = "roles/cloudbuild.builds.approver"
  member  = "group:${var.deploy_approver_group}"
}

# Cloud Build's service agent may mint short-lived credentials for the two build
# identities. Neither identity may impersonate the other.
resource "google_service_account_iam_member" "cloudbuild_uses_build" {
  service_account_id = google_service_account.build.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${local.cloudbuild_service_agent}"
}

resource "google_service_account_iam_member" "cloudbuild_uses_deploy" {
  service_account_id = google_service_account.deploy.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${local.cloudbuild_service_agent}"
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

resource "google_artifact_registry_repository_iam_member" "build_writer" {
  project    = var.project_id
  location   = google_artifact_registry_repository.hop.location
  repository = google_artifact_registry_repository.hop.repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.build.email}"
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

resource "google_secret_manager_secret_iam_member" "build_ci_token" {
  secret_id = google_secret_manager_secret.ci_readtoken.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.build.email}"
}

resource "google_secret_manager_secret_iam_member" "deploy_ci_token" {
  secret_id = google_secret_manager_secret.ci_readtoken.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.deploy.email}"
}

resource "google_kms_crypto_key_iam_member" "build_signer" {
  crypto_key_id = google_kms_crypto_key.provenance.id
  role          = "roles/cloudkms.signerVerifier"
  member        = "serviceAccount:${google_service_account.build.email}"
}

resource "google_kms_crypto_key_iam_member" "deploy_public_key" {
  crypto_key_id = google_kms_crypto_key.provenance.id
  role          = "roles/cloudkms.publicKeyViewer"
  member        = "serviceAccount:${google_service_account.deploy.email}"
}

resource "google_pubsub_topic_iam_member" "build_handoff" {
  topic  = google_pubsub_topic.deploy_requests.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.build.email}"
}

resource "google_storage_bucket_iam_member" "build_provenance_creator" {
  bucket = google_storage_bucket.deploy_control.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.build.email}"

  condition {
    title       = "immutable-provenance-only"
    description = "The source builder can create, but not read, replace, or delete, build provenance objects."
    expression  = "resource.name.startsWith('projects/_/buckets/${google_storage_bucket.deploy_control.name}/objects/provenance/')"
  }
}

resource "google_storage_bucket_iam_member" "deploy_provenance_viewer" {
  bucket = google_storage_bucket.deploy_control.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.deploy.email}"

  condition {
    title       = "trusted-inputs-only"
    description = "The deployer can read bootstrap and provenance inputs but cannot replace them."
    expression  = "resource.name.startsWith('projects/_/buckets/${google_storage_bucket.deploy_control.name}/objects/provenance/') || resource.name == 'projects/_/buckets/${google_storage_bucket.deploy_control.name}/objects/${local.contract_object}'"
  }
}

resource "google_storage_bucket_iam_member" "deploy_lease" {
  bucket = google_storage_bucket.deploy_control.name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.deploy.email}"

  condition {
    title       = "global-deployment-lease-only"
    description = "The deployer can mutate only the global control-plane lease object."
    expression  = "resource.name == 'projects/_/buckets/${google_storage_bucket.deploy_control.name}/objects/${local.lease_object}'"
  }
}

resource "google_storage_bucket_iam_member" "deploy_state" {
  bucket = var.runtime_state_bucket
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.deploy.email}"

  condition {
    title       = "runtime-state-only"
    description = "The deployer can list the backend bucket and mutate only runtime state objects."
    expression  = "resource.name == 'projects/_/buckets/${var.runtime_state_bucket}' || resource.name.startsWith('projects/_/buckets/${var.runtime_state_bucket}/objects/${var.runtime_state_prefix}/')"
  }
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

# Defense in depth: every principal is denied relay seed bytes except the dedicated
# relay runtime identity. Project administrators can change this only through the
# separately invoked bootstrap process, not through the runtime deploy account.
resource "google_iam_deny_policy" "relay_seed" {
  parent       = urlencode("cloudresourcemanager.googleapis.com/projects/${var.project_id}")
  name         = "deny-relay-seed"
  display_name = "Only the Hop relay runtime may read the relay seed"

  rules {
    description = "Deny relay identity version access to every principal except hop-relay."
    deny_rule {
      denied_principals = ["principalSet://goog/public:all"]
      exception_principals = [
        "principal://iam.googleapis.com/projects/-/serviceAccounts/${google_service_account.relay.email}",
      ]
      denied_permissions = ["secretmanager.googleapis.com/versions.access"]

      denial_condition {
        title      = "relay-seed-only"
        expression = "resource.name.endsWith('/secrets/hop-relay-identity') || resource.name.contains('/secrets/hop-relay-identity/')"
      }
    }
  }

  depends_on = [google_secret_manager_secret.relay_identity]
}
