# Stripe webhook endpoint for the console. Stripe POSTs subscription/invoice lifecycle events to the
# console, which proxies /api/* to hop-accountd (POST /webhooks/stripe). hop-accountd verifies the
# signature over the raw body and STORES the tenant's plan + subscription status as durable
# entitlement (complementing the live current_subscription read path).
#
# Only the events hop-accountd handles are subscribed, so Stripe does not deliver noise the endpoint
# would just ack. The signing secret is a computed, sensitive attribute: creating this endpoint puts
# it in this root's state no matter what, so this root also writes it into the bootstrap-owned Secret
# Manager container `stripe-webhook-secret` (see webhook_secret.tf). That is the whole seeding step.
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
  description = "Stripe webhook signing secret for hop-accountd (STRIPE_WEBHOOK_SECRET). This root writes it into the bootstrap-owned `stripe-webhook-secret` container; the output is for inspection only."
  value       = stripe_webhook_endpoint.hop_console.secret
  sensitive   = true
}
