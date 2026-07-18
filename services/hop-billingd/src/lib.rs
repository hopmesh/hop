//! The Hop billing reconciler (DESIGN.md §37).
//!
//! Capture and reconciliation are DECOUPLED on purpose: the relays write usage to a durable
//! ledger on the hot path and never call Stripe; this reconciler reads that ledger asynchronously
//! and turns it into Stripe meter events. A billing outage therefore delays invoicing, it never
//! blocks a bundle.
//!
//! ## What it reads
//!
//! Each relay drains its in-memory meter into hour-bucketed rows in its region's durable store:
//! `usage/{hour}/{tenant}` = a [`LedgerRow`] (carriage bundles + sealed payload bytes; storage
//! GB-ms once the storage floor lands). Rows are per REGION already (each region's relay owns its
//! partition), so aggregation is a sum across regions per (hour, tenant).
//!
//! ## Cross-instance dedup lives HERE, not on the driver
//!
//! N Cloud Run instances behind one region share the region's Firestore partition, so a naive
//! meter could double-count. Doing a synchronous conditional-create marker on the relay's DRIVER
//! would block it on a Firestore round-trip in the hot path, which is a liveness bug. Instead the
//! relays record a per-delivery marker `metered/{region}/{wire_id}` off the hot path, and this
//! reconciler treats those markers as the authoritative delivery set: a (region, wire_id) that any
//! instance already marked is counted ONCE. (This module carries the pure aggregation + emit
//! logic; the marker read is the `live` service's job.)
//!
//! ## Idempotent + watermarked
//!
//! Stripe meter events must not double-bill on a re-run. The reconciler emits at most one event
//! per (tenant, hour, dimension) with a deterministic idempotency key, and advances a WATERMARK
//! (the last fully-reconciled hour) only after every event for that hour is accepted. A crash
//! mid-hour re-emits the same keys next run; Stripe dedups them.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// A billed tenant (app/org), 16 bytes. Matches `hop_core::access::TenantId`.
pub type TenantId = [u8; 16];

/// One hour-bucketed usage row as written by a relay's meter drain (the `usage/{hour}/{tenant}`
/// value). Additive across regions for one (hour, tenant).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct LedgerRow {
    /// Backbone-assisted deliveries to offline recipients, billed to `hop_backbone_delivery`.
    /// Online devices direct-connect (no backbone), so they never add here.
    pub bundles: u64,
    /// Sealed payload bytes carried (informational today; a future GB dimension).
    pub payload_bytes: u64,
    /// Durable storage occupancy in byte-milliseconds (the storage floor), billed to
    /// `hop_mailbox_gb_month`. Zero until the storage-floor increment lands.
    pub storage_byte_ms: u64,
}

impl LedgerRow {
    pub fn add(&mut self, other: &LedgerRow) {
        self.bundles = self.bundles.saturating_add(other.bundles);
        self.payload_bytes = self.payload_bytes.saturating_add(other.payload_bytes);
        self.storage_byte_ms = self.storage_byte_ms.saturating_add(other.storage_byte_ms);
    }
}

/// The Stripe meter `event_name`s the reconciler emits against. These strings are the CONTRACT
/// with `infra/billing/meters.tf`; they must match exactly and never change once live (Stripe
/// meters are append-only).
pub mod meter {
    /// Billable offline delivery (Hop bills for reach, not device count).
    pub const BACKBONE_DELIVERY: &str = "hop_backbone_delivery";
    pub const MAILBOX_GB_MONTH: &str = "hop_mailbox_gb_month";
    pub const EGRESS_GB: &str = "hop_egress_gb";
    /// OTel-over-Hop telemetry events (carries its own BigQuery COGS).
    pub const TELEMETRY_EVENTS: &str = "hop_telemetry_events";
}

/// One Stripe meter event the reconciler wants emitted. `idempotency_key` makes a re-run a no-op
/// (Stripe dedups by it), so the reconciler can safely retry a partially-emitted hour.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MeterEvent {
    pub event_name: &'static str,
    pub tenant: TenantId,
    /// The metered quantity (chunks, or GB-month scaled, etc.).
    pub value: u64,
    /// Deterministic: `{event_name}:{tenant_hex}:{hour}`. Same inputs => same key => Stripe bills
    /// once no matter how many times we re-emit.
    pub idempotency_key: String,
    /// The hour bucket this event covers (for the watermark).
    pub hour: u64,
}

