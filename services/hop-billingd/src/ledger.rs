//! The ledger source (DESIGN.md §37): collect the durable usage rows every node partition wrote,
//! parse them into reconciler inputs, and never let one bad row wedge billing.
//!
//! The producers' write contracts (mirrored EXACTLY here):
//! - relays:     `usage/{hour}/{tenant_hex32}` -> 16 bytes LE (`bundles` u64, `payload_bytes` u64)
//! - collectors: `telemetry_usage/{hour}/{tenant_hex32}` -> 16 bytes LE (`events` u64,
//!   `payload_bytes` u64). Rows written before the byte measure existed are 8 bytes (`events` only)
//!   and MUST still parse, as `(events, 0)`.
//! - relays:     `carriage_usage/{hour}/{tenant_hex32}` -> 16 bytes LE (`bundles` u64,
//!   `payload_bytes` u64). MEASUREMENT ONLY: carriage the relay performed that produced no delivery
//!   event and is therefore currently UNBILLED (§40 telemetry is the systematic case). Parsed so it
//!   is visible; it drives no reconciler and no Stripe meter, and it is deliberately a SEPARATE
//!   prefix so it can never be summed into the live `usage/` reach ledger.
//!
//! Relays ALSO write `storage_usage/{hour}/{tenant_hex32}` -> 8 bytes LE (`byte_ms` u64), the
//! mailbox-occupancy axis. It is deliberately NOT parsed here: the measurement is landing ahead of
//! a pricing decision, so the rows accumulate durably while nothing collects or bills them. The
//! unknown prefix falls through to `None` like any other kv key. Wiring it up is a one-arm change
//! here plus a `reconcile_storage_rows` call in the driver, and it must not happen until storage
//! is priced.
//!
//! The kv namespace is SHARED (sessions, prekeys, and other node state live beside the ledger
//! rows), so parsing is strict: exactly three `/`-separated segments, a decimal hour, a 32-char
//! lowercase-hex tenant. Anything malformed is SKIPPED, never an error: corrupt values decode as
//! zero in the producers themselves, and a hard failure here would wedge the watermark forever on
//! one bad doc. Both reconcilers sum duplicate (hour, tenant) rows across sources, so collection
//! is pure concatenation across nodes.

use crate::{LedgerRow, TelemetryRow, TenantId};

/// One parsed ledger row: which dimension it belongs to, and the reconciler-shaped payload.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ParsedRow {
    Usage(u64, TenantId, LedgerRow),
    Telemetry(u64, TenantId, TelemetryRow),
    /// Unbilled carriage measurement. Collected and surfaced, never reconciled or billed.
    Carriage(u64, TenantId, LedgerRow),
}

/// Where ledger rows come from. The live implementation wraps `hop_store_firestore::KvReader`
/// (behind `--features live`); tests fake it, so collection logic is fully unit-tested without a
/// network.
pub trait LedgerSource {
    /// Every node partition id that may hold ledger rows.
    fn list_nodes(&self) -> Result<Vec<String>, String>;
    /// All kv pairs of one node partition, `(original key, raw value bytes)`.
    fn list_kv_of(&self, node: &str) -> Result<Vec<(String, Vec<u8>)>, String>;
}

/// Parse one kv pair into a ledger row, or `None` for everything that is not a well-formed ledger
/// row (other kv keys, malformed hour/tenant, wrong-length values reading as zero and skipped).
pub fn parse_row(key: &str, value: &[u8]) -> Option<ParsedRow> {
    let mut parts = key.split('/');
    let (prefix, hour_s, tenant_s) = (parts.next()?, parts.next()?, parts.next()?);
    if parts.next().is_some() {
        return None; // more than three segments: not a ledger key
    }
    let hour: u64 = hour_s.parse().ok()?;
    let tenant = parse_tenant_hex(tenant_s)?;
    match prefix {
        "usage" => {
            let row = decode_usage(value);
            (row.bundles > 0 || row.payload_bytes > 0)
                .then_some(ParsedRow::Usage(hour, tenant, row))
        }
        "telemetry_usage" => {
            let row = decode_telemetry(value);
            (row.events > 0 || row.payload_bytes > 0)
                .then_some(ParsedRow::Telemetry(hour, tenant, row))
        }
        "carriage_usage" => {
            let row = decode_usage(value);
            (row.bundles > 0 || row.payload_bytes > 0)
                .then_some(ParsedRow::Carriage(hour, tenant, row))
        }
        _ => None,
    }
}

