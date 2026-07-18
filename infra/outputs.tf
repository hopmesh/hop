output "relay_image" {
  value = var.relay_image
}

output "name_servers" {
  description = "Set these as the nameservers for hopme.sh at the registrar to delegate the zone."
  value       = google_dns_managed_zone.hopme.name_servers
}

output "lb_ip" {
  description = "Anycast IPv4 behind relay.hopme.sh."
  value       = google_compute_global_address.relay.address
}

output "lb_ip_v6" {
  description = "Anycast IPv6 behind relay.hopme.sh."
  value       = google_compute_global_address.relay_v6.address
}

output "region_endpoints" {
  description = "Per-region wss:// locators (the §28 backbone advertises these)."
  value       = { for r in local.regions : r => "wss://${r}.${var.domain}/" }
}

output "endpoint" {
  description = "What devices put in the Cloud relay field once the cert is ACTIVE."
  value       = "wss://${var.domain}/"
}
