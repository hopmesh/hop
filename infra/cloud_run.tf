# One relay per region. Scale-to-zero (min = 0): an idle region costs nothing and
# spins up on the first WebSocket connection, then back to zero when the last one
# drops (the user's "go offline automatically if no nodes are connected"). Ingress
# is var.cloud_run_ingress: open while testing via *.run.app, LB-only once DNS lands.
resource "google_cloud_run_v2_service" "relay" {
  for_each = local.regions

  name     = "hop-relay-${each.value}"
  location = each.value
  ingress  = var.cloud_run_ingress

  deletion_protection = false

  # The Cloud Run API auto-populates a service-level `scaling` block; we manage
  # scaling via template.scaling, so ignore the service-level one to avoid a
  # cosmetic perpetual diff.
  lifecycle {
    ignore_changes = [scaling]
  }

  template {
    service_account = google_service_account.relay.email
    timeout         = "${var.ws_request_timeout_seconds}s"

    scaling {
      min_instance_count = 0
      max_instance_count = var.max_instances_per_region
    }

    containers {
      image = local.relay_image

      # Explicit command/args (overrides the Dockerfile CMD) so each region runs as a
      # distinct backbone node: --region derives a per-region identity, --advertise is
      # this region's per-region subdomain (<region>.relay.hopme.sh) that peers dial and
      # that the node reports from hop.identify (DESIGN.md §28/§29). The presence of
      # --region + --advertise + --firestore activates the registry + pull-on-wake.
      command = ["hop-relayd"]
      args = [
        "--ws", "0.0.0.0:8080",
        "--firestore", var.project_id,
        "--identity-file", "/etc/hop/identity",
        "--region", each.value,
        "--advertise", "wss://${each.value}.${var.domain}/",
      ]

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
    }

    volumes {
      name = "identity"
      secret {
        secret = google_secret_manager_secret.relay_identity.secret_id
        items {
          version = "latest"
          path    = "identity"
        }
      }
    }
  }

  depends_on = [
    google_project_service.this,
    google_secret_manager_secret_iam_member.relay_identity,
  ]
}

# The LB front-end authenticates Hop links itself via Noise XX, so the Cloud Run
# invoker is public; access control is the handshake, not IAM.
resource "google_cloud_run_v2_service_iam_member" "public" {
  for_each = google_cloud_run_v2_service.relay

  location = each.value.location
  name     = each.value.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
