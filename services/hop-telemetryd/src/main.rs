//! # hop-telemetryd, a Hop telemetry collector (OTel-over-Hop, DESIGN.md §40)
//!
//! A mesh leaf that RECEIVES telemetry: devices call `Node::send_telemetry(collector_addr, batch)`,
//! which routes a statically sealed `hop.telemetry` bundle to this node's address; the node decodes
//! and bounds-checks it (`hop_core::telemetry`) and surfaces it via `take_telemetry`. This daemon
//! drains those batches, meters each to its billing TENANT (recovered from the carriage stamp, §35,
//! the SAME attribution as billing), and merges the per-tenant counts into the durable `telemetry_usage`
//! ledger the §37 reconciler bills as `hop_telemetry_events`. A [`TelemetrySink`] (aggregate-only
//! [`AggregateSink`]) also runs for throughput logging, never per-record or per-device (services-03: a
//! per-message log would be a traffic-analysis feed). Remaining follow-ups: the durable Firestore store
//! backend (a `firestore` feature, off by default) and a raw-event BigQuery forwarder for the dashboard.
//!
//! Mesh attachment mirrors hop-endpoint: this is a leaf that never relays others' traffic
//! (`set_max_relayed(0)`) and becomes addressable by DIALING a relay as the Noise `Role::Initiator`.
//! The relay learns our address from the handshake, then any `Destination::Device(collector_addr)`
//! bundle is delivered straight down that link. It also LISTENS: an SDK can direct-dial `wss://<domain>/`
//! and become an inbound bearer, so telemetry reaches the collector even with the relay fleet down. It
//! serves a signed reach record at `/.well-known/hop` so the SDK can resolve `telemetry.<domain>` to
//! this collector's address (what telemetry is sealed and routed to).
//!
//! Usage:
//!   hop-telemetryd --listen 0.0.0.0:9445 [--domain telemetry.hopme.sh] \
//!                  [--identity-file PATH] [--relay wss://relay.hopme.sh/ | --no-relay]

use std::collections::{HashMap, HashSet};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

// The OTLP-export module is consumed only by the `live` forwarding path and its own unit tests, so a
// default (non-live) BINARY build has no use for it; compile it only where it's actually referenced.
#[cfg(any(feature = "live", test))]
mod otlp;

use base64::Engine;
use hop_core::node::TelemetryIn;
use hop_core::prelude::*;
use hop_core::telemetry::TelemetryBatch;
use hop_gateway::resolve_relay;
#[cfg(feature = "firestore")]
use hop_store_firestore::FirestoreStore;
use hop_store_sqlite::SqliteStore;
use tungstenite::Message;
#[cfg(any(feature = "live", test))]
#[allow(dead_code)]
const _OTLP_RESP_MAX: usize = otlp::MAX_OTLP_RESPONSE_BYTES;

static NEXT_LINK: AtomicU64 = AtomicU64::new(1);

/// HNS reach-record TTL (DESIGN.md §30): how long an SDK caches this collector's `domain -> address`
/// binding. We re-sign well within it ([`WELL_KNOWN_RESIGN`]) so the served record is always fresh.
const WELL_KNOWN_TTL_SECS: u32 = 7200; // 2h
const WELL_KNOWN_RESIGN: Duration = Duration::from_secs(3600); // 1h

/// How often the driver logs an aggregate throughput line (counts only, services-03).
const STATS_LOG_INTERVAL: Duration = Duration::from_secs(60);

/// Cap on a single inbound HTTP request head, so a hostile client can't grow the read buffer to OOM.
const MAX_REQ_HEAD_BYTES: u64 = 8 * 1024;

/// Cap on concurrent inbound connections (one thread per connection), so the accept loop can't be
/// driven to thread/memory exhaustion. Inbound serves `/healthz`, the reach record, and a hops:// WS
/// bearer (direct-dial telemetry); it never proxies.
const MAX_CONNS: usize = 256;
static ACTIVE_CONNS: AtomicUsize = AtomicUsize::new(0);

#[cfg(not(test))]
const WS_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);
#[cfg(test)]
const WS_HANDSHAKE_TIMEOUT: Duration = Duration::from_millis(500);

/// Cap on a single inbound WS bearer message/frame (mirroring the relay's services-05 cap), instead of
/// tungstenite's 64 MiB default, so a mesh peer can't push a giant frame the instance must buffer.
const MAX_FRAME_BYTES: usize = 1 << 20; // 1 MiB

/// How often time-based node maintenance (tick + reach re-sign) runs, independent of inbound load.
const TICK_INTERVAL: Duration = Duration::from_millis(250);

/// How often the per-tenant telemetry counts are merged into the durable `telemetry_usage` ledger
/// the §37 reconciler reads. A crash loses at most one interval; the hour bucket bounds granularity.
const TELEMETRY_FLUSH: Duration = Duration::from_secs(30);

/// Set by SIGTERM/SIGINT so the driver drains the meter into the durable ledger and flushes the store
/// before the instance is reaped, instead of losing the window's billable usage (the relay's F-21).
static SHUTDOWN: AtomicBool = AtomicBool::new(false);

extern "C" fn on_sigterm(_sig: libc::c_int) {
    SHUTDOWN.store(true, Ordering::SeqCst);
}

fn install_shutdown_handler() {
    // Coerce to a fn pointer before the numeric cast (fn *item* to integer is a clippy lint).
    let handler = on_sigterm as extern "C" fn(libc::c_int) as libc::sighandler_t;
    unsafe {
        libc::signal(libc::SIGTERM, handler);
        libc::signal(libc::SIGINT, handler);
    }
}

/// Decrements the active-connection count when a handler thread finishes (including on panic unwind).
struct ConnGuard;
impl Drop for ConnGuard {
    fn drop(&mut self) {
        ACTIVE_CONNS.fetch_sub(1, Ordering::SeqCst);
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

// --- reach record (/.well-known/hop) -----------------------------------------------------------

/// The pre-signed `/.well-known/hop` body (JSON `{address, endpoint, reach}`), process-global because
/// a collector is bound to one domain/identity. Empty until the driver first signs it (a probe before
/// then 404s); the driver refreshes it under a Mutex so a long-lived process never serves an expired
/// record.
fn well_known_body() -> &'static Mutex<Vec<u8>> {
    static WK: OnceLock<Mutex<Vec<u8>>> = OnceLock::new();
    WK.get_or_init(|| Mutex::new(Vec::new()))
}

/// Whether this collector can actually do its job: attribute inbound telemetry to a tenant, or serve
/// it deliberately unattributed. False means every batch is refused (fail closed).
///
/// `/healthz` reports this. Without it the fail-closed posture is INVISIBLE: a misconfigured
/// collector, a missing or typo'd `--key-server`, would start, pass its Cloud Run health probe, and
/// silently refuse every batch, so the first sign of trouble is absent telemetry rather than an
/// alert. Reporting unhealthy surfaces the misconfiguration to Cloud Run and any monitoring watching
/// revision health, while keeping the process up so the log line explaining WHY stays readable. That
/// is the reason this is not an `exit(1)`: a crashloop is loud but its backoff tends to bury the one
/// message an operator needs.
fn ingest_ready() -> &'static std::sync::atomic::AtomicBool {
    static READY: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    &READY
}

/// Whether durable store writes are succeeding. Degraded store sets this to false so /healthz
/// reflects store write failures and Cloud Run can alert (STORE-005 / CAND-NET-01).
fn store_healthy() -> &'static std::sync::atomic::AtomicBool {
    static HEALTHY: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);
    &HEALTHY
}

/// Sign this collector's reach record for `public_url` and render the `/.well-known/hop` JSON body.
/// The `reach` field is the base64-std postcard record (SDKs decode exactly this); `address` +
/// `endpoint` are informational. All three are base58 / base64 / a bare wss URL, so the JSON is safe
/// to build by hand (no embedded quotes to escape).
fn sign_well_known<S: Store>(node: &Node<S>, public_url: &str) -> Vec<u8> {
    let rec = node.sign_reach_record(public_url.to_string(), WELL_KNOWN_TTL_SECS);
    let reach = base64::engine::general_purpose::STANDARD.encode(rec.to_bytes());
    let address = bs58::encode(node.address()).into_string();
    format!("{{\"address\":\"{address}\",\"endpoint\":\"{public_url}\",\"reach\":\"{reach}\"}}")
        .into_bytes()
}

fn public_url_for(domain: &str) -> String {
    format!("wss://{domain}/")
}

// --- durable store ------------------------------------------------------------------------------

/// Pick the collector's durable store: Firestore on the cloud deploy (so the `telemetry_usage` ledger
/// survives a restart and the §37 reconciler can read it), else a local SQLite file. Mirrors the
/// relay's `build_store`. Without a durable store the ledger dies with the process and nothing bills.
#[cfg(feature = "firestore")]
fn build_store(firestore: &Option<String>, db: &str, addr: &[u8]) -> Box<dyn Store> {
    if let Some(project) = firestore {
        match FirestoreStore::open(project, addr) {
            Ok(s) => {
                println!("hop-telemetryd: store = firestore (project {project})");
                return Box::new(s);
            }
            Err(e) => eprintln!("firestore open failed ({e}); falling back to sqlite"),
        }
    }
    Box::new(SqliteStore::open(db).expect("open sqlite store"))
}

#[cfg(not(feature = "firestore"))]
fn build_store(firestore: &Option<String>, db: &str, _addr: &[u8]) -> Box<dyn Store> {
    if firestore.is_some() {
        eprintln!(
            "firestore support not compiled in (build with --features firestore); using sqlite"
        );
    }
    Box::new(SqliteStore::open(db).expect("open sqlite store"))
}

/// Normalize an operator-supplied domain to a safe hostname: lowercase, no trailing dot, and only
/// `[a-z0-9.-]`, so a stray character (e.g. a double-quote) can never break the hand-built reach-record
/// JSON served at `/.well-known/hop`.
fn sanitize_domain(d: &str) -> String {
    d.trim_end_matches('.')
        .to_ascii_lowercase()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '-')
        .collect()
}

// --- telemetry sink ----------------------------------------------------------------------------

/// Where received telemetry goes. A later increment implements a BigQuery/warehouse forwarder + a
/// per-tenant meter emitter behind this trait (mirroring hop-billingd's `live` feature); the daemon
/// only knows the trait.
trait TelemetrySink: Send {
    /// Forward one received batch (already decoded + bounds-checked by the core).
    fn record(&mut self, from: PubKeyBytes, batch: &TelemetryBatch);
}

/// The default sink: aggregate counters only. It never retains per-device or per-record data
/// (services-03), so nothing here is a traffic-analysis surface; it exists so the daemon reports
/// throughput and so the receive path is exercised before a real forwarder lands.
#[derive(Default)]
struct AggregateSink {
    batches: u64,
    events: u64,
}

impl TelemetrySink for AggregateSink {
    fn record(&mut self, _from: PubKeyBytes, batch: &TelemetryBatch) {
        self.batches = self.batches.saturating_add(1);
        self.events = self.events.saturating_add(batch.billable_events());
    }
}

impl AggregateSink {
    /// Read and reset the window counters (batches, events) for the periodic aggregate log line.
    fn take(&mut self) -> (u64, u64) {
        let out = (self.batches, self.events);
        self.batches = 0;
        self.events = 0;
        out
    }
}

// --- per-tenant metering ----------------------------------------------------------------------

/// Per-tenant billable telemetry counts accumulating for the current window, flushed into the durable
/// `telemetry_usage/{hour}/{tenant}` ledger the §37 reconciler reads (`reconcile_telemetry`). This is
/// the SAME tenant attribution as billing (recovered from the carriage stamp in the core, §35), so a
/// tenant's observability bills to the same identity as its reach. Un-attributed batches (no stamp, or
/// the collector runs an `Open` policy) can't be billed, so they are counted in aggregate only.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct TelemetryCounts {
    events: u64,
    /// Measured payload bytes ([`TelemetryBatch::payload_bytes`]). Recorded ALONGSIDE the event
    /// count because batches are shape-bounded, not content-bounded: one legal "billable event" can
    /// carry several KB of arbitrary strings, so events alone hide the real resource consumption by
    /// orders of magnitude. Measurement only; nothing is priced off it yet.
    payload_bytes: u64,
}

impl TelemetryCounts {
    fn add(&mut self, other: &TelemetryCounts) {
        self.events = self.events.saturating_add(other.events);
        self.payload_bytes = self.payload_bytes.saturating_add(other.payload_bytes);
    }
}

#[derive(Default)]
struct TelemetryMeter {
    counts: HashMap<TenantId, TelemetryCounts>,
    /// Events accepted WITHOUT a tenant, which is only reachable with `--allow-unattributed`.
    unattributed: u64,
    /// Events REFUSED because they could not be attributed and the collector is fail-closed.
    refused: u64,
}

impl TelemetryMeter {
    fn add(&mut self, tenant: Option<TenantId>, counts: TelemetryCounts) {
        match tenant {
            Some(t) => self.counts.entry(t).or_default().add(&counts),
            None => self.unattributed = self.unattributed.saturating_add(counts.events),
        }
    }

    fn refuse(&mut self, events: u64) {
        self.refused = self.refused.saturating_add(events);
    }

    fn take_refused(&mut self) -> u64 {
        std::mem::replace(&mut self.refused, 0)
    }

    /// RMW-merge the accumulated per-tenant counts into the store's `telemetry_usage` ledger for the
    /// current hour, then clear. With a durable (Firestore) store the rows survive a restart and the
    /// reconciler reads them; with `MemoryStore` they are in-process only.
    ///
    /// The premise this depends on, stated exactly (SVC-005): the read half of the read-modify-write
    /// reads the process-LOCAL in-memory kv copy, never the durable row, so it is safe ONLY against a
    /// row no other process writes. This used to claim "only this node writes these keys, so the
    /// read-modify-write is race-free", which is a deployment property and not a structural one:
    /// any two collector processes that share a node identity share a Firestore partition, and the
    /// later flush would write its own stale base plus its own delta and silently discard the other's
    /// events. The row key now carries [`ledger_writer_id`], so the row this merge owns is private to
    /// THIS process; concurrent writers compose because the reconciler sums the per-writer rows.
    /// `telemetry_usage/` is one of the four prefixes the SVC-005 invariant names, and it is now
    /// scoped on the same terms as the relay's three.
    fn flush_to_store<S: Store>(&mut self, store: &mut S, now_ms: u64) {
        self.flush_to_store_with(store, now_ms, telemetry_usage_key)
    }

