# GitOps image build: a GitHub-connected Cloud Build trigger (no GitHub Actions).
# Inert until `build_connection_name` names the 2nd-gen connection created via the
# Cloud Build GitHub App (console, one-time). On push to main it builds + pushes
# hop-relayd:$SHORT_SHA; Spacelift deploys that same tag (derived from the run's
# commit), so build and deploy converge on the commit with no bridge secret.
locals {
  build_enabled = var.build_connection_name != ""
  ar_image      = "us-central1-docker.pkg.dev/${var.project_id}/hop/hop-relayd"

  # Deploy tag: an explicit relay_image wins; else the commit Spacelift is running
  # (build + deploy converge on it); else :latest as a fallback.
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

  filename       = "infra/cloudbuild.trigger.yaml"
  included_files = ["crates/**", "infra/cloudbuild.trigger.yaml"]

  depends_on = [google_project_service.this]
}
