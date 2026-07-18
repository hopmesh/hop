# Runtime data plane for the billing reconciler (services/hop-billingd, DESIGN.md section 37).
# Billing identities, IAM, WIF, and the Stripe secret container are administrator-owned resources in
# infra/bootstrap. The Stripe catalog remains isolated in infra/billing with its own provider and state.

# The reconciler appends closed-hour rows here as it emits them to Stripe. BigQuery API enablement is
# a bootstrap prerequisite rather than a dependency that the runtime deploy identity can mutate.
resource "google_bigquery_dataset" "usage" {
  dataset_id                 = "hop_usage"
  friendly_name              = "Hop usage history"
  description                = "Per-tenant metered usage (carriage, storage) rolled up by the §37 reconciler."
  location                   = "US"
  delete_contents_on_destroy = false
}

# The reconciler's persisted watermarks. In BigQuery (not Firestore) so the billingd SA needs ZERO
# new roles: dataEditor already covers both the jobless `tabledata.list` read (max per dimension is
# folded client-side, no bigquery.jobs.create needed) and the idempotent `insertAll` append. Rows
# are append-only, one per ADVANCED watermark per run; a lost row just re-emits an already-deduped
# window (Stripe dedups by the deterministic idempotency keys), so this is bookkeeping, not truth.
resource "google_bigquery_table" "reconcile_watermarks" {
  dataset_id          = google_bigquery_dataset.usage.dataset_id
  table_id            = "reconcile_watermarks"
  deletion_protection = false # append-only bookkeeping; safe to recreate (first run re-scans from 0)

  schema = jsonencode([
    { name = "dimension", type = "STRING", mode = "REQUIRED" }, # carriage | telemetry | storage
    { name = "watermark", type = "INT64", mode = "REQUIRED" },  # hour bucket (ms for storage, later)
    { name = "updated_ms", type = "INT64", mode = "REQUIRED" },
  ])
}