    /// The flush body against an explicit key function. Split out ONLY so a test can drive two
    /// different writer ids in one process and prove their rows compose (SVC-005).
    fn flush_to_store_with<S: Store>(
        &mut self,
        store: &mut S,
        now_ms: u64,
        key_for: impl Fn(u64, &TenantId) -> String,
    ) {
        if self.counts.is_empty() {
            return;
        }
        let hour = now_ms / 3_600_000;
        let mut committed = Vec::new();
        let mut failed = false;
        for (tenant, counts) in &self.counts {
            if *counts == TelemetryCounts::default() {
                committed.push(*tenant);
                continue;
            }
            let key = key_for(hour, tenant);
            let mut total = store
                .get_kv(&key)
                .map(|b| decode_counts(&b))
                .unwrap_or_default();
            total.add(counts);
            match store.put_kv_critical(&key, encode_counts(&total)) {
                Ok(()) => {
                    committed.push(*tenant);
                }
                Err(e) => {
                    failed = true;
                    eprintln!("hop-telemetryd: telemetry_usage write failed for {key}: {e}");
                }
            }
        }
        for tenant in committed {
            self.counts.remove(&tenant);
        }
        if failed {
            store_healthy().store(false, Ordering::SeqCst);
        } else {
            store_healthy().store(true, Ordering::SeqCst);
        }
    }

    fn take_unattributed(&mut self) -> u64 {
        std::mem::replace(&mut self.unattributed, 0)
    }
}

/// This process's ledger WRITER id: 8 random bytes as 16 lowercase-hex chars, minted once per process
/// (SVC-005). Identical construction and meaning to hop-relayd's `ledger_writer_id`; see
/// [`TelemetryMeter::flush_to_store`] for why the segment exists. `hop-billingd`'s `ledger::parse_row`
/// accepts exactly 16 lowercase-hex chars as the optional fourth segment, so anything else here would
/// make every row this collector writes unbillable.
fn ledger_writer_id() -> &'static str {
    static WRITER_ID: OnceLock<String> = OnceLock::new();
    // Identity::generate draws from the OS CSPRNG; take 8 bytes of a throwaway address rather than
    // adding an rng dependency for 64 bits. Collision between two live processes is ~2^-64.
    WRITER_ID.get_or_init(|| {
        Identity::generate().address()[..8]
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect()
    })
}

/// Ledger row key for an explicit writer. Split out from [`telemetry_usage_key`] so a test can stand
/// up two DIFFERENT writers in one process and prove their rows compose rather than clobber.
fn telemetry_usage_key_for(hour: u64, tenant: &TenantId, writer: &str) -> String {
    let hex: String = tenant.iter().map(|b| format!("{b:02x}")).collect();
    format!("telemetry_usage/{hour}/{hex}/{writer}")
}

/// Ledger row key: `telemetry_usage/{hour}/{tenant_hex}/{writer}`, distinct from the relay's `usage/`
/// prefix so the two capture paths never collide (the reconciler reads them as separate dimensions).
/// The writer segment is [`ledger_writer_id`] (SVC-005).
fn telemetry_usage_key(hour: u64, tenant: &TenantId) -> String {
    telemetry_usage_key_for(hour, tenant, ledger_writer_id())
}

/// Row value: `events` then `payload_bytes`, both u64 LE (16 bytes total), mirroring the relay's
/// `usage/` row shape. `hop-billingd`'s `ledger::parse_row` decodes exactly this.
fn encode_counts(c: &TelemetryCounts) -> Vec<u8> {
    let mut out = Vec::with_capacity(16);
    out.extend_from_slice(&c.events.to_le_bytes());
    out.extend_from_slice(&c.payload_bytes.to_le_bytes());
    out
}

/// Decode a row value. 16 bytes is the current shape. 8 bytes is the ORIGINAL events-only shape and
/// still decodes as `(events, 0)`, so a row written by a pre-upgrade collector keeps its events
/// through the read-modify-write instead of being reset to zero. Any other length reads as zero (the
/// row is then overwritten whole), the same corruption convention as the relay's `decode_usage`.
fn decode_counts(bytes: &[u8]) -> TelemetryCounts {
    match bytes.len() {
        16 => TelemetryCounts {
            events: u64::from_le_bytes(bytes[..8].try_into().unwrap_or_default()),
            payload_bytes: u64::from_le_bytes(bytes[8..].try_into().unwrap_or_default()),
        },
        8 => TelemetryCounts {
            events: u64::from_le_bytes(bytes.try_into().unwrap_or_default()),
            payload_bytes: 0,
        },
        _ => TelemetryCounts::default(),
    }
}

/// Load a tenant `KeyServer` from a file of `<tenant-hex-32> <pubkey-base58>` lines (`#` comments and
/// blank lines skipped), so the collector can attribute telemetry the same way the relays do. This is
/// a stopgap loader; the live sync from the account service is a follow-up. `None` if the file can't be
/// read; an empty/all-invalid file yields an empty server (attributes nothing) with a warning.
fn load_key_server(path: &str) -> Option<KeyServer> {
    let text = std::fs::read_to_string(path).ok()?;
    let mut server = KeyServer::new();
    let mut loaded = 0usize;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let mut parts = line.split_whitespace();
        let (Some(tenant_hex), Some(pubkey_b58)) = (parts.next(), parts.next()) else {
            continue;
        };
        let Some(tenant) = parse_tenant_hex(tenant_hex) else {
            continue;
        };
        let Some(pubkey) = bs58::decode(pubkey_b58)
            .into_vec()
            .ok()
            .and_then(|v| <[u8; 32]>::try_from(v.as_slice()).ok())
        else {
            continue;
        };
        server.insert(tenant, pubkey);
        loaded += 1;
    }
    if loaded == 0 {
        eprintln!("hop-telemetryd: key-server file {path} had no valid entries");
    }
    Some(server)
}

/// Build the tenant `KeyServer` from the static `--key-server` file AND, when `--firestore` is set,
/// the tenant registry the account service projects. Returns `None` only when NEITHER source is
/// configured (so the collector runs Open / unattributed). When `--firestore` is set the collector is
/// in keyed mode even if the registry is momentarily empty. A registry read error is logged and the
/// file keys are kept: under-attributing some telemetry is a revenue concern, not a reason to drop ALL
/// telemetry, so the collector stays up (unlike a relay, which fails closed and refuses).
fn build_key_server(file: Option<&str>, firestore: Option<&str>) -> Option<KeyServer> {
    #[cfg_attr(not(feature = "firestore"), allow(unused_mut))]
    let mut server = file.and_then(load_key_server);
    #[cfg(feature = "firestore")]
    if let Some(project) = firestore {
        let s = server.get_or_insert_with(KeyServer::new);
        match load_registry_keys(project) {
            Ok(keys) => {
                for (tenant, pubkey) in keys {
                    s.insert(tenant, pubkey);
                }
            }
            Err(e) => {
                eprintln!("hop-telemetryd: tenant registry read failed: {e}; keeping file keys")
            }
        }
    }
    #[cfg(not(feature = "firestore"))]
    let _ = firestore;
    server
}

/// The active, keyed, well-formed tenant carriage keys from the Firestore tenant registry. A read
/// error propagates (the caller keeps the file keys); a malformed row is skipped by `carriage_key`.
#[cfg(feature = "firestore")]
fn load_registry_keys(project: &str) -> std::result::Result<Vec<(TenantId, [u8; 32])>, String> {
    let registry = hop_store_firestore::TenantRegistry::new(project);
    let records = registry
        .all()
        .map_err(|e| format!("tenant registry read: {e}"))?;
    Ok(records.iter().filter_map(|r| r.carriage_key()).collect())
}

/// The per-tenant OTLP endpoints from the Firestore tenant registry. A read error is logged and yields
/// an empty list, so the collector keeps the static file endpoints and stays up (fail-open). A row
/// with no OTLP endpoint or a malformed tenant hex is skipped.
///
/// SVC-002: the url arriving here is NOT trusted. This comment used to say it was, because the console
/// SSRF-validated it at write time, and that delegation was the whole defect: the write-time validator
/// accepted `[::ffff:169.254.169.254]` and, being a string check, could never see where a hostname
/// resolves. The boundary now lives at the connect, in `otlp::ReqwestOtlpTransport` (resolve, refuse
/// non-global, pin the address, no redirects), so a hostile registry row is refused even if it was
/// written by a validator with a hole in it. `OtlpEndpointMap::insert` still re-checks the http(s)
/// scheme, which is a shape check and nothing more.
#[cfg(all(feature = "live", feature = "firestore"))]
fn load_registry_otlp(project: &str) -> Vec<(TenantId, otlp::OtlpEndpoint)> {
    let registry = hop_store_firestore::TenantRegistry::new(project);
    match registry.all() {
        Ok(records) => records
            .iter()
            .filter_map(|r| {
                let url = r.otlp_endpoint.as_deref()?;
                let tenant = parse_tenant_hex(&r.tenant_hex)?;
                Some((
                    tenant,
                    otlp::OtlpEndpoint {
                        url: url.to_string(),
                        auth: None,
                    },
                ))
            })
            .collect(),
        Err(e) => {
            eprintln!(
                "hop-telemetryd: tenant registry OTLP read failed: {e}; keeping file endpoints"
            );
            Vec::new()
        }
    }
}

/// Parse a 32-char hex string into a 16-byte `TenantId`; `None` if it is not exactly 32 hex chars.
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

// --- collector node assembly --------------------------------------------------------------------

/// Assemble the collector's node: the SAME configuration `main` runs, factored out so a test can
/// exercise the real thing end to end rather than the pieces in isolation.
///
/// The telemetry opt-in is the load-bearing line. `set_kind(NodeKind::Endpoint)` narrows the app
/// payload policy to `HttpRequest | HpsMessage`, which does NOT include `Telemetry`, so without
/// `set_telemetry_ingest(true)` the core's ingest gate drops every batch and the collector is inert.
/// That was a live bug: the daemon set the kind and nothing else, so telemetry ingest was dead in
/// production while every unit test (which built a default `Device`-kind node) passed. The narrow
/// opt-in is used rather than widening `NodeKind::Endpoint`'s policy, so an ordinary `hops://`
/// endpoint deployment never silently becomes a telemetry sink.
///
/// Returns whether tenant attribution is active (a key server was loaded).
fn configure_collector_node<S: Store>(
    node: &mut Node<S>,
    domain: Option<String>,
    key_server: Option<KeyServer>,
) -> bool {
    node.set_kind(NodeKind::Endpoint);
    node.set_telemetry_ingest(true); // without this the §40 ingest gate drops every batch
    node.set_name(domain);
    node.set_max_relayed(0); // a leaf: routable by address, relays nothing

    // Attribution: run the SAME Keyed access policy as the billing relays so a received stamp
    // resolves to a tenant.
    match key_server {
        Some(server) => {
            node.set_access_policy(AccessPolicy::Keyed(KeyedAccess::new(
                server,
                HashSet::new(),
            )));
            node.refresh_access();
            true
        }
        None => false,
    }
}

// --- CLI ---------------------------------------------------------------------------------------

struct CliConfig {
    listen: String,
    domain: Option<String>,
    identity_file: Option<String>,
    /// Dial a relay so the collector is reachable by its address on the mesh. Default on.
    relay: Option<String>,
    /// Whether a --relay/--no-relay was given on the CLI, so env only fills the default.
    relay_cli_set: bool,
    print_address: bool,
    /// Tenant KeyServer file (`<tenant-hex> <pubkey-b58>` lines) for telemetry attribution + billing.
    key_server_file: Option<String>,
    /// GCP project for the durable Firestore-backed ledger (needs `--features firestore`).
    firestore: Option<String>,
    /// Local SQLite path used when Firestore is not configured.
    db: String,
    /// Per-tenant OTLP endpoint file (`<tenant-hex> <base-url> [auth]` lines) for managed telemetry
    /// export (needs `--features live`). Env fallback: `HOP_OTLP_MAP`.
    otlp_map_file: Option<String>,
    /// Serve telemetry that cannot be attributed to a tenant (so cannot be billed). OFF by default:
    /// the collector fails CLOSED, refusing unattributable batches rather than ingesting and
    /// exporting them for free. Local/dev escape hatch only.
    allow_unattributed: bool,
}

/// Parse the CLI flags. Pure over its `args` iterator (no env, no I/O), so every flag/default is
/// unit-testable. Unknown flags are logged and ignored.
fn parse_args(args: impl Iterator<Item = String>) -> CliConfig {
    let mut listen = "0.0.0.0:9445".to_string();
    let mut domain: Option<String> = None;
    let mut identity_file: Option<String> = None;
    let mut relay: Option<String> = Some("wss://relay.hopme.sh/".to_string());
    let mut relay_cli_set = false;
    let mut print_address = false;
    let mut key_server_file: Option<String> = None;
    let mut firestore: Option<String> = None;
    let mut db = "hop-telemetryd.db".to_string();
    let mut otlp_map_file: Option<String> = None;
    let mut allow_unattributed = false;
    let mut args = args;
    while let Some(a) = args.next() {
        match a.as_str() {
            "--listen" => listen = args.next().unwrap_or(listen),
            "--domain" => domain = args.next(),
            "--identity-file" => identity_file = args.next(),
            "--relay" => {
                relay = args.next();
                relay_cli_set = true;
            }
            "--no-relay" => {
                relay = None;
                relay_cli_set = true;
            }
            "--key-server" => key_server_file = args.next(),
            "--firestore" => firestore = args.next(), // GCP project id, durable ledger
            "--db" => db = args.next().unwrap_or(db),
            "--otlp-map" => otlp_map_file = args.next(),
            "--allow-unattributed" => allow_unattributed = true,
            "--print-address" => print_address = true,
            other => eprintln!("ignoring unknown arg: {other}"),
        }
    }
    CliConfig {
        listen,
        domain,
        identity_file,
        relay,
        relay_cli_set,
        print_address,
        key_server_file,
        firestore,
        db,
        otlp_map_file,
        allow_unattributed,
    }
}

