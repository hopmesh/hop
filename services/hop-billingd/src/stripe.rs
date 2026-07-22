//! Stripe meter-event emission (DESIGN.md §37): turn a [`MeterEvent`] into the exact Stripe Billing
//! Meter Events API call.
//!
//! This is the path that actually charges money, so everything except the socket call is PURE and
//! unit-tested: request construction, form encoding, the tenant to customer lookup, and the
//! status-to-Result mapping. Only [`Transport`] touches the network, with a `reqwest` implementation
//! compiled under `--features live`, so the default build (and CI, which has no credentials) still
//! exercises all of the logic with a fake transport.
//!
//! Idempotency is doubled on purpose. Our deterministic `{event_name}:{tenant}:{hour}` key is sent
//! BOTH as Stripe's `identifier` (which dedups at the meter, so a retried hour never double-bills)
//! and as the `Idempotency-Key` header (which dedups the HTTP call itself). A failed emit returns
//! `Err`, which makes [`crate::reconcile`] hold its watermark and retry the same window next run,
//! landing on the same keys.

use std::collections::BTreeMap;

use crate::{hex16, MeterEvent, MeterSink, TenantId};

/// Stripe's Billing Meter Events endpoint.
pub const STRIPE_METER_EVENTS_URL: &str = "https://api.stripe.com/v1/billing/meter_events";

/// Tenant to Stripe customer id. The account service owns this mapping at signup (it creates the
/// customer + subscription); the reconciler only reads it. A tenant with no customer is an error, not
/// a silent skip: billing a meter event to nobody would lose revenue quietly.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CustomerMap {
    map: BTreeMap<TenantId, String>,
}

impl CustomerMap {
    pub fn new() -> CustomerMap {
        CustomerMap::default()
    }

    pub fn insert(&mut self, tenant: TenantId, customer_id: impl Into<String>) {
        self.map.insert(tenant, customer_id.into());
    }

    pub fn get(&self, tenant: &TenantId) -> Option<&str> {
        self.map.get(tenant).map(|s| s.as_str())
    }

    pub fn len(&self) -> usize {
        self.map.len()
    }

    pub fn is_empty(&self) -> bool {
        self.map.is_empty()
    }

    /// Parse `<tenant-hex-32> <cus_...>` lines; `#` comments and blank lines are skipped, and a
    /// malformed line is skipped rather than failing the whole map (one bad row must not stop billing).
    pub fn parse(text: &str) -> CustomerMap {
        let mut out = CustomerMap::new();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let mut parts = line.split_whitespace();
            let (Some(tenant_hex), Some(customer)) = (parts.next(), parts.next()) else {
                continue;
            };
            let Some(tenant) = parse_tenant_hex(tenant_hex) else {
                continue;
            };
            out.insert(tenant, customer);
        }
        out
    }
}

/// Parse a 32-char hex string into a 16-byte [`TenantId`].
fn parse_tenant_hex(s: &str) -> Option<TenantId> {
    if s.len() != 32 || !s.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let mut out = [0u8; 16];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(out)
}

/// Percent-encode for `application/x-www-form-urlencoded`. Everything outside the unreserved set is
/// escaped (including `[` and `]` in the `payload[...]` keys), so no customer id or event name can
/// break out of its field.
fn form_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// One outbound Stripe call: the form body plus the idempotency key to send as a header.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StripeRequest {
    pub url: &'static str,
    pub body: String,
    pub idempotency_key: String,
}

/// Build the meter-event request for `event`, billed to `customer_id`, stamped at `timestamp_s`
/// (unix seconds). Deterministic: the same event always produces byte-identical output, which is what
/// makes a retry safe.
pub fn meter_event_request(
    event: &MeterEvent,
    customer_id: &str,
    timestamp_s: u64,
) -> StripeRequest {
    let body = format!(
        "event_name={}&identifier={}&timestamp={}&payload%5Bstripe_customer_id%5D={}&payload%5Bvalue%5D={}",
        form_encode(event.event_name),
        form_encode(&event.idempotency_key),
        timestamp_s,
        form_encode(customer_id),
        event.value,
    );
    StripeRequest {
        url: STRIPE_METER_EVENTS_URL,
        body,
        idempotency_key: event.idempotency_key.clone(),
    }
}

/// The unix-seconds timestamp for an hour-bucketed event: the START of the hour it covers. Stripe
/// aggregates by timestamp into the billing period, and using the bucket start keeps a retry
/// byte-identical to the first attempt.
pub fn hour_timestamp_s(hour: u64) -> u64 {
    hour.saturating_mul(3600)
}

