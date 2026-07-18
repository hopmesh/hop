# Product + prices. One product, one base (flat) price, and four metered prices,
# each bound to a meter. A tenant's subscription carries the base price plus whichever
# metered items apply; the account service builds subscriptions at signup (§37).
#
# Metered per-unit amounts are fractions of a cent, so we use `unit_amount_decimal`
# (a string, in cents) computed from the cents-per-bulk-unit variables.

resource "stripe_product" "backbone" {
  name        = "Hop Backbone"
  description = "Hosted delay-tolerant mesh backbone: relay, mailbox, and egress."
}

# Base platform fee (flat, recurring, licensed). $0 by default (free-tier compatible).
resource "stripe_price" "base" {
  product     = stripe_product.backbone.id
  currency    = var.currency
  unit_amount = var.base_fee_cents

  recurring {
    interval   = "month"
    usage_type = "licensed"
  }
}

# Active devices, per device (priced per 1,000 MAD → divide by 1,000).
resource "stripe_price" "active_devices" {
  product             = stripe_product.backbone.id
  currency            = var.currency
  unit_amount_decimal = tostring(var.price_per_1k_devices_cents / 1000)

  recurring {
    interval   = "month"
    usage_type = "metered"
    meter      = stripe_billing_meter.active_devices.id
  }
}

# Data carried, per chunk (priced per 1,000,000 chunks → divide by 1e6).
resource "stripe_price" "data_carried" {
  product             = stripe_product.backbone.id
  currency            = var.currency
  unit_amount_decimal = tostring(var.price_per_million_chunks_cents / 1000000)

  recurring {
    interval   = "month"
    usage_type = "metered"
    meter      = stripe_billing_meter.data_carried.id
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
