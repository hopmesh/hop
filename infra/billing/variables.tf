variable "stripe_api_key" {
  description = "Stripe restricted API key (Products/Prices/Meters write). Set via TF_VAR_stripe_api_key or STRIPE_API_KEY; never commit it."
  type        = string
  sensitive   = true
  default     = ""
}

variable "currency" {
  description = "ISO currency for all prices."
  type        = string
  default     = "usd"
}

# --- Pricing (indicative; see docs/pricing-cost-model.md). All in *cents*. ---

variable "base_fee_cents" {
  description = "Flat recurring platform fee per month (licensed). 0 keeps the free tier at $0; set a committed minimum for paid plans."
  type        = number
  default     = 0
}

variable "price_per_1k_devices_cents" {
  description = "Monthly Active Devices: price per 1,000 MAD (metered). Default $25.00."
  type        = number
  default     = 2500
}

variable "price_per_million_chunks_cents" {
  description = "Data carried: price per 1,000,000 chunks (metered). Default $15.00. A large message is many chunks (DESIGN.md §31/§37)."
  type        = number
  default     = 1500
}

variable "price_per_gb_egress_cents" {
  description = "Internet egress: price per GB (metered). Default $0.18."
  type        = number
  default     = 18
}

variable "price_per_gb_month_mailbox_cents" {
  description = "Mailbox storage: price per GB-month (metered). Default $0.75."
  type        = number
  default     = 75
}