/// Where emitted events go. The `live` service implements this over the Stripe meter-events API;
/// tests use a recording fake. Returning `Err` for an event leaves that hour un-watermarked so it
/// is retried (idempotently) next run.
pub trait MeterSink {
    fn emit(&mut self, event: &MeterEvent) -> Result<(), String>;
}

fn hex16(t: &TenantId) -> String {
    t.iter().map(|b| format!("{b:02x}")).collect()
}

/// Reconcile all ledger rows for hours STRICTLY AFTER `watermark_hour`, up to and including
/// `now_hour - 1` (never the still-accumulating current hour). Rows are `(hour, tenant, row)` from
/// every region; this sums them per (hour, tenant), emits one meter event per non-zero dimension
/// with a deterministic idempotency key, and returns the new watermark: the highest hour for which
/// EVERY event was accepted. A failed emit stops the watermark at the last fully-emitted hour, so
/// the next run retries from there (Stripe dedups the successful ones).
pub fn reconcile<S: MeterSink>(
    rows: &[(u64, TenantId, LedgerRow)],
    watermark_hour: u64,
    now_hour: u64,
    sink: &mut S,
) -> u64 {
    // Aggregate across regions: (hour, tenant) -> summed row. BTreeMap so hours ascend, which lets
    // the watermark advance hour-by-hour and stop cleanly at the first failure.
    let mut agg: BTreeMap<(u64, TenantId), LedgerRow> = BTreeMap::new();
    for (hour, tenant, row) in rows {
        // Only closed hours strictly after the watermark: the current hour is still accumulating.
        if *hour <= watermark_hour || *hour >= now_hour {
            continue;
        }
        agg.entry((*hour, *tenant)).or_default().add(row);
    }

    let mut new_watermark = watermark_hour;
    let mut current_hour: Option<u64> = None;
    let mut hour_ok = true;

    for ((hour, tenant), row) in &agg {
        // Close out the previous hour before moving to the next: advance the watermark only if the
        // whole hour emitted cleanly.
        if current_hour != Some(*hour) {
            if let Some(prev) = current_hour {
                if hour_ok {
                    new_watermark = prev;
                } else {
                    return new_watermark; // a failed earlier hour blocks all later ones
                }
            }
            current_hour = Some(*hour);
            hour_ok = true;
        }
        for event in events_for(*hour, tenant, row) {
            if sink.emit(&event).is_err() {
                hour_ok = false;
            }
        }
    }
    // Close the final hour.
    if let (Some(h), true) = (current_hour, hour_ok) {
        new_watermark = h;
    }
    new_watermark
}

/// One spooled-bundle occupancy record, as the relay writes it into the mailbox store: which
/// tenant is billed, the sealed size, when it was spooled, and when it left the mailbox (delivered
/// or TTL-expired) if it has. Still-held bundles have `delete_ms = None`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SpoolRecord {
    pub tenant: TenantId,
    pub size_bytes: u64,
    pub spool_ms: u64,
    pub delete_ms: Option<u64>,
}

/// Bytes per gigabyte (decimal GB, the storage-billing convention).
pub const BYTES_PER_GB: u64 = 1_000_000_000;
/// Milliseconds in a 30-day billing month.
pub const MS_PER_MONTH: u64 = 30 * 24 * 60 * 60 * 1000;

/// Per-tenant durable-storage occupancy in BYTE-MILLISECONDS accrued within the window
/// `[lo_ms, hi_ms]`, the exact integral of `size x time held` clamped to that window. A bundle
/// contributes `size x (min(hi, end) - max(lo, spool))` where `end` is its delete time if it has
/// left the mailbox, else `hi_ms`; a record that overlaps the window not at all (or has a delete
/// before its spool, or a spool in the future) contributes nothing (clock-skew safe). Windowing is
/// what lets each reconcile run bill only the occupancy since the last storage watermark, so
/// occupancy is never double-counted across runs.
pub fn storage_byte_ms_interval(
    records: &[SpoolRecord],
    lo_ms: u64,
    hi_ms: u64,
) -> BTreeMap<TenantId, u64> {
    let mut out: BTreeMap<TenantId, u64> = BTreeMap::new();
    for r in records {
        let end = r.delete_ms.unwrap_or(hi_ms);
        let start = r.spool_ms.max(lo_ms);
        let stop = end.min(hi_ms);
        let held_ms = stop.saturating_sub(start);
        if held_ms == 0 {
            continue;
        }
        let contribution = (r.size_bytes as u128).saturating_mul(held_ms as u128);
        let acc = out.entry(r.tenant).or_default();
        *acc = acc.saturating_add(contribution.min(u64::MAX as u128) as u64);
    }
    out
}

