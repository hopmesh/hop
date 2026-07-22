# Administrator-owned control plane for the console (hop-accountd + hop-console). The automatically
# applied runtime root owns only the executable services, load balancing, DNS, and certificates; every
# identity, secret container, secret VALUE, IAM grant, and the Cloud SQL instance below is
# bootstrap-only (the runtime guard forbids identity and secret resources in infra/*.tf, and the
# low-privilege deploy identity has no Cloud SQL admin). Modeled on the billingd block (billing.tf)
# and the relay identity (iam.tf).
#
# Everything hop-accountd needs is created AND seeded by one dispatch of bootstrap-apply.yml:
# hop-api-token is generated here, and console-db-url is composed here from the generated Postgres
# password plus the instance connection name. There is no `gcloud secrets versions add` step.
#
# Posture, stated plainly: the two generated credentials (hop-api-token, and the Postgres password
# inside console-db-url) DO live in this root's OpenTofu state. Nothing outside this state ever needs
# to know them, so generating them beats making a human invent, type, and then leave them in a shell
# history. This is a deliberate, owner-approved tradeoff for zero manual seeding, and the access
# controlled hop-mesh-tfstate bucket is the boundary protecting those bytes. The credentials a third
# party issues (stripe-account-key, hop-resend-apikey, hop-github-oauth-client-secret) are still
# seeded by a human and never enter state.

locals {
  # Project roles per console identity.
  accountd_project_roles = toset([
    "roles/cloudsql.client",   # connect to the hop_console Cloud SQL instance via the Auth proxy
    "roles/datastore.user",    # the tenant-registry sync writes Firestore
    "roles/logging.logWriter", # structured logs
  ])
  console_project_roles = toset([
    "roles/logging.logWriter",
  ])
  # Every secret hop-accountd reads. Three carry values a human supplies once (the Stripe account key,
  # the Resend API key, the GitHub OAuth client secret); hop-api-token and console-db-url are generated
  # and written below; stripe-webhook-secret is written by the isolated billing root. GITHUB_CLIENT_ID
  # and RESEND_FROM are NOT here: they are public config and ride as plain Cloud Run env from
  # infra/variables.tf.
  accountd_secret_ids = toset([
    google_secret_manager_secret.stripe_account_key.secret_id,
    google_secret_manager_secret.accountd_api_token.secret_id,
    google_secret_manager_secret.console_db_url.secret_id,
    google_secret_manager_secret.stripe_webhook_secret.secret_id,
    "hop-resend-apikey",
    "hop-github-oauth-client-secret",
  ])
  # The two containers this root both creates AND writes a version into. bootstrap-apply's project
  # custom role deliberately carries no version permission (it must not be able to read the Stripe
  # keys or the relay seed), so the version authority is granted per container, on these two only.
  bootstrap_generated_secret_ids = toset([
    google_secret_manager_secret.accountd_api_token.secret_id,
    google_secret_manager_secret.console_db_url.secret_id,
  ])
}

# --- Runtime identities ---------------------------------------------------------------
resource "google_service_account" "accountd" {
  account_id   = "hop-accountd"
  display_name = "Hop console backend (Cloud Run)"

  depends_on = [google_project_service.this["iam.googleapis.com"]]
}

resource "google_service_account" "console" {
  account_id   = "hop-console"
  display_name = "Hop console front (Cloud Run)"

  depends_on = [google_project_service.this["iam.googleapis.com"]]
}

# --- Secret containers + generated values ---------------------------------------------
# hop-api-token authenticates the operator /v1/* surface on hop-accountd. Nothing outside this state
# needs to know it, so generate it rather than making a human invent one.
#
# random_bytes, not random_password: a bearer token wants raw entropy, while random_password exists to
# satisfy character-class policies ("must contain N symbols"). 32 bytes rendered as hex is 256 bits in
# 64 characters that are header-safe and URL-safe by construction, so there is no escaping hazard.
# accountd rejects anything shorter than 16 bytes, so this clears the floor comfortably.
#
# Rotation is a one-line bump of the keepers value plus an apply. That is the whole ceremony; no taint,
# no -replace. Cloud Run mounts this secret at `version = "latest"`, so a rotated value takes effect on
# the next revision deploy, not instantly, and the superseded version stays live until someone disables
# or destroys it (deliberate: it keeps the old token working through the rollout).
resource "google_secret_manager_secret" "accountd_api_token" {
  secret_id = "hop-api-token"

  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.this["secretmanager.googleapis.com"]]
}

