# Stripe billing for the Hop backbone: provider + version pins.
#
# Isolated root module (its own state) so the relay-fleet apply never needs Stripe
# credentials and vice-versa. Resources here define the *catalog* (product, meters,
# base + metered prices). Creating customers/subscriptions and reporting meter events
# is the runtime account-service / reconciler's job (DESIGN.md §37), not Terraform.

terraform {
  # Same floor as the relay-fleet module (infra/versions.tf): this state is written by the pinned
  # 1.12.3 tofu, so require >= 1.12 rather than an older floor that would let an incompatible tofu
  # touch the billing state.
  required_version = ">= 1.12"
  required_providers {
    stripe = {
      source  = "stripe/stripe"
      version = "~> 0.2.2"
    }
    # Only for writing the webhook signing secret into the bootstrap-owned Secret Manager container
    # (webhook_secret.tf). This root creates no Google resources of its own. Version pinned to the
    # same major as the other two roots so a shared provider cache stays consistent.
    google = {
      source  = "hashicorp/google"
      version = "~> 7.7.0"
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

provider "google" {
  project = var.project_id
}
