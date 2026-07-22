//! Near-realtime per-tenant usage for the console, read straight off the fleet's Firestore usage
//! ledgers (~30s fresh) rather than BigQuery (hourly, lagging) or Stripe (reconciled hours only). The
//! relays write `usage/{hour}/{tenant_hex}` (16 bytes LE: bundles, payload_bytes) into their own kv
//! partition and collectors write `telemetry_usage/{hour}/{tenant_hex}` (8 bytes LE: events); the two
//! customer meters are Reach = bundles delivered and Telemetry = events. Reading a tenant's total is a
//! concatenation across every node partition (the same shape hop-billingd's reconciler collects), via
//! the shared `hop_store_firestore::KvReader`.
//!
//!   GET /console/usage?tenant=..  -> {reach:{deliveries,included}, telemetry:{events,included}, ...}
//!
//! The window is a rolling 30 days (labelled), a stand-in for the exact Stripe billing period until
//! that alignment lands; the SUM is exact, only the boundary is approximate.

/// The two customer-facing meters' current-window totals. `payload_bytes` is carried for future use
/// but not a billed customer meter.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct UsageTotals {
    /// Reach: offline deliveries (bundles), the billed count.
    pub reach_deliveries: u64,
    /// Telemetry: OTel-over-Hop events, the billed count.
    pub telemetry_events: u64,
}

/// The free-tier allowances (per billing period), NOT encoded in Stripe (prose in
/// docs/pricing-cost-model.md), so the "usage vs included" view reads them from here.
pub const REACH_INCLUDED: u64 = 10_000;
pub const TELEMETRY_INCLUDED: u64 = 25_000_000;

/// Hours in the rolling usage window (30 days). `usage/{hour}/..` keys use hours-since-epoch, so the
/// window is `now_hour - USAGE_WINDOW_HOURS ..= now_hour`.
pub const USAGE_WINDOW_HOURS: u64 = 24 * 30;

/// Sum one node partition's kv rows into `tenant_hex`'s totals for hours `>= since_hour`. Pure: rows
/// that are not this tenant's `usage/`/`telemetry_usage/` ledger entries (or are malformed / wrong
/// length / outside the window) are skipped, so other node state in the shared kv namespace is ignored.
pub fn sum_tenant_usage(
    rows: &[(String, Vec<u8>)],
    tenant_hex: &str,
    since_hour: u64,
) -> UsageTotals {
    let mut totals = UsageTotals::default();
    for (key, value) in rows {
        let mut parts = key.split('/');
        let (Some(prefix), Some(hour_s), Some(tenant_s)) =
            (parts.next(), parts.next(), parts.next())
        else {
            continue;
        };
        if parts.next().is_some() || tenant_s != tenant_hex {
            continue; // more than 3 segments, or a different tenant
        }
        let Ok(hour) = hour_s.parse::<u64>() else {
            continue;
        };
        if hour < since_hour {
            continue;
        }
        match prefix {
            "usage" if value.len() == 16 => {
                // bundles = the first u64 LE = the delivery count (Reach).
                totals.reach_deliveries += u64::from_le_bytes(value[..8].try_into().unwrap());
            }
            "telemetry_usage" if value.len() == 8 => {
                totals.telemetry_events += u64::from_le_bytes(value[..8].try_into().unwrap());
            }
            _ => {}
        }
    }
    totals
}

/// The first hour (hours-since-epoch) of the rolling usage window ending at `now_ms`.
pub fn window_start_hour(now_ms: u64) -> u64 {
    (now_ms / 3_600_000).saturating_sub(USAGE_WINDOW_HOURS)
}

/// Read a tenant's usage across EVERY node partition (relays + collectors) for the current window.
/// A partition that fails to read is logged and skipped (its usage is picked up on the next read),
/// so one flaky partition never blanks the whole view; only node-enumeration failure is fatal.
#[cfg(feature = "firestore")]
pub fn read_tenant_usage(
    project: &str,
    tenant_hex: &str,
    since_hour: u64,
) -> Result<UsageTotals, String> {
    let reader = hop_store_firestore::KvReader::new(project);
    let nodes = reader.list_nodes().map_err(|e| format!("node list: {e}"))?;
    let mut totals = UsageTotals::default();
    for node in nodes {
        match reader.list_kv_of(&node) {
            Ok(rows) => {
                let t = sum_tenant_usage(&rows, tenant_hex, since_hour);
                totals.reach_deliveries += t.reach_deliveries;
                totals.telemetry_events += t.telemetry_events;
            }
            Err(e) => eprintln!("hop-accountd: usage partition {node} read failed: {e} (skipped)"),
        }
    }
    Ok(totals)
}

/// GET /console/usage?tenant=.. The tenant's current-window Reach + Telemetry usage against the
/// included allowances (Owner/Admin via ViewInvoices). Firestore-only: without the feature/route the
/// dashboard shows nothing for usage.
#[cfg(feature = "firestore")]
pub fn handle_usage(
    store: &dyn crate::store::Store,
    project: &str,
    cookie: Option<&str>,
    tenant: &str,
    now_ms: u64,
) -> crate::auth_api::AuthResponse {
    use crate::auth_api::AuthResponse;
    let (_user, org) = match crate::auth_api::authorize_tenant(
        store,
        cookie,
        tenant,
        crate::domain::Permission::ViewInvoices,
        now_ms,
    ) {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    let since_hour = window_start_hour(now_ms);
    match read_tenant_usage(project, &org.tenant_hex, since_hour) {
        Ok(t) => AuthResponse::json(
            200,
            &serde_json::json!({
                "reach": { "deliveries": t.reach_deliveries, "included": REACH_INCLUDED },
                "telemetry": { "events": t.telemetry_events, "included": TELEMETRY_INCLUDED },
                "windowDays": USAGE_WINDOW_HOURS / 24,
            })
            .to_string(),
        ),
        Err(_) => AuthResponse::json(502, r#"{"error":"usage_unavailable"}"#),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn le16(bundles: u64, payload: u64) -> Vec<u8> {
        let mut v = bundles.to_le_bytes().to_vec();
        v.extend_from_slice(&payload.to_le_bytes());
        v
    }

    #[test]
    fn sums_reach_and_telemetry_for_the_tenant_in_window() {
        let t = "a3f1c0d2e4b6a8091122334455667788";
        let other = "00000000000000000000000000000000";
        let rows = vec![
            (format!("usage/1000/{t}"), le16(30, 4096)),
            (format!("usage/1001/{t}"), le16(12, 100)),
            (
                format!("telemetry_usage/1001/{t}"),
                5_000u64.to_le_bytes().to_vec(),
            ),
            // a different tenant -> ignored
            (format!("usage/1001/{other}"), le16(999, 0)),
            // below the window -> ignored
            (format!("usage/500/{t}"), le16(1_000, 0)),
            // unrelated node state in the shared kv namespace -> ignored
            ("session/abc".into(), vec![1, 2, 3]),
            ("prekey/9".into(), vec![]),
            // malformed value length -> ignored
            (format!("usage/1002/{t}"), vec![0, 1, 2]),
        ];
        let got = sum_tenant_usage(&rows, t, 1000);
        assert_eq!(got.reach_deliveries, 42); // 30 + 12 (the below-window 1000 excluded)
        assert_eq!(got.telemetry_events, 5_000);
    }

    #[test]
    fn window_start_is_thirty_days_back() {
        let now_hour = 1_000_000u64;
        let now_ms = now_hour * 3_600_000;
        assert_eq!(window_start_hour(now_ms), now_hour - 720);
        // never underflows near epoch
        assert_eq!(window_start_hour(0), 0);
    }
}
