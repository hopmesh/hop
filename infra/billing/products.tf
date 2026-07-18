# Product + prices. One product, one base (flat) price, and four metered prices,
# each bound to a meter. A tenant's subscription carries the base price plus whichever
# metered items apply; the account service builds subscriptions at signup (§37).
#
# Metered per-unit amounts are fractions of a cent, so we use `unit_amount_decimal`
# (a string, in cents) computed from the cents-per-bulk-unit variables.

resource "stripe_product" "backbone" {
  name        = "Hop Backbone"
  description = "Delay-tolerant mesh backbone: reach offline devices, plus telemetry, egress, and mailbox."
}

# Base platform fee (flat, recurring, licensed). $0 by default: the free tier keeps the
# barrier to entry at zero, revenue comes from metered reach.
resource "stripe_price" "base" {
  product     = stripe_product.backbone.id
  currency    = var.currency
  unit_amount = var.base_fee_cents

  recurring {
    interval   = "month"
    usage_type = "licensed"
  }
}

# Backbone reach, per offline delivery (priced per 1,000 deliveries, so divide by 1,000).
resource "stripe_price" "reach" {
  product             = stripe_product.backbone.id
  currency            = var.currency
  unit_amount_decimal = tostring(var.price_per_1k_deliveries_cents / 1000)

  recurring {
    interval   = "month"
    usage_type = "metered"
    meter      = stripe_billing_meter.backbone_delivery.id
  }
}

# Observability, per telemetry event (priced per 1,000,000 events, so divide by 1e6).
resource "stripe_price" "observability" {
  product             = stripe_product.backbone.id
  currency            = var.currency
  unit_amount_decimal = tostring(var.price_per_million_events_cents / 1000000)

  recurring {
    interval   = "month"
    usage_type = "metered"
    meter      = stripe_billing_meter.telemetry_events.id
  }
}

# Internet egress, per GB.
resource "stripe_price" "egress" {
  product             = stripe_product.backbone.id
  currency            = var.currency
  unit_amount_decimal = tostring(var.price_per_gb_egress_cents)

  recurring {
    interval   = "month"
    usage_type = "metered"
    meter      = stripe_billing_meter.egress.id
  }
}

# Mailbox storage, per GB-month.
resource "stripe_price" "mailbox" {
  product             = stripe_product.backbone.id
  currency            = var.currency
  unit_amount_decimal = tostring(var.price_per_gb_month_mailbox_cents)

  recurring {
    interval   = "month"
    usage_type = "metered"
    meter      = stripe_billing_meter.mailbox.id
  }
}