fn main() {
    let CliConfig {
        listen,
        domain,
        identity_file,
        mut relay,
        relay_cli_set,
        print_address,
        key_server_file,
        firestore,
        db,
        otlp_map_file,
        allow_unattributed,
    } = parse_args(std::env::args().skip(1));

    // Graceful degrade when the relay fleet is off: infra can set HOP_NO_RELAY=1 so the instance
    // doesn't spin dialing a dead relay. A CLI --relay/--no-relay still wins; env only fills default.
    relay = resolve_relay(
        relay,
        relay_cli_set,
        std::env::var("HOP_NO_RELAY").ok().as_deref(),
        std::env::var("HOP_RELAY").ok().as_deref(),
    );

    if print_address {
        let identity = load_identity(&identity_file);
        println!("{}", bs58::encode(identity.address()).into_string());
        return;
    }

    let identity = load_identity(&identity_file);
    let domain = domain
        .map(|d| sanitize_domain(&d))
        .filter(|d| !d.is_empty());

    // Durable store: the telemetry_usage ledger must survive a restart for the §37 reconciler to read
    // it, so the collector runs on SQLite (local) or Firestore (cloud), never an in-memory store.
    install_shutdown_handler();
    let store = build_store(&firestore, &db, &identity.address());
    let mut node = Node::with_store(identity, store);
    // Keys come from the static --key-server file PLUS, when --firestore is set, the tenant registry
    // the account service projects. configure_collector_node then installs the SAME Keyed access
    // policy the billing relays run, and (critically) opts this node into telemetry ingest.
    let key_server = build_key_server(key_server_file.as_deref(), firestore.as_deref());
    let attributed = configure_collector_node(&mut node, domain.clone(), key_server);

    // Fail-closed posture. Serving telemetry we cannot attribute means ingesting, storing, and
    // exporting a tenant's observability for free, so a missing, empty, or typo'd key source must
    // REFUSE rather than silently give the product away. --allow-unattributed is the deliberate
    // local/dev escape hatch, and it says so loudly because leaving it on in production is the same
    // hole by another name.
    if attributed {
        println!("hop-telemetryd: keyed policy loaded; telemetry is tenant-attributed");
    } else {
        eprintln!(
            "hop-telemetryd: no --key-server and no tenant registry; NOTHING can be attributed to a tenant"
        );
    }
    if allow_unattributed {
        eprintln!(
            "hop-telemetryd: WARNING --allow-unattributed is ON: unattributable telemetry will be \
             ingested and exported UNBILLED. Local/dev only; never run this in production."
        );
    } else {
        println!(
            "hop-telemetryd: fail-closed: unattributable telemetry is REFUSED (not ingested, not \
             forwarded). Pass --allow-unattributed to serve it anyway."
        );
    }
    // Health reflects whether any batch can actually be served: a keyed policy attributes them, and
    // --allow-unattributed serves them deliberately. Neither means we refuse everything, which is a
    // misconfiguration the probe must expose rather than mask.
    ingest_ready().store(attributed || allow_unattributed, Ordering::SeqCst);

    println!(
        "hop-telemetryd: address {}",
        bs58::encode(node.address()).into_string()
    );

    // Prime the node clock BEFORE signing (sign_reach_record stamps issued_at from node.now_ms, which
    // is 0 until the first tick; signing pre-tick would mint an already-expired record).
    node.tick(now_ms());
    if let Some(d) = &domain {
        *well_known_body().lock().expect("well-known lock") =
            sign_well_known(&node, &public_url_for(d));
    }

    let (tx, rx) = mpsc::channel::<Ev>();

    // Inbound listener: /healthz (Cloud Run probe), /.well-known/hop (address resolution), and a
    // hops:// WS bearer so an SDK can direct-dial telemetry to us (works even with the relay fleet down).
    {
        let listener = TcpListener::bind(&listen).expect("bind --listen address");
        let tx = tx.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                if ACTIVE_CONNS.fetch_add(1, Ordering::SeqCst) >= MAX_CONNS {
                    ACTIVE_CONNS.fetch_sub(1, Ordering::SeqCst);
                    drop(stream);
                    continue;
                }
                let tx = tx.clone();
                // Builder::spawn returns Err instead of panicking on thread exhaustion, so a failed
                // spawn frees the reserved slot and leaves the accept loop alive (defense-in-depth).
                let spawned = std::thread::Builder::new().spawn(move || {
                    let _guard = ConnGuard; // decrements ACTIVE_CONNS on drop (incl. panic unwind)
                    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        serve_conn(stream, &tx)
                    }));
                });
                if spawned.is_err() {
                    ACTIVE_CONNS.fetch_sub(1, Ordering::SeqCst);
                }
            }
        });
    }

    // Dial the relay (if configured) so the collector joins the mesh as a routable leaf and receives
    // addressed telemetry, reconnecting forever.
    if let Some(relay_url) = relay {
        let tx = tx.clone();
        println!("hop-telemetryd: joining mesh via relay {relay_url} (routable leaf)");
        std::thread::spawn(move || dial_relay(relay_url, tx));
    } else {
        println!(
            "hop-telemetryd: no relay configured; not mesh-routable (will not receive telemetry)"
        );
    }

    // Managed OTLP export (best-effort, off the driver thread). Spawns an export worker draining a
    // bounded queue, so a slow/down tenant endpoint drops rather than stalling the meter (see below).
    let otlp_tx = setup_otlp(otlp_map_file, firestore.as_deref());

    run(node, domain, rx, otlp_tx, allow_unattributed);
}

/// One queued OTLP export: an attributed tenant + its batch, handed to the export worker off-thread.
type OtlpItem = (TenantId, TelemetryBatch);

/// Build the OTLP export queue + worker from the static `--otlp-map` file AND, when `--firestore` is
/// set, the per-tenant OTLP endpoints the account service projects into the tenant registry (so a
/// tenant that sets its endpoint in the console gets telemetry streamed without an operator file
/// edit). Live-only (the POST needs reqwest); without the feature there is no export and this returns
/// `None`, so `forward_telemetry` skips OTLP. Best-effort: the worker POSTs on its own thread and
/// counts failures, never touching the meter/ledger path.
#[cfg(feature = "live")]
fn setup_otlp(
    file: Option<String>,
    firestore: Option<&str>,
) -> Option<std::sync::mpsc::SyncSender<OtlpItem>> {
    #[cfg_attr(not(feature = "firestore"), allow(unused_mut))]
    let mut map = file
        .and_then(|p| std::fs::read_to_string(p).ok())
        .or_else(|| {
            std::env::var("HOP_OTLP_MAP")
                .ok()
                .and_then(|p| std::fs::read_to_string(p).ok())
        })
        .map(|text| otlp::OtlpEndpointMap::parse(&text))
        .unwrap_or_else(|| otlp::OtlpEndpointMap::parse(""));
    // Registry endpoints (https/SSRF-validated at the console write, 5a) win over a stale file line. A
    // read error is logged and the file endpoints are kept (fail-open, like the KeyServer).
    #[cfg(feature = "firestore")]
    if let Some(project) = firestore {
        for (tenant, endpoint) in load_registry_otlp(project) {
            map.insert(tenant, endpoint);
        }
    }
    #[cfg(not(feature = "firestore"))]
    let _ = firestore;
    if map.is_empty() {
        eprintln!("hop-telemetryd: no OTLP endpoints (file or registry); OTLP export off");
        return None;
    }
    let transport = match otlp::ReqwestOtlpTransport::new() {
        Ok(t) => t,
        Err(e) => {
            eprintln!("hop-telemetryd: {e}; OTLP export off");
            return None;
        }
    };
    let mapped = map.len();
    let sink = otlp::OtlpSink::new(transport, map);
    // Bounded: under a slow/down endpoint the queue fills and `forward_telemetry` drops (counted),
    // rather than blocking the single-owner driver on the POST.
    let (tx, rx) = std::sync::mpsc::sync_channel::<OtlpItem>(4096);
    std::thread::spawn(move || {
        let mut fails = 0u64;
        for (tenant, batch) in rx {
            // Panic-isolate each export so one bad batch can't permanently kill the worker (which
            // would silently disable export for the process and mislabel the resulting drops as
            // "endpoint slow"). The driver + meter already survive independently; this keeps the
            // worker alive too.
            let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                sink.export(&tenant, &batch)
            }));
            let reason = match outcome {
                Ok(otlp::ExportOutcome::Failed(e)) => Some(e),
                Ok(_) => None,
                Err(_) => Some("export panicked (isolated)".to_string()),
            };
            if let Some(e) = reason {
                fails = fails.saturating_add(1);
                if fails % 100 == 1 {
                    // Aggregate only (services-03): a count + a non-tenant-identifying reason.
                    eprintln!("hop-telemetryd: OTLP export failing ({fails} so far): {e}");
                }
            }
        }
    });
    println!("hop-telemetryd: OTLP export on ({mapped} tenant endpoint(s))");
    Some(tx)
}

/// Without the `live` feature there is no OTLP export path at all.
#[cfg(not(feature = "live"))]
fn setup_otlp(
    _file: Option<String>,
    _firestore: Option<&str>,
) -> Option<std::sync::mpsc::SyncSender<OtlpItem>> {
    None
}

// --- driver ------------------------------------------------------------------------------------

/// Events into the single-owner driver, from the inbound-nothing path and the outbound relay link.
enum Ev {
    Up(u64, Role, Sender<Vec<u8>>),
    Data(u64, Vec<u8>),
    Down(u64),
}

