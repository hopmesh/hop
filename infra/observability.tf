# Observability + log retention for the relay fleet (GAP-ANALYSIS.md F-16, F-24).
#
# infra-r2-04: the Monitoring + Logging APIs are enabled in apis.tf (monitoring.googleapis.com,
# logging.googleapis.com), and every resource below carries depends_on = [google_project_service.this]
# so a cold-project apply enables the APIs before creating alert policies / log buckets (otherwise the
# first apply 403s "Monitoring API has not been used"). Set TF_VAR_alert_email to receive alerts;
# leave empty to skip the notification channel + alerts.
#
# ALL of this is gated on var.relays_enabled: with the fleet off there are no relay logs to route
# or alert on. (The build SA now holds roles/logging.admin, added in cloudbuild_trigger.tf, so the
# log bucket + sink + exclusion apply cleanly when relays_enabled flips back to true; plain editor
# lacked logging.buckets.create / logging.exclusions.create, which 403'd the first apply.)

# ---- F-16: stop the relay netlog metadata from persisting 30 days in _Default ---------------------
#
# hop-relayd mirrors every netlog line to stderr (so it lands in Cloud Logging), including device
# address prefixes, ingest/handoff destinations + region, and spool mailbox-tag prefixes — exactly the
# "pseudonymous address → coarse location + activity timeline" DESIGN §33 calls the most sensitive
# dataset and claims is ephemeral/on-device only. Route the relay services' logs to a dedicated
# short-retention bucket instead of the 30-day _Default, so at-rest persistence is minimized without
# killing the live debugging stream (serve_log_stream is a separate, in-memory ring).
resource "google_logging_project_bucket_config" "relay_short" {
  count          = var.relays_enabled ? 1 : 0
  project        = var.project_id
  location       = "global"
  bucket_id      = "relay-short-retention"
  retention_days = 3
  description    = "Short-retention sink for relay logs (F-16): minimizes at-rest metadata exposure."

  depends_on = [google_project_service.this] # infra-r2-04: logging API enabled first
}

resource "google_logging_project_sink" "relay" {
  count                  = var.relays_enabled ? 1 : 0
  name                   = "relay-to-short-retention"
  project                = var.project_id
  destination            = "logging.googleapis.com/projects/${var.project_id}/locations/global/buckets/${google_logging_project_bucket_config.relay_short[0].bucket_id}"
  filter                 = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name:\"relay\""
  unique_writer_identity = true

  depends_on = [google_project_service.this] # infra-r2-04
}

# Keep the relay logs OUT of the 30-day _Default bucket (they now live in the short bucket above).
resource "google_logging_project_exclusion" "relay_from_default" {
  count       = var.relays_enabled ? 1 : 0
  name        = "exclude-relay-from-default"
  project     = var.project_id
  description = "F-16: relay logs are routed to the short-retention bucket; don't also keep them 30d in _Default."
  filter      = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name:\"relay\""

  depends_on = [google_project_service.this] # infra-r2-04
}

# ---- F-24: alerting on the failure modes that are currently invisible ------------------------------
#
# There is otherwise no alert on region crash-loops/OOM, Firestore quota/IAM failures that silently
# kill handoff/presence/§39-P5 delivery (all just eprintln'd "... FAILED"), or the known 429/wake-churn.
variable "alert_email" {
  description = "Email to receive relay fleet alerts (F-24). Empty disables the channel + alerts."
  type        = string
  default     = ""
}

resource "google_monitoring_notification_channel" "email" {
  count        = (var.relays_enabled && var.alert_email != "") ? 1 : 0
  project      = var.project_id
  display_name = "Hop relay alerts"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }

  depends_on = [google_project_service.this] # infra-r2-04: monitoring API enabled first
}

# Log-based metric counting the relay's own "FAILED" lines (handoff FAILED / spool FAILED / etc).
resource "google_logging_metric" "relay_failed" {
  count   = var.relays_enabled ? 1 : 0
  project = var.project_id
  name    = "relay_failed_ops"
  filter  = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name:\"relay\" AND textPayload:\"FAILED\""
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }

  depends_on = [google_project_service.this] # infra-r2-04
}

resource "google_monitoring_alert_policy" "relay_failed" {
  count        = (var.relays_enabled && var.alert_email != "") ? 1 : 0
  project      = var.project_id
  display_name = "Relay FAILED ops (handoff/spool/presence)"
  combiner     = "OR"
  conditions {
    display_name = "relay_failed_ops > 0"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.relay_failed[0].name}\" AND resource.type=\"cloud_run_revision\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_DELTA"
      }
    }
  }
  notification_channels = [google_monitoring_notification_channel.email[0].id]

  depends_on = [google_project_service.this] # infra-r2-04
}

# Cloud Run 5xx / request failures across the relay services (covers 429 wake-churn + crash loops).
resource "google_monitoring_alert_policy" "relay_5xx" {
  count        = (var.relays_enabled && var.alert_email != "") ? 1 : 0
  project      = var.project_id
  display_name = "Relay Cloud Run 5xx/429"
  combiner     = "OR"
  conditions {
    display_name = "request_count 4xx/5xx"
    condition_threshold {
      filter          = "resource.type=\"cloud_run_revision\" AND metric.type=\"run.googleapis.com/request_count\" AND metric.labels.response_code_class!=\"2xx\""
      comparison      = "COMPARISON_GT"
      threshold_value = 20
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }
  notification_channels = [google_monitoring_notification_channel.email[0].id]

  depends_on = [google_project_service.this] # infra-r2-04
}
