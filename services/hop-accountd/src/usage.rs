//! Near-realtime per-tenant usage for the console, read straight off the fleet's Firestore usage
//! ledgers (~30s fresh) rather than BigQuery (hourly, lagging) or Stripe (reconciled hours only). The
//! relays write `usage/{hour}/{tenant_hex}/{writer}` (16 bytes LE: bundles, payload_bytes) into their
//! own kv partition and collectors write `telemetry_usage/{hour}/{tenant_hex}/{writer}` (8 or 16 bytes
//! LE: events, payload_bytes); the two customer meters are Reach = bundles delivered and Telemetry =
//! events. Reading a tenant's total is a concatenation across every node partition (the same shape
//! hop-billingd's reconciler collects), via the shared `hop_store_firestore::KvReader`.
//!
//! The trailing `{writer}` segment is the producing process's per-process writer id (SVC-005): two
//! processes that share one node partition (a Cloud Run revision rollout runs the retiring and the
//! incoming instance of a region at once) write DISJOINT rows instead of clobbering one another's
//! read-modify-write, so a (hour, tenant) total is the SUM of every writer's row. This reader must
//! therefore aggregate the writer-scoped rows, exactly as `hop_billingd::ledger::parse_row` does.
//! Three-segment rows written before that change still count, so the console total does not dip
//! across the rollout.
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

/// A producer's per-process ledger writer id: exactly 16 lowercase-hex chars (SVC-005). Kept as
/// strict as `hop_billingd::ledger::is_writer_id` so a nested key that merely happens to have four
/// segments can never be summed as a ledger row.
fn is_writer_id(s: &str) -> bool {
    s.len() == 16
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Sum one node partition's kv rows into `tenant_hex`'s totals for hours `>= since_hour`. Pure: rows
/// that are not this tenant's `usage/`/`telemetry_usage/` ledger entries (or are malformed / wrong
/// length / outside the window) are skipped, so other node state in the shared kv namespace is ignored.
///
/// The trailing writer segment is OPTIONAL and, when present, must be a well-formed writer id; every
/// row that survives is ADDED, so the writer-scoped rows of two processes sharing one partition
/// compose into the hour's true total instead of one of them being dropped (SVC-005). Skipping them
/// would silently zero live usage in the console, which is why the test below pins both shapes.
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
        if tenant_s != tenant_hex {
            continue; // a different tenant
        }
        if let Some(writer_s) = parts.next() {
            if !is_writer_id(writer_s) {
                continue; // a four-segment key that is not writer-scoped is not a ledger row
            }
        }
        if parts.next().is_some() {
            continue; // more than four segments: not a ledger key
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
            // The collector's CURRENT row is 16 bytes (events, payload_bytes); 8 bytes is the
            // ORIGINAL events-only shape and still counts, so rows written by a pre-upgrade
            // collector keep showing up. Accepting only 8 read every live row as zero, which is the
            // same billing-invisibility failure as skipping the writer segment.
            "telemetry_usage" if value.len() == 8 || value.len() == 16 => {
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

    /// SVC-005 consumer regression. Relays and collectors write WRITER-SCOPED rows
    /// (`usage/{hour}/{tenant}/{writer}`) so two processes sharing one node partition compose rather
    /// than clobber. A parser that accepts only three segments skips every one of those rows, and the
    /// console meter reads zero while the tenant is being billed for real traffic. Against that
    /// parser this test asserts 30 reach deliveries and finds 0.
    #[test]
    fn writer_scoped_rows_are_summed_not_skipped() {
        let t = "a3f1c0d2e4b6a8091122334455667788";
        let w1 = "0000000000000001";
        let w2 = "00000000000000ff";
        let rows = vec![
            // two processes over one partition, same (hour, tenant), disjoint rows
            (format!("usage/1000/{t}/{w1}"), le16(18, 1_800)),
            (format!("usage/1000/{t}/{w2}"), le16(12, 1_200)),
            (
                format!("telemetry_usage/1000/{t}/{w1}"),
                4_000u64.to_le_bytes().to_vec(),
            ),
            (
                format!("telemetry_usage/1000/{t}/{w2}"),
                1_000u64.to_le_bytes().to_vec(),
            ),
        ];
        let got = sum_tenant_usage(&rows, t, 1000);
        assert_eq!(
            got.reach_deliveries, 30,
            "both writers' rows must be summed"
        );
        assert_eq!(got.telemetry_events, 5_000);
    }

    /// The collector writes a 16-byte `(events, payload_bytes)` row today; an 8-byte events-only row
    /// is the older shape. Accepting only the 8-byte shape read every live collector row as zero, so
    /// the console's Telemetry meter showed 0 while the tenant was billed. Against the 8-byte-only
    /// arm this asserts 900 and finds 400.
    #[test]
    fn both_telemetry_row_widths_count() {
        let t = "a3f1c0d2e4b6a8091122334455667788";
        let w = "0000000000000001";
        let mut wide = 500u64.to_le_bytes().to_vec();
        wide.extend_from_slice(&9_999u64.to_le_bytes()); // payload_bytes, not a billed meter
        let rows = vec![
            (format!("telemetry_usage/1000/{t}/{w}"), wide),
            (
                format!("telemetry_usage/1001/{t}"),
                400u64.to_le_bytes().to_vec(),
            ),
            // any other width is malformed and reads as nothing
            (format!("telemetry_usage/1002/{t}/{w}"), vec![1, 2, 3]),
        ];
        assert_eq!(sum_tenant_usage(&rows, t, 1000).telemetry_events, 900);
    }

    /// The optional fourth segment is a writer id and nothing else: a nested key that happens to be
    /// four segments must not be mistaken for a ledger row, and a fifth segment ends it.
    #[test]
    fn only_a_well_formed_writer_segment_is_accepted() {
        let t = "a3f1c0d2e4b6a8091122334455667788";
        let rows = vec![
            // not 16 hex chars -> not a ledger row
            (format!("usage/1000/{t}/nope"), le16(5, 5)),
            (format!("usage/1000/{t}/00000000000000FF"), le16(5, 5)), // uppercase
            (format!("usage/1000/{t}/000000000000000"), le16(5, 5)),  // 15 chars
            // five segments -> not a ledger row
            (format!("usage/1000/{t}/0000000000000001/extra"), le16(5, 5)),
        ];
        assert_eq!(sum_tenant_usage(&rows, t, 1000), UsageTotals::default());
    }

    /// Three-segment rows written before the writer-scoping change must keep counting, so the
    /// console total does not dip while a fleet rollout is in flight.
    #[test]
    fn pre_writer_scope_rows_still_count_alongside_scoped_ones() {
        let t = "a3f1c0d2e4b6a8091122334455667788";
        let rows = vec![
            (format!("usage/1000/{t}"), le16(7, 700)),
            (format!("usage/1000/{t}/0000000000000001"), le16(3, 300)),
        ];
        assert_eq!(sum_tenant_usage(&rows, t, 1000).reach_deliveries, 10);
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
