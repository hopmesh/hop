# Project number, used to build each region's stable Cloud Run URL for the backbone
# advertise endpoint (https://<service>-<number>.<region>.run.app).
data "google_project" "this" {
  project_id = var.project_id
}
