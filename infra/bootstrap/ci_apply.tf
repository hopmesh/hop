# CI apply path for this bootstrap root (.github/workflows/bootstrap-apply.yml).
#
# WHY THIS EXISTS: bootstrap used to be applied from an operator's terminal. A local apply against
# GCS-backed state is a destroy operation whenever the local checkout is behind: everything present in
# remote state but absent from the local configuration is planned for deletion, and this root owns IAM,
# service accounts, secrets, and KMS keys. `prevent_destroy` turns that into a half-applied root, not a
# safe refusal. The workflow always applies the exact bytes of canonical `main`, so the plan is a
# function of a reviewed commit rather than of whatever the operator last pulled.
#
# AUTHORITY: this identity is a project IAM administrator. That is not an oversight, it is what
# applying this root requires. It is deliberately SEPARATE from `hop-deploy` (the automatic
# push-to-main runtime applier), which must keep zero administrative authority, and from
# `hop-cloudbuild`. Neither of those accounts gains a single permission from this file. The controls on
# this identity are therefore: it is reachable only through GitHub OIDC, only from this repository,
# only from the two exact token subjects below, and only from a manually dispatched workflow.
locals {
  # Predefined roles this root genuinely needs. Each is annotated with the resource that forces it.
  # Anything narrower fails the apply, which is a loud failure, not a silent one.
  bootstrap_apply_project_roles = toset([
    # google_project_service.this, google_project_service_identity.cloudbuild
    "roles/serviceusage.serviceUsageAdmin",
    # google_service_account.* and every google_service_account_iam_member
    "roles/iam.serviceAccountAdmin",
    # every google_project_iam_member. This is the powerful one: it can grant any role to any
    # principal, including itself. Bootstrap owns project IAM, so it cannot be avoided.
    "roles/resourcemanager.projectIamAdmin",
    # google_project_iam_custom_role.build_secrets and .bootstrap_apply_secrets
    "roles/iam.roleAdmin",
    # google_iam_deny_policy.relay_seed
    "roles/iam.denyAdmin",
    # google_iam_workload_identity_pool.github and its provider
    "roles/iam.workloadIdentityPoolAdmin",
    # google_artifact_registry_repository.hop and its repository IAM
    "roles/artifactregistry.admin",
    # google_firestore_database.relay and the four google_firestore_field TTL policies. Unavoidably
    # broad: it also carries Firestore entity read/write, so it can see the relay bundle store.
    "roles/datastore.owner",
    # google_kms_key_ring.provenance and google_kms_crypto_key.provenance plus their IAM. Excludes the
    # crypto operations themselves, so this role cannot sign a provenance manifest.
    "roles/cloudkms.admin",
    # google_pubsub_topic.deploy_requests and its IAM. Editor cannot setIamPolicy, so admin it is.
    "roles/pubsub.admin",
    # google_cloudbuild_trigger.source and .deploy
    "roles/cloudbuild.builds.editor",
    # google_cloudbuildv2_repository.hop, which is created under the existing GitHub App connection
    "roles/cloudbuild.connectionAdmin",
  ])

  # GitHub mints a different `sub` claim once a job declares an environment, so the plan job and the
  # reviewer-gated apply job need separate bindings. Both are exact subjects, not principalSets: a
  # workflow run on any other ref, or an apply job that did not go through the environment, gets no
  # token at all.
  bootstrap_apply_plan_subject  = "repo:${var.github_repository}:ref:refs/heads/main"
  bootstrap_apply_apply_subject = "repo:${var.github_repository}:environment:${var.github_bootstrap_environment}"
  bootstrap_apply_principal     = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/subject"
}

resource "google_service_account" "bootstrap_apply" {
  account_id   = "bootstrap-apply"
  display_name = "GitHub Actions: apply infra/bootstrap from canonical main"

  depends_on = [google_project_service.this["iam.googleapis.com"]]
}

