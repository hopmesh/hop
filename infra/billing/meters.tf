# Stripe Billing Meters — the four usage dimensions (DESIGN.md §37).
#
# The `event_name` of each meter is the CONTRACT between the relay reconciler and
# Stripe: the reconciler emits meter events with these names + a payload of
# { stripe_customer_id, value }. Meters aggregate per `default_aggregation.formula`.
#
# NOTE: Stripe does not support deleting a meter via API (Terraform destroy will fail
# for meters) — they can only be deactivated. Treat meters as append-only.

# Active devices (MAD). The relay emits exactly ONE event the first time a device is
# seen for a tenant in a billing period (period-scoped dedup, §37), so `count` sums to
# the distinct monthly-active-device count. No value payload needed for a count meter.
resource "stripe_meter" "active_devices" {
  display_name = "Hop — active devices"
  event_name   = "hop_active_device"

  customer_mapping {
    event_payload_key = "stripe_customer_id"
    type              = "by_id"
  }

  default_aggregation {
    formula = "count"
  }
}

# Data carried — chunks the backbone stores-and-forwards (value = chunk count).
resource "stripe_meter" "data_carried" {
  display_name = "Hop — data carried (chunks)"
  event_name   = "hop_data_carried_chunks"

  customer_mapping {
    event_payload_key = "stripe_customer_id"
    type              = "by_id"
  }

  default_aggregation {
    formula = "sum"
  }

  value_settings {
    event_payload_key = "value"
  }
}

# Internet egress — value reported in GB.
resource "stripe_meter" "egress" {
  display_name = "Hop — internet egress (GB)"
  event_name   = "hop_egress_gb"

  customer_mapping {
    event_payload_key = "stripe_customer_id"
    type              = "by_id"
  }

  default_aggregation {
    formula = "sum"
  }

  value_settings {
    event_payload_key = "value"
  }
}

# Mailbox storage — value reported in GB-months (summed byte-hours → GB-month, §37).
resource "stripe_meter" "mailbox" {
  display_name = "Hop — mailbox storage (GB-month)"
  event_name   = "hop_mailbox_gb_month"

  customer_mapping {
    event_payload_key = "stripe_customer_id"
    type              = "by_id"
  }

  default_aggregation {
    formula = "sum"
  }

  value_settings {
    event_payload_key = "value"
  }
}
