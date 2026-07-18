#!/usr/bin/env bash
# BREAK-GLASS ONLY. The normal path is CI/CD: the `Billing catalog (Stripe)` GitHub Actions workflow
# (.github/workflows/billing-catalog.yml) plans on infra/billing PRs and applies on manual dispatch,
# authenticating keylessly via Workload Identity Federation. Use this local script only if that
# pipeline is unavailable (e.g. WIF is down and the catalog MUST change).
#
# Create the Stripe billing catalog (product + base price + 4 meters + 4 metered prices) via the
# OFFICIAL stripe/stripe provider. Run this ONCE per Stripe account; the meters are append-only.
#
# You need a RESTRICTED Stripe API key scoped to Products / Prices / Billing Meters WRITE (NOT a
# full secret key). Create one at https://dashboard.stripe.com/apikeys (Restricted keys). Pass it
# via the environment so it never lands in a shell history file or the Terraform state:
#
#   STRIPE_API_KEY='rk_live_...' ./apply.sh
#
# After it applies, it prints the ids your metering system needs (meter event_names + price ids).
# Pricing defaults live in variables.tf ($0 base fee, per-unit metered rates); override with
# TF_VAR_price_per_* if you want different numbers before the first apply.
set -euo pipefail
cd "$(dirname "$0")"

if [ -z "${STRIPE_API_KEY:-}" ] && [ -z "${TF_VAR_stripe_api_key:-}" ]; then
  echo "error: set STRIPE_API_KEY (or TF_VAR_stripe_api_key) to a RESTRICTED key with"
  echo "       Products/Prices/Billing Meters write scope, then re-run." >&2
  exit 2
fi
# The provider reads either name; mirror one to the other so both work.
export TF_VAR_stripe_api_key="${TF_VAR_stripe_api_key:-$STRIPE_API_KEY}"

echo "==> tofu init"
tofu init -input=false

echo "==> tofu plan (review what will be created)"
tofu plan -input=false

printf '\n==> Apply the plan above? This creates live Stripe billing resources. [y/N] '
read -r ans
[ "$ans" = "y" ] || { echo "aborted."; exit 0; }

echo "==> tofu apply"
tofu apply -input=false -auto-approve

echo
echo "==> catalog created. Ids your metering system needs:"
echo "    meter event_names (the reconciler emits against these):"
tofu output -json meter_event_names | sed 's/^/      /'
echo "    price ids (the account service attaches to a tenant subscription):"
tofu output -json price_ids | sed 's/^/      /'
echo "    product id:"
tofu output -raw product_id | sed 's/^/      /'
echo
echo "Next: seed the bootstrap-owned reconciler key (a DIFFERENT restricted key, Meter events write):"
echo "  printf '%s' 'rk_live_...' | gcloud secrets versions add stripe-api-key --project hop-mesh --data-file=-"
