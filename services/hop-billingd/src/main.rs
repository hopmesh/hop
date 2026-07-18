//! hop-billingd: the §37 billing reconciler service.
//!
//! The reconciliation LOGIC lives in `lib.rs` (pure, fully unit-tested with no network); the
//! ledger parse is `ledger.rs`, the Stripe emit is `stripe.rs`, and the BigQuery watermark store
//! is `bq.rs`, each with the network behind a tested seam. This binary is the `live` wiring that
//! strings them together, ONE run per invocation (schedule it externally; run-once keeps the
//! crash story trivial):
//!
//!   1. read the persisted watermarks (BigQuery `reconcile_watermarks`, jobless `tabledata.list`)
//!   2. collect `usage/` + `telemetry_usage/` rows across every node partition (Firestore, read-only)
//!   3. drive `reconcile` + `reconcile_telemetry` into the Stripe meter-events sink
//!   4. append each ADVANCED watermark (idempotent `insertAll`)
//!
//! If ANY partition failed to list, the run still emits what it collected but REFUSES to advance
//! the watermarks: rows merge cumulatively into per-(hour,tenant) docs, so advancing past an hour
//! reconciled from a partial fleet would under-bill the missing partition forever, while
//! re-emitting a complete hour next run lands on the same idempotent keys and dedups. Latency over
//! under-billing, always.
//!
//! Credential-gated (`STRIPE_API_KEY` + ADC/`FIRESTORE_ACCESS_TOKEN`) and compiled only under
//! `--features live`, so a default build (and CI without credentials) has no network surface.

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
    live::run();
}

#[cfg(feature = "live")]
mod live {
    use hop_billingd::bq::{self, BqTransport, HistorySink, DIM_CARRIAGE, DIM_TELEMETRY};
    use hop_billingd::ledger::{collect_rows, LedgerSource};
    use hop_billingd::stripe::{CustomerMap, ReqwestTransport, StripeSink};
    use hop_billingd::{reconcile, reconcile_telemetry, BillAndRecord};
    use hop_store_firestore::KvReader;

    /// The ledger source over the shared Firestore kv reader.
    struct FirestoreLedger {
        reader: KvReader,
    }
    impl LedgerSource for FirestoreLedger {
        fn list_nodes(&self) -> Result<Vec<String>, String> {
            self.reader.list_nodes()
        }
        fn list_kv_of(&self, node: &str) -> Result<Vec<(String, Vec<u8>)>, String> {
            self.reader.list_kv_of(node)
        }
    }

    /// BigQuery over reqwest, authenticated exactly like the Firestore reader: the
    /// `FIRESTORE_ACCESS_TOKEN` env override (local runs; the token is cloud-platform scoped, so
    /// one token covers both APIs) or the metadata server (Cloud Run).
    struct ReqwestBq {
        http: reqwest::blocking::Client,
    }
    impl ReqwestBq {
        fn token(&self) -> Result<String, String> {
            if let Ok(t) = std::env::var("FIRESTORE_ACCESS_TOKEN") {
                if !t.is_empty() {
                    return Ok(t);
                }
            }
            let resp = self
                .http
                .get("http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token?scopes=https://www.googleapis.com/auth/cloud-platform")
                .header("Metadata-Flavor", "Google")
                .send()
                .map_err(|e| format!("metadata token: {e}"))?;
            let v: serde_json::Value = resp.json().map_err(|e| e.to_string())?;
            v["access_token"]
                .as_str()
                .map(|s| s.to_string())
                .ok_or_else(|| "metadata token: no access_token".into())
        }
    }
    impl BqTransport for ReqwestBq {
        fn get(&self, url: &str) -> Result<(u16, serde_json::Value), String> {
            let resp = self
                .http
                .get(url)
                .bearer_auth(self.token()?)
                .send()
                .map_err(|e| e.to_string())?;
            let status = resp.status().as_u16();
            let body = resp.json().unwrap_or(serde_json::Value::Null);
            Ok((status, body))
        }
        fn post(
            &self,
            url: &str,
            body: &serde_json::Value,
        ) -> Result<(u16, serde_json::Value), String> {
            let resp = self
                .http
                .post(url)
                .bearer_auth(self.token()?)
                .json(body)
                .send()
                .map_err(|e| e.to_string())?;
            let status = resp.status().as_u16();
            let body = resp.json().unwrap_or(serde_json::Value::Null);
            Ok((status, body))
        }
    }