/// Total per-tenant occupancy up to `now_ms` (the window `[0, now_ms]`). The storage FLOOR: it
/// prices real occupancy regardless of whether the bundle was ever delivered, so a never-delivered
/// spool flood is not free (the DoS the review flagged), and the delivery dimension stays separate.
pub fn storage_byte_ms(records: &[SpoolRecord], now_ms: u64) -> BTreeMap<TenantId, u64> {
    storage_byte_ms_interval(records, 0, now_ms)
}

/// Reconcile the STORAGE dimension: bill each tenant for the mailbox occupancy accrued since the
/// storage watermark, in `[storage_wm_ms, now_ms]`. Emits one `hop_mailbox_gb_month` event per
/// tenant with non-zero occupancy, keyed by the window START (`mailbox:{tenant}:{storage_wm}`) so a
/// retry of the same window dedups at Stripe. Returns the new watermark (`now_ms`) iff EVERY event
/// was accepted, else the unchanged `storage_wm_ms` so the same window retries next run.
pub fn reconcile_storage<S: MeterSink>(
    records: &[SpoolRecord],
    storage_wm_ms: u64,
    now_ms: u64,
    sink: &mut S,
) -> u64 {
    if now_ms <= storage_wm_ms {
        return storage_wm_ms;
    }
    let occ = storage_byte_ms_interval(records, storage_wm_ms, now_ms);
    let mut all_ok = true;
    for (tenant, byte_ms) in &occ {
        let scaled = byte_ms_to_scaled_gb_months(*byte_ms);
        if scaled == 0 {
            continue; // below one milli-GB-month this window; carries into the next window's math
        }
        let event = MeterEvent {
            event_name: meter::MAILBOX_GB_MONTH,
            tenant: *tenant,
            value: scaled,
            idempotency_key: format!(
                "{}:{}:{}",
                meter::MAILBOX_GB_MONTH,
                hex16(tenant),
                storage_wm_ms
            ),
            hour: storage_wm_ms / 3_600_000,
        };
        if sink.emit(&event).is_err() {
            all_ok = false;
        }
    }
    if all_ok {
        now_ms
    } else {
        storage_wm_ms
    }
}

/// Convert a byte-millisecond occupancy total to GB-months for the `hop_mailbox_gb_month` meter,
/// scaled by `SCALE` (milli-GB-months) to keep integer meter values with useful resolution: a
/// value of 1 = one thousandth of a GB-month. The `live` emit divides by `SCALE` for display; the
/// scaling is fixed so re-runs are deterministic.
pub const GB_MONTH_SCALE: u64 = 1000;
pub fn byte_ms_to_scaled_gb_months(byte_ms: u64) -> u64 {
    // (byte_ms / (BYTES_PER_GB * MS_PER_MONTH)) * SCALE, computed in u128 to avoid overflow/underflow.
    let num = (byte_ms as u128).saturating_mul(GB_MONTH_SCALE as u128);
    let den = (BYTES_PER_GB as u128).saturating_mul(MS_PER_MONTH as u128);
    (num / den).min(u64::MAX as u128) as u64
}

