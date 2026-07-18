# One relay per region. Scale-to-zero (min = 0): an idle region costs nothing and
# spins up on the first WebSocket connection, then back to zero when the last one
# drops (the user's "go offline automatically if no nodes are connected"). Ingress
# is restricted to internal and load-balancer traffic; the default service URI is disabled.
resource "google_cloud_run_v2_service" "relay" {
  for_each = local.regions

  name     = "hop-relay-${each.value}"
  location = each.value
  ingress  = var.cloud_run_ingress
  # The global external Application Load Balancer is the only public front door.
  default_uri_disabled = true

  # Public invocation is an explicit service setting, not a runtime IAM mutation.
  # Hop authenticates links with Noise XX after ingress.
  invoker_iam_disabled = true

  labels = {
    "hop-source-sha" = var.deployment_source_sha
  }
  annotations = {
    "hopmesh.dev/build-id"        = var.deployment_build_id
    "hopmesh.dev/environment"     = var.deployment_environment
    "hopmesh.dev/manifest-sha256" = var.deployment_manifest_sha256
  }

  deletion_protection = false

  # The Cloud Run API auto-populates a service-level `scaling` block; we manage
  # scaling via template.scaling, so ignore the service-level one to avoid a
  # cosmetic perpetual diff.
  lifecycle {
    ignore_changes = [scaling]
  }

  template {
    service_account = local.relay_service_account
    timeout         = "${var.ws_request_timeout_seconds}s"

    scaling {
      min_instance_count = 0
      max_instance_count = var.max_instances_per_region
    }

    containers {
      image = var.relay_image

      # Explicit command/args (overrides the Dockerfile CMD) so each region runs as a
      # distinct backbone node: --region derives a per-region identity, --advertise is
      # this region's per-region subdomain (<region>.relay.hopme.sh) that peers dial and
      # that the node reports from hop.identify (DESIGN.md §28/§29). The presence of
      # --region + --advertise + --firestore activates the registry + pull-on-wake.
      command = ["hop-relayd"]
      # Base args; --mesh-fanout (online-only relay-to-relay epidemic, §28) is appended only
      # when var.mesh_fanout > 0, so the fleet stays handoff-only until deliberately enabled.
      args = concat(
        [
          "--ws", "0.0.0.0:8080",
          "--firestore", var.project_id,
          "--identity-file", "/etc/hop/identity",
          "--region", each.value,
          "--advertise", "wss://${each.value}.${var.domain}/",
        ],
        var.mesh_fanout > 0 ? ["--mesh-fanout", tostring(var.mesh_fanout)] : [],
      )

      # Cloud Run injects $PORT; the relay serves its WebSocket bearer there.
      ports {
        container_port = 8080
      }

      # Durable per-node store lives in Firestore in this project.
      env {
        name  = "HOP_FIRESTORE_PROJECT"
        value = var.project_id
      }
      env {
        name  = "HOP_REGION"
        value = each.value
      }

      # Shared identity seed, mounted read-only as 32 raw bytes.
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
          cpu = "1"
          # Headroom for the larger custody window (set_max_relayed=8192): at the 48 KiB
          # media-chunk size that's ~400 MiB worst case; 2 GiB leaves room for the rest.
          memory = "2Gi"
        }
        cpu_idle = true # bill CPU only while requests/connections are in flight
      }

      # F-17: container-level liveness probes tied only to the driver loop heartbeat. Durable
      # readiness remains on /healthz so a Firestore outage stops traffic without a restart loop.
      # Without these Cloud Run's default TCP check passes for a WEDGED instance forever, and with
      # one instance per region a wedged instance IS the region. These are internal to Cloud Run —
      # do NOT add an external uptime check against the region endpoints (DESIGN.md §1436: it wakes
      # scaled-to-zero instances).
      startup_probe {
        http_get {
          path = "/livez"
          port = 8080
        }
        initial_delay_seconds = 5
        period_seconds        = 10
        failure_threshold     = 6
      }
      liveness_probe {
        http_get {
          path = "/livez"
          port = 8080
        }
        period_seconds    = 30
        failure_threshold = 3
      }
    }

    volumes {
      name = "identity"
      secret {
        secret = "hop-relay-identity"
        items {
          # F-23: pin the exact version seeded during bootstrap. A mutable alias can re-key regions on
          # different cold starts, split-braining the fleet and orphaning Firestore partitions.
          version = var.relay_identity_version
          path    = "identity"
        }
      }
    }
  }

}
