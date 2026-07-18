# Runtime infrastructure for the billing reconciler (services/hop-billingd, DESIGN.md §37).
#
# This is the RUNTIME side (secret container + BigQuery dataset + service identity) in the main
# fleet root. It is deliberately SEPARATE from infra/billing/, which is the Stripe meter/product
# CATALOG in its own Terraform root + state so a fleet apply never needs Stripe credentials.
#
# The reconciler is not deployed yet (no Cloud Run service / image here); this makes its secret and
# dataset exist and be seedable so the `--features live` wiring is a drop-in when it lands.

# ---------------------------------------------------------------------------------------------
# Stripe API key. Terraform NEVER holds the value (same discipline as the relay identity seed):
# this creates the empty container only. Seed it ONCE, out-of-band, before the reconciler deploys:
#
#   printf '%s' 'rk_live_XXXXXXXX' \
#     | gcloud secrets versions add stripe-api-key --project hop-mesh --data-file=-
#
# Use a RESTRICTED Stripe key scoped to write meter events (Billing:Meters + Meter events), not a
# full secret key. hop-billingd mounts the pinned version at runtime (added when the service lands).
resource "google_secret_manager_secret" "stripe_api_key" {
  secret_id = "stripe-api-key"

  replication {
    auto {}
  }

  depends_on = [google_project_service.this]

  # The key value lives only in this container's versions, never in TF state. Destroying the
  # container would drop the key silently; reseeding is an out-of-band act.
  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------------------------
# Stripe ACCOUNT key, for the invoice/account backend (the console's native invoice rendering,
# previous payments, signup-time customer + subscription creation). A separate key from the
# reconciler's on purpose: a leaked account key can read billing history but cannot fabricate
# usage or rewrite the catalog, and vice versa. Same discipline: empty container only, seeded
# out-of-band:
#
#   pbpaste | tr -d '\n' \
#     | gcloud secrets versions add stripe-account-key --project hop-mesh --data-file=-
#
# RESTRICTED key scopes: Invoices WRITE (render + Pay now), Customers WRITE, Subscriptions WRITE,
# SetupIntents WRITE (card onboarding), PaymentIntents READ, Charges READ, Payment methods READ,
# Credit notes READ, Billing Meters READ (usage cross-check only; dashboards read BigQuery).
# NO Products/Prices/Meters write (catalog key) and NO Meter Events write (reconciler key).
# The consuming service's SA binding is added when that service lands.
resource "google_secret_manager_secret" "stripe_account_key" {
  secret_id = "stripe-account-key"

  replication {
    auto {}
  }

  depends_on = [google_project_service.this]

  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------------------------
# Dedicated runtime identity for the reconciler. Least privilege: read Firestore (the usage ledger
# + metered markers the relays write), read the Stripe secret, write BigQuery, write logs.
resource "google_service_account" "billingd" {
  account_id   = "hop-billingd"
  display_name = "Hop billing reconciler (Cloud Run)"
}

resource "google_secret_manager_secret_iam_member" "billingd_stripe" {
  secret_id = google_secret_manager_secret.stripe_api_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.billingd.email}"
}

resource "google_project_iam_member" "billingd_firestore_read" {
  project = var.project_id
  role    = "roles/datastore.viewer" # reads the ledger rows + metered markers; never writes bundles
  member  = "serviceAccount:${google_service_account.billingd.email}"
}

resource "google_project_iam_member" "billingd_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.billingd.email}"
}

resource "google_project_iam_member" "billingd_bigquery" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor" # append usage rows to the history dataset
  member  = "serviceAccount:${google_service_account.billingd.email}"
}

# ---------------------------------------------------------------------------------------------
# Usage history dataset. Cheap analytical store for per-tenant billing history + the enterprise
# dashboards; the reconciler appends closed-hour rows here as it emits them to Stripe.
resource "google_bigquery_dataset" "usage" {
  dataset_id                 = "hop_usage"
  friendly_name              = "Hop usage history"
  description                = "Per-tenant metered usage (carriage, storage) rolled up by the §37 reconciler."
  location                   = "US"
  delete_contents_on_destroy = false

  depends_on = [google_project_service.this]
}
