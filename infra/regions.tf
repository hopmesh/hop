# Deploy a relay in EVERY available GCP region (DESIGN.md §21/§28) instead of a fixed
# list — the anycast LB then routes each device to its nearest region (lowest-latency
# entrance). `excluded_regions` drops any region that can't host Cloud Run (a few
# compute regions don't), or that we simply don't want.
data "google_compute_regions" "available" {}

locals {
  # All available regions minus excluded. NOTE: a fresh GCP project can't actually
  # spin up Cloud Run in all ~43 regions — there's a per-project "initialize in
  # region" quota (and a few regions are 403-unavailable). So `region_allowlist`
  # pins a working curated set; leave it empty (after a quota increase) to go truly
  # all-regions.
  all_regions = setsubtract(
    toset(data.google_compute_regions.available.names),
    toset(var.excluded_regions),
  )
  # relays_enabled is the master switch: false empties the region set, so the relay Cloud Run
  # services (and everything that for_each-es over them: NEGs, region backends, public IAM) are
  # torn down. The LB frontend / cert / DNS stay, so re-enabling restores the fleet in place.
  regions = var.relays_enabled ? (length(var.region_allowlist) > 0 ? toset(var.region_allowlist) : local.all_regions) : toset([])
}