/// The single network seam. Implementors POST a form body and return `(status, body)`; a transport
/// level failure (DNS, TLS, timeout) is `Err`.
pub trait Transport {
    fn post_form(
        &self,
        url: &str,
        body: &str,
        idempotency_key: &str,
    ) -> Result<(u16, String), String>;
}

/// A [`MeterSink`] that emits to Stripe. Wrap any [`Transport`]; the reconciler only sees `MeterSink`,
/// so its watermark/retry contract is unchanged.
pub struct StripeSink<T: Transport> {
    transport: T,
    customers: CustomerMap,
}

impl<T: Transport> StripeSink<T> {
    pub fn new(transport: T, customers: CustomerMap) -> StripeSink<T> {
        StripeSink {
            transport,
            customers,
        }
    }
}

impl<T: Transport> MeterSink for StripeSink<T> {
    fn emit(&mut self, event: &MeterEvent) -> Result<(), String> {
        let Some(customer) = self.customers.get(&event.tenant) else {
            // Not a skip: an unmapped tenant means real usage would go unbilled, so fail loudly and
            // let the watermark hold until the account service has created the customer.
            return Err(format!(
                "no stripe customer for tenant {}",
                hex16(&event.tenant)
            ));
        };
        let req = meter_event_request(event, customer, hour_timestamp_s(event.hour));
        match self
            .transport
            .post_form(req.url, &req.body, &req.idempotency_key)
        {
            Ok((status, _)) if (200..300).contains(&status) => Ok(()),
            // 4xx and 5xx both hold the watermark. A 4xx is usually a config error (bad key, unknown
            // meter) that a retry will surface again rather than silently dropping the usage.
            Ok((status, body)) => Err(format!(
                "stripe {status}: {}",
                body.chars().take(200).collect::<String>()
            )),
            Err(e) => Err(e),
        }
    }
}

/// The real transport: a blocking `reqwest` POST with the restricted Stripe key. Compiled only under
/// `--features live` so the default build has no network dependency.
#[cfg(feature = "live")]
pub struct ReqwestTransport {
    client: reqwest::blocking::Client,
    api_key: String,
}

#[cfg(feature = "live")]
impl ReqwestTransport {
    pub fn new(api_key: String) -> Result<ReqwestTransport, String> {
        let client = reqwest::blocking::Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .map_err(|e| format!("http client: {e}"))?;
        Ok(ReqwestTransport { client, api_key })
    }
}