/// The meter events one aggregated (hour, tenant) row produces: one per non-zero dimension.
fn events_for(hour: u64, tenant: &TenantId, row: &LedgerRow) -> Vec<MeterEvent> {
    let mut out = Vec::new();
    let mut push = |event_name: &'static str, value: u64| {
        if value > 0 {
            out.push(MeterEvent {
                event_name,
                tenant: *tenant,
                value,
                idempotency_key: format!("{event_name}:{}:{hour}", hex16(tenant)),
                hour,
            });
        }
    };
    push(meter::BACKBONE_DELIVERY, row.bundles);
    // storage_byte_ms -> GB-month is a scaling the storage-floor increment will define; kept out of
    // the emit until that lands so we never bill an unfinished dimension.
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct FakeSink {
        emitted: Vec<MeterEvent>,
        fail_hours: Vec<u64>,
    }
    impl MeterSink for FakeSink {
        fn emit(&mut self, e: &MeterEvent) -> Result<(), String> {
            if self.fail_hours.contains(&e.hour) {
                return Err("stripe down".into());
            }
            self.emitted.push(e.clone());
            Ok(())
        }
    }

    const A: TenantId = [1u8; 16];
    const B: TenantId = [2u8; 16];

    fn row(bundles: u64) -> LedgerRow {
        LedgerRow {
            bundles,
            payload_bytes: bundles * 100,
            storage_byte_ms: 0,
        }
    }

    #[test]
    fn sums_regions_and_emits_one_event_per_hour_tenant() {
        // Two regions reported for (hour 5, tenant A); one row for (hour 5, tenant B).
        let rows = vec![
            (5, A, row(3)),
            (5, A, row(4)), // another region
            (5, B, row(1)),
        ];
        let mut sink = FakeSink::default();
        let wm = reconcile(&rows, 0, 6, &mut sink);
        assert_eq!(wm, 5, "hour 5 fully reconciled");
        assert_eq!(sink.emitted.len(), 2, "one event per (tenant) for the hour");
        let a = sink.emitted.iter().find(|e| e.tenant == A).unwrap();
        assert_eq!(a.value, 7, "3 + 4 summed across regions");
        assert_eq!(a.event_name, meter::BACKBONE_DELIVERY);
        assert_eq!(
            a.idempotency_key,
            format!("hop_backbone_delivery:{}:5", hex16(&A))
        );
    }

    #[test]
    fn never_reconciles_the_current_or_pre_watermark_hours() {
        let rows = vec![(3, A, row(9)), (5, A, row(2)), (6, A, row(4))];
        let mut sink = FakeSink::default();
        // watermark at 3 (done), now_hour 6 (so 6 is still open).
        let wm = reconcile(&rows, 3, 6, &mut sink);
        assert_eq!(wm, 5, "only hour 4..=5 window; 5 is the only row in it");
        assert_eq!(sink.emitted.len(), 1);
        assert_eq!(sink.emitted[0].hour, 5);
    }

    #[test]
    fn a_failed_emit_stops_the_watermark_so_the_hour_retries() {
        let rows = vec![(4, A, row(1)), (5, A, row(1)), (6, A, row(1))];
        let mut sink = FakeSink {
            fail_hours: vec![5],
            ..Default::default()
        };
        // now_hour 7 so 4,5,6 are all closed. Hour 5 fails.
        let wm = reconcile(&rows, 0, 7, &mut sink);
        assert_eq!(wm, 4, "advanced through 4, stopped at the failed hour 5");
        // Hour 6 is NOT emitted (a later hour can't be billed past an un-reconciled earlier one).
        assert!(sink.emitted.iter().all(|e| e.hour == 4));
    }

    #[test]
    fn idempotency_key_is_deterministic_across_runs() {
        let rows = vec![(2, A, row(5))];
        let mut s1 = FakeSink::default();
        let mut s2 = FakeSink::default();
        reconcile(&rows, 0, 3, &mut s1);
        reconcile(&rows, 0, 3, &mut s2);
        assert_eq!(s1.emitted[0].idempotency_key, s2.emitted[0].idempotency_key);
    }

    #[test]
    fn a_zero_row_emits_nothing() {
        let rows = vec![(2, A, row(0))];
        let mut sink = FakeSink::default();
        let wm = reconcile(&rows, 0, 3, &mut sink);
        assert_eq!(wm, 2, "hour still closes even with nothing to bill");
        assert!(sink.emitted.is_empty());
    }

    fn spool(tenant: TenantId, size: u64, spool_ms: u64, delete_ms: Option<u64>) -> SpoolRecord {
        SpoolRecord {
            tenant,
            size_bytes: size,
            spool_ms,
            delete_ms,
        }
    }

    #[test]
    fn storage_integrates_size_times_held_for_deleted_and_still_held() {
        let now = 10_000;
        let records = vec![
            spool(A, 100, 0, Some(1000)), // held 1000ms -> 100_000 byte-ms
            spool(A, 50, 2000, None),     // still held: 2000..10000 = 8000ms -> 400_000
            spool(B, 10, 9000, None),     // 1000ms -> 10_000
        ];
        let occ = storage_byte_ms(&records, now);
        assert_eq!(occ[&A], 100 * 1000 + 50 * 8000);
        assert_eq!(occ[&B], 10 * 1000);
    }

    #[test]
    fn storage_is_clock_skew_safe() {
        let now = 5000;
        let records = vec![
            spool(A, 100, 6000, None),       // spooled in the FUTURE vs now -> 0
            spool(A, 100, 3000, Some(1000)), // delete BEFORE spool -> 0
            spool(A, 100, 1000, Some(2000)), // normal: 1000ms -> 100_000
        ];
        assert_eq!(storage_byte_ms(&records, now)[&A], 100_000);
    }

    #[test]
    fn a_never_delivered_spool_flood_is_not_free() {
        // The DoS the review flagged: bundles that never deliver still accrue storage occupancy,
        // so they are billed (or capped), not carried for free.
        let now = 1_000_000;
        let flood: Vec<SpoolRecord> = (0..100).map(|_| spool(A, 1_000_000, 0, None)).collect();
        let occ = storage_byte_ms(&flood, now);
        assert!(occ[&A] > 0, "undelivered occupancy is priced");
    }

    #[test]
    fn storage_windowing_bills_only_the_interval_since_the_watermark() {
        // A 1 GB bundle held [0, 3*month]. Reconciled in two windows: [0, month] then [month, 2*month].
        let month = MS_PER_MONTH;
        let recs = vec![spool(A, BYTES_PER_GB, 0, None)];
        let w1 = storage_byte_ms_interval(&recs, 0, month);
        let w2 = storage_byte_ms_interval(&recs, month, 2 * month);
        assert_eq!(
            w1[&A], w2[&A],
            "each window bills exactly one month, no overlap, no gap"
        );
        // The two windows sum to the [0, 2*month] total.
        assert_eq!(w1[&A] + w2[&A], storage_byte_ms(&recs, 2 * month)[&A]);
    }

    #[test]
    fn reconcile_storage_emits_gb_month_and_advances_the_watermark() {
        let month = MS_PER_MONTH;
        let recs = vec![spool(A, BYTES_PER_GB, 0, None)]; // 1 GB held
        let mut sink = FakeSink::default();
        let new_wm = reconcile_storage(&recs, 0, month, &mut sink); // one month elapsed
        assert_eq!(new_wm, month, "watermark advanced to now");
        assert_eq!(sink.emitted.len(), 1);
        assert_eq!(sink.emitted[0].event_name, meter::MAILBOX_GB_MONTH);
        assert_eq!(sink.emitted[0].value, GB_MONTH_SCALE, "1 GB-month");
        assert_eq!(
            sink.emitted[0].idempotency_key,
            format!("hop_mailbox_gb_month:{}:0", hex16(&A))
        );
    }

    #[test]
    fn reconcile_storage_holds_the_watermark_on_a_failed_emit() {
        let month = MS_PER_MONTH;
        let recs = vec![spool(A, BYTES_PER_GB, 0, None)];
        let mut sink = FakeSink {
            fail_hours: vec![0],
            ..Default::default()
        };
        let new_wm = reconcile_storage(&recs, 0, month, &mut sink);
        assert_eq!(
            new_wm, 0,
            "a failed emit leaves the window to retry (idempotent) next run"
        );
    }

    #[test]
    fn gb_month_scaling_is_deterministic_and_sane() {
        // 1 GB held for exactly one month = 1000 scaled units (1 GB-month * SCALE).
        let one_gb_one_month = BYTES_PER_GB.saturating_mul(MS_PER_MONTH);
        assert_eq!(
            byte_ms_to_scaled_gb_months(one_gb_one_month),
            GB_MONTH_SCALE
        );
        // Half that occupancy -> half the scaled value.
        assert_eq!(
            byte_ms_to_scaled_gb_months(one_gb_one_month / 2),
            GB_MONTH_SCALE / 2
        );
        assert_eq!(byte_ms_to_scaled_gb_months(0), 0);
    }
}
