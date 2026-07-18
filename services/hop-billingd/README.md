# hop-billingd

The Hop billing reconciler (DESIGN.md §37). It reads the relays' durable usage ledger
(`usage/{hour}/{tenant}` rows written off the hot path) and turns it into idempotent Stripe meter
events, then rolls closed hours into BigQuery history.

Capture and reconciliation are decoupled on purpose: the relays never call Stripe, so a billing
outage delays invoicing but never blocks a bundle. Cross-instance dedup and the storage GB-month
dimension are reconciled here, not on the relay's hot path.

- `src/lib.rs` is the pure, fully unit-tested reconciler (`reconcile`, `MeterSink`, no network).
- `src/main.rs` is the `live` wiring (Firestore read + Stripe emit + BigQuery), compiled under
  `--features live` and gated on a `STRIPE_API_KEY` secret + a BigQuery dataset (see `infra/billing`).

Licensed Apache-2.0 (the SDK/tooling tier).