/// The driver: sole owner of the node. Drives the mesh link, drains received telemetry into the sink,
/// and re-signs the reach record before it expires. Every core call on attacker-controlled bytes runs
/// under [`guard_core`] so a malformed-bundle panic is a logged skip, not process death.
fn run<S: Store>(
    mut node: Node<S>,
    domain: Option<String>,
    rx: Receiver<Ev>,
    otlp_tx: Option<std::sync::mpsc::SyncSender<OtlpItem>>,
    allow_unattributed: bool,
) {
    let mut writers: HashMap<u64, Sender<Vec<u8>>> = HashMap::new();
    let mut sink = AggregateSink::default();
    let mut meter = TelemetryMeter::default();
    let mut otlp_dropped: u64 = 0;
    let public_url = domain.as_deref().map(public_url_for);
    let mut last_wk = Instant::now();
    let mut last_stats = Instant::now();
    let mut last_tick = Instant::now();
    let mut last_flush = Instant::now();
    loop {
        // Cloud Run is about to reap us: drain the meter into the ledger BEFORE flushing the store, so
        // the window's billable usage rides the same durable drain out instead of being lost (F-21).
        if SHUTDOWN.load(Ordering::SeqCst) {
            meter.flush_to_store(&mut node.store, now_ms());
            let flushed = node.store.flush(Duration::from_secs(8));
            println!(
                "hop-telemetryd: SIGTERM: ledger flush {}, exiting",
                if flushed { "drained" } else { "timed out" }
            );
            return;
        }
        match rx.recv_timeout(Duration::from_millis(1000)) {
            Ok(Ev::Up(link, role, out)) => {
                writers.insert(link, out);
                guard_core("bearer-connected", || {
                    node.handle(BearerEvent::Connected(link, role))
                });
            }
            Ok(Ev::Data(link, bytes)) => {
                guard_core("bearer-data", || {
                    node.handle(BearerEvent::Data(link, bytes))
                });
            }
            Ok(Ev::Down(link)) => {
                writers.remove(&link);
                guard_core("bearer-disconnected", || {
                    node.handle(BearerEvent::Disconnected(link))
                });
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break,
        }

        // Time-based node maintenance runs EVERY iteration (throttled to TICK_INTERVAL), not only on an
        // idle timeout, so a sustained inbound telemetry burst can't starve the clock or the re-sign.
        if last_tick.elapsed() >= TICK_INTERVAL {
            guard_core("tick", || node.tick(now_ms()));
            last_tick = Instant::now();
            if let Some(url) = &public_url {
                if last_wk.elapsed() >= WELL_KNOWN_RESIGN {
                    if let Ok(mut wk) = well_known_body().lock() {
                        *wk = sign_well_known(&node, url);
                    }
                    last_wk = Instant::now();
                }
            }
        }

        // Drain received telemetry into the sink. The batch was already decoded + DoS-bounded by the
        // core on receipt; take_telemetry itself parses no attacker bytes but is guarded for symmetry.
        let received = guard_core("take-telemetry", || node.take_telemetry()).unwrap_or_default();
        otlp_dropped = otlp_dropped.saturating_add(forward_telemetry(
            &mut sink,
            &mut meter,
            otlp_tx.as_ref(),
            received,
            allow_unattributed,
        ));

        // Aggregate throughput line (counts only, services-03).
        if last_stats.elapsed() >= STATS_LOG_INTERVAL {
            let (batches, events) = sink.take();
            if batches > 0 {
                println!(
                    "hop-telemetryd: {batches} batches, {events} events forwarded this window"
                );
            }
            if otlp_dropped > 0 {
                eprintln!(
                    "hop-telemetryd: {otlp_dropped} batch(es) dropped from the OTLP export queue this window (endpoint slow or down); billing unaffected"
                );
                otlp_dropped = 0;
            }
            last_stats = Instant::now();
        }

        // Merge per-tenant billable counts into the durable telemetry_usage ledger (§37 reconciler
        // reads it). Attribution is aggregate-only in the log (services-03: no per-tenant line).
        if last_flush.elapsed() >= TELEMETRY_FLUSH {
            let now = now_ms();
            meter.flush_to_store(&mut node.store, now);
            sweep_expired_telemetry_markers(&mut node.store, now);
            let unattributed = meter.take_unattributed();
            if unattributed > 0 {
                eprintln!(
                    "hop-telemetryd: {unattributed} unattributed events INGESTED UNBILLED this window (--allow-unattributed is on)"
                );
            }
            let refused = meter.take_refused();
            if refused > 0 {
                eprintln!(
                    "hop-telemetryd: {refused} events REFUSED this window (unattributable: unstamped, stale stamp, or no key server)"
                );
            }
            last_flush = Instant::now();
        }

        let outgoing = guard_core("drain-outgoing", || node.drain_outgoing()).unwrap_or_default();
        for (link, bytes) in outgoing {
            if let Some(out) = writers.get(&link) {
                if out.send(bytes).is_err() {
                    writers.remove(&link);
                }
            }
        }
    }
}

/// Bounded sweep to prune telemetry dedup markers older than MAX_ATTRIBUTION_AGE_EPOCHS + 1 hours
/// via list_kv_page, bounding the marker set to the 24 h attribution window (SVC-006).
pub fn sweep_expired_telemetry_markers<S: Store>(store: &mut S, now_ms: u64) -> usize {
    let now_epoch_hour = now_ms / 3_600_000;
    let cutoff_epoch_hour =
        now_epoch_hour.saturating_sub(hop_core::access::MAX_ATTRIBUTION_AGE_EPOCHS + 1);
    let mut deleted = 0;
    let mut cursor: Option<String> = None;
    const SWEEP_PAGE_LIMIT: usize = 100;
    const MAX_SWEEP_PAGES: usize = 50;
    let mut pages = 0;

    while pages < MAX_SWEEP_PAGES {
        pages += 1;
        let page = store.list_kv_page("telemetry_seen/", cursor.as_deref(), SWEEP_PAGE_LIMIT);
        if page.is_empty() {
            break;
        }
        let has_more = page.len() == SWEEP_PAGE_LIMIT;
        let last_key = page.last().map(|(k, _)| k.clone());
        for (key, _) in page {
            let mut parts = key.split('/');
            let prefix = parts.next();
            let epoch_str = parts.next();
            if prefix == Some("telemetry_seen") {
                if let Some(epoch) = epoch_str.and_then(|s| s.parse::<u64>().ok()) {
                    if epoch < cutoff_epoch_hour || epoch > now_epoch_hour {
                        let _ = store.remove_kv_critical(&key);
                        deleted += 1;
                    }
                }
            }
        }
        if !has_more {
            break;
        }
        cursor = last_key;
    }
    deleted
}

/// Hand each received batch to the sink (throughput), the meter (per-tenant billing), and, for
/// attributed batches, the OTLP export queue (managed forwarding). Split out of `run` so it's
/// unit-testable without the driver. Returns the number of batches DROPPED from the OTLP queue.
///
/// **Fail closed.** A batch with no tenant cannot be billed, so unless `allow_unattributed` is set
/// it is REFUSED outright: not sunk, not metered, not exported. Serving it would hand a tenant free
/// ingest and free managed export, which is exactly what a missing or typo'd `--key-server` used to
/// do silently. Refusals are counted so the operator sees the volume being turned away.
///
/// Ordering is load-bearing for accepted batches: `meter.add` (the authoritative billing path,
/// feeding the durable ledger) runs FIRST. The OTLP enqueue is a non-blocking `try_send`; a full
/// queue (a slow/down tenant endpoint backing up the export worker) drops the batch and is counted,
/// never blocking the meter. Same asymmetry as hop-billingd's `BillAndRecord`. Only attributed
/// batches can be routed at all, since an OTLP endpoint is resolved per tenant.
fn forward_telemetry(
    sink: &mut dyn TelemetrySink,
    meter: &mut TelemetryMeter,
    otlp_tx: Option<&std::sync::mpsc::SyncSender<OtlpItem>>,
    received: Vec<TelemetryIn>,
    allow_unattributed: bool,
) -> u64 {
    let mut dropped = 0u64;
    for t in &received {
        if t.tenant.is_none() && !allow_unattributed {
            meter.refuse(t.batch.billable_events());
            continue; // refused: no sink, no meter, no export
        }
        sink.record(t.from, &t.batch);
        let counts = TelemetryCounts {
            events: t.batch.billable_events(),
            payload_bytes: t.batch.payload_bytes(),
        };
        meter.add(t.tenant, counts); // authoritative; always runs first
        if let (Some(tx), Some(tenant)) = (otlp_tx, t.tenant) {
            if tx.try_send((tenant, t.batch.clone())).is_err() {
                dropped = dropped.saturating_add(1); // queue full or worker gone: best-effort drop
            }
        }
    }
    dropped
}

/// Run a node call that touches attacker-controlled bytes under catch_unwind, so a core panic (e.g.
/// on a malformed bundle) becomes a logged skip instead of tearing down the process. `node` is
/// `&mut`, so the closure is `AssertUnwindSafe`. Returns `None` if the call panicked (services
/// panic-isolation invariant).
fn guard_core<T>(what: &str, f: impl FnOnce() -> T) -> Option<T> {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(v) => Some(v),
        Err(_) => {
            // services-03: don't log the offending bytes; note the stage so the collector stays up.
            eprintln!("hop-telemetryd: core panic in {what}; skipped (collector stays up)");
            None
        }
    }
}

// --- inbound connection (WS bearer OR healthz/reach record) ------------------------------------

/// What a peeked connection is: a WebSocket upgrade (a hops:// bearer link), a plain HTTP request
/// (healthz / reach record), or nothing to serve (no bytes / a bare probe).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum PeekKind {
    WsUpgrade,
    Http,
    Empty,
}

/// Decide from the peeked head bytes whether we can classify yet, and how. `Some` once final:
/// `WsUpgrade` if the `upgrade: websocket` token is present, `Http` once the whole header block has
/// arrived with no upgrade token. `None` while still incomplete (peek again for a segmented handshake).
fn classify_head(head: &[u8]) -> Option<PeekKind> {
    let req = String::from_utf8_lossy(head).to_ascii_lowercase();
    if req.contains("upgrade: websocket") {
        return Some(PeekKind::WsUpgrade);
    }
    if req.contains("\r\n\r\n") || req.contains("\n\n") {
        return Some(PeekKind::Http);
    }
    None
}