#[cfg(feature = "live")]
impl Transport for ReqwestTransport {
    fn post_form(
        &self,
        url: &str,
        body: &str,
        idempotency_key: &str,
    ) -> Result<(u16, String), String> {
        let resp = self
            .client
            .post(url)
            .bearer_auth(&self.api_key)
            .header("Idempotency-Key", idempotency_key)
            .header("Content-Type", "application/x-www-form-urlencoded")
            .body(body.to_string())
            .send()
            .map_err(|e| format!("stripe request failed: {e}"))?;
        let status = resp.status().as_u16();
        let text = resp.text().unwrap_or_default();
        Ok((status, text))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::meter;
    use std::cell::RefCell;

    const A: TenantId = [1u8; 16];
    const B: TenantId = [2u8; 16];

    /// Records what was sent and replays a scripted response.
    struct FakeTransport {
        response: Result<(u16, String), String>,
        sent: RefCell<Vec<(String, String, String)>>,
    }
    impl FakeTransport {
        fn ok() -> FakeTransport {
            FakeTransport {
                response: Ok((200, "{}".into())),
                sent: RefCell::new(Vec::new()),
            }
        }
        fn status(code: u16, body: &str) -> FakeTransport {
            FakeTransport {
                response: Ok((code, body.into())),
                sent: RefCell::new(Vec::new()),
            }
        }
        fn boom() -> FakeTransport {
            FakeTransport {
                response: Err("connection reset".into()),
                sent: RefCell::new(Vec::new()),
            }
        }
    }
    impl Transport for FakeTransport {
        fn post_form(&self, url: &str, body: &str, key: &str) -> Result<(u16, String), String> {
            self.sent
                .borrow_mut()
                .push((url.into(), body.into(), key.into()));
            self.response.clone()
        }
    }

    fn event(tenant: TenantId, value: u64, hour: u64) -> MeterEvent {
        MeterEvent {
            event_name: meter::TELEMETRY_EVENTS,
            tenant,
            value,
            idempotency_key: format!("{}:{}:{hour}", meter::TELEMETRY_EVENTS, hex16(&tenant)),
            hour,
        }
    }

    #[test]
    fn builds_the_exact_stripe_form_body() {
        let e = event(A, 420, 5);
        let req = meter_event_request(&e, "cus_ABC123", hour_timestamp_s(5));
        assert_eq!(req.url, STRIPE_METER_EVENTS_URL);
        assert_eq!(
            req.body,
            format!(
                "event_name=hop_telemetry_events&identifier=hop_telemetry_events%3A{}%3A5\
                 &timestamp=18000&payload%5Bstripe_customer_id%5D=cus_ABC123&payload%5Bvalue%5D=420",
                hex16(&A)
            )
        );
        assert_eq!(req.idempotency_key, e.idempotency_key);
    }

    #[test]
    fn a_retry_is_byte_identical_so_stripe_dedups() {
        let e = event(A, 7, 9);
        let first = meter_event_request(&e, "cus_X", hour_timestamp_s(e.hour));
        let again = meter_event_request(&e, "cus_X", hour_timestamp_s(e.hour));
        assert_eq!(first, again);
    }

    #[test]
    fn form_encode_escapes_reserved_characters() {
        assert_eq!(form_encode("a b&c=d"), "a%20b%26c%3Dd");
        assert_eq!(form_encode("cus_A-1.2~3"), "cus_A-1.2~3"); // unreserved passes through
    }

    #[test]
    fn emits_and_sends_the_idempotency_key_header() {
        let mut sink = StripeSink::new(FakeTransport::ok(), {
            let mut m = CustomerMap::new();
            m.insert(A, "cus_ABC123");
            m
        });
        let e = event(A, 3, 1);
        assert!(sink.emit(&e).is_ok());
        let sent = sink.transport.sent.borrow();
        assert_eq!(sent.len(), 1);
        assert_eq!(sent[0].0, STRIPE_METER_EVENTS_URL);
        assert_eq!(sent[0].2, e.idempotency_key, "idempotency key header");
    }

    #[test]
    fn a_4xx_or_5xx_holds_the_watermark_by_returning_err() {
        for code in [400u16, 401, 429, 500, 503] {
            let mut sink = StripeSink::new(FakeTransport::status(code, "{\"error\":\"nope\"}"), {
                let mut m = CustomerMap::new();
                m.insert(A, "cus_ABC123");
                m
            });
            let err = sink.emit(&event(A, 1, 1)).unwrap_err();
            assert!(
                err.contains(&code.to_string()),
                "surfaces the status: {err}"
            );
        }
    }

    #[test]
    fn a_transport_failure_is_an_error_not_a_silent_drop() {
        let mut sink = StripeSink::new(FakeTransport::boom(), {
            let mut m = CustomerMap::new();
            m.insert(A, "cus_ABC123");
            m
        });
        assert!(sink.emit(&event(A, 1, 1)).is_err());
    }

    #[test]
    fn an_unmapped_tenant_errors_rather_than_billing_nobody() {
        let mut sink = StripeSink::new(FakeTransport::ok(), CustomerMap::new());
        let err = sink.emit(&event(B, 5, 1)).unwrap_err();
        assert!(err.contains("no stripe customer"), "{err}");
        assert!(
            sink.transport.sent.borrow().is_empty(),
            "nothing sent for an unmapped tenant"
        );
    }

    #[test]
    fn customer_map_parses_and_skips_junk() {
        let text = format!(
            "# comment\n\n{} cus_AAA\nnot-a-tenant cus_BBB\n{} cus_CCC\nshort\n",
            hex16(&A),
            hex16(&B)
        );
        let m = CustomerMap::parse(&text);
        assert_eq!(m.len(), 2);
        assert_eq!(m.get(&A), Some("cus_AAA"));
        assert_eq!(m.get(&B), Some("cus_CCC"));
    }

    #[test]
    fn hour_timestamp_is_the_bucket_start() {
        assert_eq!(hour_timestamp_s(0), 0);
        assert_eq!(hour_timestamp_s(5), 18_000);
        assert_eq!(hour_timestamp_s(u64::MAX), u64::MAX); // saturates, no overflow panic
    }

    /// The whole point of the seam: `reconcile` drives a Stripe sink exactly like any other sink, and
    /// a mid-run Stripe failure holds the watermark so the hour retries (onto the same keys).
    #[test]
    fn reconcile_over_a_stripe_sink_holds_the_watermark_on_failure() {
        use crate::{reconcile_telemetry, TelemetryRow};
        let mut customers = CustomerMap::new();
        customers.insert(A, "cus_ABC123");
        let mut sink = StripeSink::new(FakeTransport::status(500, "down"), customers);
        let rows = vec![(
            4,
            A,
            TelemetryRow {
                events: 10,
                payload_bytes: 0,
            },
        )];
        let wm = reconcile_telemetry(&rows, 0, 6, &mut sink);
        assert_eq!(wm, 0, "watermark held: the hour retries next run");
    }
}
