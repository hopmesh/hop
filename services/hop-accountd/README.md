# hop-accountd

The account/invoice backend behind the Hop console's billing surfaces: native invoice rendering
(list + line items), previous payments, the card on file, and server-driven "Pay now". The
`stripe-account-key` consumer (see `infra/billing_runtime.tf` for the restricted-key scope list).

Stripe stays the billing system of record; this service reads it and the console renders natively.
Usage dashboards do NOT come from here: they read our own ledger and BigQuery (DESIGN.md §37).

## Shape

- `stripe_api.rs`: the pure Stripe read layer. Request builders + response parsers behind a
  `Transport` seam; ids are validated before any URL construction so a crafted id can never smuggle
  a path or query into a Stripe call. Malformed entries in a Stripe page are skipped, never fatal.
- `api.rs`: the pure console-facing layer. Routing, the bearer-token gate (`HOP_API_TOKEN`,
  fold-compared, and an unset token never means open), the tenant map, and THE OWNERSHIP RULE: an
  invoice id is not a capability; every per-invoice route verifies `invoice.customer` equals the
  tenant's mapped customer and answers 404 on mismatch, indistinguishable from absent.
- `main.rs`: std-thread HTTP server (no tokio), bounded head reads + connection cap, glued to the
  real Stripe transport only under `--features live`.

## Run (live)

```sh
STRIPE_ACCOUNT_KEY=rk_live_... HOP_API_TOKEN=<random, 16+ bytes> \
HOP_TENANT_MAP=/etc/hop/tenants PORT=9446 \
  hop-accountd   # built with --features live
```

`HOP_TENANT_MAP` lines are `<tenant-hex-32> <cus_...>` (the reconciler's map format), provisioned
by the operator until the signup flow owns customer creation.

Deliberately not here yet: signup (customer + subscription + SetupIntent creation), webhook status
sync, and any deploy wiring. A default build has no network surface at all.

Licensed Apache-2.0 (the SDK/tooling tier). Internal; not mirrored to the public repos.
