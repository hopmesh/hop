# Stripe Billing Meters, the four usage dimensions (DESIGN.md §37).
#
# The `event_name` of each meter is the CONTRACT between the relay reconciler and
# Stripe: the reconciler emits meter events with these names + a payload of
# { stripe_customer_id, value }. Meters aggregate per `default_aggregation.formula`.
#
# Hop bills for REACH, not device count. A device with connectivity direct-connects to
# the endpoint (free, no backbone), so the billable unit is a backbone-assisted delivery
# to an OFFLINE recipient. Metrics carry their own COGS (BigQuery), so observability is a
# separate meter rather than folded into a per-device fee.
#
# NOTE: Stripe does not support deleting a meter via API (Terraform destroy will fail for
# meters), they can only be deactivated. Treat meters as append-only.

# Backbone reach: one event per bundle the backbone delivered to an offline recipient
# (proven by ack or vaccine purge, §37). `count` sums to billable deliveries; a device
# that never needed the backbone (direct-connect or pure P2P) produces no event.
resource "stripe_billing_meter" "backbone_delivery" {
  display_name = "Hop: backbone reach"
  event_name   = "hop_backbone_delivery"

  customer_mapping {
    event_payload_key = "stripe_customer_id"
    type              = "by_id"
  }

  default_aggregation {
    formula = "count"
  }
}

# Observability: OTel-over-Hop telemetry events ingested (value = event count). Priced to
# carry its own BigQuery COGS, kept separate from reach so metrics never inflate it.
resource "stripe_billing_meter" "telemetry_events" {
  display_name = "Hop: telemetry events"
  event_name   = "hop_telemetry_events"

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

# Internet egress, value reported in GB.
resource "stripe_billing_meter" "egress" {
  display_name = "Hop: internet egress (GB)"
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

# Mailbox storage, value reported in GB-months (summed byte-hours to GB-month, §37).
resource "stripe_billing_meter" "mailbox" {
  display_name = "Hop: mailbox storage (GB-month)"
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