# The plan job runs without a GitHub environment, so its token subject is the ref form.
resource "google_service_account_iam_member" "bootstrap_apply_wif_plan" {
  service_account_id = google_service_account.bootstrap_apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "${local.bootstrap_apply_principal}/${local.bootstrap_apply_plan_subject}"
}

# The apply job declares the environment, so its token subject is the environment form. Required
# reviewers and the environment's deployment-branch policy are GitHub repository settings; this root
# does not create them and does not pretend to.
resource "google_service_account_iam_member" "bootstrap_apply_wif_apply" {
  service_account_id = google_service_account.bootstrap_apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "${local.bootstrap_apply_principal}/${local.bootstrap_apply_apply_subject}"
}

resource "google_project_iam_member" "bootstrap_apply" {
  for_each = local.bootstrap_apply_project_roles
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.bootstrap_apply.email}"
}

# Secret containers and their IAM bindings, WITHOUT any access to version payloads. Bootstrap creates
# empty containers and grants accessors; the bytes are seeded out of band and must never be readable
# by the identity that happens to be applying. `roles/secretmanager.admin` would hand this identity
# every stored secret, so it is deliberately not used. Delete is omitted too: removing a secret from
# the configuration should fail the apply rather than destroy a container.
resource "google_project_iam_custom_role" "bootstrap_apply_secrets" {
  role_id     = "hopBootstrapApplySecrets"
  title       = "Hop bootstrap CI secret containers"
  description = "Create and bind secret containers from CI. No version data, no deletion."
  permissions = [
    "secretmanager.secrets.create",
    "secretmanager.secrets.get",
    "secretmanager.secrets.getIamPolicy",
    "secretmanager.secrets.list",
    "secretmanager.secrets.setIamPolicy",
    "secretmanager.secrets.update",
  ]
}

resource "google_project_iam_member" "bootstrap_apply_secrets" {
  project = var.project_id
  role    = google_project_iam_custom_role.bootstrap_apply_secrets.id
  member  = "serviceAccount:${google_service_account.bootstrap_apply.email}"
}

# The deploy control bucket is bootstrap-owned (bucket config, IAM conditions, and the bootstrap
# contract object), so the grant is bucket-scoped rather than a project-wide storage role. Creating
# the bucket from nothing needs project-level storage.buckets.create, which is intentionally NOT
# granted: the bucket exists, and a CI identity should not be able to mint new buckets.
resource "google_storage_bucket_iam_member" "bootstrap_apply_control" {
  bucket = google_storage_bucket.deploy_control.name
  role   = "roles/storage.admin"
  member = "serviceAccount:${google_service_account.bootstrap_apply.email}"
}

# State access is the `bootstrap/` prefix only, matching this root's backend. The bucket itself is
# allowed so the GCS backend can list; runtime (`relay-fleet/`) and `billing/` state stay unreachable.
resource "google_storage_bucket_iam_member" "bootstrap_apply_state" {
  bucket = var.runtime_state_bucket
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.bootstrap_apply.email}"

  condition {
    title       = "bootstrap-state-prefix-only"
    description = "Only the backend bucket listing and objects under the bootstrap/ state prefix."
    expression  = "resource.name == \"projects/_/buckets/${var.runtime_state_bucket}\" || resource.name.startsWith(\"projects/_/buckets/${var.runtime_state_bucket}/objects/bootstrap/\")"
  }

  depends_on = [google_project_service.this["storage.googleapis.com"]]
}

output "bootstrap_wif_provider" {
  description = "Workload identity provider for the bootstrap-apply workflow (repo variable GCP_BOOTSTRAP_WIF_PROVIDER)."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "bootstrap_wif_service_account" {
  description = "Service account impersonated by the bootstrap-apply workflow (repo variable GCP_BOOTSTRAP_SERVICE_ACCOUNT)."
  value       = google_service_account.bootstrap_apply.email
}
