# example.hopme.sh — a live `hops://` demo (DESIGN.md §30).
#
# A single-region Cloud Run service runs the hop-example image: a tiny HTTP origin on
# localhost fronted by a `hop-endpoint` bound to example.hopme.sh. A client speaking
# hops://example.hopme.sh resolves the endpoint address from the `_hopaddress` TXT record
# (HNS), reaches it over the mesh (or dials wss://example.hopme.sh through the shared LB),
# and the endpoint serves ONLY its own origin — never an open proxy.
#
# It reuses the relay's global LB (one more host rule + a SNI cert entry) and anycast IPs,
# so it costs one Cloud Run service, not a second load balancer.

locals {
  example_domain   = "example.${trimsuffix(var.dns_zone_dns_name, ".")}" # example.hopme.sh
  example_ar_image = "us-central1-docker.pkg.dev/${var.project_id}/hop/hop-example"
  example_image = (
    length(var.spacelift_commit_sha) >= 7 ? "${local.example_ar_image}:${substr(var.spacelift_commit_sha, 0, 7)}" :
    "${local.example_ar_image}:latest"
  )
  # The endpoint's published Hop address (base58), computed once from its identity seed via
  # `hop-endpoint --print-address`. This is a public key, safe to commit; the seed itself
  # lives only in Secret Manager (see data.google_secret_manager_secret.example_identity).
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
# Terraform only reads it (a data source) so it never holds the private key.
data "google_secret_manager_secret" "example_identity" {
  secret_id = "hop-example-identity"
}

resource "google_secret_manager_secret_iam_member" "example_identity" {
  secret_id = data.google_secret_manager_secret.example_identity.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.relay.email}"
}

# The endpoint service. Scale-to-zero like the relays; one region is plenty for a demo.
resource "google_cloud_run_v2_service" "example" {
  name     = "hop-example"
  location = var.example_region
  ingress  = var.cloud_run_ingress

  deletion_protection = false

  lifecycle {
    ignore_changes = [scaling]
  }

  template {
    service_account = google_service_account.relay.email
    timeout         = "${var.ws_request_timeout_seconds}s"

    # Always-on (min = 1): the endpoint must stay connected to the relay to be routable by
    # its address — a scaled-to-zero endpoint disconnects, so messages to it just sit held on
    # the relay. As a routable mesh leaf (DESIGN.md §30) it needs a persistent presence.
    scaling {
      min_instance_count = 1
      max_instance_count = 1
    }

    containers {
      image = local.example_image

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
        secret = data.google_secret_manager_secret.example_identity.secret_id
        items {
          version = "latest"
          path    = "identity"
        }
      }
    }
  }

  depends_on = [
    google_project_service.this,
    google_secret_manager_secret_iam_member.example_identity,
  ]
}

# Public invoker — access control is the Noise handshake, not IAM (same as the relays).
resource "google_cloud_run_v2_service_iam_member" "example_public" {
  location = google_cloud_run_v2_service.example.location
  name     = google_cloud_run_v2_service.example.name
  role     = "roles/run.invoker"
  member   = "allUsers"
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
# already serves the map, so adding this entry makes it serve example.hopme.sh too — the
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

# HNS record (DESIGN.md §30): clients resolve _hopaddress.example.hopme.sh → the endpoint's
# Hop address, then seal hops:// requests to it. The TTL is the HNS cache lifetime.
resource "google_dns_record_set" "example_hopaddress" {
  name         = "_hopaddress.${local.example_domain}."
  managed_zone = google_dns_managed_zone.hopme.name
  type         = "TXT"
  ttl          = 300
  rrdatas      = ["\"${local.example_endpoint_address}\""]
}

# The CNAME proving control for the example cert's DNS authorization.
resource "google_dns_record_set" "example_dnsauth" {
  name         = google_certificate_manager_dns_authorization.example.dns_resource_record[0].name
  managed_zone = google_dns_managed_zone.hopme.name
  type         = google_certificate_manager_dns_authorization.example.dns_resource_record[0].type
  ttl          = 300
  rrdatas      = [google_certificate_manager_dns_authorization.example.dns_resource_record[0].data]
}
