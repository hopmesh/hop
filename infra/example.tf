# example.hopme.sh: a live `hops://` demo (DESIGN.md §30).
#
# A single-region Cloud Run service runs the hop-example image: a tiny HTTP origin on
# localhost fronted by a `hop-endpoint` bound to example.hopme.sh. A client speaking
# hops://example.hopme.sh resolves the endpoint address by fetching the signed reach record
# at https://example.hopme.sh/.well-known/hop (HNS, §30), reaches it over the mesh (or dials
# wss://example.hopme.sh through the shared LB), and the endpoint serves ONLY its own origin,
# never an open proxy.
#
# It reuses the relay's global LB (one more host rule + a SNI cert entry) and anycast IPs,
# so it costs one Cloud Run service, not a second load balancer.

locals {
  example_domain = "example.${trimsuffix(var.dns_zone_dns_name, ".")}" # example.hopme.sh
  # The endpoint's published Hop address (base58), computed once from its identity seed via
  # `hop-endpoint --print-address`. This is a public key, safe to commit; the seed itself
  # lives only in Secret Manager and is provisioned by infra/bootstrap.
  example_endpoint_address = "J8XGeYT2VA3aq6KeP85LEujpAjg3LBbLLvivyoNFWTFr"
}

# The example endpoint's 32-byte identity seed. Created + seeded out-of-band (never in TF
# state), so the published address (local.example_endpoint_address) stays stable. Recreate
# with, then point local.example_endpoint_address at its `--print-address`:
#
#   gcloud secrets create hop-example-identity --project hop-mesh --replication-policy=automatic
#   head -c 32 /dev/urandom > /tmp/seed
#   gcloud secrets versions add hop-example-identity --project hop-mesh --data-file=/tmp/seed
#   hop-endpoint --print-address --identity-file /tmp/seed
#
# The endpoint service. Always-on (min=1); one region is plenty for a demo. (F-39: NOT scale-to-zero
# like the relays, the endpoint must stay relay-connected to be routable, so min_instance_count=1.)
resource "google_cloud_run_v2_service" "example" {
  name     = "hop-example"
  location = var.example_region
  # The endpoint trusts the load balancer's exact XFF suffix only for internal Cloud Run proxy peers.
  # Prevent direct *.run.app ingress from bypassing that topology and supplying its own chain.
  ingress              = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  default_uri_disabled = true

  invoker_iam_disabled = true

  labels = {
    "hop-source-sha" = var.deployment_source_sha
  }
  annotations = {
    "hopmesh.dev/environment" = var.deployment_environment
  }

  deletion_protection = false

  lifecycle {
    ignore_changes = [scaling]
  }

  template {
    service_account = local.example_service_account
    timeout         = "${var.ws_request_timeout_seconds}s"

    # Always-on (min = 1): the endpoint must stay connected to the relay to be routable by
    # its address, a scaled-to-zero endpoint disconnects, so messages to it just sit held on
    # the relay. As a routable mesh leaf (DESIGN.md §30) it needs a persistent presence.
    scaling {
      min_instance_count = 1
      max_instance_count = 1
    }

    containers {
      image = var.example_image

      ports {
        container_port = 8080
      }

      env {
        name  = "HOP_DOMAIN"
        value = local.example_domain
      }
      env {
        name  = "HOP_IDENTITY_FILE"
        value = "/etc/hop/identity"
      }
      env {
        name  = "HOP_TRUSTED_PROXY"
        value = "google-cloud-run"
      }
      env {
        name  = "HOP_TRUSTED_PROXY_HOPS"
        value = "1"
      }
      env {
        name  = "HOP_TRUSTED_PROXY_PEER_CIDRS"
        value = "169.254.8.129/32"
      }
      env {
        name  = "HOP_TRUSTED_PROXY_SUFFIX_CIDRS"
        value = "${google_compute_global_address.relay.address}/32,${google_compute_global_address.relay_v6.address}/128"
      }
      # services-r2-01: actually ACTIVATE the coded graceful-degrade path. When the relay fleet is
      # torn down (var.relays_enabled = false) the always-on (min=1) example instance would otherwise
      # dial the default wss://relay.hopme.sh/ forever, logging "mesh-unreachable" + burning a
      # reconnect every 60s. The endpoint reads HOP_NO_RELAY=1 (services-11) to skip the dead relay
      # and just serve its origin over HTTP. Gated on the SAME var so it flips back to relay-dialing
      # (env absent -> default dial) the moment the fleet is re-enabled (no container arg change).
      dynamic "env" {
        for_each = var.relays_enabled ? [] : [1]
        content {
          name  = "HOP_NO_RELAY"
          value = "1"
        }
      }
      volume_mounts {
        name       = "identity"
        mount_path = "/etc/hop"
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        # Always-allocated CPU (not idle-throttled): the endpoint keeps a persistent outbound
        # WebSocket to the relay in a background thread, which would stall under request-only
        # CPU. Pairs with min_instance_count = 1.
        cpu_idle = false
      }
    }

    volumes {
      name = "identity"
      secret {
        secret = "hop-example-identity"
        items {
          # PINNED to the bootstrap-selected numeric version, NOT "latest".
          # The endpoint's published address (local.example_endpoint_address, in DNS + the HNS TXT
          # record) is derived from THIS seed, so the seed must never silently change. With "latest",
          # anyone adding a new secret version would swap the identity out from under the mount on the
          # next revision, making the endpoint unreachable at its published address. Pinning the version
          # makes the identity, and therefore the published address, immutable across deploys. If the
          # identity is ever intentionally rotated, bump both this version and
          # local.example_endpoint_address together.
          version = var.example_identity_version
          path    = "identity"
        }
      }
    }
  }

}