resource "random_bytes" "accountd_api_token" {
  length = 32

  # Bump this date to rotate the token on the next apply.
  keepers = {
    rotation = "2026-07-21"
  }
}

resource "google_secret_manager_secret_version" "accountd_api_token" {
  secret      = google_secret_manager_secret.accountd_api_token.id
  secret_data = random_bytes.accountd_api_token.hex

  # The applier grants itself the version authority in this same run (see
  # google_secret_manager_secret_iam_member.bootstrap_apply_generated_secrets), so order the write
  # after the grant. IAM propagation can still lag by a few seconds on the very first apply; if that
  # happens the step fails 403 and a re-dispatch of confirm=apply succeeds.
  depends_on = [google_secret_manager_secret_iam_member.bootstrap_apply_generated_secrets]
}

# The Postgres DSN hop-accountd reads as DATABASE_URL. Composed here from the generated user password
# and the instance connection name, so the credential is created, granted, and delivered in one apply.
# Cloud Run mounts the Cloud SQL Auth proxy socket, hence the host=/cloudsql/<connection> form and no
# port. The password is generated with `special = false`, so it is URL-safe and needs no encoding.
resource "google_secret_manager_secret" "console_db_url" {
  secret_id = "console-db-url"

  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.this["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret_version" "console_db_url" {
  secret      = google_secret_manager_secret.console_db_url.id
  secret_data = "postgresql://${google_sql_user.console.name}:${random_password.console_db.result}@/${google_sql_database.console.name}?host=/cloudsql/${google_sql_database_instance.console.connection_name}"

  depends_on = [google_secret_manager_secret_iam_member.bootstrap_apply_generated_secrets]
}

# --- Cloud SQL (Postgres 16) backing hop-accountd --------------------------------------
# Orgs, users, magic-link auth, API keys, team, and the tenant-registry writer bookkeeping. A single
# db-f1-micro carries the console's transactional load (the high-volume usage reads come from
# Firestore, not here).
#
# This is bootstrap-owned rather than runtime-owned for two reasons: the low-privilege hop-deploy
# identity has no Cloud SQL admin role, and the generated password has to land in a Secret Manager
# version, which the runtime guard forbids in infra/*.tf. The runtime root only mounts the instance,
# addressing it by var.console_db_connection_name.
#
# Connectivity: hop-accountd reaches this instance through the Cloud SQL Auth proxy socket that Cloud
# Run mounts via the run.googleapis.com/cloudsql-instances template annotation (IAM-authenticated), so
# there are no authorized networks and no public client path. deletion_protection guards the data.
resource "google_sql_database_instance" "console" {
  name             = "hop-console-db"
  database_version = "POSTGRES_16"
  region           = var.region

  # Terraform-level guard: no `tofu destroy` can drop the instance and its data.
  deletion_protection = true

  settings {
    tier              = "db-f1-micro"
    availability_type = "ZONAL"
    disk_size         = 10
    disk_type         = "PD_SSD"
    disk_autoresize   = true

    backup_configuration {
      enabled = true
    }

    ip_configuration {
      # Public IP is on, but with no authorized networks the only reachable path is the IAM-authed
      # Cloud SQL Auth proxy socket the Cloud Run service mounts. A private-IP setup would need a VPC
      # connector, which this single-instance console does not warrant.
      ipv4_enabled = true
    }
  }

  # roles/cloudsql.admin is granted to bootstrap-apply in ci_apply.tf, in this same root. Order the
  # instance after the API enablement and after the identity's own role bindings so the first apply
  # does not race its own grant.
  depends_on = [
    google_project_service.this["sqladmin.googleapis.com"],
    google_project_iam_member.bootstrap_apply,
  ]
}

resource "google_sql_database" "console" {
  name     = "hop_console"
  instance = google_sql_database_instance.console.name
}

# One generated password, used for the google_sql_user AND baked into console-db-url above, so the
# database and the connection string can never drift apart. random_password is the right tool here
# (unlike the bearer token above): `special = false` keeps every character URL-safe where the value is
# interpolated into the postgresql:// DSN, so no encoding step is needed.
#
# Rotation is a one-line bump of the keepers value plus an apply: the new password lands on the user
# and in a new console-db-url version in the same run. Cloud Run reads `version = "latest"`, so the new
# DSN takes effect on the next revision deploy; the superseded version remains until it is explicitly
# disabled or destroyed.
resource "random_password" "console_db" {
  length  = 32
  special = false

  # Bump this date to rotate the database password on the next apply.
  keepers = {
    rotation = "2026-07-21"
  }
}

resource "google_sql_user" "console" {
  name     = "hop_console"
  instance = google_sql_database_instance.console.name
  password = random_password.console_db.result
}

# --- hop-accountd IAM -----------------------------------------------------------------
resource "google_project_iam_member" "accountd" {
  for_each = local.accountd_project_roles
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.accountd.email}"
}

resource "google_secret_manager_secret_iam_member" "accountd_secrets" {
  for_each  = local.accountd_secret_ids
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.accountd.email}"
}

