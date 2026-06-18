# The shared 32-byte relay identity seed. All regions mount the SAME version, so
# every entrance/exit presents one stable Hop address backed by one Firestore node.
#
# The seed is a private key, so Terraform never holds it in state: this resource
# creates the empty secret container only. Seed it ONCE, out-of-band, before the
# first deploy:
#
#   head -c 32 /dev/urandom \
#     | gcloud secrets versions add hop-relay-identity --project hop-mesh --data-file=-
#
# hop-relayd reads the mounted 32 bytes via --identity-file (see cloud_run.tf).
resource "google_secret_manager_secret" "relay_identity" {
  secret_id = "hop-relay-identity"

  replication {
    auto {}
  }

  depends_on = [google_project_service.this]
}