/// The relay's value layout: exactly 16 bytes, `bundles` u64 LE then `payload_bytes` u64 LE. Any
/// other length reads as zero (the producer's own corruption convention).
fn decode_usage(bytes: &[u8]) -> LedgerRow {
    if bytes.len() != 16 {
        return LedgerRow::default();
    }
    LedgerRow {
        bundles: u64::from_le_bytes(bytes[..8].try_into().unwrap_or_default()),
        payload_bytes: u64::from_le_bytes(bytes[8..].try_into().unwrap_or_default()),
        storage_byte_ms: 0, // not in the wire value; the storage floor has no producer yet
    }
}

/// The collector's value layout: 16 bytes, `events` u64 LE then `payload_bytes` u64 LE.
///
/// 8 bytes is the ORIGINAL events-only layout and still parses as `(events, 0)`: rows written by a
/// pre-upgrade collector must keep billing their events, not silently vanish. Any other length reads
/// as zero (the producer's own corruption convention).
fn decode_telemetry(bytes: &[u8]) -> TelemetryRow {
    match bytes.len() {
        16 => TelemetryRow {
            events: u64::from_le_bytes(bytes[..8].try_into().unwrap_or_default()),
            payload_bytes: u64::from_le_bytes(bytes[8..].try_into().unwrap_or_default()),
        },
        8 => TelemetryRow {
            events: u64::from_le_bytes(bytes.try_into().unwrap_or_default()),
            payload_bytes: 0,
        },
        _ => TelemetryRow::default(),
    }
}

/// Parse a 32-char lowercase-hex string into a [`TenantId`].
fn parse_tenant_hex(s: &str) -> Option<TenantId> {
    if s.len() != 32
        || !s
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return None;
    }
    let mut out = [0u8; 16];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(out)
}

/// Everything the reconcilers need this run, collected across every node partition.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CollectedRows {
    pub usage: Vec<(u64, TenantId, LedgerRow)>,
    pub telemetry: Vec<(u64, TenantId, TelemetryRow)>,
    /// Unbilled carriage measurement (see the module docs). Surfaced for visibility; no reconciler
    /// consumes it and no Stripe event is emitted for it.
    pub carriage: Vec<(u64, TenantId, LedgerRow)>,
    /// Partitions that could not be listed this run. Their rows are simply absent; because the
    /// watermark only advances past hours whose emits SUCCEEDED, and absent rows produce no emits,
    /// a skipped partition's usage is picked up on a later run. Surfaced so the operator sees it.
    pub failed_nodes: Vec<String>,
}