# --- Plumb example.hopme.sh through the shared global LB ------------------------------

resource "google_compute_region_network_endpoint_group" "example" {
  name                  = "hop-example-neg"
  region                = var.example_region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_v2_service.example.name
  }
}

resource "google_compute_backend_service" "example" {
  name                  = "hop-example-backend"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTP"

  backend {
    group = google_compute_region_network_endpoint_group.example.id
  }
}

# --- TLS for example.hopme.sh via the existing Certificate Manager cert map -----------
# A separate DNS-authorized cert + a SNI (hostname) cert-map entry. The relay's proxy
# already serves the map, so adding this entry makes it serve example.hopme.sh too, the
# relay's own cert/entry is untouched.
resource "google_certificate_manager_dns_authorization" "example" {
  name   = "hop-example-dnsauth"
  domain = local.example_domain

  depends_on = [time_sleep.certmanager_ready]
}

resource "google_certificate_manager_certificate" "example" {
  name = "hop-example-cert"

  managed {
    domains            = [local.example_domain]
    dns_authorizations = [google_certificate_manager_dns_authorization.example.id]
  }
}

resource "google_certificate_manager_certificate_map_entry" "example" {
  name         = "hop-example-certmap-entry"
  map          = google_certificate_manager_certificate_map.relay.name
  certificates = [google_certificate_manager_certificate.example.id]
  hostname     = local.example_domain
}

# --- DNS for example.hopme.sh --------------------------------------------------------
# A/AAAA point at the same anycast LB IPs; the host rule (in load_balancer.tf) routes the
# example host to the example backend.
resource "google_dns_record_set" "example_a" {
  name         = "${local.example_domain}."
  managed_zone = google_dns_managed_zone.hopme.name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.relay.address]
}

resource "google_dns_record_set" "example_aaaa" {
  name         = "${local.example_domain}."
  managed_zone = google_dns_managed_zone.hopme.name
  type         = "AAAA"
  ttl          = 300
  rrdatas      = [google_compute_global_address.relay_v6.address]
}

# HNS resolution (DESIGN.md §30) needs NO DNS record: clients resolve example.hopme.sh by fetching
# https://example.hopme.sh/.well-known/hop, which the hop-endpoint serves (a signed reach record) via
# the same LB host rule + cert already wired below. The domain's TLS cert proves the domain; the reach
# record self-certifies the Hop address.

# The CNAME proving control for the example cert's DNS authorization.
resource "google_dns_record_set" "example_dnsauth" {
  name         = google_certificate_manager_dns_authorization.example.dns_resource_record[0].name
  managed_zone = google_dns_managed_zone.hopme.name
  type         = google_certificate_manager_dns_authorization.example.dns_resource_record[0].type
  ttl          = 300
  rrdatas      = [google_certificate_manager_dns_authorization.example.dns_resource_record[0].data]
}
