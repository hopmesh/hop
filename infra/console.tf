# The console: hop-accountd (backend) + hop-console (Next.js front at dashboard.hopme.sh).
#
# hop-accountd is the console backend (auth, orgs, billing, keys, console reads, team, tenant-sync
# writer). hop-console is public through the SAME shared global LB the relay and example use (one more
# host rule + SNI cert entry on dashboard.hopme.sh), so it costs one Cloud Run service, not a second
# load balancer.

locals {
  console_domain = "dashboard.${trimsuffix(var.dns_zone_dns_name, ".")}" # dashboard.hopme.sh
  # Stripe price ids for the two-meter model, read from the isolated billing state (infra/billing).
  # HOP_STRIPE_USAGE_PRICES / HOP_STRIPE_SCALE_METERED_PRICES are the metered (reach + observability)
  # prices; HOP_STRIPE_SCALE_BASE_PRICE is the committed-tier base.
  billing_prices         = data.terraform_remote_state.billing.outputs.price_ids
  console_metered_prices = "${local.billing_prices.reach},${local.billing_prices.observability}"
}

# The Stripe catalog lives in its own OpenTofu root (infra/billing) so the account service reads the
# price ids from that state rather than re-deriving them. A deliberate, reviewed cross-root read: the
# authority guard allows only this one terraform_remote_state data source, and hop-deploy holds
# READ-ONLY object access on the billing/ prefix (infra/bootstrap/console.tf).
data "terraform_remote_state" "billing" {
  backend = "gcs"
  config = {
    bucket = "hop-mesh-tfstate"
    prefix = "billing"
  }
}

# --- hop-accountd: the console backend ------------------------------------------------
# min = 1 / cpu_idle = false: it runs the Firestore tenant-sync thread and a persistent Postgres pool,
# both of which need always-allocated CPU and a warm instance. Its default run.app URI stays enabled
# (NOT default_uri_disabled) so the console addresses it via google_cloud_run_v2_service.accountd.uri.
#
# Ingress is ALL so the console's server-side proxy (a separate Cloud Run service) can reach it over the
# run.app URI without VPC plumbing. This is NOT an open door: every accountd route is authenticated at
# the app layer, a __Host- session cookie (/console/*, /keys/*, /settings/*, /billing/*), the HOP_API_TOKEN
# bearer (/v1/*), or the Stripe signature (/webhooks/stripe); /auth/* is a login surface by design. The
# private-hardening follow-up (ingress INTERNAL_ONLY + a Direct VPC egress on the console so its calls
# are classified internal) needs the live project's VPC/subnet to validate, so it is a first-apply item.
#
# SVC-003: because ingress is ALL, nothing here makes accountd reachable ONLY through the console proxy,
# so no app-layer control may assume it. In particular the `X-Hop-Client-IP` header the console sets is
# not authenticated: any internet host can reach /auth/request-link on the run.app URI and send its own.
# accountd therefore bounds sign-in mail on the address the platform appends (REQUEST_LINK_MAX_PER_HOP in
# auth_api.rs) and uses the forwarded value only to subdivide that bound. If this ingress ever becomes
# INTERNAL_ONLY, that is when the forwarded value can be promoted to a trusted identity, not before.
resource "google_cloud_run_v2_service" "accountd" {
  name     = "hop-accountd"
  location = var.example_region
  ingress  = "INGRESS_TRAFFIC_ALL"

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
    service_account = local.accountd_service_account

    # Mount the Cloud SQL Auth proxy socket for the hop_console instance at /cloudsql/<connection>.
    # The instance itself is bootstrap-owned (infra/bootstrap/console.tf), so the runtime root takes
    # its connection name as a pinned variable rather than a resource reference.
    annotations = {
      "run.googleapis.com/cloudsql-instances" = var.console_db_connection_name
    }

    # Always-on single instance: one tenant-sync writer, one warm PG pool. A second instance would
    # double-write the Firestore tenant registry, so pin max = 1.
    scaling {
      min_instance_count = 1
      max_instance_count = 1
    }

    containers {
      image = var.accountd_image

      ports {
        container_port = 8080
      }

      # --- plain config -----------------------------------------------------------------
      env {
        name  = "HOP_CONSOLE_BASE"
        value = "https://${local.console_domain}"
      }
      env {
        name  = "HOP_FIRESTORE_PROJECT"
        value = var.project_id
      }
      # Setting HOP_TENANT_SYNC_PROJECT activates the tenant-registry projection into Firestore that
      # the relays already read. HOP_TENANT_MAP is intentionally omitted: it drives the legacy operator
      # /v1/* invoice surface, while the console uses the cookie-authed /console/* surface.
      env {
        name  = "HOP_TENANT_SYNC_PROJECT"
        value = var.project_id
      }
      env {
        name  = "HOP_STRIPE_USAGE_PRICES"
        value = local.console_metered_prices
      }
      env {
        name  = "HOP_STRIPE_SCALE_METERED_PRICES"
        value = local.console_metered_prices
      }
      env {
        name  = "HOP_STRIPE_SCALE_BASE_PRICE"
        value = local.billing_prices.base
      }
      # An OAuth client id is public by construction: it rides in the authorize redirect URL every
      # browser sees. It is config, not a credential, so it lives in code (var.github_client_id)
      # where it is reviewable. The matching client SECRET stays in Secret Manager below.
      env {
        name  = "GITHUB_CLIENT_ID"
        value = var.github_client_id
      }
      # The Resend envelope-from address is public (it appears in every message header). Same
      # reasoning as the client id: plain config, not a credential.
      env {
        name  = "RESEND_FROM"
        value = var.resend_from
      }

      # --- secrets (bootstrap-owned containers; see infra/bootstrap/console.tf) ---------
      # Two postures, both deliberate. stripe-account-key, hop-resend-apikey, and
      # hop-github-oauth-client-secret hold credentials a third party issues to a human, so a human
      # seeds them and the bytes never enter any OpenTofu state. hop-api-token, console-db-url, and
      # stripe-webhook-secret are machine-generated and their values DO live in the bootstrap and
      # billing states, an owner-approved tradeoff for zero manual seeding; the access controlled
      # hop-mesh-tfstate bucket is the boundary protecting them. This runtime root reads none of
      # them: Cloud Run resolves every reference below at instance start.
      env {
        name = "STRIPE_ACCOUNT_KEY"
        value_source {
          secret_key_ref {
            secret  = "stripe-account-key"
            version = "latest"
          }
        }
      }
      env {
        name = "HOP_API_TOKEN"
        value_source {
          secret_key_ref {
            secret  = "hop-api-token"
            version = "latest"
          }
        }
      }
      env {
        name = "RESEND_API_KEY"
        value_source {
          secret_key_ref {
            secret  = "hop-resend-apikey"
            version = "latest"
          }
        }
      }
      env {
        name = "GITHUB_CLIENT_SECRET"
        value_source {
          secret_key_ref {
            secret  = "hop-github-oauth-client-secret"
            version = "latest"
          }
        }
      }
      # The full Postgres DSN. Both the container and its value are composed in infra/bootstrap
      # (console.tf) from the generated user password plus the Cloud SQL connection name, so no
      # operator ever types this.
      env {
        name = "DATABASE_URL"
        value_source {
          secret_key_ref {
            secret  = "console-db-url"
            version = "latest"
          }
        }
      }
      # Verifies Stripe webhook deliveries (POST /webhooks/stripe). The container is created in
      # infra/bootstrap (billing.tf); the value is written by the infra/billing apply, which is the root
      # that owns the Stripe webhook endpoint the signing secret belongs to.
      env {
        name = "STRIPE_WEBHOOK_SECRET"
        value_source {
          secret_key_ref {
            secret  = "stripe-webhook-secret"
            version = "latest"
          }
        }
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        # Always-allocated CPU: the tenant-sync thread and PG pool run outside request scope.
        cpu_idle = false
      }

      # hop-accountd serves readiness on /healthz (it has no /livez). Point both probes there.
      startup_probe {
        http_get {
          path = "/healthz"
          port = 8080
        }
        initial_delay_seconds = 5
        period_seconds        = 10
        failure_threshold     = 6
      }
      liveness_probe {
        http_get {
          path = "/healthz"
          port = 8080
        }
        period_seconds    = 30
        failure_threshold = 3
      }
    }
  }
}

