//! Stripe webhook verification + event parsing, PURE (no network), so the durable-entitlement update
//! is exercised entirely in CI with no Stripe call (the hop-billingd discipline). The socket layer
//! (`main.rs`, `--features live`) reads the RAW request bytes plus the `Stripe-Signature` header and
//! hands them here; a verified event is projected onto the tenant's STORED plan + subscription status,
//! complementing the live `billing::current_subscription` read path.
//!
//! The signature scheme is Stripe's: the header is `t=<unix>,v1=<hex>[,v1=<hex>,v0=...]`; the signed
//! payload is `"{t}.{body}"`, HMAC-SHA256'd under the endpoint's signing secret. We reject a timestamp
//! outside the tolerance (replay guard) and CONSTANT-TIME compare the MAC against every provided `v1`
//! (Stripe sends more than one only during a signing-secret rotation).

use hmac::{Hmac, KeyInit, Mac};
use sha2::Sha256;
use thiserror::Error;

type HmacSha256 = Hmac<Sha256>;

/// Why a webhook was rejected. A signature/timestamp failure MUST short-circuit BEFORE any processing,
/// so an unverified body never reaches [`parse_event`] or the store.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum WebhookError {
    /// The `Stripe-Signature` header is absent or malformed (no `t`, no `v1`, or an unparseable `t`).
    #[error("malformed Stripe-Signature header")]
    InvalidHeader,
    /// The timestamp is outside the accepted tolerance from now: a replay, or a badly skewed clock.
    #[error("timestamp outside tolerance")]
    TimestampOutOfTolerance,
    /// No provided `v1` matched the computed HMAC.
    #[error("signature mismatch")]
    SignatureMismatch,
    /// The event body is not a JSON object with a `type` (genuinely malformed, not merely missing an
    /// optional field, which is tolerated as a skip).
    #[error("invalid webhook payload")]
    InvalidPayload,
}

/// HMAC-SHA256 of `msg` under `secret`. HMAC accepts a key of any length, so this never errors.
fn hmac_sha256(secret: &[u8], msg: &[u8]) -> Vec<u8> {
    let mut mac =
        <HmacSha256 as KeyInit>::new_from_slice(secret).expect("HMAC accepts any key length");
    mac.update(msg);
    mac.finalize().into_bytes().to_vec()
}

/// Decode a hex string to bytes, or `None` if it is not even-length valid hex.
fn hex_decode(s: &str) -> Option<Vec<u8>> {
    if !s.len().is_multiple_of(2) {
        return None;
    }
    let val = |c: u8| -> Option<u8> {
        match c {
            b'0'..=b'9' => Some(c - b'0'),
            b'a'..=b'f' => Some(c - b'a' + 10),
            b'A'..=b'F' => Some(c - b'A' + 10),
            _ => None,
        }
    };
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(s.len() / 2);
    for pair in bytes.chunks(2) {
        out.push((val(pair[0])? << 4) | val(pair[1])?);
    }
    Some(out)
}

/// Constant-time byte equality. It never short-circuits on content: it folds every XORed byte with
/// `|=`, so the running time is independent of WHERE two equal-length inputs first differ (the timing
/// side channel a `==` on the signature would leak). Length is not secret, so a mismatch returns early.
fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

