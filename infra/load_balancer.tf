# Global external Application Load Balancer: one anycast IP + one DNS name in front
# of every regional Cloud Run relay. Premium-tier routing sends each device to the
# nearest healthy region — the "closest entrance/exit, lowest latency" goal.

# Anycast IPs the domain's A/AAAA records point at. Dual-stack: an IPv4 frontend and
# an IPv6 one share the same proxies/url-map/backends/cert. IPv6 lets clients on
# IPv6-only carrier networks reach the relay natively instead of via NAT64/464XLAT.
resource "google_compute_global_address" "relay" {
  name = "hop-relay-ip"
}

resource "google_compute_global_address" "relay_v6" {
  name       = "hop-relay-ip6"
  ip_version = "IPV6"
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

# Single backend gathering all regional NEGs — the anycast default behind
# relay.hopme.sh (nearest healthy region). timeout_sec is NOT allowed on serverless-NEG
# backends — the WebSocket lifetime is governed by the Cloud Run service's own request
# timeout (var.ws_request_timeout_seconds, set in cloud_run.tf).
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

# One backend per region, each holding only that region's NEG, so a host rule can pin
# <region>.relay.hopme.sh to that specific region (the §28 per-region network locator the
# backbone dials). Unlike the anycast default, these never route cross-region.
resource "google_compute_backend_service" "relay_region" {
  for_each = google_compute_region_network_endpoint_group.relay

  name                  = "hop-relay-backend-${each.key}"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTP"

  backend {
    group = each.value.id
  }
}

# relay.hopme.sh → nearest region (default); <region>.relay.hopme.sh → that exact region.
resource "google_compute_url_map" "relay" {
  name            = "hop-relay-urlmap"
  default_service = google_compute_backend_service.relay.id

  dynamic "host_rule" {
    for_each = google_compute_backend_service.relay_region
    content {
      hosts        = ["${host_rule.key}.${var.domain}"]
      path_matcher = "region-${host_rule.key}"
    }
  }

  dynamic "path_matcher" {
    for_each = google_compute_backend_service.relay_region
    content {
      name            = "region-${path_matcher.key}"
      default_service = path_matcher.value.id
    }
  }
}

# The original single-domain managed cert. No longer attached to the proxy (the cert map
# below serves TLS now), but kept so Terraform doesn't try to delete it *while* the proxy
# still references it in the same apply (that ordering fails: resourceInUseByAnother). A
# later apply can remove this once the proxy is confirmed on the cert map.
resource "google_compute_managed_ssl_certificate" "relay" {
  name = "hop-relay-cert"

  managed {
    domains = [var.domain]
  }
}

# --- Wildcard cert via Certificate Manager (relay.hopme.sh + *.relay.hopme.sh) --------
# A DNS-authorized managed cert: one authorization on the apex also authorizes the
# wildcard, so it covers every current and future region subdomain and renews without
# re-touching the proxy. (A compute managed cert can't do wildcards and re-provisions
# whenever its domain list changes.) Phase 1 just creates it; the proxy is switched onto
# the cert map in Phase 2, once the cert reports ACTIVE.
# A freshly-enabled API needs a moment to propagate before it accepts calls, so gate
# the Certificate Manager resources on the API enable + a short wait (avoids the
# "API has not been used before" 403 on a cold project).
resource "time_sleep" "certmanager_ready" {
  depends_on      = [google_project_service.this]
  create_duration = "120s"
}

resource "google_certificate_manager_dns_authorization" "relay" {
  name   = "hop-relay-dnsauth"
  domain = var.domain # relay.hopme.sh — also authorizes *.relay.hopme.sh

  depends_on = [time_sleep.certmanager_ready]
}

resource "google_certificate_manager_certificate" "relay" {
  name = "hop-relay-wildcard"

  managed {
    domains            = [var.domain, "*.${var.domain}"]
    dns_authorizations = [google_certificate_manager_dns_authorization.relay.id]
  }
}

resource "google_certificate_manager_certificate_map" "relay" {
  name = "hop-relay-certmap"

  depends_on = [time_sleep.certmanager_ready]
}

resource "google_certificate_manager_certificate_map_entry" "relay" {
  name         = "hop-relay-certmap-primary"
  map          = google_certificate_manager_certificate_map.relay.name
  certificates = [google_certificate_manager_certificate.relay.id]
  matcher      = "PRIMARY"
}

resource "google_compute_target_https_proxy" "relay" {
  name    = "hop-relay-https-proxy"
  url_map = google_compute_url_map.relay.id
  # The wildcard cert map serves relay.hopme.sh + every <region>.relay.hopme.sh.
  certificate_map = "//certificatemanager.googleapis.com/${google_certificate_manager_certificate_map.relay.id}"
}

resource "google_compute_global_forwarding_rule" "https" {
  name                  = "hop-relay-https"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "443"
  target                = google_compute_target_https_proxy.relay.id
  ip_address            = google_compute_global_address.relay.id
}

# IPv6 frontends — same proxies, just the v6 anycast address.
resource "google_compute_global_forwarding_rule" "https_v6" {
  name                  = "hop-relay-https-v6"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "443"
  target                = google_compute_target_https_proxy.relay.id
  ip_address            = google_compute_global_address.relay_v6.id
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

resource "google_compute_global_forwarding_rule" "http_v6" {
  name                  = "hop-relay-http-v6"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "80"
  target                = google_compute_target_http_proxy.redirect.id
  ip_address            = google_compute_global_address.relay_v6.id
}
