# GitOps image build (no GitHub Actions): a GitHub-triggered Cloud Build. Reuses the
# Cloud Build GitHub App already installed on hopmesh/hop (1st-gen `github` form, so
# no 2nd-gen connection needed). On push to main it builds + pushes
# hop-relayd:$SHORT_SHA + :latest; Spacelift deploys the $SHORT_SHA tag (derived from
# the run's commit), so build and deploy converge on the commit — no bridge secret.
locals {
  ar_image = "us-central1-docker.pkg.dev/${var.project_id}/hop/hop-relayd"

  # Deploy tag: an explicit relay_image wins; else the commit Spacelift is running
  # (build + deploy converge on it); else :latest as a fallback.
  relay_image = (
    var.relay_image != "" ? var.relay_image :
    length(var.spacelift_commit_sha) >= 7 ? "${local.ar_image}:${substr(var.spacelift_commit_sha, 0, 7)}" :
    "${local.ar_image}:latest"
  )
}

resource "google_cloudbuild_trigger" "image" {
  name     = "hop-relayd-image"
  location = "global"

  github {
    owner = "hopmesh"
    name  = "hop"
    push {
      branch = "^main$"
    }
  }

  filename       = "infra/cloudbuild.trigger.yaml"
  included_files = ["crates/**", "infra/cloudbuild.trigger.yaml"]

  depends_on = [google_project_service.this]
}