/// Verify a Stripe webhook signature against the RAW body bytes. Parses the `Stripe-Signature` header,
/// rejects a timestamp more than `tolerance_secs` from `now_unix` (replay guard), then HMAC-SHA256s the
/// `"{t}.{body}"` payload under `secret` and constant-time compares it against every provided `v1`.
/// `Ok(())` iff at least one `v1` matches. The body MUST be the exact received bytes (never a
/// re-serialized JSON), or the MAC will not reproduce.
pub fn verify_signature(
    secret: &str,
    sig_header: &str,
    body: &[u8],
    now_unix: i64,
    tolerance_secs: i64,
) -> Result<(), WebhookError> {
    let mut t: Option<&str> = None;
    let mut v1s: Vec<&str> = Vec::new();
    for item in sig_header.split(',') {
        let Some((k, v)) = item.split_once('=') else {
            continue;
        };
        match k.trim() {
            "t" => t = Some(v.trim()),
            "v1" => v1s.push(v.trim()),
            _ => {} // v0 (test-mode) and any future scheme element are ignored
        }
    }
    let t = t.ok_or(WebhookError::InvalidHeader)?;
    if v1s.is_empty() {
        return Err(WebhookError::InvalidHeader);
    }
    let ts: i64 = t.parse().map_err(|_| WebhookError::InvalidHeader)?;
    if (now_unix - ts).abs() > tolerance_secs {
        return Err(WebhookError::TimestampOutOfTolerance);
    }
    // signed_payload = "{t}.{body}" over the EXACT raw bytes.
    let mut signed = Vec::with_capacity(t.len() + 1 + body.len());
    signed.extend_from_slice(t.as_bytes());
    signed.push(b'.');
    signed.extend_from_slice(body);
    let expected = hmac_sha256(secret.as_bytes(), &signed);
    for v1 in v1s {
        if let Some(got) = hex_decode(v1) {
            if ct_eq(&expected, &got) {
                return Ok(());
            }
        }
    }
    Err(WebhookError::SignatureMismatch)
}

/// A verified webhook projected to only what the durable-entitlement update needs. `Ignored` is an
/// event we recognize but that carries no stored-entitlement change (e.g. `checkout.session.completed`,
/// whose authoritative plan/status arrive on the paired `customer.subscription.*` event).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WebhookEvent {
    /// A subscription's current state: the Stripe `customer`, its `status`, and the subscribed price
    /// ids (which the caller maps to a plan via the price catalog).
    Subscription {
        customer: String,
        status: String,
        price_ids: Vec<String>,
    },
    /// The subscription ended: the caller forces the plan to Developer and the status to `canceled`.
    SubscriptionDeleted { customer: String },
    /// Recognized but not an entitlement change; the caller acks it (200) and writes nothing.
    Ignored,
}

/// Parse a (already signature-verified) event body into a [`WebhookEvent`]. Defensive: a recognized
/// event missing the fields it needs becomes `Ignored` (a skip, never a panic); only a body that is not
/// a JSON object with a string `type` is an error. Handles the subscription lifecycle
/// (`customer.subscription.created|updated|deleted`), `checkout.session.completed`, and the invoice
/// paid/failed pair; every other type acks as `Ignored`.
pub fn parse_event(body: &[u8]) -> Result<WebhookEvent, WebhookError> {
    let v: serde_json::Value =
        serde_json::from_slice(body).map_err(|_| WebhookError::InvalidPayload)?;
    if !v.is_object() {
        return Err(WebhookError::InvalidPayload);
    }
    let event_type = v
        .get("type")
        .and_then(|t| t.as_str())
        .ok_or(WebhookError::InvalidPayload)?;
    let object = &v["data"]["object"];
    let customer = object.get("customer").and_then(|c| c.as_str());
    match event_type {
        "customer.subscription.created" | "customer.subscription.updated" => {
            let (Some(customer), Some(status)) =
                (customer, object.get("status").and_then(|s| s.as_str()))
            else {
                return Ok(WebhookEvent::Ignored); // missing fields -> skip, never panic
            };
            Ok(WebhookEvent::Subscription {
                customer: customer.to_string(),
                status: status.to_string(),
                price_ids: price_ids_from(&object["items"]["data"]),
            })
        }
        "customer.subscription.deleted" => match customer {
            Some(customer) => Ok(WebhookEvent::SubscriptionDeleted {
                customer: customer.to_string(),
            }),
            None => Ok(WebhookEvent::Ignored),
        },
        "invoice.paid" | "invoice.payment_failed" => {
            let Some(customer) = customer else {
                return Ok(WebhookEvent::Ignored);
            };
            let price_ids = price_ids_from(&object["lines"]["data"]);
            // Only actionable when the invoice carried its subscription's line prices; without them we
            // cannot derive a plan and must NOT blindly downgrade a paying tenant to Developer.
            if price_ids.is_empty() {
                return Ok(WebhookEvent::Ignored);
            }
            let status = if event_type == "invoice.paid" {
                "active"
            } else {
                "past_due"
            };
            Ok(WebhookEvent::Subscription {
                customer: customer.to_string(),
                status: status.to_string(),
                price_ids,
            })
        }
        // Recognized, but the authoritative plan/status arrive on the paired subscription event.
        "checkout.session.completed" => Ok(WebhookEvent::Ignored),
        _ => Ok(WebhookEvent::Ignored),
    }
}

