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

# relay.hopme.sh → the global LB's anycast IPs (dual-stack). Once these resolve, the
# managed TLS cert provisions and wss://relay.hopme.sh/ routes to the nearest region.
resource "google_dns_record_set" "relay" {
  name         = "${var.domain}." # relay.hopme.sh.
  managed_zone = google_dns_managed_zone.hopme.name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.relay.address]
}

resource "google_dns_record_set" "relay_aaaa" {
  name         = "${var.domain}." # relay.hopme.sh.
  managed_zone = google_dns_managed_zone.hopme.name
  type         = "AAAA"
  ttl          = 300
  rrdatas      = [google_compute_global_address.relay_v6.address]
}

# *.relay.hopme.sh → the same anycast IPs. One wildcard record covers every per-region
# subdomain (current and future); the LB's host rules pin each to its region. The
# wildcard cert (Certificate Manager) provides TLS for all of them.
resource "google_dns_record_set" "relay_wildcard" {
  name         = "*.${var.domain}." # *.relay.hopme.sh.
  managed_zone = google_dns_managed_zone.hopme.name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.relay.address]
}

resource "google_dns_record_set" "relay_wildcard_aaaa" {
  name         = "*.${var.domain}." # *.relay.hopme.sh.
  managed_zone = google_dns_managed_zone.hopme.name
  type         = "AAAA"
  ttl          = 300
  rrdatas      = [google_compute_global_address.relay_v6.address]
}

# The CNAME that proves domain control to Certificate Manager so the wildcard cert can
# be issued (DNS authorization). Emitted by the dns_authorization resource.
resource "google_dns_record_set" "relay_dnsauth" {
  name         = google_certificate_manager_dns_authorization.relay.dns_resource_record[0].name
  managed_zone = google_dns_managed_zone.hopme.name
  type         = google_certificate_manager_dns_authorization.relay.dns_resource_record[0].type
  ttl          = 300
  rrdatas      = [google_certificate_manager_dns_authorization.relay.dns_resource_record[0].data]
}
