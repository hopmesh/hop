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

use base64::Engine;
use hop_core::node::TelemetryIn;
use hop_core::prelude::*;
use hop_core::telemetry::TelemetryBatch;
use hop_gateway::resolve_relay;
#[cfg(feature = "firestore")]
use hop_store_firestore::FirestoreStore;
use hop_store_sqlite::SqliteStore;
use tungstenite::Message;

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
#[derive(Default)]
struct TelemetryMeter {
    counts: HashMap<TenantId, u64>,
    unattributed: u64,
}

impl TelemetryMeter {
    fn add(&mut self, tenant: Option<TenantId>, events: u64) {
        match tenant {
            Some(t) => {
                let c = self.counts.entry(t).or_insert(0);
                *c = c.saturating_add(events);
            }
            None => self.unattributed = self.unattributed.saturating_add(events),
        }
    }

    /// RMW-merge the accumulated per-tenant counts into the store's `telemetry_usage` ledger for the
    /// current hour, then clear. Mirrors the relay's usage merge; only this node writes these keys, so
    /// the read-modify-write is race-free. With a durable (Firestore) store the rows survive a restart
    /// and the reconciler reads them; with `MemoryStore` they are in-process only.
    fn flush_to_store<S: Store>(&mut self, store: &mut S, now_ms: u64) {
        if self.counts.is_empty() {
            return;
        }
        let hour = now_ms / 3_600_000;
        for (tenant, events) in self.counts.drain() {
            if events == 0 {
                continue;
            }
            let key = telemetry_usage_key(hour, &tenant);
            let total = store.get_kv(&key).map(|b| decode_events(&b)).unwrap_or(0);
            store.put_kv(&key, encode_events(total.saturating_add(events)));
        }
    }

    fn take_unattributed(&mut self) -> u64 {
        std::mem::replace(&mut self.unattributed, 0)
    }
}

/// Ledger row key: `telemetry_usage/{hour}/{tenant_hex}`, distinct from the relay's `usage/` prefix so
/// the two capture paths never collide (the reconciler reads them as separate dimensions).
fn telemetry_usage_key(hour: u64, tenant: &TenantId) -> String {
    let hex: String = tenant.iter().map(|b| format!("{b:02x}")).collect();
    format!("telemetry_usage/{hour}/{hex}")
}

