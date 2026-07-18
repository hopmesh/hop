locals {
  services = toset([
    "artifactregistry.googleapis.com",
    "bigquery.googleapis.com",
    "certificatemanager.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudkms.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "containeranalysis.googleapis.com",
    "dns.googleapis.com",
    "firestore.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "pubsub.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ])
  relay_image_repository   = "${var.region}-docker.pkg.dev/${var.project_id}/hop/hop-relayd"
  example_image_repository = "${var.region}-docker.pkg.dev/${var.project_id}/hop/hop-example"
  build_identity           = google_service_account.build.email
  deploy_identity          = google_service_account.deploy.email
  cloudbuild_service_agent = google_project_service_identity.cloudbuild.email
  github_expected = {
    repository     = var.github_repository
    repository_id  = var.github_repository_id
    actions_app_id = var.github_actions_app_id
    canonical_ref  = "refs/heads/main"
    workflows = [{
      id     = var.github_ci_workflow_id
      path   = ".github/workflows/ci.yml"
      sha256 = var.github_ci_workflow_sha256
      checks = var.github_required_checks
    }]
  }
}

resource "google_project_service" "this" {
  for_each = local.services

  service            = each.value
  disable_on_destroy = false
}

resource "google_project_service_identity" "cloudbuild" {
  provider = google-beta

  project = var.project_id
  service = "cloudbuild.googleapis.com"

  depends_on = [google_project_service.this["cloudbuild.googleapis.com"]]
}

resource "google_artifact_registry_repository" "hop" {
  location      = var.region
  repository_id = "hop"
  description   = "Hop container images."
  format        = "DOCKER"

  depends_on = [google_project_service.this]
}

resource "google_firestore_database" "relay" {
  name        = "(default)"
  location_id = var.firestore_location
  type        = "FIRESTORE_NATIVE"

  deletion_policy = "ABANDON"

  depends_on = [google_project_service.this]
}

resource "google_firestore_field" "bundle_ttl" {
  database   = google_firestore_database.relay.name
  collection = "bundles"
  field      = "expireAt"

  ttl_config {}
  index_config {}
}

resource "google_firestore_field" "presence_ttl" {
  database   = google_firestore_database.relay.name
  collection = "presence"
  field      = "expireAt"

  ttl_config {}
  index_config {}
}

resource "google_firestore_field" "registry_ttl" {
  database   = google_firestore_database.relay.name
  collection = "registry"
  field      = "expireAt"

  ttl_config {}
  index_config {}
}

# Critical mutation idempotency/readiness markers outlive every HTTP retry, then expire so proof is
# bounded without allowing a delayed in-process retry to reapply the same transaction.
resource "google_firestore_field" "operation_ttl" {
  database   = google_firestore_database.relay.name
  collection = "operations"
  field      = "expireAt"

  ttl_config {}
  index_config {}
}

resource "google_secret_manager_secret" "relay_identity" {
  secret_id = "hop-relay-identity"

  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.this]
}

resource "google_secret_manager_secret" "example_identity" {
  secret_id = "hop-example-identity"

  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.this]
}

resource "google_secret_manager_secret" "ci_readtoken" {
  secret_id = "hop-ci-readtoken"

  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.this]
}

resource "google_storage_bucket" "deploy_control" {
  name                        = var.control_bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      days_since_noncurrent_time = 30
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.this["storage.googleapis.com"]]
}

resource "google_kms_key_ring" "provenance" {
  name     = "hop-provenance"
  location = var.region

  depends_on = [google_project_service.this]
}

resource "google_kms_crypto_key" "provenance" {
  name     = "build-manifest"
  key_ring = google_kms_key_ring.provenance.id
  purpose  = "ASYMMETRIC_SIGN"

  version_template {
    algorithm = "EC_SIGN_P256_SHA256"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_pubsub_topic" "deploy_requests" {
  name = "hop-deploy-requests"

  message_retention_duration = "86400s"

  depends_on = [google_project_service.this]
}
