# Seed the Stripe webhook signing secret into Secret Manager, so hop-accountd can read it as
# STRIPE_WEBHOOK_SECRET without anyone running `gcloud secrets versions add`.
#
# The value is `stripe_webhook_endpoint.hop_console.secret`, a computed attribute Stripe returns only
# at create time. It is therefore already in this root's state; writing it to Secret Manager adds no
# new exposure and removes the one manual step left in the console deploy.
#
# The CONTAINER is bootstrap-owned (infra/bootstrap/billing.tf), together with the accountd
# secretAccessor grant, so this root writes a version into it by id and never creates or deletes the
# container itself. That means the bootstrap root must already be applied (a `confirm=apply` dispatch
# of bootstrap-apply.yml) before this apply, otherwise the version write fails missing-secret.
#
# The normal apply path is the `Billing catalog (Stripe)` workflow running as billing-catalog-apply.
# Bootstrap grants that identity secretVersionAdder + secretAccessor on THIS container only
# (infra/bootstrap/billing.tf), which is exactly what the write and the next refresh need.
resource "google_secret_manager_secret_version" "stripe_webhook_secret" {
  secret      = "projects/${var.project_id}/secrets/stripe-webhook-secret"
  secret_data = stripe_webhook_endpoint.hop_console.secret
}
