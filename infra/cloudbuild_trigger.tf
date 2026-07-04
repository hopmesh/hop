# GitOps build + deploy (no GitHub Actions, no Spacelift): a GitHub-connected Cloud
# Build trigger that, on every push to main, builds + pushes the images AND runs
# `tofu apply` in the same run (see infra/cloudbuild.trigger.yaml). Inert until
# `build_connection_name` names the 2nd-gen connection (Cloud Build GitHub App).
locals {
  build_enabled = var.build_connection_name != ""
  ar_image      = "us-central1-docker.pkg.dev/${var.project_id}/hop/hop-relayd"

  # Deploy tag: explicit relay_image wins; else the commit being deployed
  # (deploy_image_sha = $SHORT_SHA, passed by the Cloud Build apply step); else :latest.
  relay_image = (
    var.relay_image != "" ? var.relay_image :
    length(var.deploy_image_sha) >= 7 ? "${local.ar_image}:${substr(var.deploy_image_sha, 0, 7)}" :
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

# The build + deploy identity. The trigger runs as this SA; it builds + pushes images
# AND runs `tofu apply`, so it needs Artifact Registry write + build logs PLUS the
# broad deploy perms (it manages the whole infra/ module incl. IAM, Cloud Run, LB,
# DNS, Firestore, secrets) PLUS read/write on the GCS state bucket. roles/owner mirrors
# what the retired Spacelift SA held — tighten to a least-privilege custom role later.
resource "google_service_account" "build" {
  count        = local.build_enabled ? 1 : 0
  account_id   = "hop-cloudbuild"
  display_name = "Hop Cloud Build (build + tofu apply)"
}

resource "google_project_iam_member" "build" {
  for_each = local.build_enabled ? toset([
    "roles/cloudbuild.builds.builder",
    "roles/artifactregistry.writer",
    "roles/logging.logWriter",
    # Deploy perms for `tofu apply`. WARNING (F-22): this set is effectively OWNER-EQUIVALENT and the
    # earlier claim that it grants no owner was FALSE. `roles/resourcemanager.projectIamAdmin` carries
    # `resourcemanager.projects.setIamPolicy`, which in this in-org project can grant `roles/owner`; and
    # `roles/secretmanager.admin` includes `versions.access`, so the pipeline can read the relay identity
    # root seed directly. Combined with `tofu apply -auto-approve` on every push, one bad commit to main
    # = full project takeover + fleet identity theft. Bounded today (single-maintainer, main-push
    # required), but before production narrow these: drop projectIamAdmin/secretmanager.admin in favor of
    # specific bindings, and gate IAM-touching changes behind plan-then-approve.
    "roles/editor",
    "roles/resourcemanager.projectIamAdmin", # google_project_iam_member bindings (⚠ can grant owner)
    "roles/iam.serviceAccountAdmin",         # create/manage the build + relay SAs
    "roles/iam.serviceAccountUser",          # Cloud Run deploy runs services as the relay SA
    "roles/run.admin",                       # run service setIamPolicy (allUsers invoker)
    "roles/secretmanager.admin",             # secret setIamPolicy (⚠ also grants versions.access)
    "roles/storage.admin",                   # state-bucket setIamPolicy (build_state below)
    "roles/cloudbuild.connectionAdmin",      # google_cloudbuildv2_repository / connection
  ]) : []
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.build[0].email}"
}

# Explicit state-bucket grant for the apply step (storage.admin covers it project-wide too).
resource "google_storage_bucket_iam_member" "build_state" {
  count  = local.build_enabled ? 1 : 0
  bucket = "hop-mesh-tfstate"
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.build[0].email}"
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
