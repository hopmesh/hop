# Docker repo for the hop-relayd image. One repo in the primary region is enough;
# Cloud Run pulls cross-region transparently.
resource "google_artifact_registry_repository" "hop" {
  location      = "us-central1"
  repository_id = "hop"
  description   = "Hop container images (hop-relayd)."
  format        = "DOCKER"

  depends_on = [google_project_service.this]
}
