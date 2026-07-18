//! hop-billingd: the §37 billing reconciler service.
//!
//! The reconciliation LOGIC lives in `lib.rs` (pure, fully unit-tested with no network). This
//! binary is the `live` wiring: read the relays' `usage/{hour}/{tenant}` ledger rows + the
//! `metered/{region}/{wire_id}` markers from Firestore, call `reconcile`, emit meter events to
//! Stripe, and roll the closed hours into BigQuery. That path is credential-gated (a
//! STRIPE_API_KEY secret + a BigQuery dataset) and compiled only under `--features live`, so a
//! default build (and CI without credentials) builds the reconciler without any external calls.

fn main() {
    #[cfg(not(feature = "live"))]
    {
        eprintln!(
            "hop-billingd: built without the `live` feature. The reconciler logic is in the \
             library (hop_billingd::reconcile); the live Firestore/Stripe/BigQuery wiring builds \
             with `--features live` once STRIPE_API_KEY + a BigQuery dataset are configured."
        );
    }
    #[cfg(feature = "live")]
    {
        // TODO(live): read ledger rows + metered markers from Firestore, reconcile against the
        // persisted watermark, emit to the Stripe meter-events API, append to BigQuery. Gated on
        // credentials (see infra/billing) so it is wired in the credential step, not here.
        eprintln!("hop-billingd: live path not yet wired");
    }
}
