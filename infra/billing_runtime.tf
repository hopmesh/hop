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

# The console dashboards' raw data source: the billed usage the reconciler records as it emits to
# Stripe (insertId = the meter event's own `{event_name}:{tenant}:{hour}` key). Written via the same
# streaming `insertAll` as the watermarks. IMPORTANT: BigQuery streaming insertId dedup is BEST-EFFORT
# within a short (~1 minute) window, NOT the durable exactly-once Stripe gives its meter events, so it
# only collapses rapid retries. A scheduled re-run of a held hour (a Stripe retry, or a partial-fleet
# read that held the watermark) lands outside that window and appends a SECOND physical row. So this
# base table is APPEND-ONLY WITH POSSIBLE DUPLICATES; the authoritative one-row-per-(event_name,
# tenant, hour) is the `usage_history_current` view below, which is what dashboards read. This is why
# usage/invoice views live in OUR system and never read back from Stripe. Zero-new-IAM: dataEditor
# already covers the streaming append. (Hour-partitioned + tenant-clustered would scale better later.)
resource "google_bigquery_table" "usage_history" {
  dataset_id          = google_bigquery_dataset.usage.dataset_id
  table_id            = "usage_history"
  deletion_protection = false # append-only; safe to recreate (reconciler re-appends, view dedups)

  schema = jsonencode([
    { name = "event_name", type = "STRING", mode = "REQUIRED" }, # the Stripe meter event_name (dimension)
    { name = "tenant", type = "STRING", mode = "REQUIRED" },     # 32-char lowercase-hex TenantId
    { name = "hour", type = "INT64", mode = "REQUIRED" },        # hours-since-epoch bucket
    { name = "value", type = "INT64", mode = "REQUIRED" },       # metered quantity for that hour
    { name = "updated_ms", type = "INT64", mode = "REQUIRED" },  # reconcile run time (dedup tiebreaker)
  ])
}

# The AUTHORITATIVE usage view: exactly one row per (event_name, tenant, hour), the latest write
# wins. This is what makes "one authoritative row" true despite the base table's best-effort-only
# streaming dedup (see above): dashboards and invoice rendering read THIS, never the raw table, so a
# duplicate physical append from a re-run never double-counts a SUM(value). A view is metadata only
# (no storage, no scheduled job), created by the deploy identity under the same dataEditor grant.
resource "google_bigquery_table" "usage_history_current" {
  dataset_id          = google_bigquery_dataset.usage.dataset_id
  table_id            = "usage_history_current"
  deletion_protection = false

  view {
    use_legacy_sql = false
    query          = <<-SQL
      SELECT event_name, tenant, hour, value, updated_ms
      FROM `${google_bigquery_dataset.usage.project}.${google_bigquery_dataset.usage.dataset_id}.usage_history`
      QUALIFY ROW_NUMBER() OVER (
        PARTITION BY event_name, tenant, hour ORDER BY updated_ms DESC
      ) = 1
    SQL
  }

  depends_on = [google_bigquery_table.usage_history]
}
