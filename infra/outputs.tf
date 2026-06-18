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