# --- hop-console IAM (no secrets; HOP_ACCOUNTD_URL is plain env) -----------------------
resource "google_project_iam_member" "console" {
  for_each = local.console_project_roles
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.console.email}"
}

# --- The applier's own version authority, scoped to the two containers it generates ----
# hopBootstrapApplySecrets (ci_apply.tf) is deliberately container-only: no version add, no version
# access, so applying this root can never read the Stripe keys, the relay seed, or the OAuth secret.
# Writing hop-api-token and console-db-url needs both (add to write, accessor because the provider
# re-reads secret_data on every refresh), so grant them per container, on these two only. Every other
# secret in the project stays unreadable to this identity.
resource "google_secret_manager_secret_iam_member" "bootstrap_apply_generated_secrets" {
  for_each = {
    for pair in setproduct(local.bootstrap_generated_secret_ids, [
      "roles/secretmanager.secretVersionAdder",
      "roles/secretmanager.secretAccessor",
    ]) : "${pair[0]}:${pair[1]}" => { secret_id = pair[0], role = pair[1] }
  }
  secret_id = each.value.secret_id
  role      = each.value.role
  member    = "serviceAccount:${google_service_account.bootstrap_apply.email}"
}

# --- Deploy identity may attach the two new runtime identities to Cloud Run -----------
# hop-deploy creates the Cloud Run services in the runtime root, and setting a service's
# service_account is an iam.serviceAccounts.actAs on that identity. Mirrors deploy_uses_relay /
# deploy_uses_example in iam.tf.
resource "google_service_account_iam_member" "deploy_uses_accountd" {
  service_account_id = google_service_account.accountd.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.deploy.email}"
}

resource "google_service_account_iam_member" "deploy_uses_console" {
  service_account_id = google_service_account.console.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.deploy.email}"
}

# The runtime root reads the isolated billing state (terraform_remote_state.billing) for the Stripe
# price ids, and the merge-to-main deploy runs that apply as hop-deploy. deploy_state (iam.tf) scopes
# writes to the runtime-state prefix only, so grant a separate READ-ONLY view of the billing/ prefix.
# This is the only state outside relay-fleet/ that hop-deploy can see, and it cannot write it.
resource "google_storage_bucket_iam_member" "deploy_billing_state_reader" {
  bucket = var.runtime_state_bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.deploy.email}"

  condition {
    title       = "billing-state-read-only"
    description = "The deployer may read (never write) the isolated billing state for price ids."
    expression  = "resource.name.startsWith(\"projects/_/buckets/${var.runtime_state_bucket}/objects/billing/\")"
  }

  # Setting this member requires bootstrap-apply's bucket-policy grant (ci_apply.tf).
  depends_on = [google_storage_bucket_iam_member.bootstrap_apply_state_bucket_iam]
}
