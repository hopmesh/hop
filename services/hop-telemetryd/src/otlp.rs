//! OTLP export: translate the compact §40 [`TelemetryBatch`] into OTLP/HTTP JSON and forward it to a
//! per-tenant endpoint, so a managed tenant's device telemetry lands in their own observability stack
//! (Datadog, Grafana, Honeycomb, ...). Compact on the wire, OTLP on the output.
//!
//! This is a BEST-EFFORT side effect of receiving telemetry. The authoritative path is the billing
//! meter, which always runs FIRST (see `forward_telemetry`), so an endpoint outage or a slow POST can
//! never gate metering, the same asymmetry as hop-billingd's `BillAndRecord`. Only ATTRIBUTED batches
//! (a resolved tenant) can be routed; unattributed ones stay aggregate-only. The POST itself runs off
//! the single-owner driver thread on a bounded queue (`main.rs`), so a slow tenant endpoint cannot
//! stall the mesh link or the meter flush.
//!
//! Everything except the socket is pure and unit-tested (the hop-billingd discipline): the endpoint
//! map parse, the OTLP JSON builders, and the export routing. Only [`OtlpTransport`] touches the
//! network, with a `reqwest` impl under `--features live`.

use std::collections::BTreeMap;

use hop_core::prelude::*;
use hop_core::telemetry::{Signal, TelemetryBatch};
use serde_json::{json, Value};

/// One tenant's OTLP destination: a base OTLP/HTTP endpoint plus an optional `Authorization` header
/// value. Metrics POST to `{url}/v1/metrics`, logs to `{url}/v1/logs` (the OTLP/HTTP convention).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OtlpEndpoint {
    pub url: String,
    pub auth: Option<String>,
}

/// tenant -> OTLP endpoint, parsed from a file of `<tenant-hex-32> <base-url> [auth header value]`
/// lines (`#` comments + blank lines skipped), the same operator-provisioned shape as the KeyServer
/// file. The auth token is the rest of the line, so `Bearer abc123` (with a space) is fine.
#[derive(Clone, Debug, Default)]
pub struct OtlpEndpointMap {
    map: BTreeMap<TenantId, OtlpEndpoint>,
}

impl OtlpEndpointMap {
    pub fn parse(text: &str) -> OtlpEndpointMap {
        let mut map = BTreeMap::new();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((tenant_hex, tail)) = line.split_once(char::is_whitespace) else {
                continue;
            };
            let Some(tenant) = super::parse_tenant_hex(tenant_hex) else {
                continue;
            };
            let tail = tail.trim_start();
            let (url, auth) = match tail.split_once(char::is_whitespace) {
                Some((u, a)) => (u, {
                    let a = a.trim();
                    (!a.is_empty()).then(|| a.to_string())
                }),
                None => (tail, None),
            };
            // Only http(s) endpoints; anything else is a typo, skip it rather than post nonsense.
            if !(url.starts_with("http://") || url.starts_with("https://")) {
                continue;
            }
            map.insert(
                tenant,
                OtlpEndpoint {
                    url: url.to_string(),
                    auth,
                },
            );
        }
        OtlpEndpointMap { map }
    }

    pub fn get(&self, tenant: &TenantId) -> Option<&OtlpEndpoint> {
        self.map.get(tenant)
    }
    // len/is_empty are consumed only by the `live` setup path; harmless dead code in a default build.
    #[allow(dead_code)]
    pub fn len(&self) -> usize {
        self.map.len()
    }
    #[allow(dead_code)]
    pub fn is_empty(&self) -> bool {
        self.map.is_empty()
    }
}

/// OTLP `KeyValue[]` from `(key, value)` string pairs (each value an OTLP `AnyValue.stringValue`).
fn kv_attrs(attrs: &[(String, String)]) -> Vec<Value> {
    attrs
        .iter()
        .map(|(k, v)| json!({ "key": k, "value": { "stringValue": v } }))
        .collect()
}

/// OTLP wants nanoseconds; the batch carries unix millis. Saturating so a bogus far-future clock can't
/// overflow (u64 nanos covers years past any real device clock).
fn nanos(time_ms: u64) -> String {
    time_ms.saturating_mul(1_000_000).to_string()
}