/// Collect and parse the ledger rows from every node partition. Node-level failures are recorded
/// and skipped, never fatal: billing a partial fleet this run and the rest next run is safe under
/// the watermark + idempotency contract; failing the whole run on one flaky partition is not.
///
/// CAVEAT (why callers should treat a large `failed_nodes` as "do not advance"): the watermark
/// protection above holds only when a missed partition's rows stay ABSENT while the hour is
/// reconciled. Rows merge cumulatively into the SAME (hour, tenant) doc, so a partition that fails
/// this run but succeeds next run still contributes its full row, UNLESS the hour was already
/// reconciled past in between with partial data. The live driver therefore refuses to advance
/// watermarks when any partition failed (see `main.rs`), trading latency for never under-billing.
pub fn collect_rows<S: LedgerSource>(source: &S) -> Result<CollectedRows, String> {
    let nodes = source.list_nodes()?;
    let mut out = CollectedRows::default();
    for node in nodes {
        let pairs = match source.list_kv_of(&node) {
            Ok(p) => p,
            Err(_) => {
                out.failed_nodes.push(node);
                continue;
            }
        };
        for (key, value) in pairs {
            match parse_row(&key, &value) {
                Some(ParsedRow::Usage(h, t, r)) => out.usage.push((h, t, r)),
                Some(ParsedRow::Telemetry(h, t, r)) => out.telemetry.push((h, t, r)),
                Some(ParsedRow::Carriage(h, t, r)) => out.carriage.push((h, t, r)),
                None => {}
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    const T: &str = "000102030405060708090a0b0c0d0e0f";
    const TENANT: TenantId = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];

    fn usage_val(bundles: u64, bytes: u64) -> Vec<u8> {
        let mut v = bundles.to_le_bytes().to_vec();
        v.extend_from_slice(&bytes.to_le_bytes());
        v
    }

    #[test]
    fn parses_both_row_kinds() {
        assert_eq!(
            parse_row(&format!("usage/402/{T}"), &usage_val(3, 300)),
            Some(ParsedRow::Usage(
                402,
                TENANT,
                LedgerRow {
                    bundles: 3,
                    payload_bytes: 300,
                    storage_byte_ms: 0
                }
            ))
        );
        assert_eq!(
            parse_row(&format!("telemetry_usage/402/{T}"), &7u64.to_le_bytes()),
            Some(ParsedRow::Telemetry(
                402,
                TENANT,
                TelemetryRow {
                    events: 7,
                    payload_bytes: 0
                }
            ))
        );
    }

    #[test]
    fn telemetry_rows_parse_at_both_widths() {
        // Current 16-byte shape: events + measured payload bytes.
        let mut v = 7u64.to_le_bytes().to_vec();
        v.extend_from_slice(&900u64.to_le_bytes());
        assert_eq!(
            parse_row(&format!("telemetry_usage/402/{T}"), &v),
            Some(ParsedRow::Telemetry(
                402,
                TENANT,
                TelemetryRow {
                    events: 7,
                    payload_bytes: 900
                }
            ))
        );
        // Legacy 8-byte (events-only) rows written before the byte measure existed must STILL
        // parse, as (events, 0), or upgrading the collector would drop a billable hour on the floor.
        assert_eq!(
            parse_row(&format!("telemetry_usage/402/{T}"), &7u64.to_le_bytes()),
            Some(ParsedRow::Telemetry(
                402,
                TENANT,
                TelemetryRow {
                    events: 7,
                    payload_bytes: 0
                }
            ))
        );
        // A bytes-only row (no events) is still a real row and must not be dropped.
        let mut bytes_only = 0u64.to_le_bytes().to_vec();
        bytes_only.extend_from_slice(&50u64.to_le_bytes());
        assert!(matches!(
            parse_row(&format!("telemetry_usage/402/{T}"), &bytes_only),
            Some(ParsedRow::Telemetry(..))
        ));
    }

    #[test]
    fn carriage_rows_parse_on_their_own_prefix_and_never_as_reach_usage() {
        // Unbilled carriage measurement: parsed and surfaced, but on a prefix of its own so it can
        // never be summed into the live `usage/` reach ledger that actually bills.
        assert_eq!(
            parse_row(&format!("carriage_usage/402/{T}"), &usage_val(2, 200)),
            Some(ParsedRow::Carriage(
                402,
                TENANT,
                LedgerRow {
                    bundles: 2,
                    payload_bytes: 200,
                    storage_byte_ms: 0
                }
            ))
        );
        let source = FakeSource {
            nodes: vec![(
                "relay-a",
                Ok(vec![
                    (format!("usage/402/{T}"), usage_val(3, 300)),
                    (format!("carriage_usage/402/{T}"), usage_val(9, 900)),
                ]),
            )],
        };
        let rows = collect_rows(&source).unwrap();
        assert_eq!(rows.usage.len(), 1, "reach ledger is untouched");
        assert_eq!(rows.usage[0].2.bundles, 3, "carriage did not leak into it");
        assert_eq!(rows.carriage.len(), 1);
        assert_eq!(rows.carriage[0].2.bundles, 9);
    }

    #[test]
    fn skips_everything_that_is_not_a_ledger_row() {
        // The kv namespace is shared: sessions, prekeys, and other node state live beside the
        // ledger rows. None of these may fail the run; all must simply be skipped.
        for (key, value) in [
            ("session/abcd", b"x".to_vec()), // other kv state
            ("usage", usage_val(1, 1)),      // too few segments
            (&format!("usage/402/{T}/extra")[..], usage_val(1, 1)), // too many segments
            ("usage/notahour/deadbeef", usage_val(1, 1)), // non-numeric hour
            ("usage/402/short", usage_val(1, 1)), // bad tenant hex
            (
                &format!("usage/402/{}", T.to_uppercase())[..],
                usage_val(1, 1),
            ), // uppercase hex
            (&format!("other_usage/402/{T}")[..], usage_val(1, 1)), // unknown prefix
        ] {
            assert_eq!(parse_row(key, &value), None, "must skip {key}");
        }
    }

    #[test]
    fn wrong_length_values_read_as_zero_and_are_skipped() {
        // The producers' own convention: corrupt = zero. A zero row emits nothing anyway, so the
        // parser drops it rather than shipping a no-op row to the reconciler.
        assert_eq!(parse_row(&format!("usage/402/{T}"), b"tooshort"), None);
        assert_eq!(parse_row(&format!("telemetry_usage/402/{T}"), b"xx"), None);
        assert_eq!(parse_row(&format!("usage/402/{T}"), &usage_val(0, 0)), None);
    }

    #[test]
    fn storage_rows_are_written_but_never_collected_so_nothing_bills_storage() {
        // The storage axis is measurement-only pending a pricing decision. Relays write these rows,
        // but the collector must not turn them into a reconciler input: doing so would start
        // billing hop_mailbox_gb_month with no priced meter behind it. If this test starts failing
        // because storage was intentionally wired up, that is a pricing decision, not a bug fix.
        assert_eq!(
            parse_row(&format!("storage_usage/402/{T}"), &123u64.to_le_bytes()),
            None,
            "storage_usage must not parse into a billable row"
        );
        // And it must never be mistaken for the carriage row it sits beside.
        assert_eq!(
            parse_row(&format!("storage_usage/402/{T}"), &usage_val(3, 300)),
            None
        );
    }

    #[test]
    fn telemetry_prefix_never_bleeds_into_usage() {
        // "telemetry_usage/..." must parse as telemetry, and a starts_with("usage/") shortcut
        // would misfile it; the strict segment match prevents that.
        let row = parse_row(&format!("telemetry_usage/5/{T}"), &1u64.to_le_bytes());
        assert!(matches!(row, Some(ParsedRow::Telemetry(..))));
    }

    type KvResult = Result<Vec<(String, Vec<u8>)>, String>;
    struct FakeSource {
        nodes: Vec<(&'static str, KvResult)>,
    }
    impl LedgerSource for FakeSource {
        fn list_nodes(&self) -> Result<Vec<String>, String> {
            Ok(self.nodes.iter().map(|(n, _)| n.to_string()).collect())
        }
        fn list_kv_of(&self, node: &str) -> Result<Vec<(String, Vec<u8>)>, String> {
            self.nodes
                .iter()
                .find(|(n, _)| *n == node)
                .map(|(_, r)| r.clone())
                .unwrap_or_else(|| Err("unknown node".into()))
        }
    }

    #[test]
    fn collects_across_nodes_and_records_failures() {
        let source = FakeSource {
            nodes: vec![
                (
                    "relay-a",
                    Ok(vec![
                        (format!("usage/402/{T}"), usage_val(3, 300)),
                        ("session/junk".into(), b"z".to_vec()),
                    ]),
                ),
                ("relay-b", Err("500".into())),
                (
                    "collector-c",
                    Ok(vec![(
                        format!("telemetry_usage/402/{T}"),
                        9u64.to_le_bytes().to_vec(),
                    )]),
                ),
            ],
        };
        let rows = collect_rows(&source).unwrap();
        assert_eq!(rows.usage.len(), 1);
        assert_eq!(rows.telemetry.len(), 1);
        assert_eq!(rows.failed_nodes, vec!["relay-b"]);
    }

    #[test]
    fn duplicate_hour_tenant_rows_from_two_nodes_both_survive() {
        // reconcile() sums duplicates; collection must NOT pre-aggregate or drop them.
        let source = FakeSource {
            nodes: vec![
                ("a", Ok(vec![(format!("usage/402/{T}"), usage_val(3, 300))])),
                ("b", Ok(vec![(format!("usage/402/{T}"), usage_val(4, 400))])),
            ],
        };
        let rows = collect_rows(&source).unwrap();
        assert_eq!(rows.usage.len(), 2);
    }
}
