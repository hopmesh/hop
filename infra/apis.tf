# APIs the relay fleet needs. Kept disable_on_destroy = false so tearing down the
# module never yanks an API another resource in the project still depends on.
locals {
  services = [
    "run.googleapis.com",
    "compute.googleapis.com",            # global load balancer, NEGs, certs, IP
    "certificatemanager.googleapis.com", # wildcard *.relay.hopme.sh cert (per-region subdomains)
    "firestore.googleapis.com",          # durable per-node store
    "artifactregistry.googleapis.com",   # container image
    "secretmanager.googleapis.com",      # relay identity seed
    "cloudbuild.googleapis.com",         # build the image in-cloud (no local docker)
    "dns.googleapis.com",                # public DNS zone for hopme.sh
    "monitoring.googleapis.com",         # infra-r2-04: observability.tf alert policies + notification channel
    "logging.googleapis.com",            # infra-r2-04: observability.tf log bucket/sink/exclusion/metric
    "bigquery.googleapis.com",           # billing reconciler usage history (DESIGN.md §37)
    "iam.googleapis.com",                # workload identity federation (GitHub Actions -> GCP)
    "iamcredentials.googleapis.com",     # WIF: mint short-lived SA credentials for GitHub OIDC
    "sts.googleapis.com",                # WIF: exchange the GitHub OIDC token for a GCP token
  ]
}

resource "google_project_service" "this" {
  for_each = toset(local.services)

  service            = each.value
  disable_on_destroy = false
}