/// Classify an inbound connection from a NON-consuming peek, robust to a handshake split across TCP
/// segments. Bounded by attempts + the socket read timeout; the peek never consumes, so the handler
/// re-reads the same bytes.
fn peek_kind(stream: &TcpStream) -> PeekKind {
    let mut head = [0u8; 2048];
    let mut last_n = 0usize;
    for attempt in 0..8 {
        match stream.peek(&mut head) {
            Ok(0) => return PeekKind::Empty,
            Ok(n) => {
                last_n = n;
                if let Some(kind) = classify_head(&head[..n]) {
                    return kind;
                }
                if n == head.len() {
                    break;
                }
            }
            Err(ref e)
                if e.kind() == std::io::ErrorKind::WouldBlock
                    || e.kind() == std::io::ErrorKind::TimedOut =>
            {
                if attempt == 0 && last_n == 0 {
                    return PeekKind::Empty;
                }
            }
            Err(_) => break,
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    if last_n > 0 {
        PeekKind::Http
    } else {
        PeekKind::Empty
    }
}

/// The WS config the inbound bearer accepts with: caps a single message AND frame at
/// [`MAX_FRAME_BYTES`] instead of tungstenite's 64 MiB default, so a peer can't push a giant frame.
fn bearer_ws_config() -> tungstenite::protocol::WebSocketConfig {
    tungstenite::protocol::WebSocketConfig::default()
        .max_message_size(Some(MAX_FRAME_BYTES))
        .max_frame_size(Some(MAX_FRAME_BYTES))
}

/// Handle one inbound connection: a WebSocket becomes a Hop bearer link (a device direct-dialing
/// telemetry); anything else is a plain HTTP request (healthz / reach record). We peek (non-consuming)
/// to decide, leaving the bytes for whichever handler takes over.
fn serve_conn(stream: TcpStream, ev_tx: &Sender<Ev>) {
    let _ = stream.set_nodelay(true);
    let _ = stream.set_read_timeout(Some(WS_HANDSHAKE_TIMEOUT));
    match peek_kind(&stream) {
        PeekKind::Http => {
            serve_http_min(stream);
            return;
        }
        PeekKind::WsUpgrade => {}
        PeekKind::Empty => return,
    }
    // SVC-013: Keep a bounded read timeout configured on the socket across tungstenite's
    // accept_with_config. Do NOT remove it (set_read_timeout(None)): an unauthenticated client
    // that sends `Upgrade: websocket` and then stalls must not block indefinitely and exhaust
    // connection slots (blocking /healthz). The steady-state WS loop resets its own 100ms
    // read timeout right after accept_with_config succeeds.
    let _ = stream.set_read_timeout(Some(WS_HANDSHAKE_TIMEOUT));

    let mut ws = match tungstenite::accept_with_config(stream, Some(bearer_ws_config())) {
        Ok(w) => w,
        Err(_) => return,
    };
    let _ = ws
        .get_ref()
        .set_read_timeout(Some(Duration::from_millis(100)));

    let link = NEXT_LINK.fetch_add(1, Ordering::Relaxed);
    let (out_tx, out_rx) = mpsc::channel::<Vec<u8>>();
    if ev_tx.send(Ev::Up(link, Role::Responder, out_tx)).is_err() {
        return;
    }
    'conn: loop {
        loop {
            match out_rx.try_recv() {
                Ok(bytes) => {
                    if ws.write(Message::Binary(bytes.into())).is_err() {
                        break 'conn;
                    }
                }
                Err(mpsc::TryRecvError::Empty) => break,
                Err(mpsc::TryRecvError::Disconnected) => break 'conn,
            }
        }
        if ws.flush().is_err() {
            break;
        }
        match ws.read() {
            Ok(Message::Binary(b)) => {
                if ev_tx.send(Ev::Data(link, b.to_vec())).is_err() {
                    break;
                }
            }
            Ok(Message::Close(_)) => break,
            Ok(_) => {}
            Err(tungstenite::Error::Io(e))
                if e.kind() == std::io::ErrorKind::WouldBlock
                    || e.kind() == std::io::ErrorKind::TimedOut => {}
            Err(_) => break,
        }
    }
    let _ = ev_tx.send(Ev::Down(link));
}

/// Serve a plain HTTP request: only `GET /healthz` and `GET /.well-known/hop`; everything else is 404.
/// Never touches the mesh. The request head is bounded ([`MAX_REQ_HEAD_BYTES`]) and read-timed-out.
fn serve_http_min(mut stream: TcpStream) {
    let Ok(clone) = stream.try_clone() else {
        return;
    };
    let mut reader = BufReader::new(clone.take(MAX_REQ_HEAD_BYTES));
    let mut line = String::new();
    if reader.read_line(&mut line).is_err() {
        return;
    }
    // Request line: "GET /path HTTP/1.1".
    let mut parts = line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let target = parts.next().unwrap_or("");
    let path = target.split(['?', '#']).next().unwrap_or("");

    let (code, ctype, body): (&str, &str, Vec<u8>) = if method.eq_ignore_ascii_case("GET")
        && path == "/healthz"
    {
        // A collector that cannot attribute anything is refusing every batch, so it is NOT
        // healthy even though the process is up. Report that, or the misconfiguration hides
        // behind a green probe until someone notices the telemetry never arrived.
        if !ingest_ready().load(Ordering::SeqCst) {
            (
                "503 Service Unavailable",
                "text/plain",
                b"hop-telemetryd: no tenant key server; every batch is refused (fail closed). \
                      Configure --key-server, or pass --allow-unattributed for local/dev."
                    .to_vec(),
            )
        } else if !store_healthy().load(Ordering::SeqCst) {
            (
                "503 Service Unavailable",
                "text/plain",
                b"hop-telemetryd: degraded store; durable telemetry_usage write failed\n".to_vec(),
            )
        } else {
            ("200 OK", "text/plain", b"ok\n".to_vec())
        }
    } else if method.eq_ignore_ascii_case("GET") && path == "/.well-known/hop" {
        let record = well_known_body()
            .lock()
            .map(|b| b.clone())
            .unwrap_or_default();
        if record.is_empty() {
            (
                "404 Not Found",
                "text/plain",
                b"hop-telemetryd: reach record not ready".to_vec(),
            )
        } else {
            ("200 OK", "application/json", record)
        }
    } else {
        (
            "404 Not Found",
            "text/plain",
            b"hop-telemetryd: not found".to_vec(),
        )
    };

    let header = format!(
        "HTTP/1.1 {code}\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let _ = stream.write_all(header.as_bytes());
    let _ = stream.write_all(&body);
    let _ = stream.flush();
}

// --- outbound relay dial (mesh attach) ---------------------------------------------------------

const RECONNECT_BASE: Duration = Duration::from_secs(5);
const RECONNECT_MAX: Duration = Duration::from_secs(60);
/// A connection must stay up at least this long to count as "good" and reset the backoff; a shorter
/// one is a flap (accept-then-close) and keeps the backoff climbing so a broken relay isn't hammered.
const MIN_GOOD_CONN: Duration = Duration::from_secs(10);

/// Backoff after `failures` consecutive failed dials: `BASE * 2^(failures-1)`, capped at MAX. A fresh
/// success resets to BASE. Pure + total, so it is unit-testable.
fn reconnect_backoff(failures: u32) -> Duration {
    if failures == 0 {
        return RECONNECT_BASE;
    }
    let base = RECONNECT_BASE.as_secs();
    let mult = 1u64.checked_shl(failures - 1).unwrap_or(u64::MAX);
    let secs = base.saturating_mul(mult).min(RECONNECT_MAX.as_secs());
    Duration::from_secs(secs)
}

/// Dial a relay over `wss://` and bridge it as a Hop bearer link (we are the Initiator), so this
/// collector is reachable by its address through the mesh. Reconnects with exponential backoff so a
/// dead relay isn't hammered every 5s.
fn dial_relay(url: String, ev_tx: Sender<Ev>) {
    use tungstenite::stream::MaybeTlsStream;
    let mut failures: u32 = 0;
    loop {
        match tungstenite::connect(&url) {
            Ok((mut ws, _resp)) => {
                eprintln!("hop-telemetryd: connected to relay {url}");
                let connected_at = Instant::now();
                // Non-blocking socket: a read MUST NOT block, or the loop never gets back to send our
                // outgoing Noise handshake msg1 (produced by the driver right after Ev::Up).
                match ws.get_ref() {
                    MaybeTlsStream::Plain(s) => {
                        let _ = s.set_nonblocking(true);
                    }
                    MaybeTlsStream::Rustls(t) => {
                        let _ = t.get_ref().set_nonblocking(true);
                    }
                    _ => {}
                }
                let link = NEXT_LINK.fetch_add(1, Ordering::Relaxed);
                let (out_tx, out_rx) = mpsc::channel::<Vec<u8>>();
                if ev_tx.send(Ev::Up(link, Role::Initiator, out_tx)).is_err() {
                    return;
                }
                'conn: loop {
                    // Flush any queued outgoing (handshake + bundles), retrying WouldBlock.
                    loop {
                        match out_rx.try_recv() {
                            Ok(bytes) => match ws.write(Message::Binary(bytes.into())) {
                                Ok(()) => {}
                                Err(tungstenite::Error::Io(e))
                                    if e.kind() == std::io::ErrorKind::WouldBlock => {}
                                Err(_) => break 'conn,
                            },
                            Err(mpsc::TryRecvError::Empty) => break,
                            Err(mpsc::TryRecvError::Disconnected) => break 'conn,
                        }
                    }
                    match ws.flush() {
                        Ok(()) => {}
                        Err(tungstenite::Error::Io(e))
                            if e.kind() == std::io::ErrorKind::WouldBlock => {}
                        Err(_) => break,
                    }
                    match ws.read() {
                        Ok(Message::Binary(b)) => {
                            if ev_tx.send(Ev::Data(link, b.to_vec())).is_err() {
                                return;
                            }
                        }
                        Ok(Message::Close(_)) => break,
                        Ok(_) => {}
                        Err(tungstenite::Error::Io(e))
                            if e.kind() == std::io::ErrorKind::WouldBlock
                                || e.kind() == std::io::ErrorKind::TimedOut =>
                        {
                            std::thread::sleep(Duration::from_millis(10));
                        }
                        Err(_) => break,
                    }
                }
                let _ = ev_tx.send(Ev::Down(link));
                // A connection that stayed up long enough is good (reset the backoff); a flap keeps it
                // climbing so an accept-then-close relay isn't reconnected every 5s forever.
                failures = if connected_at.elapsed() >= MIN_GOOD_CONN {
                    0
                } else {
                    failures.saturating_add(1)
                };
                std::thread::sleep(reconnect_backoff(failures));
            }
            Err(e) => {
                failures = failures.saturating_add(1);
                let wait = reconnect_backoff(failures);
                eprintln!(
                    "hop-telemetryd: relay {url} unreachable ({e}); mesh-unreachable, \
                     retry #{failures} in {}s",
                    wait.as_secs()
                );
                std::thread::sleep(wait);
            }
        }
    }
}

// --- identity ----------------------------------------------------------------------------------

/// Load a stable identity from a 32-byte file (so the collector's published address survives
/// restarts), generating and persisting one on first run.
///
/// STORE-006, SVC-014: If the identity file exists but is unreadable or not exactly 32 bytes,
/// the service fails loudly (panics) rather than silently rotating identity and overwriting
/// the corrupt file.
fn load_identity(path: &Option<String>) -> Identity {
    if let Some(path) = path {
        let p = std::path::Path::new(path);
        if p.exists() {
            match std::fs::read(path) {
                Ok(bytes) => match <[u8; 32]>::try_from(bytes.as_slice()) {
                    Ok(seed) => return Identity::from_secret_bytes(&seed),
                    Err(_) => panic!("--identity-file {path} must be exactly 32 bytes"),
                },
                Err(e) => panic!("--identity-file {path} unreadable: {e}"),
            }
        }
        let id = Identity::generate();
        if let Err(e) = write_secret_atomic(path, &id.to_secret_bytes()) {
            eprintln!(
                "warning: could not persist identity to {path}: {e}; address will change on restart"
            );
        }
        return id;
    }
    eprintln!("warning: no --identity-file; address will change on restart");
    Identity::generate()
}

/// Write `bytes` to `path` atomically with owner-only (0600) permissions.
/// Distinguishes EEXIST from absence, never truncates an existing file,
/// and fsyncs the file and parent directory.
fn write_secret_atomic(path: &str, bytes: &[u8]) -> std::io::Result<()> {
    let path = std::path::Path::new(path);
    if path.exists() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::AlreadyExists,
            format!("identity file {} already exists", path.display()),
        ));
    }
    let parent = path.parent().unwrap_or_else(|| std::path::Path::new("."));
    static COUNTER: AtomicU64 = AtomicU64::new(1);
    let tmp_name = format!(
        ".tmp.{}.{}.key",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    );
    let tmp_path = parent.join(tmp_name);

    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&tmp_path)?;
        f.write_all(bytes)?;
        f.sync_all()?;
    }
    #[cfg(not(unix))]
    {
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp_path)?;
        f.write_all(bytes)?;
        f.sync_all()?;
    }

    if let Err(e) = std::fs::rename(&tmp_path, path) {
        let _ = std::fs::remove_file(&tmp_path);
        return Err(e);
    }

    #[cfg(unix)]
    if let Ok(dir) = std::fs::File::open(parent) {
        let _ = dir.sync_all();
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn counts(events: u64, payload_bytes: u64) -> TelemetryCounts {
        TelemetryCounts {
            events,
            payload_bytes,
        }
    }

    struct DeferRemove(std::path::PathBuf);
    impl Drop for DeferRemove {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }

    #[test]
    #[should_panic(expected = "must be exactly 32 bytes")]
    fn load_identity_panics_on_short_identity_file() {
        // SVC-014: corrupt non-32-byte identity files must panic immediately
        let dir = std::env::temp_dir();
        let path = dir.join(format!("test_telemetryd_short_{}.key", std::process::id()));
        std::fs::write(&path, &[1u8; 31]).unwrap();
        let _guard = DeferRemove(path.clone());
        load_identity(&Some(path.to_str().unwrap().to_string()));
    }

    #[test]
    #[should_panic(expected = "must be exactly 32 bytes")]
    fn load_identity_panics_on_oversized_identity_file() {
        // SVC-014: corrupt non-32-byte identity files must panic immediately
        let dir = std::env::temp_dir();
        let path = dir.join(format!("test_telemetryd_long_{}.key", std::process::id()));
        std::fs::write(&path, &[1u8; 33]).unwrap();
        let _guard = DeferRemove(path.clone());
        load_identity(&Some(path.to_str().unwrap().to_string()));
    }

    #[test]
    fn load_identity_generates_and_persists_then_reloads_stable() {
        let dir = std::env::temp_dir();
        let path = dir.join(format!("test_telemetryd_persist_{}.key", std::process::id()));
        let _guard = DeferRemove(path.clone());
        let id1 = load_identity(&Some(path.to_str().unwrap().to_string()));
        let id2 = load_identity(&Some(path.to_str().unwrap().to_string()));
        assert_eq!(id1.address(), id2.address());
    }

    #[test]
    fn serve_conn_stalled_ws_upgrade_times_out_and_allows_healthz() {
        // SVC-013: A client that sends an incomplete WebSocket upgrade request must time out
        // and release the connection slot so that subsequent /healthz connections succeed.
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (ev_tx, _ev_rx) = mpsc::channel();

        let (done_tx, done_rx) = mpsc::channel();
        let ev_tx_clone = ev_tx.clone();

        let server = std::thread::spawn(move || {
            for _ in 0..2 {
                let (sock, _) = listener.accept().unwrap();
                if ACTIVE_CONNS.fetch_add(1, Ordering::SeqCst) >= MAX_CONNS {
                    ACTIVE_CONNS.fetch_sub(1, Ordering::SeqCst);
                    drop(sock);
                    continue;
                }
                let tx = ev_tx_clone.clone();
                let dt = done_tx.clone();
                std::thread::spawn(move || {
                    let _guard = ConnGuard;
                    serve_conn(sock, &tx);
                    let _ = dt.send(());
                });
            }
        });

        // Client 1: sends partial WS upgrade and stalls without completing headers
        let mut client1 = TcpStream::connect(addr).unwrap();
        client1
            .write_all(b"GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n")
            .unwrap();

        // Wait for server to time out client 1 and drop ConnGuard
        done_rx
            .recv_timeout(Duration::from_secs(3))
            .expect("stalled WS upgrade timed out");

        // Client 2: /healthz request must succeed immediately
        let mut client2 = TcpStream::connect(addr).unwrap();
        client2
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        client2
            .write_all(b"GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n")
            .unwrap();

        let mut resp = String::new();
        let mut buf = [0u8; 512];
        while let Ok(n) = client2.read(&mut buf) {
            if n == 0 {
                break;
            }
            resp.push_str(&String::from_utf8_lossy(&buf[..n]));
            if resp.contains("\r\n\r\n") {
                break;
            }
        }
        assert!(
            resp.starts_with("HTTP/1.1 200 OK") || resp.starts_with("HTTP/1.1 503 Service Unavailable"),
            "healthz responded after stalled client: {resp}"
        );
        drop(client1);
        server.join().unwrap();
    }

    #[test]
    fn sweep_expired_telemetry_markers_removes_future_and_expired_markers() {
        // SVC-012: sweep_expired_telemetry_markers must prune both expired markers (< cutoff)
        // and invalid future markers (> now), preventing permanent unprunable bloat.
        let mut store = MemoryStore::new();
        let now_ms = 1_000 * 3_600_000; // epoch 1000
        let now_epoch_hour = 1_000;
        let expired_epoch = now_epoch_hour - (hop_core::access::MAX_ATTRIBUTION_AGE_EPOCHS + 5);
        let valid_epoch = now_epoch_hour - 1;
        let future_epoch = now_epoch_hour + 500;

        store.put_kv(&format!("telemetry_seen/{expired_epoch}/id1"), vec![1]);
        store.put_kv(&format!("telemetry_seen/{valid_epoch}/id2"), vec![2]);
        store.put_kv(&format!("telemetry_seen/{future_epoch}/id3"), vec![3]);

        let deleted = sweep_expired_telemetry_markers(&mut store, now_ms);
        assert_eq!(deleted, 2, "both expired and future markers pruned");
        assert!(store.get_kv(&format!("telemetry_seen/{expired_epoch}/id1")).is_none());
        assert!(store.get_kv(&format!("telemetry_seen/{valid_epoch}/id2")).is_some());
        assert!(store.get_kv(&format!("telemetry_seen/{future_epoch}/id3")).is_none());
    }

    #[test]
    fn parse_args_defaults() {
        let c = parse_args(std::iter::empty());
        assert_eq!(c.listen, "0.0.0.0:9445");
        assert_eq!(c.domain, None);
        assert_eq!(c.relay.as_deref(), Some("wss://relay.hopme.sh/"));
        assert!(!c.relay_cli_set);
        assert!(!c.print_address);
    }

    #[test]
    fn parse_args_flags() {
        let args = [
            "--listen",
            "0.0.0.0:1234",
            "--domain",
            "telemetry.hopme.sh",
            "--no-relay",
            "--print-address",
        ]
        .into_iter()
        .map(String::from);
        let c = parse_args(args);
        assert_eq!(c.listen, "0.0.0.0:1234");
        assert_eq!(c.domain.as_deref(), Some("telemetry.hopme.sh"));
        assert_eq!(c.relay, None);
        assert!(c.relay_cli_set);
        assert!(c.print_address);
    }

    #[test]
    fn aggregate_sink_counts_and_resets() {
        let mut sink = AggregateSink::default();
        let addr = [7u8; 32];
        let batch = TelemetryBatch::new()
            .counter("hop.bundle.delivered", 1, 0)
            .gauge("hop.delivery.latency_ms", 42, 0);
        sink.record(addr, &batch);
        sink.record(addr, &TelemetryBatch::new().event("hop.spool.parked", 0));
        assert_eq!(sink.take(), (2, 3)); // 2 batches, 2 + 1 = 3 events
        assert_eq!(sink.take(), (0, 0)); // reset
    }

    #[test]
    fn forward_telemetry_feeds_the_sink_and_meters_by_tenant() {
        let mut sink = AggregateSink::default();
        let mut meter = TelemetryMeter::default();
        let tenant = [9u8; 16];
        let received = vec![
            TelemetryIn {
                from: [1u8; 32],
                batch: TelemetryBatch::new().counter("a", 1, 0),
                tenant: Some(tenant),
            },
            TelemetryIn {
                from: [2u8; 32],
                batch: TelemetryBatch::new().counter("b", 1, 0).counter("c", 1, 0),
                tenant: None, // unattributed
            },
        ];
        // --allow-unattributed ON: the legacy behaviour, both batches served.
        let dropped = forward_telemetry(&mut sink, &mut meter, None, received, true);
        assert_eq!(dropped, 0);
        assert_eq!(sink.take(), (2, 3)); // throughput: 2 batches, 3 events
        assert_eq!(meter.counts.get(&tenant).map(|c| c.events), Some(1));
        assert_eq!(meter.take_unattributed(), 2); // 2 unattributed events
        assert_eq!(
            meter.take_refused(),
            0,
            "nothing refused when the opt-out is on"
        );
    }

    #[test]
    fn forward_telemetry_enqueues_only_attributed_batches_for_otlp() {
        let mut sink = AggregateSink::default();
        let mut meter = TelemetryMeter::default();
        let tenant = [9u8; 16];
        let (tx, rx) = std::sync::mpsc::sync_channel::<OtlpItem>(16);
        let received = vec![
            TelemetryIn {
                from: [1u8; 32],
                batch: TelemetryBatch::new().counter("a", 1, 0),
                tenant: Some(tenant),
            },
            TelemetryIn {
                from: [2u8; 32],
                batch: TelemetryBatch::new().counter("b", 1, 0),
                tenant: None, // unattributed: metered aggregate-only, NOT forwarded
            },
        ];
        let dropped = forward_telemetry(&mut sink, &mut meter, Some(&tx), received, true);
        assert_eq!(dropped, 0);
        drop(tx);
        let queued: Vec<OtlpItem> = rx.iter().collect();
        assert_eq!(
            queued.len(),
            1,
            "only the attributed batch is queued for OTLP"
        );
        assert_eq!(queued[0].0, tenant);
    }

    #[test]
    fn forward_telemetry_drops_and_counts_when_the_otlp_queue_is_full() {
        let mut sink = AggregateSink::default();
        let mut meter = TelemetryMeter::default();
        let tenant = [9u8; 16];
        // Capacity 1, never drained: the second attributed batch has nowhere to go.
        let (tx, _rx) = std::sync::mpsc::sync_channel::<OtlpItem>(1);
        let received = vec![
            TelemetryIn {
                from: [1u8; 32],
                batch: TelemetryBatch::new().counter("a", 1, 0),
                tenant: Some(tenant),
            },
            TelemetryIn {
                from: [2u8; 32],
                batch: TelemetryBatch::new().counter("b", 1, 0),
                tenant: Some(tenant),
            },
        ];
        let dropped = forward_telemetry(&mut sink, &mut meter, Some(&tx), received, false);
        assert_eq!(dropped, 1, "full queue drops the overflow, best-effort");
        // Billing is unaffected: BOTH events still metered to the tenant.
        assert_eq!(meter.counts.get(&tenant).map(|c| c.events), Some(2));
    }

    #[test]
    fn telemetry_meter_flushes_per_tenant_rows_to_the_store_and_rmw_accumulates() {
        let mut store = MemoryStore::default();
        let now = 5 * 3_600_000 + 123; // hour 5
        let tenant = [7u8; 16];
        let mut meter = TelemetryMeter::default();
        meter.add(Some(tenant), counts(10, 100));
        meter.add(Some(tenant), counts(5, 50));
        meter.add(None, counts(3, 30));
        meter.flush_to_store(&mut store, now);
        let key = telemetry_usage_key(5, &tenant);
        assert_eq!(
            store.get_kv(&key).map(|b| decode_counts(&b)),
            Some(counts(15, 150))
        );
        assert!(meter.counts.is_empty(), "cleared after flush");
        // A second window RMW-adds into the same hour row.
        meter.add(Some(tenant), counts(4, 40));
        meter.flush_to_store(&mut store, now);
        assert_eq!(
            store.get_kv(&key).map(|b| decode_counts(&b)),
            Some(counts(19, 190))
        );
    }

    #[test]
    fn two_collector_processes_sharing_one_partition_compose_instead_of_clobbering() {
        // SVC-005 for the fourth prefix the invariant names. `FirestoreStore`'s read half answers
        // from the process-local in-memory copy (loaded at open) while writes mirror through to the
        // shared partition, so a read-modify-write on a SHARED row silently discards a concurrent
        // process's contribution. Model that asymmetry exactly: each handle opens on a snapshot of
        // the durable partition and its writes are mirrored back.
        let mut durable: std::collections::BTreeMap<String, Vec<u8>> =
            std::collections::BTreeMap::new();
        let tenant: TenantId = [3u8; 16];
        let hour = 900u64;
        let now = hour * 3_600_000 + 1_000;

        // A handle onto `durable`: eagerly loads the rows that exist NOW (the stale base).
        let open = |durable: &std::collections::BTreeMap<String, Vec<u8>>| {
            let mut s = MemoryStore::default();
            for (k, v) in durable.iter() {
                s.put_kv(k, v.clone());
            }
            s
        };
        // Mirror this handle's ledger rows out to the shared partition (the write-through half).
        let mirror =
            |s: &MemoryStore, durable: &mut std::collections::BTreeMap<String, Vec<u8>>| {
                for (k, v) in s.list_kv("telemetry_usage/") {
                    durable.insert(k, v);
                }
            };

        let old_key = |h: u64, t: &TenantId| telemetry_usage_key_for(h, t, "0000000000000001");
        let new_key = |h: u64, t: &TenantId| telemetry_usage_key_for(h, t, "0000000000000002");

        // The OLD instance opens first and flushes 10 events / 100 bytes.
        let mut old = open(&durable);
        let mut old_meter = TelemetryMeter::default();
        old_meter.add(Some(tenant), counts(10, 100));
        old_meter.flush_to_store_with(&mut old, now, old_key);
        mirror(&old, &mut durable);

        // The NEW instance opens while the old one is still serving and flushes 25 / 250. Its write
        // lands FIRST; the old instance then flushes again from its own stale in-memory base.
        let mut new = open(&durable);
        let mut new_meter = TelemetryMeter::default();
        new_meter.add(Some(tenant), counts(25, 250));
        new_meter.flush_to_store_with(&mut new, now, new_key);
        mirror(&new, &mut durable);

        old_meter.add(Some(tenant), counts(5, 50));
        old_meter.flush_to_store_with(&mut old, now, old_key);
        mirror(&old, &mut durable);

        // Sum the hour the way hop-billingd's reconciler does: duplicate (hour, tenant) rows are
        // summed across sources. Against the pre-fix single-row key this asserts 40 and finds 15.
        let want = format!(
            "telemetry_usage/{hour}/{}",
            tenant
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>()
        );
        let mut total = TelemetryCounts::default();
        for (key, value) in durable.iter() {
            if key == &want || key.starts_with(&format!("{want}/")) {
                total.add(&decode_counts(value));
            }
        }
        assert_eq!(
            total,
            counts(40, 400),
            "the partition total must be the sum of every writer's flush, not the last writer's view"
        );
    }

    #[test]
    fn the_collector_writer_segment_is_a_well_formed_16_hex_id_and_is_stable_in_process() {
        // hop-billingd only accepts exactly 16 lowercase-hex chars as the 4th segment, so a
        // malformed id here would make every row this collector writes unbillable.
        let id = ledger_writer_id();
        assert_eq!(id.len(), 16, "writer id is 16 hex chars: {id}");
        assert!(
            id.bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
            "writer id is lowercase hex: {id}"
        );
        assert_eq!(id, ledger_writer_id(), "minted once per process");
        let key = telemetry_usage_key(5, &[4u8; 16]);
        assert!(key.ends_with(&format!("/{id}")), "writer-scoped: {key}");
        assert_eq!(key.split('/').count(), 4, "exactly four segments: {key}");
    }

    /// Pump two nodes against each other over a synthetic bearer link until quiet: exactly what the
    /// driver's `handle`/`drain_outgoing` loop does, so the Noise handshake and bundle delivery are
    /// the real paths, not a stub.
    fn pump<A: Store, B: Store>(a: &mut Node<A>, b: &mut Node<B>) {
        const LINK: u64 = 1;
        a.handle(BearerEvent::Connected(LINK, Role::Initiator));
        b.handle(BearerEvent::Connected(LINK, Role::Responder));
        for _ in 0..40 {
            let mut moved = false;
            for (_, bytes) in a.drain_outgoing() {
                b.handle(BearerEvent::Data(LINK, bytes));
                moved = true;
            }
            for (_, bytes) in b.drain_outgoing() {
                a.handle(BearerEvent::Data(LINK, bytes));
                moved = true;
            }
            if !moved {
                break;
            }
        }
    }

    /// A device that stamps everything it originates with `tenant`, plus the key server a collector
    /// needs to verify those stamps.
    fn stamping_device(tenant: TenantId, now: u64) -> (Node<MemoryStore>, KeyServer) {
        let key = Identity::generate();
        let mut device = Node::new(Identity::generate());
        device.set_time(now);
        device.set_stamper(Some(Stamper::new(
            tenant,
            Identity::from_secret_bytes(&key.to_secret_bytes()),
        )));
        let mut server = KeyServer::new();
        server.insert(tenant, key.address());
        (device, server)
    }

    #[test]
    fn the_assembled_collector_node_actually_ingests_telemetry() {
        // THE regression test for the live bug. It exercises `configure_collector_node`, the node
        // the daemon really builds, rather than `forward_telemetry` on a hand-made `TelemetryIn`.
        // Before the fix this failed: set_kind(Endpoint) left the app payload policy without the
        // Telemetry bit, so the core's ingest gate dropped every batch and take_telemetry was empty.
        // The old unit tests all passed anyway because they either built a default Device-kind node
        // or skipped the node entirely, which is precisely why CI never caught it.
        let tenant: TenantId = [4u8; 16];
        let now = 900 * CARRIAGE_EPOCH_MS + 7;
        let (mut device, server) = stamping_device(tenant, now);

        let mut collector: Node<MemoryStore> = Node::new(Identity::generate());
        collector.set_time(now);
        let attributed = configure_collector_node(
            &mut collector,
            Some("telemetry.hopme.sh".to_string()),
            Some(server),
        );
        assert!(attributed, "a key server means tenant attribution is on");
        assert!(
            collector.telemetry_ingest(),
            "the assembled collector must accept telemetry"
        );

        let batch = TelemetryBatch::new()
            .with_resource("platform", "ios")
            .counter("hop.bundle.delivered", 1, now)
            .gauge("hop.delivery.latency_ms", 2100, now);
        device.send_telemetry(collector.address(), &batch).unwrap();
        pump(&mut device, &mut collector);

        let received = collector.take_telemetry();
        assert_eq!(received.len(), 1, "the batch reached the collector");
        assert_eq!(received[0].batch, batch);
        assert_eq!(
            received[0].tenant,
            Some(tenant),
            "and it is attributed to the stamping tenant, so it can be billed"
        );

        // And it survives the daemon's own forwarding path into the ledger, fail-closed.
        let mut sink = AggregateSink::default();
        let mut meter = TelemetryMeter::default();
        forward_telemetry(&mut sink, &mut meter, None, received, false);
        assert_eq!(meter.counts.get(&tenant).map(|c| c.events), Some(2));
        assert_eq!(meter.take_refused(), 0);
    }

    #[test]
    fn a_collector_without_a_key_server_refuses_rather_than_serving_free() {
        // Fail closed: no key server means nothing attributes, and unattributable telemetry must be
        // refused instead of ingested and exported unbilled.
        let tenant: TenantId = [5u8; 16];
        let now = 901 * CARRIAGE_EPOCH_MS + 7;
        let (mut device, _server) = stamping_device(tenant, now);

        let mut collector: Node<MemoryStore> = Node::new(Identity::generate());
        collector.set_time(now);
        let attributed = configure_collector_node(&mut collector, None, None);
        assert!(!attributed, "no key server, no attribution");

        let batch = TelemetryBatch::new().counter("hop.bundle.delivered", 1, now);
        device.send_telemetry(collector.address(), &batch).unwrap();
        pump(&mut device, &mut collector);

        let received = collector.take_telemetry();
        assert_eq!(received.len(), 1, "it arrives at the node");
        assert_eq!(received[0].tenant, None, "but attributes to nobody");

        // Fail-closed (the default): refused outright.
        let mut sink = AggregateSink::default();
        let mut meter = TelemetryMeter::default();
        let dropped = forward_telemetry(&mut sink, &mut meter, None, received.clone(), false);
        assert_eq!(dropped, 0);
        assert_eq!(meter.take_refused(), 1, "refused, not served");
        assert_eq!(sink.take(), (0, 0), "not even counted as throughput");
        assert!(meter.counts.is_empty());
        assert_eq!(meter.take_unattributed(), 0);
        let mut store = MemoryStore::default();
        meter.flush_to_store(&mut store, now);
        assert!(
            store
                .get_kv(&telemetry_usage_key(now / 3_600_000, &tenant))
                .is_none(),
            "nothing reaches the ledger"
        );

        // --allow-unattributed: the deliberate dev escape hatch, served but visibly unbilled.
        let mut sink = AggregateSink::default();
        let mut meter = TelemetryMeter::default();
        forward_telemetry(&mut sink, &mut meter, None, received, true);
        assert_eq!(meter.take_refused(), 0);
        assert_eq!(
            meter.take_unattributed(),
            1,
            "served, and counted as unbilled"
        );
        assert_eq!(sink.take(), (1, 1));
    }

    #[test]
    fn parse_args_allow_unattributed_defaults_off() {
        assert!(!parse_args(std::iter::empty()).allow_unattributed);
        let c = parse_args(["--allow-unattributed"].into_iter().map(String::from));
        assert!(c.allow_unattributed);
    }

    #[test]
    fn the_ledger_row_is_16_bytes_and_still_reads_legacy_8_byte_rows() {
        // The write contract hop-billingd::ledger mirrors. A pre-upgrade 8-byte row must keep its
        // events through the read-modify-write, or upgrading the collector silently zeroes the hour.
        let c = counts(7, 700);
        let encoded = encode_counts(&c);
        assert_eq!(encoded.len(), 16);
        assert_eq!(decode_counts(&encoded), c);
        // Legacy 8-byte (events-only) row.
        assert_eq!(decode_counts(&9u64.to_le_bytes()), counts(9, 0));
        // Corruption reads as zero, the producer convention.
        assert_eq!(decode_counts(b"xyz"), TelemetryCounts::default());

        // The RMW over a legacy row preserves the old events and starts counting bytes.
        let mut store = MemoryStore::default();
        let tenant = [1u8; 16];
        let key = telemetry_usage_key(3, &tenant);
        store.put_kv(&key, 100u64.to_le_bytes().to_vec()); // legacy row
        let mut meter = TelemetryMeter::default();
        meter.add(Some(tenant), counts(5, 500));
        meter.flush_to_store(&mut store, 3 * 3_600_000);
        assert_eq!(
            store.get_kv(&key).map(|b| decode_counts(&b)),
            Some(counts(105, 500)),
            "legacy events carried forward, bytes accumulate from now on"
        );
    }

    #[test]
    fn payload_bytes_are_metered_not_just_event_counts() {
        // Why FIX 4 exists: two batches with identical event counts, wildly different real cost.
        let tenant: TenantId = [6u8; 16];
        let fat = TelemetryBatch::new().push(
            hop_core::telemetry::Record::counter("x", 1, 0)
                .with_attr("k", &"v".repeat(hop_core::telemetry::MAX_STR)),
        );
        let thin = TelemetryBatch::new().counter("x", 1, 0);
        let mut sink = AggregateSink::default();
        let mut meter = TelemetryMeter::default();
        forward_telemetry(
            &mut sink,
            &mut meter,
            None,
            vec![
                TelemetryIn {
                    from: [1u8; 32],
                    batch: thin,
                    tenant: Some(tenant),
                },
                TelemetryIn {
                    from: [2u8; 32],
                    batch: fat,
                    tenant: Some(tenant),
                },
            ],
            false,
        );
        let c = meter.counts.get(&tenant).copied().expect("metered");
        assert_eq!(c.events, 2, "event count cannot tell them apart");
        assert!(
            c.payload_bytes > 130,
            "but the byte measure can: {}",
            c.payload_bytes
        );
    }

    fn tmp_db(tag: &str) -> String {
        format!(
            "{}/hop-telemetryd-test-{tag}.db",
            std::env::temp_dir().display()
        )
    }

    #[test]
    fn build_store_opens_a_usable_local_sqlite_store() {
        let db = tmp_db("plain");
        let _ = std::fs::remove_file(&db);
        let addr = Identity::generate().address();
        let store = build_store(&None, &db, &addr);
        let _node = Node::with_store(Identity::generate(), store);
        assert!(std::fs::metadata(&db).is_ok(), "sqlite db file created");
        let _ = std::fs::remove_file(&db);
    }

    #[cfg(not(feature = "firestore"))]
    #[test]
    fn build_store_falls_back_to_sqlite_without_the_firestore_feature() {
        // A mis-flagged plain build must still come up with a working store, not fail.
        let db = tmp_db("fallback");
        let _ = std::fs::remove_file(&db);
        let addr = Identity::generate().address();
        let _store = build_store(&Some("some-gcp-project".to_string()), &db, &addr);
        assert!(std::fs::metadata(&db).is_ok(), "fell back to local sqlite");
        let _ = std::fs::remove_file(&db);
    }

    #[test]
    fn telemetry_ledger_round_trips_through_the_durable_store() {
        // The point of the durable store: a flushed telemetry_usage row is readable back out, so the
        // §37 reconciler can bill it. (Firestore adds cross-instance durability; SQLite proves the
        // same kv path, which an in-memory store would silently no-op.)
        let db = tmp_db("ledger");
        let _ = std::fs::remove_file(&db);
        let addr = Identity::generate().address();
        let mut store = build_store(&None, &db, &addr);
        let tenant = [3u8; 16];
        let now = 9 * 3_600_000;
        let mut meter = TelemetryMeter::default();
        meter.add(Some(tenant), counts(42, 420));
        meter.flush_to_store(&mut store, now);
        assert_eq!(
            store
                .get_kv(&telemetry_usage_key(9, &tenant))
                .map(|b| decode_counts(&b)),
            Some(counts(42, 420)),
            "the ledger row survives the durable store round trip"
        );
        let _ = std::fs::remove_file(&db);
    }

    #[test]
    fn build_key_server_is_none_without_any_source() {
        // No file and no firestore project -> Open (unattributed), never a bogus empty keyed policy.
        assert!(build_key_server(None, None).is_none());
    }

    #[test]
    fn parse_tenant_hex_round_trips_and_rejects_bad_input() {
        assert_eq!(
            parse_tenant_hex("000102030405060708090a0b0c0d0e0f"),
            Some([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15])
        );
        assert_eq!(parse_tenant_hex("07"), None); // too short
        assert_eq!(parse_tenant_hex("zz0102030405060708090a0b0c0d0e0f"), None); // non-hex
    }

    #[test]
    fn backoff_grows_then_caps() {
        assert_eq!(reconnect_backoff(0), RECONNECT_BASE);
        assert_eq!(reconnect_backoff(1), Duration::from_secs(5));
        assert_eq!(reconnect_backoff(2), Duration::from_secs(10));
        assert_eq!(reconnect_backoff(4), Duration::from_secs(40));
        assert_eq!(reconnect_backoff(99), RECONNECT_MAX); // saturates at the cap
    }

    #[test]
    fn well_known_body_is_signed_json_with_address_and_reach() {
        let mut node: Node<MemoryStore> = Node::new(Identity::generate());
        node.tick(now_ms());
        let body = sign_well_known(&node, &public_url_for("telemetry.hopme.sh"));
        let s = String::from_utf8(body).unwrap();
        assert!(s.contains("\"address\":\""));
        assert!(s.contains("\"endpoint\":\"wss://telemetry.hopme.sh/\""));
        assert!(s.contains("\"reach\":\""));
    }

    #[test]
    fn sanitize_domain_strips_unsafe_chars() {
        assert_eq!(sanitize_domain("Telemetry.HopMe.SH."), "telemetry.hopme.sh");
        // A double-quote can never reach the hand-built reach-record JSON.
        assert_eq!(sanitize_domain("bad\".com"), "bad.com");
        assert_eq!(sanitize_domain("a b/c"), "abc");
    }

    #[test]
    fn classify_head_detects_ws_vs_http() {
        assert_eq!(
            classify_head(b"GET / HTTP/1.1\r\nUpgrade: websocket\r\n\r\n"),
            Some(PeekKind::WsUpgrade)
        );
        assert_eq!(
            classify_head(b"GET /healthz HTTP/1.1\r\n\r\n"),
            Some(PeekKind::Http)
        );
        // Incomplete head (no terminator, no upgrade token): peek again.
        assert_eq!(classify_head(b"GET /healthz HTTP/1.1\r\n"), None);
    }

    /// The fail-closed posture must be VISIBLE. A collector that can attribute nothing refuses every
    /// batch, so its health probe has to say so; otherwise Cloud Run sees a green service that
    /// silently ingests nothing and the first symptom is missing telemetry, not an alert.
    #[test]
    fn healthz_reports_unhealthy_while_no_batch_can_be_served() {
        use std::io::{Read as _, Write as _};
        use std::net::{TcpListener, TcpStream};

        fn probe() -> String {
            let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
            let addr = listener.local_addr().expect("addr");
            let server = std::thread::spawn(move || {
                if let Ok((stream, _)) = listener.accept() {
                    serve_http_min(stream);
                }
            });
            let mut client = TcpStream::connect(addr).expect("connect");
            client
                .write_all(b"GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n")
                .expect("write");
            let mut out = String::new();
            let _ = client.read_to_string(&mut out);
            let _ = server.join();
            out
        }

        // Misconfigured: no key server and no explicit opt-in, so every batch is refused.
        store_healthy().store(true, Ordering::SeqCst);
        ingest_ready().store(false, Ordering::SeqCst);
        let refused = probe();
        assert!(
            refused.starts_with("HTTP/1.1 503"),
            "a collector refusing every batch must fail its probe, got: {refused}"
        );
        assert!(
            refused.contains("key server"),
            "the body must say WHY, got: {refused}"
        );

        // Attributing (or deliberately serving unattributed) telemetry is healthy.
        ingest_ready().store(true, Ordering::SeqCst);
        let ok = probe();
        assert!(
            ok.starts_with("HTTP/1.1 200"),
            "a working collector must pass its probe, got: {ok}"
        );
    }

    // --- STORE-005 hostile regression tests --------------------------------------------------

    #[test]
    fn store_005_hostile_telemetry_flush_failure_discards_drained_meter_counts_and_hides_from_healthz(
    ) {
        use hop_core::store::{KvMutation, Store};

        struct FailingStore(hop_core::store::MemoryStore);
        impl Store for FailingStore {
            fn put(&mut self, b: Bundle, now: u64) -> bool {
                self.0.put(b, now)
            }
            fn get(&self, id: &BundleId) -> Option<Bundle> {
                self.0.get(id)
            }
            fn remove(&mut self, id: &BundleId) -> Option<Bundle> {
                self.0.remove(id)
            }
            fn seen(&self, id: &BundleId) -> bool {
                self.0.seen(id)
            }
            fn contains(&self, id: &BundleId) -> bool {
                self.0.contains(id)
            }
            fn have(&self) -> hop_core::store::HaveSet {
                self.0.have()
            }
            fn prune(&mut self, now: u64) {
                self.0.prune(now);
            }
            fn put_kv(&mut self, _key: &str, _value: Vec<u8>) {}
            fn apply_kv_batch(
                &mut self,
                _mutations: &[KvMutation],
            ) -> std::result::Result<(), String> {
                Err("disk full / firestore unavailable".into())
            }
        }

        let mut meter = TelemetryMeter::default();
        let tenant: TenantId = [42u8; 16];
        meter.add(
            Some(tenant),
            TelemetryCounts {
                events: 100,
                payload_bytes: 4096,
            },
        );

        assert_eq!(meter.counts.len(), 1);

        let mut store = FailingStore(hop_core::store::MemoryStore::new());
        meter.flush_to_store(&mut store, 3_600_000);

        // On the unfixed tree:
        // 1. meter.counts was drained unconditionally by self.counts.drain(), so meter.counts is EMPTY!
        // 2. store_healthy() was not tracked or /healthz was not set to unhealthy!
        assert!(
            !meter.counts.is_empty(),
            "STORE-005 failure: drained meter counts were lost after store write failure"
        );
        assert_eq!(
            meter.counts.get(&tenant).copied(),
            Some(TelemetryCounts {
                events: 100,
                payload_bytes: 4096,
            }),
            "unwritten tenant counts must be retained in retry buffer"
        );
        assert!(!store_healthy().load(Ordering::SeqCst));
        store_healthy().store(true, Ordering::SeqCst);
    }

    // --- SVC-006 regression tests -----------------------------------------------------------

    #[derive(Clone, Default)]
    struct SharedMirrorState {
        kv: std::sync::Arc<std::sync::Mutex<std::collections::BTreeMap<String, Vec<u8>>>>,
    }

    struct SimulatedPartitionStore {
        inner: hop_core::store::MemoryStore,
        remote: SharedMirrorState,
        _eager_cap: usize,
    }

    impl Store for SimulatedPartitionStore {
        fn put(&mut self, b: Bundle, now: u64) -> bool {
            self.inner.put(b, now)
        }
        fn get(&self, id: &BundleId) -> Option<Bundle> {
            self.inner.get(id)
        }
        fn remove(&mut self, id: &BundleId) -> Option<Bundle> {
            self.inner.remove(id)
        }
        fn seen(&self, id: &BundleId) -> bool {
            self.inner.seen(id)
        }
        fn contains(&self, id: &BundleId) -> bool {
            self.inner.contains(id)
        }
        fn have(&self) -> hop_core::store::HaveSet {
            self.inner.have()
        }
        fn prune(&mut self, now: u64) {
            self.inner.prune(now);
        }
        fn put_kv(&mut self, key: &str, value: Vec<u8>) {
            self.remote
                .kv
                .lock()
                .unwrap()
                .insert(key.to_string(), value.clone());
            self.inner.put_kv(key, value);
        }
        fn apply_kv_batch(
            &mut self,
            mutations: &[hop_core::store::KvMutation],
        ) -> std::result::Result<(), String> {
            for m in mutations {
                if let hop_core::store::KvMutation::Put { key, value } = m {
                    self.remote
                        .kv
                        .lock()
                        .unwrap()
                        .insert(key.clone(), value.clone());
                } else if let hop_core::store::KvMutation::Remove { key } = m {
                    self.remote.kv.lock().unwrap().remove(key);
                }
            }
            self.inner.apply_kv_batch(mutations)
        }
        fn put_kv_critical(
            &mut self,
            key: &str,
            value: Vec<u8>,
        ) -> std::result::Result<(), String> {
            self.remote
                .kv
                .lock()
                .unwrap()
                .insert(key.to_string(), value.clone());
            self.inner.put_kv_critical(key, value)
        }
        fn get_kv(&self, key: &str) -> Option<Vec<u8>> {
            if let Some(val) = self.inner.get_kv(key) {
                return Some(val);
            }
            // Remote read-through for exempt/lazy prefixes like telemetry_seen/
            if key.starts_with("telemetry_seen/") {
                return self.remote.kv.lock().unwrap().get(key).cloned();
            }
            None
        }
        fn put_kv_if_absent_critical(
            &mut self,
            key: &str,
            value: Vec<u8>,
        ) -> std::result::Result<bool, String> {
            if self.inner.get_kv(key).is_some() {
                return Ok(false);
            }
            let mut remote = self.remote.kv.lock().unwrap();
            if let Some(existing) = remote.get(key) {
                self.inner.put_kv(key, existing.clone());
                return Ok(false);
            }
            remote.insert(key.to_string(), value.clone());
            self.inner.put_kv(key, value);
            Ok(true)
        }
        fn list_kv_page(
            &self,
            prefix: &str,
            after: Option<&str>,
            limit: usize,
        ) -> Vec<(String, Vec<u8>)> {
            let remote = self.remote.kv.lock().unwrap();
            remote
                .iter()
                .filter(|(k, _)| k.starts_with(prefix) && after.is_none_or(|cur| k.as_str() > cur))
                .take(limit)
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect()
        }
        fn remove_kv_critical(&mut self, key: &str) -> std::result::Result<(), String> {
            self.remote.kv.lock().unwrap().remove(key);
            self.inner.remove_kv_critical(key)
        }
    }

    impl SimulatedPartitionStore {
        fn open(remote: SharedMirrorState, eager_cap: usize) -> Self {
            let mut inner = hop_core::store::MemoryStore::new();
            let remote_guard = remote.kv.lock().unwrap();
            let mut loaded = 0;
            for (k, v) in remote_guard.iter() {
                // telemetry_seen keys are exempt from eager KV admission
                if k.starts_with("telemetry_seen/") {
                    continue;
                }
                if loaded < eager_cap {
                    inner.put_kv(k, v.clone());
                    loaded += 1;
                }
            }
            drop(remote_guard);
            Self {
                inner,
                remote,
                _eager_cap: eager_cap,
            }
        }
    }

    #[test]
    fn svc_006_two_instances_over_shared_mirror_does_not_double_meter() {
        let collector_id = Identity::generate();
        let collector_seed = collector_id.to_secret_bytes();
        let shared_remote = SharedMirrorState::default();
        let now = 1_000_000u64;

        // Instance A connects to partition
        let mut instance_a = Node::with_store(
            Identity::from_secret_bytes(&collector_seed),
            SimulatedPartitionStore::open(shared_remote.clone(), 100),
        );
        instance_a.set_time(now);
        configure_collector_node(&mut instance_a, None, None);

        let batch = TelemetryBatch::new().counter("test.events", 5, now);
        let bundle = Bundle::create(
            &Identity::generate(),
            Destination::Device(collector_id.address()),
            &collector_id.address(),
            &Payload::ServiceRequest {
                service: hop_core::node::SERVICE_TELEMETRY.into(),
                method: "export".into(),
                args: batch.to_bytes(),
            },
            BundleOpts::default(),
        )
        .unwrap();

        // Instance A receives bundle and meters it
        instance_a.ingest(bundle.clone());
        let received_a = instance_a.take_telemetry();
        assert_eq!(
            received_a.len(),
            1,
            "Instance A must accept initial delivery"
        );

        // Instance B runs concurrently over the same partition, with its own in-memory state
        let mut instance_b = Node::with_store(
            Identity::from_secret_bytes(&collector_seed),
            SimulatedPartitionStore::open(shared_remote.clone(), 100),
        );
        instance_b.set_time(now + 100);
        configure_collector_node(&mut instance_b, None, None);

        // Instance B receives the exact same bundle
        instance_b.ingest(bundle);
        let received_b = instance_b.take_telemetry();
        assert!(
            received_b.is_empty(),
            "SVC-006 failure: Instance B double-metered a bundle already processed by Instance A"
        );
    }

    #[test]
    fn svc_006_restart_with_eager_cap_reached_still_dedups() {
        let collector_id = Identity::generate();
        let collector_seed = collector_id.to_secret_bytes();
        let shared_remote = SharedMirrorState::default();

        // Saturate eager KV capacity with session keys
        let eager_cap = 5usize;
        for i in 0..eager_cap {
            shared_remote
                .kv
                .lock()
                .unwrap()
                .insert(format!("session/peer_{i}"), vec![i as u8; 32]);
        }

        let now = 1_000_000u64;
        let mut node = Node::with_store(
            Identity::from_secret_bytes(&collector_seed),
            SimulatedPartitionStore::open(shared_remote.clone(), eager_cap),
        );
        node.set_time(now);
        configure_collector_node(&mut node, None, None);

        let batch = TelemetryBatch::new().counter("test.events", 10, now);
        let bundle = Bundle::create(
            &Identity::generate(),
            Destination::Device(collector_id.address()),
            &collector_id.address(),
            &Payload::ServiceRequest {
                service: hop_core::node::SERVICE_TELEMETRY.into(),
                method: "export".into(),
                args: batch.to_bytes(),
            },
            BundleOpts::default(),
        )
        .unwrap();

        // First delivery admitted
        node.ingest(bundle.clone());
        let received = node.take_telemetry();
        assert_eq!(received.len(), 1, "first delivery accepted");

        // Simulate cold restart with eager cap already full
        let mut restarted = Node::with_store(
            Identity::from_secret_bytes(&collector_seed),
            SimulatedPartitionStore::open(shared_remote.clone(), eager_cap),
        );
        restarted.set_time(now + 2000);
        configure_collector_node(&mut restarted, None, None);

        // Replay bundle to restarted node: must dedup even though eager cap was reached on cold open
        restarted.ingest(bundle);
        let replayed = restarted.take_telemetry();
        assert!(
            replayed.is_empty(),
            "SVC-006 failure: restarted node with saturated eager KV cap failed to dedup replayed bundle"
        );
    }

    #[test]
    fn svc_006_sweep_bounds_total_markers() {
        let mut store = hop_core::store::MemoryStore::new();
        let base_hour = 30u64;
        let now_ms = base_hour * 3_600_000;

        // Seed markers from hour 0 to hour 30 (31 markers)
        for hour in 0..=base_hour {
            let key = format!("telemetry_seen/{hour}/marker_{hour}");
            store.put_kv_critical(&key, vec![1, 2, 3]).unwrap();
        }

        assert_eq!(store.list_kv_page("telemetry_seen/", None, 100).len(), 31);

        // Sweep at hour 30. MAX_ATTRIBUTION_AGE_EPOCHS is 24, so cutoff is 30 - 25 = 5.
        // Markers for hours 0..4 (5 markers) should be deleted.
        // Markers for hours 5..30 (26 markers) should remain.
        let deleted = sweep_expired_telemetry_markers(&mut store, now_ms);
        assert_eq!(deleted, 5, "sweep must prune exactly 5 expired markers");

        for hour in 0..5 {
            let key = format!("telemetry_seen/{hour}/marker_{hour}");
            assert!(store.get_kv(&key).is_none(), "hour {hour} must be pruned");
        }
        for hour in 5..=base_hour {
            let key = format!("telemetry_seen/{hour}/marker_{hour}");
            assert!(store.get_kv(&key).is_some(), "hour {hour} must be retained");
        }
        assert_eq!(store.list_kv_page("telemetry_seen/", None, 100).len(), 26);
    }

    #[test]
    fn svc_006_sqlite_telemetry_replay_after_restart_does_not_double_meter() {
        let db = tmp_db("svc006-restart");
        let _ = std::fs::remove_file(&db);

        let collector_id = Identity::generate();
        let collector_seed = collector_id.to_secret_bytes();
        let now = 1_000_000u64;

        let batch = TelemetryBatch::new().counter("test.events", 5, now);
        let bundle = Bundle::create(
            &Identity::generate(),
            Destination::Device(collector_id.address()),
            &collector_id.address(),
            &Payload::ServiceRequest {
                service: hop_core::node::SERVICE_TELEMETRY.into(),
                method: "export".into(),
                args: batch.to_bytes(),
            },
            BundleOpts::default(),
        )
        .unwrap();

        // Open SQLite store on disk
        {
            let store = SqliteStore::open(&db).expect("open sqlite");
            let mut collector =
                Node::with_store(Identity::from_secret_bytes(&collector_seed), store);
            collector.set_time(now);
            configure_collector_node(&mut collector, None, None);

            collector.ingest(bundle.clone());
            let received = collector.take_telemetry();
            assert_eq!(
                received.len(),
                1,
                "first delivery must yield batch on SQLite"
            );
        }

        // Reopen SQLite store from disk (process restart)
        {
            let store = SqliteStore::open(&db).expect("reopen sqlite");
            let mut restarted =
                Node::with_store(Identity::from_secret_bytes(&collector_seed), store);
            restarted.set_time(now + 1000);
            configure_collector_node(&mut restarted, None, None);

            restarted.ingest(bundle);
            let replayed = restarted.take_telemetry();
            assert!(
                replayed.is_empty(),
                "SVC-006 failure: SQLite backend replayed telemetry after restart"
            );

            // Also verify sweep works on SQLite store
            let pruned = sweep_expired_telemetry_markers(&mut restarted.store, now + 1000);
            assert_eq!(pruned, 0, "fresh marker must not be pruned");
        }

        let _ = std::fs::remove_file(&db);
    }

    #[cfg(feature = "firestore")]
    #[test]
    fn svc_006_firestore_two_instances_and_restart_with_eager_cap() {
        use hop_store_firestore::{
            BundleMirror, BundleMirrorRow, FirestoreStore, KvMirrorRow, MirrorBatchError,
            MirrorPage,
        };

        #[allow(clippy::type_complexity)]
        #[derive(Clone, Default)]
        struct DoubleMirror {
            bundles: std::sync::Arc<
                std::sync::Mutex<std::collections::BTreeMap<BundleId, (Vec<u8>, u64)>>,
            >,
            kv: std::sync::Arc<std::sync::Mutex<std::collections::BTreeMap<String, Vec<u8>>>>,
        }

        impl BundleMirror for DoubleMirror {
            fn list_bundle_page(
                &self,
                _cursor: Option<&str>,
                _limit: usize,
                _max_bytes: usize,
            ) -> std::result::Result<MirrorPage<BundleMirrorRow>, String> {
                Ok(MirrorPage {
                    rows: Vec::new(),
                    next: None,
                    scanned_bytes: 0,
                    scanned_pages: 1,
                })
            }
            fn put_bundle(
                &self,
                id: &BundleId,
                data: &[u8],
                expires_at: u64,
            ) -> std::result::Result<(), String> {
                self.bundles
                    .lock()
                    .unwrap()
                    .insert(*id, (data.to_vec(), expires_at));
                Ok(())
            }
            fn delete_bundle(&self, id: &BundleId) -> std::result::Result<(), String> {
                self.bundles.lock().unwrap().remove(id);
                Ok(())
            }
            fn list_eager_kv_page(
                &self,
                after: Option<&str>,
                limit: usize,
                _max_bytes: usize,
                _max_pages: usize,
            ) -> std::result::Result<MirrorPage<KvMirrorRow>, String> {
                let kv = self.kv.lock().unwrap();
                let mut rows = Vec::new();
                for (k, v) in kv.iter() {
                    if !hop_store_firestore::is_telemetry_seen_key(k)
                        && !hop_store_firestore::is_billing_ledger_key(k)
                        && after.is_none_or(|cur| k.as_str() > cur)
                    {
                        rows.push(KvMirrorRow {
                            document_id: bs58::encode(k.as_bytes()).into_string(),
                            key: k.clone(),
                            value: Some(v.clone()),
                        });
                        if rows.len() == limit {
                            break;
                        }
                    }
                }
                Ok(MirrorPage {
                    rows,
                    next: None,
                    scanned_bytes: 0,
                    scanned_pages: 1,
                })
            }
            fn list_kv_page(
                &self,
                prefix: &str,
                after: Option<&str>,
                limit: usize,
            ) -> std::result::Result<Vec<(String, Vec<u8>)>, String> {
                let kv = self.kv.lock().unwrap();
                let rows: Vec<_> = kv
                    .iter()
                    .filter(|(k, _)| {
                        k.starts_with(prefix) && after.is_none_or(|cur| k.as_str() > cur)
                    })
                    .take(limit)
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect();
                Ok(rows)
            }
            fn put_kv(&self, key: &str, value: &[u8]) -> std::result::Result<(), String> {
                self.kv
                    .lock()
                    .unwrap()
                    .insert(key.to_string(), value.to_vec());
                Ok(())
            }
            fn delete_kv(&self, key: &str) -> std::result::Result<(), String> {
                self.kv.lock().unwrap().remove(key);
                Ok(())
            }
            fn get_kv(&self, key: &str) -> std::result::Result<Option<Vec<u8>>, String> {
                Ok(self.kv.lock().unwrap().get(key).cloned())
            }
            fn put_kv_if_absent(
                &self,
                key: &str,
                value: &[u8],
            ) -> std::result::Result<bool, MirrorBatchError> {
                let mut kv = self.kv.lock().unwrap();
                if kv.contains_key(key) {
                    return Ok(false);
                }
                kv.insert(key.to_string(), value.to_vec());
                Ok(true)
            }
            fn apply_kv_batch(
                &self,
                mutations: &[hop_core::store::KvMutation],
            ) -> std::result::Result<(), MirrorBatchError> {
                let mut kv = self.kv.lock().unwrap();
                for m in mutations {
                    match m {
                        hop_core::store::KvMutation::Put { key, value } => {
                            kv.insert(key.clone(), value.clone());
                        }
                        hop_core::store::KvMutation::Remove { key } => {
                            kv.remove(key);
                        }
                        _ => {}
                    }
                }
                Ok(())
            }
        }

        let collector_id = Identity::generate();
        let collector_seed = collector_id.to_secret_bytes();
        let shared_mirror = DoubleMirror::default();
        let now = 1_000_000u64;

        // 1. Concurrent instance dedup check over FirestoreStore
        let store_a = FirestoreStore::open_with_mirror(shared_mirror.clone()).unwrap();
        let mut node_a = Node::with_store(Identity::from_secret_bytes(&collector_seed), store_a);
        node_a.set_time(now);
        configure_collector_node(&mut node_a, None, None);

        let batch = TelemetryBatch::new().counter("test.events", 5, now);
        let bundle = Bundle::create(
            &Identity::generate(),
            Destination::Device(collector_id.address()),
            &collector_id.address(),
            &Payload::ServiceRequest {
                service: hop_core::node::SERVICE_TELEMETRY.into(),
                method: "export".into(),
                args: batch.to_bytes(),
            },
            BundleOpts::default(),
        )
        .unwrap();

        node_a.ingest(bundle.clone());
        let received_a = node_a.take_telemetry();
        assert_eq!(received_a.len(), 1, "Node A accepts delivery");

        // Node B opens independently over the same mirror
        let store_b = FirestoreStore::open_with_mirror(shared_mirror.clone()).unwrap();
        let mut node_b = Node::with_store(Identity::from_secret_bytes(&collector_seed), store_b);
        node_b.set_time(now + 50);
        configure_collector_node(&mut node_b, None, None);

        node_b.ingest(bundle.clone());
        let received_b = node_b.take_telemetry();
        assert!(
            received_b.is_empty(),
            "SVC-006 failure: FirestoreStore Node B double-metered across shared mirror"
        );

        // 2. Restart with eager cap reached over FirestoreStore
        let mirror_c = DoubleMirror::default();
        // Populate 2 session keys
        mirror_c.put_kv("session/peer_1", &[1; 32]).unwrap();
        mirror_c.put_kv("session/peer_2", &[2; 32]).unwrap();

        let store_c1 = FirestoreStore::open_with_mirror(mirror_c.clone()).unwrap();
        let mut node_c1 = Node::with_store(Identity::from_secret_bytes(&collector_seed), store_c1);
        node_c1.set_time(now);
        configure_collector_node(&mut node_c1, None, None);

        node_c1.ingest(bundle.clone());
        assert_eq!(node_c1.take_telemetry().len(), 1);
        drop(node_c1);

        // Restart store C with eager cap reached
        let store_c2 = FirestoreStore::open_with_mirror(mirror_c.clone()).unwrap();
        let mut node_c2 = Node::with_store(Identity::from_secret_bytes(&collector_seed), store_c2);
        node_c2.set_time(now + 1000);
        configure_collector_node(&mut node_c2, None, None);

        node_c2.ingest(bundle);
        assert!(
            node_c2.take_telemetry().is_empty(),
            "SVC-006 failure: FirestoreStore restart with eager cap reached failed to dedup"
        );
    }
}
