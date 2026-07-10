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

  # infra-15: remote state in the same GCS bucket as the relay-fleet module, under a distinct prefix
  # so the two isolated root modules never share state. This state binds the append-only Stripe meters
  # and the price IDs the reconciler contract depends on (see meters.tf); keeping it local meant whoever
  # ran the apply held the only, unreconstructable copy. GCS is versioned (rollback) and has native
  # state locking. The bucket pre-exists (created out-of-band, same as the relay-fleet backend).
  backend "gcs" {
    bucket = "hop-mesh-tfstate"
    prefix = "billing"
  }
}

provider "stripe" {
  # Restricted API key. Prefer TF_VAR_stripe_api_key or the STRIPE_API_KEY env var;
  # never commit it. Use a *restricted* key scoped to Products/Prices/Meters write.
  api_key = var.stripe_api_key
}
