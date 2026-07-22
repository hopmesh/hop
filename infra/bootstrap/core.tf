locals {
  # Only the APIs the runtime + bootstrap roots actually consume. Cloud Build, Cloud KMS, Pub/Sub, and
  # Container Analysis were part of the deleted GCP-side deploy trust apparatus (images now build in
  # GitHub Actions, which applies the runtime root via WIF), so they are no longer enabled here.
  services = toset([
    "artifactregistry.googleapis.com",
    "bigquery.googleapis.com",
    "certificatemanager.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "dns.googleapis.com",
    "firestore.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "serviceusage.googleapis.com",
    # Cloud SQL Admin: the hop_console Postgres instance backing hop-accountd (console.tf).
    "sqladmin.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ])
  relay_image_repository   = "${var.region}-docker.pkg.dev/${var.project_id}/hop/hop-relayd"
  example_image_repository = "${var.region}-docker.pkg.dev/${var.project_id}/hop/hop-example"
}

resource "google_project_service" "this" {
  for_each = local.services

  service            = each.value
  disable_on_destroy = false
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
