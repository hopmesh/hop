# Runtime identity for every regional Cloud Run relay. Least privilege: read/write
# its Firestore mailbox, read the identity secret, write logs.
resource "google_service_account" "relay" {
  account_id   = "hop-relay"
  display_name = "Hop relay (Cloud Run)"
}

resource "google_project_iam_member" "relay_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.relay.email}"
}

resource "google_project_iam_member" "relay_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.relay.email}"
}

# Access to the shared relay identity seed.
resource "google_secret_manager_secret_iam_member" "relay_identity" {
  secret_id = google_secret_manager_secret.relay_identity.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.relay.email}"
}