    fn env_or(name: &str, default: &str) -> String {
        std::env::var(name)
            .ok()
            .filter(|v| !v.is_empty())
            .unwrap_or_else(|| default.to_string())
    }

    pub fn run() {
        let Ok(api_key) = std::env::var("STRIPE_API_KEY") else {
            eprintln!("hop-billingd: STRIPE_API_KEY is not set; refusing to start the live path");
            std::process::exit(2);
        };
        let project = env_or("HOP_FIRESTORE_PROJECT", "hop-mesh");
        let dataset = env_or("HOP_BQ_DATASET", "hop_usage");
        let wm_table = env_or("HOP_BQ_WATERMARKS", "reconcile_watermarks");
        let usage_table = env_or("HOP_BQ_USAGE", "usage_history");

        let customers = std::env::var("HOP_CUSTOMER_MAP")
            .ok()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .map(|t| CustomerMap::parse(&t))
            .unwrap_or_default();
        if customers.is_empty() {
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
        let stripe = StripeSink::new(transport, customers);

        let bq_client = ReqwestBq {
            http: reqwest::blocking::Client::builder()
                .timeout(std::time::Duration::from_secs(30))
                .build()
                .expect("http client"),
        };

        // 1. Watermarks.
        let wm = match bq::read_watermarks(&bq_client, &project, &dataset, &wm_table) {
            Ok(w) => w,
            Err(e) => {
                eprintln!("hop-billingd: watermark read failed ({e}); aborting run");
                std::process::exit(1);
            }
        };

        // 2. Ledger rows across every partition.
        let source = FirestoreLedger {
            reader: KvReader::new(&project),
        };
        let rows = match collect_rows(&source) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("hop-billingd: node enumeration failed ({e}); aborting run");
                std::process::exit(1);
            }
        };
        let complete = rows.failed_nodes.is_empty();
        if !complete {
            eprintln!(
                "hop-billingd: {} partition(s) unreadable this run; will emit but NOT advance \
                 watermarks (re-emits dedup at Stripe)",
                rows.failed_nodes.len()
            );
        }

        // 3. Reconcile: bill Stripe (authoritative, drives the watermark) and record usage history
        // in our own BigQuery as a BEST-EFFORT side effect (the console dashboards read our data,
        // never Stripe). A history failure is counted, never propagated, so a dashboards-store
        // outage can never freeze revenue. now_hour excludes the still-accumulating current hour.
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        let now_hour = now_ms / 3_600_000;
        let mut sink = BillAndRecord::new(
            stripe,
            HistorySink {
                transport: &bq_client,
                project: project.clone(),
                dataset: dataset.clone(),
                table: usage_table,
                updated_ms: now_ms,
            },
        );
        let new_carriage = reconcile(&rows.usage, wm.carriage_hour, now_hour, &mut sink);
        let new_telemetry =
            reconcile_telemetry(&rows.telemetry, wm.telemetry_hour, now_hour, &mut sink);
        let record_failures = sink.record_failures;
        if record_failures > 0 {
            eprintln!(
                "hop-billingd: {record_failures} usage_history append(s) failed (best-effort; \
                 billing unaffected, dashboard rows may lag)"
            );
        }
        drop(sink); // release the &bq_client borrow before the watermark appends

        // 4. Persist only what ADVANCED, and only from a complete fleet read.
        let mut ok = true;
        if complete {
            for (dim, old, new) in [
                (DIM_CARRIAGE, wm.carriage_hour, new_carriage),
                (DIM_TELEMETRY, wm.telemetry_hour, new_telemetry),
            ] {
                if new > old {
                    if let Err(e) = bq::append_watermark(
                        &bq_client, &project, &dataset, &wm_table, dim, new, now_ms,
                    ) {
                        // Non-fatal: a lost watermark re-emits an already-deduped window next run.
                        eprintln!("hop-billingd: watermark append failed for {dim} ({e})");
                        ok = false;
                    }
                }
            }
        }

        println!(
            "hop-billingd: run complete. carriage {} -> {}, telemetry {} -> {}, partitions_failed={}, history_failures={}, watermarks_persisted={}",
            wm.carriage_hour, new_carriage, wm.telemetry_hour, new_telemetry,
            rows.failed_nodes.len(),
            record_failures,
            if complete && ok { "yes" } else { "no" },
        );
    }
}
