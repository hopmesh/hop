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
//! `usage/{hour}/{tenant}` = a [`LedgerRow`] (carriage bundles + sealed payload bytes). Rows are
//! per REGION already (each region's relay owns its partition), so aggregation is a sum across
//! regions per (hour, tenant).
//!
//! Storage occupancy is a SEPARATE axis under its own `storage_usage/{hour}/{tenant}` prefix (a
//! [`StorageRow`]). Carriage counts bytes a relay moved and is drained on read; storage measures
//! bytes a relay is currently HOLDING and is sampled repeatedly without draining. They answer
//! different questions and are never folded into one number. The storage rows are written by the
//! relay today but are NOT yet collected or reconciled: [`reconcile_storage_rows`] exists and is
//! tested, but nothing drives it, pending a pricing decision. Nothing bills storage yet.
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

pub mod bq;
pub mod ledger;
pub mod stripe;

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
    /// Vestigial: storage occupancy does NOT ride the carriage row. It is sampled separately and
    /// written under the `storage_usage/` prefix as a [`StorageRow`], because occupancy is a
    /// standing quantity (sampled, never drained) while carriage is a drained counter. Kept at zero
    /// by the `usage/` decoder; do not populate it, or a tenant would be billed for the same
    /// occupancy twice (once here, once via [`reconcile_storage_rows`]).
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

/// Bill the primary sink (Stripe, authoritative) and record usage history on the secondary as a
/// BEST-EFFORT side effect. The primary's result ALONE is returned, so it alone drives the
/// reconcile watermark.
///
/// This asymmetry is deliberate and load-bearing. History is our own dashboards store (the console
/// reads our data, never Stripe); it must NEVER gate revenue. A symmetric "fail if either fails"
/// tee would freeze the single per-dimension watermark the moment the history table hiccuped (a 404
/// on a not-yet-warm streaming buffer, a quota blip, a transient 5xx), and because `reconcile`
/// advances the watermark only for fully-emitted hours, every later hour would stop reaching Stripe
/// too. So a dashboards outage would halt live invoicing. Here, a history failure is counted and
/// swallowed; only the Stripe result propagates.
///
/// History records only events that actually BILLED (`billed.is_ok()`), so the usage/invoice views
/// mirror billed usage. Tradeoff: an event that bills on the same run whose history append fails is
/// not retried (its hour's watermark advances on the Stripe success), so a rare history hiccup can
/// leave a single hour's dashboard row missing for one tenant. That is an acceptable gap for a
/// best-effort analytics store; a durable-history upgrade would give `record` its own watermark.
pub struct BillAndRecord<P: MeterSink, H: MeterSink> {
    pub bill: P,
    pub record: H,
    /// How many history appends failed this run (surfaced by the caller for observability).
    pub record_failures: u64,
}

impl<P: MeterSink, H: MeterSink> BillAndRecord<P, H> {
    pub fn new(bill: P, record: H) -> Self {
        Self {
            bill,
            record,
            record_failures: 0,
        }
    }
}

impl<P: MeterSink, H: MeterSink> MeterSink for BillAndRecord<P, H> {
    fn emit(&mut self, event: &MeterEvent) -> Result<(), String> {
        let billed = self.bill.emit(event);
        if billed.is_ok() && self.record.emit(event).is_err() {
            self.record_failures = self.record_failures.saturating_add(1);
        }
        billed
    }
}

pub(crate) fn hex16(t: &TenantId) -> String {
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

/// One hour-bucketed telemetry-usage row, written by hop-telemetryd's meter drain (the
/// `telemetry_usage/{hour}/{tenant}` value). Kept SEPARATE from [`LedgerRow`] on purpose: telemetry
/// counts come from the collector (OTel-over-Hop, §40), a different producer than the relay carriage
/// ledger (§37), so the two capture paths never couple. Additive across a tenant's collectors for one
/// (hour, tenant).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TelemetryRow {
    /// OTel-over-Hop events ingested this hour for this tenant (billed to `hop_telemetry_events`).
    pub events: u64,
    /// Measured payload bytes behind those events. Recorded because a telemetry batch is
    /// shape-bounded, not content-bounded, so one billable event can carry several KB of arbitrary
    /// strings and the event count alone hides real consumption by orders of magnitude.
    ///
    /// MEASUREMENT ONLY: nothing is priced off this and no meter reads it. Whether telemetry should
    /// be billed by bytes, by events, or by both is the owner's pricing decision.
    pub payload_bytes: u64,
}

