# IDs the runtime needs: the account service attaches prices to subscriptions, and the
# reconciler emits meter events by `event_name` (DESIGN.md §37).

output "product_id" {
  description = "Stripe product id for the Hop Backbone."
  value       = stripe_product.backbone.id
}

output "price_ids" {
  description = "Price ids to attach to a tenant subscription (base + metered)."
  value = {
    base           = stripe_price.base.id
    active_devices = stripe_price.active_devices.id
    data_carried   = stripe_price.data_carried.id
    egress         = stripe_price.egress.id
    mailbox        = stripe_price.mailbox.id
  }
}

output "meter_event_names" {
  description = "Meter event_names the reconciler emits usage against."
  value = {
    active_devices = stripe_billing_meter.active_devices.event_name
    data_carried   = stripe_billing_meter.data_carried.event_name
    egress         = stripe_billing_meter.egress.event_name
    mailbox        = stripe_billing_meter.mailbox.event_name
  }
}
