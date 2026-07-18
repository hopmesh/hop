# Global external Application Load Balancer: one anycast IP + one DNS name in front
# of every regional Cloud Run relay. Premium-tier routing sends each device to the
# nearest healthy region — the "closest entrance/exit, lowest latency" goal.

# Anycast IPs the domain's A/AAAA records point at. Dual-stack: an IPv4 frontend and
# an IPv6 one share the same proxies/url-map/backends/cert. IPv6 lets clients on
# IPv6-only carrier networks reach the relay natively instead of via NAT64/464XLAT.
# prevent_destroy: these anycast IPs are what the domain's A/AAAA records point at, and they
# deliberately survive the relays_enabled teardown (the off-state chain reuses the SAME IP). A
# destroy+recreate here would hand out a NEW public IP and black-hole every device until DNS
# re-propagates. Guard both so no plan can silently drop them; releasing an IP is a deliberate,
# out-of-band act (comment out the guard for that one apply).
resource "google_compute_global_address" "relay" {
  name = "hop-relay-ip"
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_global_address" "relay_v6" {
  name       = "hop-relay-ip6"
  ip_version = "IPV6"
  lifecycle {
    prevent_destroy = true
  }
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
# count-gated (not just empty backends) so a relay teardown DESTROYS this whole resource rather than
# updating it to zero backends: an in-place update-to-empty while the url_map references it and the
# regional NEGs are being destroyed forms a Terraform destroy-time cycle. When relays are off this
# whole on-state chain is destroyed; the separate OFF-STATE chain below (url_map.off + its proxy +
# forwarding rules, gated on !relays_enabled) then serves example.hopme.sh on the same anycast IP.
resource "google_compute_backend_service" "relay" {
  count                 = var.relays_enabled ? 1 : 0
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

# relay.hopme.sh → nearest region (default); <region>.relay.hopme.sh → that exact region;
# example.hopme.sh → the hops:// demo endpoint backend (DESIGN.md §30).
#
# The ENTIRE relay HTTPS serving chain is count-gated on var.relays_enabled and destroyed as one set
# when the fleet goes off: the anycast backend, THIS url_map, the https proxy, and the :443 forwarding
# rules. That avoids a Terraform destroy-time cycle: any of them left as an in-place UPDATE while the
# per-region backends/NEGs it references are destroyed forms a cycle (a conditional/alternate url_map
# doesn't help, since `x ? on[0] : off[0]` statically references BOTH). Destroying the whole chain
# together has no in-place-update-referencing-a-destroyed-resource, so no cycle. Kept alive across the
# teardown: the anycast IPs, the wildcard cert, DNS, the :80->:443 redirect, and the example service.
# In the off state the separate OFF-STATE chain (url_map.off, below) takes over :443 to keep
# example.hopme.sh reachable (infra-06); re-enabling (relays_enabled = true) restores the fleet on the
# SAME IP + cert and hands :443 back to this chain.
resource "google_compute_url_map" "relay" {
  count           = var.relays_enabled ? 1 : 0
  name            = "hop-relay-urlmap"
  default_service = google_compute_backend_service.relay[0].id

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

  host_rule {
    hosts        = [local.example_domain]
    path_matcher = "example"
  }

  path_matcher {
    name            = "example"
    default_service = google_compute_backend_service.example.id
  }
}

# --- OFF-STATE serving chain (relays_enabled = false) --------------------------------
# infra-06: when the relay fleet is off, the ENTIRE on-state HTTPS chain above (url_map.relay, the
# https proxy, and both :443 forwarding rules) is destroyed. The example host_rule lives INSIDE
# url_map.relay, so example.hopme.sh would go dark on the anycast IP even though the example Cloud Run
# service (example.tf) keeps running (min_instances = 1, always-allocated CPU) and billing. This
# parallel chain, count-gated on the INVERSE of relays_enabled, keeps a :443 listener whose default
# (and only) backend is the example service, so example.hopme.sh stays reachable in the off state.
#
# It reuses the SAME anycast IPs and the SAME wildcard cert map, so re-enabling the fleet just swaps
# which chain owns the :443 forwarding rules (this one is destroyed as the on-state one is created).
# Exactly one of the two chains exists at any time, so there is never a forwarding-rule/IP collision.
# Like the on-state chain, the whole off-state set is count-gated (not updated in place) to avoid a
# Terraform destroy-time cycle when flipping relays_enabled.
resource "google_compute_url_map" "off" {
  count           = var.relays_enabled ? 0 : 1
  name            = "hop-off-urlmap"
  default_service = google_compute_backend_service.example.id

  # Keep example.hopme.sh explicit too (in addition to being the default), so the intent is legible.
  host_rule {
    hosts        = [local.example_domain]
    path_matcher = "example"
  }

  path_matcher {
    name            = "example"
    default_service = google_compute_backend_service.example.id
  }
}

resource "google_compute_target_https_proxy" "off" {
  count           = var.relays_enabled ? 0 : 1
  name            = "hop-off-https-proxy"
  url_map         = google_compute_url_map.off[0].id
  certificate_map = "//certificatemanager.googleapis.com/${google_certificate_manager_certificate_map.relay.id}"
}

resource "google_compute_global_forwarding_rule" "off_https" {
  count                 = var.relays_enabled ? 0 : 1
  name                  = "hop-off-https"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "443"
  target                = google_compute_target_https_proxy.off[0].id
  ip_address            = google_compute_global_address.relay.id
}

resource "google_compute_global_forwarding_rule" "off_https_v6" {
  count                 = var.relays_enabled ? 0 : 1
  name                  = "hop-off-https-v6"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "443"
  target                = google_compute_target_https_proxy.off[0].id
  ip_address            = google_compute_global_address.relay_v6.id
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
  # Part of the count-gated relay HTTPS chain (see the url_map.relay comment): destroyed wholesale on
  # teardown rather than updated in place, which is what avoids the destroy-time cycle. Name is `-cm`
  # from the one-time move off ssl_certificates onto the certificate map (that switch 412s in place, so
  # a fresh proxy was created on the cert map); that migration is done.
  count   = var.relays_enabled ? 1 : 0
  name    = "hop-relay-https-proxy-cm"
  url_map = google_compute_url_map.relay[0].id
  # The wildcard cert map serves relay.hopme.sh + every <region>.relay.hopme.sh.
  certificate_map = "//certificatemanager.googleapis.com/${google_certificate_manager_certificate_map.relay.id}"
}

resource "google_compute_global_forwarding_rule" "https" {
  count                 = var.relays_enabled ? 1 : 0
  name                  = "hop-relay-https"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "443"
  target                = google_compute_target_https_proxy.relay[0].id
  ip_address            = google_compute_global_address.relay.id
}

# IPv6 frontends — same proxies, just the v6 anycast address.
resource "google_compute_global_forwarding_rule" "https_v6" {
  count                 = var.relays_enabled ? 1 : 0
  name                  = "hop-relay-https-v6"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "443"
  target                = google_compute_target_https_proxy.relay[0].id
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