/// Row value: the event count as 8 LE bytes. Decode tolerates corruption by reading as zero (the row
/// is overwritten whole), the same convention as the relay's `decode_usage`.
fn encode_events(events: u64) -> Vec<u8> {
    events.to_le_bytes().to_vec()
}
fn decode_events(bytes: &[u8]) -> u64 {
    <[u8; 8]>::try_from(bytes)
        .map(u64::from_le_bytes)
        .unwrap_or(0)
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
    node.set_kind(NodeKind::Endpoint);
    node.set_name(domain.clone());
    node.set_max_relayed(0); // a leaf: routable by address, relays nothing

    // Attribution: run the SAME Keyed access policy as the billing relays so a received stamp resolves
    // to a tenant. Without a key server the collector runs Open and telemetry is unattributed (counted
    // in aggregate, not billed) until one is provided.
    match key_server_file.as_deref().and_then(load_key_server) {
        Some(server) => {
            node.set_access_policy(AccessPolicy::Keyed(KeyedAccess::new(server, HashSet::new())));
            node.refresh_access();
            println!("hop-telemetryd: keyed policy loaded; telemetry is tenant-attributed");
        }
        None => eprintln!(
            "hop-telemetryd: no --key-server; telemetry is UNATTRIBUTED (not billable) until one is set"
        ),
    }

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

    run(node, domain, rx);
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
fn run<S: Store>(mut node: Node<S>, domain: Option<String>, rx: Receiver<Ev>) {
    let mut writers: HashMap<u64, Sender<Vec<u8>>> = HashMap::new();
    let mut sink = AggregateSink::default();
    let mut meter = TelemetryMeter::default();
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
        forward_telemetry(&mut sink, &mut meter, received);

        // Aggregate throughput line (counts only, services-03).
        if last_stats.elapsed() >= STATS_LOG_INTERVAL {
            let (batches, events) = sink.take();
            if batches > 0 {
                println!(
                    "hop-telemetryd: {batches} batches, {events} events forwarded this window"
                );
            }
            last_stats = Instant::now();
        }

        // Merge per-tenant billable counts into the durable telemetry_usage ledger (§37 reconciler
        // reads it). Attribution is aggregate-only in the log (services-03: no per-tenant line).
        if last_flush.elapsed() >= TELEMETRY_FLUSH {
            meter.flush_to_store(&mut node.store, now_ms());
            let unattributed = meter.take_unattributed();
            if unattributed > 0 {
                eprintln!(
                    "hop-telemetryd: {unattributed} unattributed events this window (unstamped or no key server)"
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

/// Hand each received batch to the sink (throughput) and the meter (per-tenant billing). Split out of
/// `run` so it's unit-testable without the driver.
fn forward_telemetry(
    sink: &mut dyn TelemetrySink,
    meter: &mut TelemetryMeter,
    received: Vec<TelemetryIn>,
) {
    for t in &received {
        sink.record(t.from, &t.batch);
        meter.add(t.tenant, t.batch.billable_events());
    }
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
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    match peek_kind(&stream) {
        PeekKind::Http => {
            serve_http_min(stream);
            return;
        }
        PeekKind::WsUpgrade => {}
        PeekKind::Empty => return,
    }
    let _ = stream.set_read_timeout(None); // hand a clean blocking socket to tungstenite

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

    let (code, ctype, body): (&str, &str, Vec<u8>) =
        if method.eq_ignore_ascii_case("GET") && path == "/healthz" {
            ("200 OK", "text/plain", b"ok".to_vec())
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
/// restarts), generating and persisting one 0600 on first run.
fn load_identity(path: &Option<String>) -> Identity {
    if let Some(path) = path {
        if let Ok(bytes) = std::fs::read(path) {
            if let Ok(seed) = <[u8; 32]>::try_from(bytes.as_slice()) {
                return Identity::from_secret_bytes(&seed);
            }
        }
        let id = Identity::generate();
        if let Err(e) = write_secret_600(path, &id.to_secret_bytes()) {
            eprintln!(
                "warning: could not persist identity to {path}: {e}; address will change on restart"
            );
        }
        return id;
    }
    eprintln!("warning: no --identity-file; address will change on restart");
    Identity::generate()
}

/// Write `bytes` to `path` with owner-only (0600) permissions. On Unix the mode is applied at create
/// time so the secret is never briefly world-readable.
fn write_secret_600(path: &str, bytes: &[u8]) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(path)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        Ok(())
    }
    #[cfg(not(unix))]
    {
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(path)?;
        f.write_all(bytes)?;
        f.sync_all()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
        forward_telemetry(&mut sink, &mut meter, received);
        assert_eq!(sink.take(), (2, 3)); // throughput: 2 batches, 3 events
        assert_eq!(meter.counts.get(&tenant), Some(&1)); // 1 billable event to the tenant
        assert_eq!(meter.take_unattributed(), 2); // 2 unattributed events
    }

    #[test]
    fn telemetry_meter_flushes_per_tenant_rows_to_the_store_and_rmw_accumulates() {
        let mut store = MemoryStore::default();
        let now = 5 * 3_600_000 + 123; // hour 5
        let tenant = [7u8; 16];
        let mut meter = TelemetryMeter::default();
        meter.add(Some(tenant), 10);
        meter.add(Some(tenant), 5);
        meter.add(None, 3);
        meter.flush_to_store(&mut store, now);
        let key = telemetry_usage_key(5, &tenant);
        assert_eq!(store.get_kv(&key).map(|b| decode_events(&b)), Some(15));
        assert!(meter.counts.is_empty(), "cleared after flush");
        // A second window RMW-adds into the same hour row.
        meter.add(Some(tenant), 4);
        meter.flush_to_store(&mut store, now);
        assert_eq!(store.get_kv(&key).map(|b| decode_events(&b)), Some(19));
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
        meter.add(Some(tenant), 42);
        meter.flush_to_store(&mut store, now);
        assert_eq!(
            store
                .get_kv(&telemetry_usage_key(9, &tenant))
                .map(|b| decode_events(&b)),
            Some(42),
            "the ledger row survives the durable store round trip"
        );
        let _ = std::fs::remove_file(&db);
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
}
