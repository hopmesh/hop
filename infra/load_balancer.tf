# Global external Application Load Balancer: one anycast IP + one DNS name in front
# of every regional Cloud Run relay. Premium-tier routing sends each device to the
# nearest healthy region — the "closest entrance/exit, lowest latency" goal.

# Anycast IP the domain's A record points at.
resource "google_compute_global_address" "relay" {
  name = "hop-relay-ip"
}

# One serverless NEG per region, each targeting that region's Cloud Run service.
resource "google_compute_region_network_endpoint_group" "relay" {
  for_each = google_cloud_run_v2_service.relay

  name                  = "hop-relay-neg-${each.key}"
  region                = each.key
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = each.value.name
  }
}

# Single backend gathering all regional NEGs. timeout_sec is NOT allowed on
# serverless-NEG backends — the WebSocket lifetime is governed by the Cloud Run
# service's own request timeout (var.ws_request_timeout_seconds, set in cloud_run.tf).
resource "google_compute_backend_service" "relay" {
  name                  = "hop-relay-backend"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTP"

  dynamic "backend" {
    for_each = google_compute_region_network_endpoint_group.relay
    content {
      group = backend.value.id
    }
  }
}

resource "google_compute_url_map" "relay" {
  name            = "hop-relay-urlmap"
  default_service = google_compute_backend_service.relay.id
}

# Google-managed TLS cert. Goes ACTIVE once the domain's A record resolves to the
# anycast IP above (so provisioning waits on the DNS step you do by hand).
resource "google_compute_managed_ssl_certificate" "relay" {
  name = "hop-relay-cert"

  managed {
    domains = [var.domain]
  }
}

resource "google_compute_target_https_proxy" "relay" {
  name             = "hop-relay-https-proxy"
  url_map          = google_compute_url_map.relay.id
  ssl_certificates = [google_compute_managed_ssl_certificate.relay.id]
}

resource "google_compute_global_forwarding_rule" "https" {
  name                  = "hop-relay-https"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "443"
  target                = google_compute_target_https_proxy.relay.id
  ip_address            = google_compute_global_address.relay.id
}

# Redirect plain :80 to :443 so http:// connects upgrade cleanly.
resource "google_compute_url_map" "https_redirect" {
  name = "hop-relay-https-redirect"

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_target_http_proxy" "redirect" {
  name    = "hop-relay-http-proxy"
  url_map = google_compute_url_map.https_redirect.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "hop-relay-http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "80"
  target                = google_compute_target_http_proxy.redirect.id
  ip_address            = google_compute_global_address.relay.id
}