/// The OTLP metrics request body (`ExportMetricsServiceRequest`) for the batch's Counter/Gauge
/// records, or `None` if it has none. `value` is a fixed-point i64, emitted as OTLP `asInt` (a string
/// per proto3 JSON) so it never becomes a lossy float. Counter -> Sum (delta, monotonic), Gauge ->
/// Gauge. The batch resource becomes the OTLP Resource, shared by every data point.
pub fn metrics_payload(batch: &TelemetryBatch) -> Option<String> {
    let mut metrics = Vec::new();
    for r in &batch.records {
        let dp = json!({
            "asInt": r.value.to_string(),
            "timeUnixNano": nanos(r.time_ms),
            "attributes": kv_attrs(&r.attrs),
        });
        match r.signal {
            Signal::Counter => metrics.push(json!({
                "name": r.name,
                "unit": r.unit,
                "sum": {
                    "dataPoints": [dp],
                    "aggregationTemporality": 1, // AGGREGATION_TEMPORALITY_DELTA (a counter delta, §40)
                    "isMonotonic": true,
                },
            })),
            Signal::Gauge => metrics.push(json!({
                "name": r.name,
                "unit": r.unit,
                "gauge": { "dataPoints": [dp] },
            })),
            Signal::Event => {}
        }
    }
    if metrics.is_empty() {
        return None;
    }
    Some(
        json!({
            "resourceMetrics": [{
                "resource": { "attributes": kv_attrs(&batch.resource) },
                "scopeMetrics": [{ "scope": { "name": "hop" }, "metrics": metrics }],
            }]
        })
        .to_string(),
    )
}

/// The OTLP logs request body (`ExportLogsServiceRequest`) for the batch's Event records, or `None` if
/// it has none. Each Event becomes a LogRecord whose body is the dotted name; the fixed-point value
/// rides as a `hop.value` int attribute.
pub fn logs_payload(batch: &TelemetryBatch) -> Option<String> {
    let mut records = Vec::new();
    for r in &batch.records {
        if !matches!(r.signal, Signal::Event) {
            continue;
        }
        let mut attrs = kv_attrs(&r.attrs);
        attrs.push(json!({ "key": "hop.value", "value": { "intValue": r.value.to_string() } }));
        records.push(json!({
            "timeUnixNano": nanos(r.time_ms),
            "body": { "stringValue": r.name },
            "attributes": attrs,
        }));
    }
    if records.is_empty() {
        return None;
    }
    Some(
        json!({
            "resourceLogs": [{
                "resource": { "attributes": kv_attrs(&batch.resource) },
                "scopeLogs": [{ "scope": { "name": "hop" }, "logRecords": records }],
            }]
        })
        .to_string(),
    )
}

/// The OTLP network seam: POST a JSON body to a URL with an optional `Authorization` header value.
pub trait OtlpTransport {
    fn post_json(
        &self,
        url: &str,
        body: &str,
        auth: Option<&str>,
    ) -> std::result::Result<(u16, String), String>;
}

/// The outcome of exporting one batch.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ExportOutcome {
    /// No endpoint mapped for this tenant; nothing forwarded (the common case for an unmapped tenant).
    Skipped,
    /// Forwarded, or nothing to forward, and every POST was accepted.
    Ok,
    /// At least one POST failed. Best-effort: the caller counts this, never propagates it.
    Failed(String),
}

/// Translate + forward attributed batches to their tenant's OTLP endpoint, over any [`OtlpTransport`].
pub struct OtlpSink<T: OtlpTransport> {
    transport: T,
    endpoints: OtlpEndpointMap,
}

impl<T: OtlpTransport> OtlpSink<T> {
    pub fn new(transport: T, endpoints: OtlpEndpointMap) -> Self {
        Self {
            transport,
            endpoints,
        }
    }

