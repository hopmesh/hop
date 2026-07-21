# CI apply path for this bootstrap root (.github/workflows/bootstrap-apply.yml).
#
# WHY THIS EXISTS: bootstrap used to be applied from an operator's terminal. A local apply against
# GCS-backed state is a destroy operation whenever the local checkout is behind: everything present in
# remote state but absent from the local configuration is planned for deletion, and this root owns IAM,
# service accounts, secrets, and WIF. `prevent_destroy` turns that into a half-applied root, not a safe
# refusal. The workflow always applies the exact bytes of canonical `main`, so the plan is a function of
# a reviewed commit rather than of whatever the operator last pulled.
#
# AUTHORITY: this identity is a project IAM administrator. That is not an oversight, it is what applying
# this root requires. It is deliberately SEPARATE from `hop-deploy` (the automatic push-to-main runtime
# applier, runtime_deploy.tf), which must keep zero administrative authority. hop-deploy gains no
# permission from this file. The controls on this identity are: it is reachable only through GitHub
# OIDC, only from this repository, only from the single exact token subject below (a push-driven run on
# refs/heads/main), and only from a manually dispatched workflow.
locals {
  # Predefined roles this root genuinely needs. Each is annotated with the resource that forces it.
  # Anything narrower fails the apply, which is a loud failure, not a silent one.
  bootstrap_apply_project_roles = toset([
    # google_project_service.this
    "roles/serviceusage.serviceUsageAdmin",
    # google_service_account.* and every google_service_account_iam_member
    "roles/iam.serviceAccountAdmin",
    # every google_project_iam_member. This is the powerful one: it can grant any role to any
    # principal, including itself. Bootstrap owns project IAM, so it cannot be avoided.
    "roles/resourcemanager.projectIamAdmin",
    # google_project_iam_custom_role.build_secrets and .bootstrap_apply_secrets
    "roles/iam.roleAdmin",
    # google_iam_workload_identity_pool.github and its provider
    "roles/iam.workloadIdentityPoolAdmin",
    # google_artifact_registry_repository.hop and its repository IAM
    "roles/artifactregistry.admin",
    # google_firestore_database.relay and the four google_firestore_field TTL policies. Unavoidably
    # broad: it also carries Firestore entity read/write, so it can see the relay bundle store.
    "roles/datastore.owner",
  ])

  # A single exact OIDC subject: a push-driven workflow run on canonical main. It is an exact subject,
  # not a principalSet: a workflow run on any other ref, or from a pull request, gets no token at all.
  bootstrap_apply_subject   = "repo:${var.github_repository}:ref:refs/heads/main"
  bootstrap_apply_principal = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/subject"
}

resource "google_service_account" "bootstrap_apply" {
  account_id   = "bootstrap-apply"
  display_name = "GitHub Actions: apply infra/bootstrap from canonical main"

  depends_on = [google_project_service.this["iam.googleapis.com"]]
}

# Both the plan and apply jobs run from refs/heads/main (no GitHub environment), so one exact subject
# binding covers them. The apply job is gated by workflow_dispatch confirm=apply, not by an environment.
resource "google_service_account_iam_member" "bootstrap_apply_wif" {
  service_account_id = google_service_account.bootstrap_apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "${local.bootstrap_apply_principal}/${local.bootstrap_apply_subject}"
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

  # Setting this member requires the bucket-policy grant below.
  depends_on = [
    google_project_service.this["storage.googleapis.com"],
    google_storage_bucket_iam_member.bootstrap_apply_state_bucket_iam,
  ]
}

# Managing IAM on the runtime state bucket needs storage.buckets.setIamPolicy, which neither
# roles/storage.objectAdmin (bootstrap_apply_state above) nor roles/storage.objectUser carries, and no
# project storage role is granted to this identity. Without it, the three bindings this root owns on the
# state bucket (bootstrap_apply_state here, google_storage_bucket_iam_member.deploy_state in iam.tf, and
# .billing_catalog_state in billing.tf) cannot be applied. A project-wide storage role would reach every
# bucket, and bucket-scoped roles/storage.admin would also carry storage.objects.* across the runtime and
# billing state prefixes this root deliberately keeps unreachable. So this is a bucket-policy-only custom
# role, granted bucket-scoped on the state bucket: exactly setIamPolicy plus the reads it needs, no object
# data access. Same pattern as bootstrap_apply_secrets. The first grant of this permission is owner-seeded
# out of band, like this identity's baseline project roles, because a self-authenticating applier cannot
# grant itself its first bucket-policy permission (see infra/DEPLOY-CONSOLE.md).
resource "google_project_iam_custom_role" "bootstrap_apply_state_bucket_iam" {
  role_id     = "hopBootstrapApplyStateBucketIam"
  title       = "Hop bootstrap CI state-bucket IAM"
  description = "Manage IAM policy on the runtime state bucket only. No object data access."
  permissions = [
    "storage.buckets.get",
    "storage.buckets.getIamPolicy",
    "storage.buckets.setIamPolicy",
  ]
}

resource "google_storage_bucket_iam_member" "bootstrap_apply_state_bucket_iam" {
  bucket = var.runtime_state_bucket
  role   = google_project_iam_custom_role.bootstrap_apply_state_bucket_iam.id
  member = "serviceAccount:${google_service_account.bootstrap_apply.email}"

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