impl TelemetryRow {
    pub fn add(&mut self, other: &TelemetryRow) {
        self.events = self.events.saturating_add(other.events);
        self.payload_bytes = self.payload_bytes.saturating_add(other.payload_bytes);
    }
}

/// Reconcile the TELEMETRY dimension (OTel-over-Hop observability, §40). Same hour-bucketed,
/// watermarked, idempotent contract as [`reconcile`], but over `telemetry_usage` rows written by the
/// collector: it sums events per (hour, tenant) for closed hours strictly after `watermark_hour`,
/// emits one `hop_telemetry_events` event per non-zero (hour, tenant) with a deterministic idempotency
/// key, and returns the highest hour for which EVERY event was accepted (a failed emit stops there so
/// the next run retries; Stripe dedups the successes).
pub fn reconcile_telemetry<S: MeterSink>(
    rows: &[(u64, TenantId, TelemetryRow)],
    watermark_hour: u64,
    now_hour: u64,
    sink: &mut S,
) -> u64 {
    let mut agg: BTreeMap<(u64, TenantId), TelemetryRow> = BTreeMap::new();
    for (hour, tenant, row) in rows {
        if *hour <= watermark_hour || *hour >= now_hour {
            continue;
        }
        agg.entry((*hour, *tenant)).or_default().add(row);
    }

    let mut new_watermark = watermark_hour;
    let mut current_hour: Option<u64> = None;
    let mut hour_ok = true;

    for ((hour, tenant), row) in &agg {
        if current_hour != Some(*hour) {
            if let Some(prev) = current_hour {
                if hour_ok {
                    new_watermark = prev;
                } else {
                    return new_watermark;
                }
            }
            current_hour = Some(*hour);
            hour_ok = true;
        }
        if row.events > 0 {
            let event = MeterEvent {
                event_name: meter::TELEMETRY_EVENTS,
                tenant: *tenant,
                value: row.events,
                idempotency_key: format!("{}:{}:{}", meter::TELEMETRY_EVENTS, hex16(tenant), hour),
                hour: *hour,
            };
            if sink.emit(&event).is_err() {
                hour_ok = false;
            }
        }
    }
    if let (Some(h), true) = (current_hour, hour_ok) {
        new_watermark = h;
    }
    new_watermark
}

/// Bytes per gigabyte (decimal GB, the storage-billing convention).
pub const BYTES_PER_GB: u64 = 1_000_000_000;
/// Milliseconds in a 30-day billing month.
pub const MS_PER_MONTH: u64 = 30 * 24 * 60 * 60 * 1000;

/// One hour-bucketed storage-occupancy row as written by a relay's meter flush (the
/// `storage_usage/{hour}/{tenant}` value): mailbox occupancy accrued this hour in BYTE-MILLISECONDS.
///
/// The relay integrates `size x time held` IN MEMORY off the hot path (sampling held sealed bytes
/// per tenant at each 30s flush and multiplying by the interval), so billingd only sums a
/// pre-integrated scalar here, never per-bundle lifecycle records. That is deliberate: a durable
/// per-object occupancy timeline per tenant would leak more metadata than carriage does (§39), and
/// the sampled scalar is the same (hour, tenant) grain as the carriage row. It also means storage
/// is billed only while the relay is warm: a bundle held across a relay restart is not re-attributed
/// (the §39 mailbox is blind; tenant is known only via the in-memory custody stamp), so this
/// UNDER-bills after a restart and never over-bills. Additive across a relay's flushes and across
/// regions for one (hour, tenant).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct StorageRow {
    /// Durable mailbox occupancy in byte-milliseconds, billed to `hop_mailbox_gb_month`.
    pub byte_ms: u64,
}

impl StorageRow {
    pub fn add(&mut self, other: &StorageRow) {
        self.byte_ms = self.byte_ms.saturating_add(other.byte_ms);
    }
}