    /// Forward one batch to its tenant's endpoint. Metrics and logs are separate OTLP signals, so up
    /// to two POSTs (only the non-empty ones). An unmapped tenant is `Skipped`; a non-2xx or transport
    /// error on either POST is `Failed` (best-effort, surfaced to the caller only as a count).
    pub fn export(&self, tenant: &TenantId, batch: &TelemetryBatch) -> ExportOutcome {
        let Some(ep) = self.endpoints.get(tenant) else {
            return ExportOutcome::Skipped;
        };
        let base = ep.url.trim_end_matches('/');
        let mut fail: Option<String> = None;
        for (path, body) in [
            ("/v1/metrics", metrics_payload(batch)),
            ("/v1/logs", logs_payload(batch)),
        ] {
            let Some(body) = body else { continue };
            let url = format!("{base}{path}");
            match self.transport.post_json(&url, &body, ep.auth.as_deref()) {
                Ok((s, _)) if (200..300).contains(&s) => {}
                // Only the signal path + status, never the response body: the reason is logged
                // aggregate-only (services-03) and the body could echo tenant-identifying content.
                Ok((s, _)) => {
                    if fail.is_none() {
                        fail = Some(format!("{path} {s}"));
                    }
                }
                Err(e) => {
                    if fail.is_none() {
                        fail = Some(format!("{path} {e}"));
                    }
                }
            }
        }
        match fail {
            Some(e) => ExportOutcome::Failed(e),
            None => ExportOutcome::Ok,
        }
    }
}

/// The reqwest OTLP transport (live only). A short client timeout so one slow tenant endpoint holds
/// the export thread for seconds, not minutes; the queue is bounded, so backpressure drops rather than
/// blocks (see `main.rs`).
#[cfg(feature = "live")]
pub struct ReqwestOtlpTransport {
    client: reqwest::blocking::Client,
}

#[cfg(feature = "live")]
impl ReqwestOtlpTransport {
    pub fn new() -> std::result::Result<ReqwestOtlpTransport, String> {
        let client = reqwest::blocking::Client::builder()
            .timeout(std::time::Duration::from_secs(5))
            .build()
            .map_err(|e| format!("otlp http client: {e}"))?;
        Ok(ReqwestOtlpTransport { client })
    }
}

#[cfg(feature = "live")]
impl OtlpTransport for ReqwestOtlpTransport {
    fn post_json(
        &self,
        url: &str,
        body: &str,
        auth: Option<&str>,
    ) -> std::result::Result<(u16, String), String> {
        let mut req = self
            .client
            .post(url)
            .header("Content-Type", "application/json")
            .body(body.to_string());
        if let Some(a) = auth {
            req = req.header("Authorization", a);
        }
        // without_url() strips the endpoint URL from the error's Display: reqwest appends
        // ` for url (https://tenant.../v1/metrics)`, which is a per-tenant identifier that would land
        // in operator logs and break the services-03 aggregate-only guarantee.
        let resp = req
            .send()
            .map_err(|e| format!("otlp post: {}", e.without_url()))?;
        let status = resp.status().as_u16();
        let text = resp.text().unwrap_or_default();
        Ok((status, text))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    const T: &str = "000102030405060708090a0b0c0d0e0f";
    const TENANT: TenantId = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];

    #[test]
    fn parse_reads_url_and_optional_space_bearing_auth() {
        let text = format!(
            "# comment\n\
             {T} https://otlp.acme.example Bearer abc 123\n\
             ffffffffffffffffffffffffffffffff https://plain.example\n\
             bad-tenant https://x.example tok\n\
             {T2} ftp://nope.example tok\n",
            T = T,
            T2 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        );
        let m = OtlpEndpointMap::parse(&text);
        assert_eq!(m.len(), 2, "bad tenant + non-http rows are skipped");
        let a = m.get(&TENANT).unwrap();
        assert_eq!(a.url, "https://otlp.acme.example");
        assert_eq!(
            a.auth.as_deref(),
            Some("Bearer abc 123"),
            "auth keeps its spaces"
        );
        let b = m.get(&[0xff; 16]).unwrap();
        assert_eq!(b.url, "https://plain.example");
        assert_eq!(b.auth, None);
    }

    fn batch() -> TelemetryBatch {
        TelemetryBatch::new()
            .counter("hop.bundle.delivered", 3, 1_700_000_000_000)
            .gauge("hop.delivery.latency_ms", 42, 1_700_000_000_000)
            .event("hop.spool.parked", 1_700_000_000_000)
    }

