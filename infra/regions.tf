# Deploy a relay in EVERY available GCP region (DESIGN.md §21/§28) instead of a fixed
# list — the anycast LB then routes each device to its nearest region (lowest-latency
# entrance). `excluded_regions` drops any region that can't host Cloud Run (a few
# compute regions don't), or that we simply don't want.
data "google_compute_regions" "available" {}

locals {
  regions = setsubtract(
    toset(data.google_compute_regions.available.names),
    toset(var.excluded_regions),
  )
}
