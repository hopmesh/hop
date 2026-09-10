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
    # google_sql_database_instance.console + its database and user (console.tf). Cloud SQL has no
    # narrower create role: roles/cloudsql.editor cannot create an instance and roles/cloudsql.client
    # is a connect-only runtime role. This is a control-plane role, not a data-plane one: it manages
    # instances, databases, and users, and reads no table contents.
    "roles/cloudsql.admin",
  ])

}

resource "google_service_account" "bootstrap_apply" {
  account_id   = "bootstrap-apply"
  display_name = "GitHub Actions: apply infra/bootstrap from canonical main"

  depends_on = [google_project_service.this["iam.googleapis.com"]]
}

# Bootstrap authority is bound to the exact canonical workflow. Explicit rollback temporarily restores
# only platform's reviewed handoff workflow so rollback remains executable without admitting other jobs.
resource "google_service_account_iam_member" "bootstrap_apply_wif" {
  service_account_id = google_service_account.bootstrap_apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.github_workflow_members.bootstrap

  depends_on = [google_iam_workload_identity_pool_provider.github]

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_service_account_iam_member" "bootstrap_apply_wif_platform_rollback" {
  count              = var.github_authority_phase == "handoff" ? 1 : 0
  service_account_id = google_service_account.bootstrap_apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.platform_rollback_workflow_members.bootstrap

  depends_on = [google_iam_workload_identity_pool_provider.github]
}

resource "google_project_iam_member" "bootstrap_apply" {
  for_each = local.bootstrap_apply_project_roles
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.bootstrap_apply.email}"
}

# Drift gets a separate read-only identity. It can refresh the runtime plan, read the narrowed price
# map, and read runtime state. It cannot mutate IAM, services, state, secrets, or application data.
resource "google_service_account" "infra_drift" {
  account_id   = "hop-infra-drift"
  display_name = "GitHub Actions: read-only runtime infrastructure drift"

  depends_on = [google_project_service.this["iam.googleapis.com"]]
}

resource "google_service_account_iam_member" "infra_drift_wif" {
  service_account_id = google_service_account.infra_drift.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.github_workflow_members.drift

  depends_on = [google_iam_workload_identity_pool_provider.github]

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_project_iam_custom_role" "infra_drift" {
  role_id     = "hopInfraDriftViewer"
  title       = "Hop runtime infrastructure drift viewer"
  description = "Read runtime infrastructure metadata. No application data or mutation permissions."
  permissions = [
    "bigquery.datasets.get",
    "bigquery.tables.get",
    "bigquery.tables.list",
    "certificatemanager.certmapentries.get",
    "certificatemanager.certmapentries.list",
    "certificatemanager.certmaps.get",
    "certificatemanager.certmaps.list",
    "certificatemanager.certs.get",
    "certificatemanager.certs.list",
    "certificatemanager.dnsauthorizations.get",
    "certificatemanager.dnsauthorizations.list",
    "certificatemanager.locations.get",
    "certificatemanager.locations.list",
    "compute.addresses.get",
    "compute.addresses.list",
    "compute.backendServices.get",
    "compute.backendServices.list",
    "compute.forwardingRules.get",
    "compute.forwardingRules.list",
    "compute.networkEndpointGroups.get",
    "compute.networkEndpointGroups.list",
    "compute.regions.get",
    "compute.regions.list",
    "compute.sslCertificates.get",
    "compute.sslCertificates.list",
    "compute.targetHttpProxies.get",
    "compute.targetHttpProxies.list",
    "compute.targetHttpsProxies.get",
    "compute.targetHttpsProxies.list",
    "compute.urlMaps.get",
    "compute.urlMaps.list",
    "dns.changes.get",
    "dns.managedZones.get",
    "dns.projects.get",
    "dns.resourceRecordSets.list",
    "logging.buckets.get",
    "logging.buckets.list",
    "logging.exclusions.get",
    "logging.exclusions.list",
    "logging.logMetrics.get",
    "logging.logMetrics.list",
    "logging.sinks.get",
    "logging.sinks.list",
    "monitoring.alertPolicies.get",
    "monitoring.alertPolicies.list",
    "monitoring.notificationChannels.get",
    "monitoring.notificationChannels.list",
    "resourcemanager.projects.get",
    "run.services.get",
    "run.services.list",
    "serviceusage.services.use",
  ]
}

resource "google_project_iam_member" "infra_drift_viewer" {
  project = var.project_id
  role    = google_project_iam_custom_role.infra_drift.id
  member  = "serviceAccount:${google_service_account.infra_drift.email}"
}

resource "google_storage_bucket_iam_member" "infra_drift_state_reader" {
  bucket = var.runtime_state_bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.infra_drift.email}"

  condition {
    title       = "runtime-drift-state-read-only"
    description = "The drift identity may list the backend and read only runtime state objects."
    expression  = "resource.name == \"projects/_/buckets/${var.runtime_state_bucket}\" || resource.name.startsWith(\"projects/_/buckets/${var.runtime_state_bucket}/objects/${var.runtime_state_prefix}/\")"
  }
}

resource "google_secret_manager_secret_iam_member" "infra_drift_price_ids_accessor" {
  secret_id = google_secret_manager_secret.billing_price_ids.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.infra_drift.email}"
}

resource "google_secret_manager_secret_iam_member" "infra_drift_price_ids_viewer" {
  secret_id = google_secret_manager_secret.billing_price_ids.secret_id
  role      = "roles/secretmanager.viewer"
  member    = "serviceAccount:${google_service_account.infra_drift.email}"
}

# One planned migration removes two duplicate state bindings, retired Cloud Build secret and bucket
# grants, all 12 hop-cloudbuild roles, and every role on the unused default compute and legacy build
# identities. It disables hop-cloudbuild and records completion in bootstrap state.
resource "terraform_data" "remove_legacy_iam_bindings" {
  input = {
    migration = "remove-legacy-deploy-iam-v1"
  }

  triggers_replace = ["5a0d2bb3ce619a904f32f0d347e0c9763c033b8197ff7f3e6ec969c0a95391b7"]

  provisioner "local-exec" {
    command = "python3 ${path.module}/remove_legacy_state_bindings.py"
    environment = {
      PROJECT_ID                = var.project_id
      STATE_BUCKET              = var.runtime_state_bucket
      BOOTSTRAP_SERVICE_ACCOUNT = google_service_account.bootstrap_apply.email
      BILLING_SERVICE_ACCOUNT   = google_service_account.billing_catalog_apply.email
    }
  }
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

output "infra_drift_wif_provider" {
  description = "Workload identity provider for infra-drift (repo variable GCP_DRIFT_WIF_PROVIDER)."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "infra_drift_wif_service_account" {
  description = "Read-only service account for infra-drift (repo variable GCP_DRIFT_SERVICE_ACCOUNT)."
  value       = google_service_account.infra_drift.email
}
