# GitOps image build (no GitHub Actions): a GitHub-connected Cloud Build trigger.
# Inert until `build_connection_name` names the 2nd-gen connection (Cloud Build GitHub
# App). On push to main it builds + pushes hop-relayd:$SHORT_SHA + :latest; Spacelift
# deploys the $SHORT_SHA tag (derived from the run's commit), so build and deploy
# converge on the commit with no bridge secret.
locals {
  build_enabled = var.build_connection_name != ""
  ar_image      = "us-central1-docker.pkg.dev/${var.project_id}/hop/hop-relayd"

  # Deploy tag: explicit relay_image wins; else the commit Spacelift is running; else :latest.
  relay_image = (
    var.relay_image != "" ? var.relay_image :
    length(var.spacelift_commit_sha) >= 7 ? "${local.ar_image}:${substr(var.spacelift_commit_sha, 0, 7)}" :
    "${local.ar_image}:latest"
  )
}

resource "google_cloudbuildv2_repository" "hop" {
  count             = local.build_enabled ? 1 : 0
  name              = "hop"
  location          = "us-central1"
  parent_connection = "projects/${var.project_id}/locations/us-central1/connections/${var.build_connection_name}"
  remote_uri        = "https://github.com/hopmesh/hop.git"
}

# Dedicated build identity. This (fresh) project has no legacy Cloud Build SA, so a
# trigger MUST specify its own service account; needs to push to Artifact Registry
# and write build logs.
resource "google_service_account" "build" {
  count        = local.build_enabled ? 1 : 0
  account_id   = "hop-cloudbuild"
  display_name = "Hop Cloud Build"
}

resource "google_project_iam_member" "build" {
  for_each = local.build_enabled ? toset([
    "roles/cloudbuild.builds.builder",
    "roles/artifactregistry.writer",
    "roles/logging.logWriter",
  ]) : []
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.build[0].email}"
}

resource "google_cloudbuild_trigger" "image" {
  count    = local.build_enabled ? 1 : 0
  name     = "hop-relayd-image"
  location = "us-central1"

  repository_event_config {
    repository = google_cloudbuildv2_repository.hop[0].id
    push {
      branch = "^main$"
    }
  }

  filename = "infra/cloudbuild.trigger.yaml"
  # Build on EVERY push to main (no path filter): the deploy derives the image tag from
  # the commit sha, so every commit must have a matching image (else the deploy can't
  # find it). Builds are cheap (~2-3 min) and produce a fresh :$SHORT_SHA each time.
  service_account = google_service_account.build[0].id

  depends_on = [google_project_service.this, google_project_iam_member.build]
}