/// Reconcile the STORAGE dimension (mailbox occupancy, §35 storage floor). Same hour-bucketed,
/// watermarked, idempotent contract as [`reconcile`]/[`reconcile_telemetry`], over `storage_usage`
/// rows: it sums byte-ms per (hour, tenant) for closed hours strictly after `watermark_hour`,
/// converts each to scaled milli-GB-months via [`byte_ms_to_scaled_gb_months`], emits one
/// `hop_mailbox_gb_month` event per (hour, tenant) whose scaled value is non-zero with a
/// deterministic idempotency key, and returns the highest hour for which EVERY emit was accepted (a
/// failed emit stops there so the next run retries; Stripe dedups the successes).
///
/// A sub-threshold hour (occupancy that scales to 0 milli-GB-months) emits nothing but STILL closes
/// the hour and advances the watermark, so a tiny-occupancy hour never wedges the reconciler; that
/// remainder is dropped rather than carried, an acceptable rounding for a floor priced in
/// milli-GB-months.
pub fn reconcile_storage_rows<S: MeterSink>(
    rows: &[(u64, TenantId, StorageRow)],
    watermark_hour: u64,
    now_hour: u64,
    sink: &mut S,
) -> u64 {
    let mut agg: BTreeMap<(u64, TenantId), StorageRow> = BTreeMap::new();
    for (hour, tenant, row) in rows {
        if *hour <= watermark_hour || *hour >= now_hour {
            continue;
        }
        agg.entry((*hour, *tenant)).or_default().add(row);
    }

    let mut new_watermark = watermark_hour;
    let mut current_hour: Option<u64> = None;
    let mut hour_ok = true;

    for ((hour, tenant), row) in &agg {
        if current_hour != Some(*hour) {
            if let Some(prev) = current_hour {
                if hour_ok {
                    new_watermark = prev;
                } else {
                    return new_watermark;
                }
            }
            current_hour = Some(*hour);
            hour_ok = true;
        }
        let scaled = byte_ms_to_scaled_gb_months(row.byte_ms);
        if scaled > 0 {
            let event = MeterEvent {
                event_name: meter::MAILBOX_GB_MONTH,
                tenant: *tenant,
                value: scaled,
                idempotency_key: format!("{}:{}:{}", meter::MAILBOX_GB_MONTH, hex16(tenant), hour),
                hour: *hour,
            };
            if sink.emit(&event).is_err() {
                hour_ok = false;
            }
        }
    }
    if let (Some(h), true) = (current_hour, hour_ok) {
        new_watermark = h;
    }
    new_watermark
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

    /// A telemetry row with only events set. Bytes are measurement, not a billing input, so the
    /// reconciler tests deliberately leave them at zero except where the point IS the bytes.
    fn tel(events: u64) -> TelemetryRow {
        TelemetryRow {
            events,
            payload_bytes: 0,
        }
    }

    fn sample_event() -> MeterEvent {
        MeterEvent {
            event_name: meter::BACKBONE_DELIVERY,
            tenant: A,
            value: 7,
            idempotency_key: "hop_backbone_delivery:0101...:5".into(),
            hour: 5,
        }
    }

    #[test]
    fn bill_and_record_bills_and_records_when_both_are_up() {
        let mut sink = BillAndRecord::new(FakeSink::default(), FakeSink::default());
        assert!(sink.emit(&sample_event()).is_ok());
        assert_eq!(sink.bill.emitted.len(), 1);
        assert_eq!(sink.record.emitted.len(), 1);
        assert_eq!(sink.record_failures, 0);
    }

    #[test]
    fn a_history_failure_never_fails_the_emit_so_revenue_is_never_frozen() {
        // History (secondary) down: the emit still SUCCEEDS (Stripe billed), so the watermark
        // advances and billing keeps making progress. The failure is counted, not propagated.
        let mut sink = BillAndRecord::new(
            FakeSink::default(),
            FakeSink {
                fail_hours: vec![5],
                ..Default::default()
            },
        );
        assert!(
            sink.emit(&sample_event()).is_ok(),
            "a dashboards-store failure must NEVER gate revenue"
        );
        assert_eq!(sink.bill.emitted.len(), 1, "Stripe still billed");
        assert_eq!(sink.record_failures, 1, "history failure is counted");
    }

    #[test]
    fn a_billing_failure_propagates_and_skips_the_history_record() {
        // Stripe down: emit fails (holds the watermark, retried next run), and history is NOT
        // recorded for an event that did not bill (the usage view mirrors billed usage).
        let mut sink = BillAndRecord::new(
            FakeSink {
                fail_hours: vec![5],
                ..Default::default()
            },
            FakeSink::default(),
        );
        assert!(sink.emit(&sample_event()).is_err());
        assert_eq!(
            sink.record.emitted.len(),
            0,
            "unbilled usage is not recorded"
        );
    }

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
    fn reconcile_telemetry_sums_collectors_and_emits_one_event_per_hour_tenant() {
        // Two collectors reported for (hour 5, tenant A); one row for (hour 5, tenant B).
        let rows = vec![
            (5, A, tel(300)),
            (5, A, tel(120)), // another collector
            (5, B, tel(40)),
        ];
        let mut sink = FakeSink::default();
        let wm = reconcile_telemetry(&rows, 0, 6, &mut sink);
        assert_eq!(wm, 5, "hour 5 fully reconciled");
        assert_eq!(sink.emitted.len(), 2, "one event per tenant for the hour");
        let a = sink.emitted.iter().find(|e| e.tenant == A).unwrap();
        assert_eq!(a.value, 420, "300 + 120 summed across collectors");
        assert_eq!(a.event_name, meter::TELEMETRY_EVENTS);
        assert_eq!(
            a.idempotency_key,
            format!("hop_telemetry_events:{}:5", hex16(&A))
        );
    }

    #[test]
    fn reconcile_telemetry_holds_the_watermark_on_a_failed_emit() {
        let rows = vec![(4, A, tel(10)), (5, A, tel(20))];
        let mut sink = FakeSink {
            fail_hours: vec![5],
            ..Default::default()
        };
        // hour 4 emits; hour 5 fails -> watermark stops at 4, retried next run (Stripe dedups).
        let wm = reconcile_telemetry(&rows, 0, 6, &mut sink);
        assert_eq!(wm, 4);
        assert_eq!(sink.emitted.len(), 1);
        assert_eq!(sink.emitted[0].hour, 4);
    }

    #[test]
    fn reconcile_telemetry_skips_zero_and_out_of_window_hours() {
        let rows = vec![
            (3, A, tel(99)), // <= watermark, skipped
            (5, A, tel(0)),  // zero -> no event
            (5, B, tel(7)),
            (6, A, tel(5)), // current hour, still open
        ];
        let mut sink = FakeSink::default();
        let wm = reconcile_telemetry(&rows, 3, 6, &mut sink);
        assert_eq!(wm, 5);
        assert_eq!(sink.emitted.len(), 1, "only (5,B) with non-zero events");
        assert_eq!(sink.emitted[0].tenant, B);
        assert_eq!(sink.emitted[0].value, 7);
    }

    #[test]
    fn telemetry_payload_bytes_are_recorded_but_change_no_price() {
        // Bytes are measurement only. They must sum through the row arithmetic (so the data is
        // there when someone decides how to price it) while emitting the SAME meter events, on the
        // SAME meter, with the SAME values as before the field existed.
        let mut row = TelemetryRow {
            events: 10,
            payload_bytes: 1000,
        };
        row.add(&TelemetryRow {
            events: 5,
            payload_bytes: 500,
        });
        assert_eq!(row.events, 15);
        assert_eq!(row.payload_bytes, 1500, "bytes accumulate for visibility");

        let fat = vec![(
            5,
            A,
            TelemetryRow {
                events: 3,
                payload_bytes: 999_999,
            },
        )];
        let mut sink = FakeSink::default();
        assert_eq!(reconcile_telemetry(&fat, 0, 6, &mut sink), 5);
        assert_eq!(sink.emitted.len(), 1, "still one event per (hour, tenant)");
        assert_eq!(sink.emitted[0].event_name, meter::TELEMETRY_EVENTS);
        assert_eq!(
            sink.emitted[0].value, 3,
            "billed on EVENTS only; no byte meter, no price change"
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

    /// One hour's worth of byte-milliseconds for a tenant holding `gb` gigabytes for the whole hour.
    fn gb_for_an_hour(gb: u64) -> StorageRow {
        StorageRow {
            byte_ms: gb.saturating_mul(BYTES_PER_GB).saturating_mul(3_600_000),
        }
    }

    #[test]
    fn reconcile_storage_sums_relay_flushes_and_emits_one_event_per_hour_tenant() {
        // Each relay flush writes its own accrual for (hour, tenant); they are additive, both
        // across a single relay's 30s flushes and across regions. Two accruals for (5, A) sum.
        let rows = vec![
            (5, A, StorageRow { byte_ms: 300 }),
            (5, A, StorageRow { byte_ms: 120 }), // a later flush, or another region
            (5, B, gb_for_an_hour(1)),
        ];
        let mut sink = FakeSink::default();
        let wm = reconcile_storage_rows(&rows, 0, 6, &mut sink);
        assert_eq!(wm, 5, "hour 5 fully reconciled");
        // A holds 420 byte-ms, far below one milli-GB-month, so it scales to 0 and emits nothing.
        assert_eq!(sink.emitted.len(), 1, "only the non-zero scaled tenant");
        let b = &sink.emitted[0];
        assert_eq!(b.tenant, B);
        assert_eq!(b.event_name, meter::MAILBOX_GB_MONTH);
        assert_eq!(
            b.idempotency_key,
            format!("hop_mailbox_gb_month:{}:5", hex16(&B))
        );
    }

    #[test]
    fn occupancy_that_never_delivered_is_still_priced() {
        // The DoS the review flagged: bundles that never deliver still accrue storage occupancy.
        // The storage axis is sampled from HELD bytes, so it is nonzero for a tenant that produced
        // no delivery event at all this hour, which is exactly what carriage alone would miss.
        let rows = vec![(5, A, gb_for_an_hour(10))];
        let mut sink = FakeSink::default();
        let wm = reconcile_storage_rows(&rows, 0, 6, &mut sink);
        assert_eq!(wm, 5);
        assert_eq!(sink.emitted.len(), 1, "undelivered occupancy is priced");
        assert!(sink.emitted[0].value > 0);
    }

    #[test]
    fn storage_hours_do_not_overlap_so_occupancy_is_never_double_counted() {
        // Hour bucketing is what windowing used to do: each hour is billed exactly once, and the
        // per-hour values sum to the total occupancy across both hours.
        let rows = vec![(4, A, gb_for_an_hour(1)), (5, A, gb_for_an_hour(1))];
        let mut sink = FakeSink::default();
        let wm = reconcile_storage_rows(&rows, 0, 6, &mut sink);
        assert_eq!(wm, 5);
        assert_eq!(sink.emitted.len(), 2, "one event per closed hour");
        assert_eq!(sink.emitted[0].value, sink.emitted[1].value, "equal hours");
        // Re-running the same window from the advanced watermark emits nothing further.
        let mut again = FakeSink::default();
        assert_eq!(reconcile_storage_rows(&rows, wm, 6, &mut again), wm);
        assert!(
            again.emitted.is_empty(),
            "no double count past the watermark"
        );
    }

    #[test]
    fn reconcile_storage_holds_the_watermark_on_a_failed_emit() {
        let rows = vec![(4, A, gb_for_an_hour(1)), (5, A, gb_for_an_hour(1))];
        let mut sink = FakeSink {
            fail_hours: vec![5],
            ..Default::default()
        };
        // hour 4 emits; hour 5 fails -> watermark stops at 4, retried next run (Stripe dedups).
        let wm = reconcile_storage_rows(&rows, 0, 6, &mut sink);
        assert_eq!(
            wm, 4,
            "a failed emit leaves the hour to retry (idempotent) next run"
        );
        assert_eq!(sink.emitted.len(), 1);
        assert_eq!(sink.emitted[0].hour, 4);
    }

    #[test]
    fn a_sub_threshold_storage_hour_closes_without_wedging_the_reconciler() {
        // Occupancy too small to scale to one milli-GB-month emits nothing but STILL advances the
        // watermark, so a near-idle relay never parks the storage dimension forever.
        let rows = vec![(5, A, StorageRow { byte_ms: 1 })];
        let mut sink = FakeSink::default();
        let wm = reconcile_storage_rows(&rows, 0, 6, &mut sink);
        assert_eq!(wm, 5, "the hour closes even though nothing was billable");
        assert!(sink.emitted.is_empty());
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