/// The `price.id` of every entry in a Stripe `data` array (subscription items or invoice lines).
fn price_ids_from(data: &serde_json::Value) -> Vec<String> {
    data.as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(|i| i["price"]["id"].as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    const SECRET: &str = "whsec_test_secret_key";
    const BODY: &[u8] = br#"{"id":"evt_1","type":"customer.subscription.updated"}"#;
    const TS: i64 = 1_700_000_000;

    /// Lowercase-hex encode (only the tests need to render a signature back to the header form).
    fn hex_encode(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    /// Build a valid `Stripe-Signature` header for `body` at `ts` under `secret` (the known-answer
    /// vector: deterministic, computed once here from the same primitives verify uses).
    fn header_for(secret: &str, ts: i64, body: &[u8]) -> String {
        let mut signed = Vec::new();
        signed.extend_from_slice(ts.to_string().as_bytes());
        signed.push(b'.');
        signed.extend_from_slice(body);
        let sig = hex_encode(&hmac_sha256(secret.as_bytes(), &signed));
        format!("t={ts},v1={sig}")
    }

    #[test]
    fn verify_accepts_a_known_good_signature() {
        let h = header_for(SECRET, TS, BODY);
        assert!(verify_signature(SECRET, &h, BODY, TS + 5, 300).is_ok());
    }

    #[test]
    fn verify_rejects_a_tampered_body() {
        let h = header_for(SECRET, TS, BODY);
        let tampered = br#"{"id":"evt_1","type":"customer.subscription.deleted"}"#;
        assert_eq!(
            verify_signature(SECRET, &h, tampered, TS, 300),
            Err(WebhookError::SignatureMismatch)
        );
    }

    #[test]
    fn verify_rejects_the_wrong_secret() {
        let h = header_for(SECRET, TS, BODY);
        assert_eq!(
            verify_signature("whsec_other", &h, BODY, TS, 300),
            Err(WebhookError::SignatureMismatch)
        );
    }

    #[test]
    fn verify_rejects_an_out_of_tolerance_timestamp() {
        let h = header_for(SECRET, TS, BODY);
        // 400s after the signing time with a 300s tolerance -> the replay guard trips.
        assert_eq!(
            verify_signature(SECRET, &h, BODY, TS + 400, 300),
            Err(WebhookError::TimestampOutOfTolerance)
        );
        // and 400s before.
        assert_eq!(
            verify_signature(SECRET, &h, BODY, TS - 400, 300),
            Err(WebhookError::TimestampOutOfTolerance)
        );
    }

    #[test]
    fn verify_rejects_bad_hex_and_malformed_headers() {
        // valid timestamp, but v1 is not hex -> no candidate can match.
        assert_eq!(
            verify_signature(SECRET, &format!("t={TS},v1=zzzznothex"), BODY, TS, 300),
            Err(WebhookError::SignatureMismatch)
        );
        // no v1 at all.
        assert_eq!(
            verify_signature(SECRET, &format!("t={TS}"), BODY, TS, 300),
            Err(WebhookError::InvalidHeader)
        );
        // no t at all.
        assert_eq!(
            verify_signature(SECRET, "v1=abcd", BODY, TS, 300),
            Err(WebhookError::InvalidHeader)
        );
        // t is not an integer.
        assert_eq!(
            verify_signature(SECRET, "t=notanumber,v1=abcd", BODY, TS, 300),
            Err(WebhookError::InvalidHeader)
        );
    }

    #[test]
    fn verify_accepts_when_one_of_several_v1_matches() {
        // Stripe sends multiple v1 lines during a signing-secret rotation; any match is acceptance.
        let good = header_for(SECRET, TS, BODY)
            .split_once("v1=")
            .unwrap()
            .1
            .to_string();
        let header = format!("t={TS},v1=deadbeef,v1={good}");
        assert!(verify_signature(SECRET, &header, BODY, TS, 300).is_ok());
    }

    #[test]
    fn parse_subscription_updated_pulls_customer_status_and_prices() {
        let body = br#"{
            "type":"customer.subscription.updated",
            "data":{"object":{
                "customer":"cus_123",
                "status":"active",
                "items":{"data":[{"price":{"id":"price_usage"}},{"price":{"id":"price_tel"}}]}
            }}
        }"#;
        assert_eq!(
            parse_event(body).unwrap(),
            WebhookEvent::Subscription {
                customer: "cus_123".into(),
                status: "active".into(),
                price_ids: vec!["price_usage".into(), "price_tel".into()],
            }
        );
    }

    #[test]
    fn parse_subscription_deleted_is_a_cancel() {
        let body = br#"{"type":"customer.subscription.deleted","data":{"object":{"customer":"cus_9","status":"canceled"}}}"#;
        assert_eq!(
            parse_event(body).unwrap(),
            WebhookEvent::SubscriptionDeleted {
                customer: "cus_9".into()
            }
        );
    }

    #[test]
    fn parse_invoice_paid_projects_active_with_line_prices() {
        let body = br#"{"type":"invoice.paid","data":{"object":{"customer":"cus_7","lines":{"data":[{"price":{"id":"price_scale_base"}}]}}}}"#;
        assert_eq!(
            parse_event(body).unwrap(),
            WebhookEvent::Subscription {
                customer: "cus_7".into(),
                status: "active".into(),
                price_ids: vec!["price_scale_base".into()],
            }
        );
    }

    #[test]
    fn parse_invoice_payment_failed_projects_past_due() {
        let body = br#"{"type":"invoice.payment_failed","data":{"object":{"customer":"cus_7","lines":{"data":[{"price":{"id":"price_usage"}}]}}}}"#;
        match parse_event(body).unwrap() {
            WebhookEvent::Subscription {
                status, customer, ..
            } => {
                assert_eq!(status, "past_due");
                assert_eq!(customer, "cus_7");
            }
            other => panic!("expected Subscription, got {other:?}"),
        }
    }

    #[test]
    fn parse_checkout_completed_is_ignored() {
        let body = br#"{"type":"checkout.session.completed","data":{"object":{"customer":"cus_1","status":"complete"}}}"#;
        assert_eq!(parse_event(body).unwrap(), WebhookEvent::Ignored);
    }

    #[test]
    fn parse_defends_against_missing_fields_and_junk() {
        // a subscription event with no customer -> Ignored, never a panic.
        let no_customer =
            br#"{"type":"customer.subscription.updated","data":{"object":{"status":"active"}}}"#;
        assert_eq!(parse_event(no_customer).unwrap(), WebhookEvent::Ignored);
        // an invoice with no line prices -> Ignored (cannot derive a plan; must not downgrade).
        let no_lines = br#"{"type":"invoice.paid","data":{"object":{"customer":"cus_7"}}}"#;
        assert_eq!(parse_event(no_lines).unwrap(), WebhookEvent::Ignored);
        // an unknown event type -> Ignored.
        let unknown = br#"{"type":"payout.paid","data":{"object":{}}}"#;
        assert_eq!(parse_event(unknown).unwrap(), WebhookEvent::Ignored);
        // not JSON -> InvalidPayload.
        assert_eq!(parse_event(b"not json"), Err(WebhookError::InvalidPayload));
        // JSON but not an object -> InvalidPayload.
        assert_eq!(parse_event(b"[1,2,3]"), Err(WebhookError::InvalidPayload));
        // an object with no type -> InvalidPayload.
        assert_eq!(
            parse_event(br#"{"data":{}}"#),
            Err(WebhookError::InvalidPayload)
        );
    }
}
