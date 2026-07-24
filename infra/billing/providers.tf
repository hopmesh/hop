# Keyed third-party SaaS for the Hop backbone: provider + version pins.
#
# Isolated root module (its own state) so the relay-fleet apply never needs these third-party
# credentials and vice-versa. It holds the Stripe billing catalog (product, meters, base + metered
# prices) AND the Resend sending domain (resend.tf): both are "register a resource on a SaaS via its
# API key", so they share this root's WIF identity and the billing-catalog.yml apply rather than each
# standing up its own. Creating customers/subscriptions and reporting meter events is the runtime
# account-service / reconciler's job (DESIGN.md §37), not Terraform.
#
# There is no official Resend Terraform provider; y0n0zawa/resend is the highest-adoption community
# build, pinned to an exact version below. Bump it deliberately, with a reviewed plan.

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
    # Registers the Resend sending domain (resend.tf) and returns the DNS records it needs. No official
    # provider exists, so pin the community build to an exact version.
    resend = {
      source  = "y0n0zawa/resend"
      version = "1.0.1"
    }
    # Writes the webhook signing secret into the bootstrap-owned Secret Manager container
    # (webhook_secret.tf). This root creates no other Google resources. Version pinned to the
    # same major as the other roots so a shared provider cache stays consistent.
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

provider "resend" {
  # Resend API key with DOMAIN (full-access) scope, not the sending-only key hop-accountd uses. Prefer
  # TF_VAR_resend_api_key or the RESEND_API_KEY env var; never commit it. It authenticates the domain
  # create/verify calls and never lands in state (only the returned public DNS records do).
  api_key = var.resend_api_key
}

provider "google" {
  project = var.project_id
}
