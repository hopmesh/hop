# APIs the relay fleet needs. Kept disable_on_destroy = false so tearing down the
# module never yanks an API another resource in the project still depends on.
locals {
  services = [
    "run.googleapis.com",
    "compute.googleapis.com",          # global load balancer, NEGs, certs, IP
    "firestore.googleapis.com",        # durable per-node store
    "artifactregistry.googleapis.com", # container image
    "secretmanager.googleapis.com",    # relay identity seed
    "cloudbuild.googleapis.com",       # build the image in-cloud (no local docker)
    "dns.googleapis.com",              # public DNS zone for hopme.sh
  ]
}

resource "google_project_service" "this" {
  for_each = toset(local.services)

  service            = each.value
  disable_on_destroy = false
}
