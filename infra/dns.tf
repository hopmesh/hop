# Public DNS zone for hopme.sh. Delegate the registrar's nameservers to the
# `name_servers` output below; once propagated, records (relay.hopme.sh, etc.) are
# managed here in Terraform.
resource "google_dns_managed_zone" "hopme" {
  name        = var.dns_zone_name     # "hopme-sh"
  dns_name    = var.dns_zone_dns_name # "hopme.sh."
  description = "Hop public DNS zone (hopme.sh)"
  visibility  = "public"

  depends_on = [google_project_service.this]
}

# relay.hopme.sh → the global LB's anycast IP. Once this resolves, the managed TLS
# cert provisions and wss://relay.hopme.sh/ routes to the nearest Cloud Run region.
resource "google_dns_record_set" "relay" {
  name         = "${var.domain}." # relay.hopme.sh.
  managed_zone = google_dns_managed_zone.hopme.name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.relay.address]
}