# --- hop-console: the Next.js front at dashboard.hopme.sh -----------------------------
# Public through the shared LB (INTERNAL_LOAD_BALANCER ingress = reachable only via the LB, not the
# run.app URI, which is disabled). min = 0 / cpu_idle = true: scale-to-zero front. It holds no secrets;
# HOP_ACCOUNTD_URL is plain env pointing at the accountd service URI.
resource "google_cloud_run_v2_service" "console" {
  name                 = "hop-console"
  location             = var.example_region
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
    service_account = local.console_service_account

    scaling {
      min_instance_count = 0
      max_instance_count = 4
    }

    containers {
      image = var.console_image

      ports {
        container_port = 8080
      }

      env {
        name  = "HOP_ACCOUNTD_URL"
        value = google_cloud_run_v2_service.accountd.uri
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle = true
      }
      # No health endpoint on the Next front: rely on Cloud Run's default TCP startup check.
    }
  }
}

# --- Plumb dashboard.hopme.sh through the shared global LB ----------------------------
resource "google_compute_region_network_endpoint_group" "console" {
  name                  = "hop-console-neg"
  region                = var.example_region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_v2_service.console.name
  }
}

resource "google_compute_backend_service" "console" {
  name                  = "hop-console-backend"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTP"

  backend {
    group = google_compute_region_network_endpoint_group.console.id
  }
}

# --- TLS for dashboard.hopme.sh via the existing Certificate Manager cert map ---------
resource "google_certificate_manager_dns_authorization" "console" {
  name   = "hop-console-dnsauth"
  domain = local.console_domain

  depends_on = [time_sleep.certmanager_ready]
}

resource "google_certificate_manager_certificate" "console" {
  name = "hop-console-cert"

  managed {
    domains            = [local.console_domain]
    dns_authorizations = [google_certificate_manager_dns_authorization.console.id]
  }
}

resource "google_certificate_manager_certificate_map_entry" "console" {
  name         = "hop-console-certmap-entry"
  map          = google_certificate_manager_certificate_map.relay.name
  certificates = [google_certificate_manager_certificate.console.id]
  hostname     = local.console_domain
}

# --- DNS for dashboard.hopme.sh -------------------------------------------------------
resource "google_dns_record_set" "console_a" {
  name         = "${local.console_domain}."
  managed_zone = google_dns_managed_zone.hopme.name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.relay.address]
}

resource "google_dns_record_set" "console_aaaa" {
  name         = "${local.console_domain}."
  managed_zone = google_dns_managed_zone.hopme.name
  type         = "AAAA"
  ttl          = 300
  rrdatas      = [google_compute_global_address.relay_v6.address]
}

# The CNAME proving control for the console cert's DNS authorization.
resource "google_dns_record_set" "console_dnsauth" {
  name         = google_certificate_manager_dns_authorization.console.dns_resource_record[0].name
  managed_zone = google_dns_managed_zone.hopme.name
  type         = google_certificate_manager_dns_authorization.console.dns_resource_record[0].type
  ttl          = 300
  rrdatas      = [google_certificate_manager_dns_authorization.console.dns_resource_record[0].data]
}
