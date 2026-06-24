# infra/billing — Stripe catalog for the Hop backbone

Terraform (Stripe provider) that defines the **billing catalog**: one product, a flat
**base price**, and four **metered prices**, each bound to a Stripe **Billing Meter**.
Pricing model and rationale: [`docs/pricing-cost-model.md`](../../docs/pricing-cost-model.md).
Metering pipeline: `DESIGN.md` §37.

This is a **separate root module** from the relay fleet (`infra/`) — its own state, its
own provider — so a relay apply never needs Stripe credentials.

## What it creates

| Resource | Purpose |
|---|---|
| `stripe_product.backbone` | "Hop Backbone" |
| `stripe_price.base` | Flat monthly platform fee (licensed); `$0` default |
| `stripe_meter.* / stripe_price.*` | Metered usage: active devices, data carried (chunks), egress (GB), mailbox (GB-month) |

## The contract with the runtime

Terraform defines the **catalog only**. At runtime (DESIGN.md §37):

1. The **account service** creates a Stripe customer per tenant and a subscription with
   the `base` price + the metered items it needs (price ids → `terraform output price_ids`).
2. The **reconciler** reads the durable usage ledger and emits **meter events** by
   `event_name` (`terraform output meter_event_names`) with payload
   `{ stripe_customer_id, value }`, idempotently. Stripe aggregates and invoices.

Meter `event_name`s are the integration contract — keep them stable.

## Apply

```sh
export STRIPE_API_KEY='rk_live_...'        # restricted key: Products/Prices/Meters write
terraform -chdir=infra/billing init
terraform -chdir=infra/billing plan
terraform -chdir=infra/billing apply
```

Override indicative rates with `-var` / a (gitignored) `terraform.tfvars`, e.g.:

```hcl
base_fee_cents                 = 0
price_per_1k_devices_cents     = 2500   # $25 / 1,000 active devices
price_per_million_chunks_cents = 1500   # $15 / 1M chunks
price_per_gb_egress_cents      = 18      # $0.18 / GB
price_per_gb_month_mailbox_cents = 75    # $0.75 / GB-month
```

## Caveats

- **Meters can't be deleted** via the Stripe API — `terraform destroy` will fail on
  `stripe_meter`; they can only be deactivated. Treat meters as append-only.
- **Included allowances** (free tier, per-MAD bundles) are not yet modeled here. Add them
  as **tiered metered prices** (first *N* units at `$0`) so invoices stay transparent and
  the reconciler can keep reporting gross usage (§37).
- Use a **restricted** key and start against **Stripe test mode** before live.
