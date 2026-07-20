# Stripe webhook endpoint for the console. Stripe POSTs subscription/invoice lifecycle events to the
# console, which proxies /api/* to hop-accountd (POST /webhooks/stripe). hop-accountd verifies the
# signature over the raw body and STORES the tenant's plan + subscription status as durable
# entitlement (complementing the live current_subscription read path).
#
# Only the events hop-accountd handles are subscribed, so Stripe does not deliver noise the endpoint
# would just ack. The signing secret is a computed, sensitive attribute exposed as an output; it is
# seeded OUT OF BAND into the bootstrap-owned Secret Manager container `stripe-webhook-secret`
# (infra/bootstrap/billing.tf). The billing and bootstrap roots have separate state and providers
# (Stripe vs Google), so the secret is deliberately not wired across them in Terraform.
resource "stripe_webhook_endpoint" "hop_console" {
  url = "https://dashboard.hopme.sh/api/webhooks/stripe"

  enabled_events = [
    "customer.subscription.created",
    "customer.subscription.updated",
    "customer.subscription.deleted",
    "checkout.session.completed",
    "invoice.paid",
    "invoice.payment_failed",
  ]

  description = "Hop console durable-entitlement sync (hop-accountd)."
}

output "webhook_signing_secret" {
  description = "Stripe webhook signing secret for hop-accountd (STRIPE_WEBHOOK_SECRET). Seed it into the bootstrap-owned Secret Manager container `stripe-webhook-secret` out of band."
  value       = stripe_webhook_endpoint.hop_console.secret
  sensitive   = true
}
