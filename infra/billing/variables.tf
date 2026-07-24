variable "stripe_api_key" {
  description = "Stripe restricted API key (Products/Prices/Meters write). Set via TF_VAR_stripe_api_key or STRIPE_API_KEY; never commit it."
  type        = string
  sensitive   = true
  default     = ""
}

variable "project_id" {
  description = "GCP project holding the bootstrap-owned stripe-webhook-secret container this root seeds."
  type        = string
  default     = "hop-mesh"
}

variable "resend_api_key" {
  description = "Resend API key with domain (full-access) scope. Set via TF_VAR_resend_api_key or RESEND_API_KEY; never commit it. Empty is fine for plan/validate without the domain."
  type        = string
  sensitive   = true
  default     = ""
}

# The console sending domain, deliberately a subdomain and not the bare apex: sending from
# account.hopme.sh keeps Resend's SPF/DKIM reputation off the hopme.sh apex mail Google Workspace
# handles. Must match var.resend_from's domain in infra/variables.tf. Set to "hopme.sh" to send from
# the apex instead (which drops that reputation split).
variable "resend_sending_domain" {
  description = "Domain registered in Resend and used as the console sending domain (account.hopme.sh)."
  type        = string
  default     = "account.hopme.sh"
}

variable "resend_region" {
  description = "Resend hosting region. Must match the SES endpoints in the returned records (us-east-1 gives feedback-smtp.us-east-1.amazonses.com)."
  type        = string
  default     = "us-east-1"
}

variable "currency" {
  description = "ISO currency for all prices."
  type        = string
  default     = "usd"
}

# --- Pricing (indicative; see docs/pricing-cost-model.md). All in *cents*. ---
# Hop bills for REACH, not devices: you pay when the backbone delivers to an offline
# recipient. Online devices direct-connect for free. Metrics carry their own COGS.

variable "base_fee_cents" {
  description = "Flat recurring platform fee per month (licensed). 0 keeps the free tier at $0; set a committed minimum for Enterprise."
  type        = number
  default     = 0
}

variable "price_per_1k_deliveries_cents" {
  description = "Backbone reach: price per 1,000 offline deliveries (metered). Default $2.00, so $0.002 per delivery."
  type        = number
  default     = 200
}

variable "price_per_million_events_cents" {
  description = "Observability: price per 1,000,000 OTel-over-Hop telemetry events (metered). Default $0.30. Carries the BigQuery COGS."
  type        = number
  default     = 30
}

variable "price_per_gb_egress_cents" {
  description = "Internet egress: price per GB (metered). Default $0.15."
  type        = number
  default     = 15
}

variable "price_per_gb_month_mailbox_cents" {
  description = "Mailbox storage: price per GB-month (metered). Default $0.40."
  type        = number
  default     = 40
}