    #[test]
    fn metrics_payload_maps_counter_to_sum_and_gauge_to_gauge() {
        let v: Value = serde_json::from_str(&metrics_payload(&batch()).unwrap()).unwrap();
        let metrics = &v["resourceMetrics"][0]["scopeMetrics"][0]["metrics"];
        // Counter -> Sum, monotonic delta, value as a STRING asInt, time in nanos.
        assert_eq!(metrics[0]["name"], "hop.bundle.delivered");
        assert_eq!(metrics[0]["sum"]["isMonotonic"], true);
        assert_eq!(metrics[0]["sum"]["aggregationTemporality"], 1);
        assert_eq!(metrics[0]["sum"]["dataPoints"][0]["asInt"], "3");
        assert_eq!(
            metrics[0]["sum"]["dataPoints"][0]["timeUnixNano"],
            "1700000000000000000"
        );
        // Gauge -> Gauge.
        assert_eq!(metrics[1]["gauge"]["dataPoints"][0]["asInt"], "42");
        // The Event is NOT in the metrics payload.
        assert_eq!(metrics.as_array().unwrap().len(), 2);
    }

    #[test]
    fn logs_payload_maps_event_to_logrecord() {
        let v: Value = serde_json::from_str(&logs_payload(&batch()).unwrap()).unwrap();
        let lr = &v["resourceLogs"][0]["scopeLogs"][0]["logRecords"][0];
        assert_eq!(lr["body"]["stringValue"], "hop.spool.parked");
        assert_eq!(lr["timeUnixNano"], "1700000000000000000");
        let val_attr = lr["attributes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|a| a["key"] == "hop.value")
            .unwrap();
        assert_eq!(val_attr["value"]["intValue"], "1");
    }

    #[test]
    fn payloads_are_none_when_the_signal_class_is_absent() {
        let only_counter = TelemetryBatch::new().counter("c", 1, 0);
        assert!(metrics_payload(&only_counter).is_some());
        assert!(logs_payload(&only_counter).is_none());
        let only_event = TelemetryBatch::new().event("e", 0);
        assert!(metrics_payload(&only_event).is_none());
        assert!(logs_payload(&only_event).is_some());
    }

    #[derive(Default)]
    struct FakeTransport {
        posts: RefCell<Vec<(String, String, Option<String>)>>,
        status: u16,
    }
    impl OtlpTransport for FakeTransport {
        fn post_json(
            &self,
            url: &str,
            body: &str,
            auth: Option<&str>,
        ) -> std::result::Result<(u16, String), String> {
            self.posts.borrow_mut().push((
                url.to_string(),
                body.to_string(),
                auth.map(str::to_string),
            ));
            Ok((
                if self.status == 0 { 200 } else { self.status },
                "{}".into(),
            ))
        }
    }

    fn sink(status: u16) -> OtlpSink<FakeTransport> {
        let map = OtlpEndpointMap::parse(&format!("{T} https://otlp.acme.example/ Bearer k"));
        OtlpSink::new(
            FakeTransport {
                status,
                ..Default::default()
            },
            map,
        )
    }

    #[test]
    fn export_skips_an_unmapped_tenant() {
        let s = sink(200);
        assert_eq!(s.export(&[9u8; 16], &batch()), ExportOutcome::Skipped);
        assert!(s.transport.posts.borrow().is_empty());
    }

    #[test]
    fn export_posts_metrics_and_logs_to_the_right_urls_with_auth() {
        let s = sink(200);
        assert_eq!(s.export(&TENANT, &batch()), ExportOutcome::Ok);
        let posts = s.transport.posts.borrow();
        assert_eq!(posts.len(), 2, "one metrics POST + one logs POST");
        // trailing slash on the base is trimmed, not doubled.
        assert_eq!(posts[0].0, "https://otlp.acme.example/v1/metrics");
        assert_eq!(posts[1].0, "https://otlp.acme.example/v1/logs");
        assert_eq!(posts[0].2.as_deref(), Some("Bearer k"));
    }

    #[test]
    fn export_reports_a_non_2xx_as_failed() {
        let s = sink(503);
        assert!(matches!(
            s.export(&TENANT, &batch()),
            ExportOutcome::Failed(_)
        ));
    }
}
