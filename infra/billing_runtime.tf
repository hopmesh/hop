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
