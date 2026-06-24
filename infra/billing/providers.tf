# Stripe billing for the Hop backbone — provider + version pins.
#
# Isolated root module (its own state) so the relay-fleet apply never needs Stripe
# credentials and vice-versa. Resources here define the *catalog* (product, meters,
# base + metered prices). Creating customers/subscriptions and reporting meter events
# is the runtime account-service / reconciler's job (DESIGN.md §37), not Terraform.

terraform {
  required_version = ">= 1.5"
  required_providers {
    stripe = {
      source  = "lukasaron/stripe"
      version = "~> 3.4"
    }
  }
}

provider "stripe" {
  # Restricted API key. Prefer TF_VAR_stripe_api_key or the STRIPE_API_KEY env var;
  # never commit it. Use a *restricted* key scoped to Products/Prices/Meters write.
  api_key = var.stripe_api_key
}
