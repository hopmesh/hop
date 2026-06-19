# LB-dependent outputs (lb_ip, dns_setup, the relay.hopme.sh endpoint) live in
# load_balancer.tf.disabled and come back when the LB layer is enabled post-DNS.

output "cloud_run_urls" {
  description = "Per-region Cloud Run service URLs."
  value       = { for k, s in google_cloud_run_v2_service.relay : k => s.uri }
}

# What to enter in a device's Cloud relay field while testing via *.run.app (valid
# Google TLS, no custom DNS). The relay speaks WebSocket, so swap https→wss.
output "test_endpoints" {
  description = "wss:// endpoints for direct *.run.app testing before DNS exists."
  value       = { for k, s in google_cloud_run_v2_service.relay : k => "${replace(s.uri, "https://", "wss://")}/" }
}

output "relay_image" {
  value = var.relay_image
}

output "name_servers" {
  description = "Set these as the nameservers for hopme.sh at the registrar to delegate the zone."
  value       = google_dns_managed_zone.hopme.name_servers
}

output "lb_ip" {
  description = "Anycast IP behind relay.hopme.sh."
  value       = google_compute_global_address.relay.address
}

output "endpoint" {
  description = "What devices put in the Cloud relay field once the cert is ACTIVE."
  value       = "wss://${var.domain}/"
}
