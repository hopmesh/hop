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
# deploy perms (it manages the whole infra/ module incl. IAM, Cloud Run, LB, DNS,
# Firestore, secret containers) PLUS read/write on the GCS state bucket. infra-02: the
# seed-reading grant (secretmanager.admin) has been removed in favor of the scoped custom
# role below; projectIamAdmin is the one remaining broad grant, documented on the binding.
resource "google_service_account" "build" {
  count        = local.build_enabled ? 1 : 0
  account_id   = "hop-cloudbuild"
  display_name = "Hop Cloud Build (build + tofu apply)"
}

# infra-02: a custom role for the secret-management this module actually does, so the build SA does
# NOT hold `roles/secretmanager.admin` (which carries `secretmanager.versions.access` = the ability to
# read the relay identity ROOT SEED). The module only ever: creates the secret CONTAINER
# (secrets.tf, no version), sets secret IAM policy (secret_iam_member in iam.tf + example.tf), and
# reads secret METADATA via a data source (example.tf, `secrets.get`, not the version bytes). None of
# that needs versions.access. This closes the "one bad main commit exfiltrates the fleet seed" vector
# while leaving `tofu apply` fully functional. Seeding a version is still done out-of-band by a human
# (see secrets.tf), never by this pipeline.
resource "google_project_iam_custom_role" "build_secrets" {
  count       = local.build_enabled ? 1 : 0
  role_id     = "hopCloudBuildSecrets"
  title       = "Hop Cloud Build - secret container + IAM (no versions.access)"
  description = "Manage secret containers and their IAM bindings without the ability to read secret version bytes (infra-02)."
  permissions = [
    "secretmanager.secrets.create",
    "secretmanager.secrets.get",
    "secretmanager.secrets.list",
    "secretmanager.secrets.update",
    "secretmanager.secrets.delete",
    "secretmanager.secrets.getIamPolicy",
    "secretmanager.secrets.setIamPolicy",
    # version metadata only (enable/disable/list) - NOT versions.access, which reads the bytes.
    "secretmanager.versions.get",
    "secretmanager.versions.list",
  ]
}

resource "google_project_iam_member" "build" {
  for_each = local.build_enabled ? toset([
    "roles/cloudbuild.builds.builder",
    "roles/artifactregistry.writer",
    "roles/logging.logWriter",
    # Deploy perms for `tofu apply`. The pipeline manages the whole infra/ module (IAM bindings, Cloud
    # Run, LB, DNS, Firestore, secret containers) so it is a high-privilege identity by necessity.
    # infra-02 status:
    #   - secretmanager.admin: REMOVED. Replaced by the custom role above (secret containers + IAM,
    #     no versions.access), so the pipeline can no longer read the relay identity seed. [CLOSED]
    #   - projectIamAdmin: RETAINED. The module applies google_project_iam_member bindings (relay SA
    #     roles, this SA's own roles), which requires resourcemanager.projects.setIamPolicy; there is
    #     no resource-scoped substitute for project-level IAM. This still carries the theoretical
    #     "grant self owner" path, so it is the residual broad grant. Mitigation before production:
    #     gate IAM-touching TF changes behind plan-then-approve instead of -auto-approve on every push
    #     (bounded today by single-maintainer + required main-push + the CI deploy gate). [DOCUMENTED]
    "roles/editor",
    "roles/resourcemanager.projectIamAdmin",            # google_project_iam_member bindings (⚠ residual: can grant owner; see note)
    "roles/iam.serviceAccountAdmin",                    # create/manage the build + relay SAs
    "roles/iam.serviceAccountUser",                     # Cloud Run deploy runs services as the relay SA
    "roles/run.admin",                                  # run service setIamPolicy (allUsers invoker)
    "roles/storage.admin",                              # state-bucket setIamPolicy (build_state below)
    "roles/cloudbuild.connectionAdmin",                 # google_cloudbuildv2_repository / connection
    "roles/logging.admin",                              # observability.tf log bucket + sink + exclusion (editor lacks buckets.create)
    google_project_iam_custom_role.build_secrets[0].id, # secret containers + IAM, NO versions.access (infra-02)
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
