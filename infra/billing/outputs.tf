# IDs the runtime needs: the account service attaches prices to subscriptions, and the
# reconciler emits meter events by `event_name` (DESIGN.md §37).

output "product_id" {
  description = "Stripe product id for the Hop Backbone."
  value       = stripe_product.backbone.id
}

output "price_ids" {
  description = "Price ids to attach to a tenant subscription (base + metered)."
  value = {
    base          = stripe_price.base.id
    reach         = stripe_price.reach.id
    observability = stripe_price.observability.id
    egress        = stripe_price.egress.id
    mailbox       = stripe_price.mailbox.id
  }
}

output "meter_event_names" {
  description = "Meter event_names the reconciler emits usage against."
  value = {
    backbone_delivery = stripe_billing_meter.backbone_delivery.event_name
    telemetry_events  = stripe_billing_meter.telemetry_events.event_name
    egress            = stripe_billing_meter.egress.event_name
    mailbox           = stripe_billing_meter.mailbox.event_name
  }
}
