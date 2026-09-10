output "relay_image" {
  value = var.relay_image
}

# Non-secret applied inputs used by the read-only drift workflow. Keeping these in runtime state lets
# drift refresh current infrastructure without rebuilding or checking out private source.
output "drift_inputs" {
  value = {
    relay_image               = var.relay_image
    example_image             = var.example_image
    accountd_image            = var.accountd_image
    console_image             = var.console_image
    deployment_source_sha     = var.deployment_source_sha
    private_source_sha        = var.private_source_sha
    billing_price_ids_version = var.billing_price_ids_version
    deployment_environment    = var.deployment_environment
    relay_identity_version    = var.relay_identity_version
    example_identity_version  = var.example_identity_version
  }
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
