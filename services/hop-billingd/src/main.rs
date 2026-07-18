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
        use hop_billingd::stripe::{CustomerMap, ReqwestTransport, StripeSink};

        // The EMIT half is wired: a restricted key plus the tenant-to-customer map give the
        // reconciler a real MeterSink (see `stripe.rs`, whose request construction and failure
        // handling are unit-tested). Still missing: the LEDGER SOURCE, reading the relays'
        // `usage/{hour}/{tenant}` and the collectors' `telemetry_usage/{hour}/{tenant}` rows plus the
        // persisted watermark out of Firestore, then driving `reconcile` / `reconcile_telemetry`.
        let Ok(api_key) = std::env::var("STRIPE_API_KEY") else {
            eprintln!("hop-billingd: STRIPE_API_KEY is not set; refusing to start the live path");
            std::process::exit(2);
        };
        let customers = std::env::var("HOP_CUSTOMER_MAP")
            .ok()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .map(|t| CustomerMap::parse(&t))
            .unwrap_or_default();
        let mapped = customers.len();
        if mapped == 0 {
            eprintln!(
                "hop-billingd: HOP_CUSTOMER_MAP is empty or unset; every emit would fail unmapped"
            );
        }
        let transport = match ReqwestTransport::new(api_key) {
            Ok(t) => t,
            Err(e) => {
                eprintln!("hop-billingd: {e}");
                std::process::exit(1);
            }
        };
        let _sink = StripeSink::new(transport, customers);
        eprintln!(
            "hop-billingd: stripe meter sink ready ({mapped} tenants mapped). Ledger source \
             (Firestore read + persisted watermark) is the remaining piece before reconciliation runs."
        );
    }
}
