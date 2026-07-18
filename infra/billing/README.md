# infra/billing: Stripe catalog for the Hop backbone

Terraform (Stripe provider) that defines the **billing catalog**: one product, a flat
**base price**, and four **metered prices**, each bound to a Stripe **Billing Meter**.
Pricing model and rationale: [`docs/pricing-cost-model.md`](../../docs/pricing-cost-model.md).
Metering pipeline: `DESIGN.md` §37.

Hop bills for **reach, not device count**: a device with connectivity direct-connects to the
endpoint for free, so you pay only when the backbone delivers to an **offline** recipient.
Metrics carry their own COGS (BigQuery), so observability is a separate meter, not a per-device fee.

This is a **separate root module** from the relay fleet (`infra/`), its own state, its
own provider, so a relay apply never needs Stripe credentials.

## How it is applied (CI/CD, not a local run)

The `Billing catalog (Stripe)` GitHub Actions workflow (`.github/workflows/billing-catalog.yml`)
owns this module:

- **On a PR touching `infra/billing/**`** it runs `tofu plan` so the catalog diff is reviewable.
- **On manual dispatch** (Actions tab → run workflow → `confirm: apply`) it runs `tofu apply`.
  Creating live Stripe billing resources is consequential and meters are append-only, so it is
  gated behind a deliberate click rather than firing on every push.

Auth is keyless: GitHub OIDC → Workload Identity Federation → the `billing-catalog-apply` service
account (`infra/wif_github.tf`), scoped to the `billing/` state prefix only. The Stripe key is the
`STRIPE_API_KEY` repo secret. One-time setup: apply the fleet root (which creates WIF), then set the
`GCP_PROJECT_NUMBER` repo variable so the workflow can construct the WIF provider path. `apply.sh` is
a break-glass local fallback only.

## What it creates

| Resource | Purpose |
|---|---|
| `stripe_product.backbone` | "Hop Backbone" |
| `stripe_price.base` | Flat monthly platform fee (licensed); `$0` default (free tier) |
| `stripe_billing_meter.* / stripe_price.*` | Metered usage: backbone reach (offline deliveries), telemetry events, egress (GB), mailbox (GB-month) |

## The contract with the runtime

Terraform defines the **catalog only**. At runtime (DESIGN.md §37):

1. The **account service** creates a Stripe customer per tenant and a subscription with
   the `base` price + the metered items it needs (price ids → `terraform output price_ids`).
2. The **reconciler** reads the durable usage ledger and emits **meter events** by
   `event_name` (`terraform output meter_event_names`) with payload
   `{ stripe_customer_id, value }`, idempotently. Stripe aggregates and invoices.

Meter `event_name`s are the integration contract, keep them stable.

## State (remote, GCS)

State lives in `gs://hop-mesh-tfstate` under prefix `billing` (see `providers.tf`), separate from the
relay-fleet state (prefix `relay-fleet`). This is deliberate (infra-15): the meters are **append-only
and undeletable**, so the state that binds them to their price/event IDs must not live only on one
operator's laptop. GCS is versioned (rollback) and locks natively.

If you applied this module **before** the backend was added (local `terraform.tfstate`), migrate once:

```sh
terraform -chdir=infra/billing init -migrate-state   # copies local state up to gs://hop-mesh-tfstate/billing
```

Answer "yes" when prompted. After that the local `terraform.tfstate` is a stale copy; delete it.

## Apply (break-glass only)

The normal path is the `Billing catalog (Stripe)` CI/CD workflow (see "How it is applied" above).
Only if that pipeline is unavailable, `./apply.sh` runs the same thing locally against the GCS
backend (needs `STRIPE_API_KEY` in the environment and a GCP login that can reach the `billing`
state prefix).

Override indicative rates with `-var` / a (gitignored) `terraform.tfvars`, e.g.:

```hcl
base_fee_cents                   = 0     # free tier, revenue is metered reach
price_per_1k_deliveries_cents    = 200   # $2.00 / 1,000 offline deliveries ($0.002 each)
price_per_million_events_cents   = 30    # $0.30 / 1M telemetry events
price_per_gb_egress_cents        = 15    # $0.15 / GB
price_per_gb_month_mailbox_cents = 40    # $0.40 / GB-month
```

## Caveats

- **Meters can't be deleted** via the Stripe API, `terraform destroy` will fail on
  `stripe_billing_meter`; they can only be deactivated. Treat meters as append-only.
- **Included allowances** (free tier, per-MAD bundles) are not yet modeled here. Add them
  as **tiered metered prices** (first *N* units at `$0`) so invoices stay transparent and
  the reconciler can keep reporting gross usage (§37).
- Use a **restricted** key and start against **Stripe test mode** before live.
