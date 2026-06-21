//! The node event loop — the orchestration that turns the tested pieces into a
//! running Hop node. See DESIGN.md §3 (it spans every layer).
//!
//! A [`Node`] is driven by [`BearerEvent`]s from a bearer and produces opaque
//! bytes to send back over it. Per connection it:
//! 1. runs a Noise XX handshake ([`crate::link`]), exchanging a signed binding so
//!    each side learns the other's *hop address* (Ed25519), not just its link key;
//! 2. once up, offers its stored bundles via binary spray-and-wait ([`crate::routing`])
//!    and gossips its directory of adverts ([`crate::discover`]);
//! 3. on receiving a bundle addressed to itself, delivers it to the inbox;
//!    otherwise stores it for onward relay.
//!
//! The loop is transport-agnostic and fully testable without a radio: feed it
//! events, drain its outgoing bytes, read its inbox. v1 sends each message as one
//! link packet; MTU fragmentation (`link::fragment`) wraps this when a bearer
//! needs it — a TODO for the BLE shim.

use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};

use crate::bundle::{
    Bundle, BundleFlags, BundleId, BundleOpts, Destination, Payload, StreamId,
};
use crate::stream::StreamReassembler;
use crate::crypto::{self, short_addr, Identity, PubKeyBytes, SignedPreKey, XPubKeyBytes};
use crate::error::{Error, Result};
use crate::discover::{Advert, AdvertId, AdvertKind, Directory};
use crate::link::{BearerEvent, LinkHandshake, LinkId, LinkSession, Role};
use crate::route::RouteTable;
use crate::routing::{BundleMeta, ForwardDecision, Router, SprayAndWait};
use crate::{short_app, AppId, FABRIC_APP};
use crate::session::Session;
use crate::store::{MemoryStore, Store};

/// A link packet on the wire: a Noise handshake message, or an encrypted record.
#[derive(Serialize, Deserialize)]
enum LinkPacket {
    Handshake(Vec<u8>),
    Data(Vec<u8>),
}

/// Claims the peer's hop address during the Noise handshake. No signature needed:
/// the sealing key is derived from the address (Montgomery), so the peer is bound to
/// the address iff `address_to_x(address)` equals the static key Noise authenticated.
#[derive(Serialize, Deserialize)]
struct LinkAuth {
    address: PubKeyBytes,
}

/// An application record exchanged over an established link.
#[derive(Serialize, Deserialize)]
enum Wire {
    Bundle(Bundle),
    Advert(Advert),
}

struct Handshaking {
    hs: LinkHandshake,
    verified: Option<PubKeyBytes>,
}

struct Established {
    session: LinkSession,
    peer: PubKeyBytes,
    sent_bundles: HashSet<crate::bundle::BundleId>,
    sent_adverts: HashSet<crate::discover::AdvertId>,
}

// Boxed because a Noise handshake state is much larger than an established session.
enum LinkState {
    Handshaking(Box<Handshaking>),
    Up(Box<Established>),
}

/// Tracking for a locally-originated bundle awaiting an end-to-end ACK (§7).
#[derive(Clone, Copy)]
struct PendingTx {
    copies: u16,
    created_at: u64,
    lifetime_ms: u32,
    next_retx_at: u64,
    /// Current backoff gap; doubles each retransmit up to [`MAX_RETX_INTERVAL_MS`].
    retx_interval: u64,
}

/// Default *initial* gap between retransmission attempts for an unacked bundle. The gap
/// then backs off exponentially up to [`MAX_RETX_INTERVAL_MS`], so a days-long hop costs a
/// handful of retransmits rather than thousands.
pub const DEFAULT_RETX_INTERVAL_MS: u64 = 30_000;

/// Ceiling on the retransmission backoff (15 min). Past this, retries pace at this rate
/// for the rest of the bundle's lifetime.
pub const MAX_RETX_INTERVAL_MS: u64 = 900_000;

/// How many distinct peers a delivery-ACK is replicated to before it stops spreading
/// (DESIGN.md §7). Until then it rides along to every new contact — the ACK both confirms
/// delivery and vaccinates the mesh, so it's worth replicating, but bounded.
pub const ACK_REPLICATION_TARGET: usize = 3;

/// Hard cap on a delivery-ACK's lifetime (7 days). The ACK otherwise lives as long as the
/// message it confirms.
pub const MAX_ACK_LIFETIME_MS: u32 = 7 * 86_400_000;

/// Don't re-emit a delivery-ACK for the same message more often than this — a burst of
/// duplicate copies can't trigger an ACK storm (the re-ACK recovers a lost ACK; §7).
pub const REACK_MIN_INTERVAL_MS: u64 = 30_000;

/// Default cap on relayed (not-ours) bundles held for forwarding. Our own messages
/// are never counted or evicted; relayed ones decay under this bound.
pub const DEFAULT_MAX_RELAYED: usize = 128;

/// After we've relayed a not-ours bundle to ≥1 peer, keep it at least this long before
/// it becomes eviction-eligible — so in a populated area it can be handed off again, and
/// so a flood of big transfers can't immediately evict freshly-relayed traffic (DESIGN.md
/// §6). Under cap pressure, eviction *prefers* such already-relayed, past-grace bundles
/// and only drops a not-yet-relayed bundle when nothing else can be freed.
pub const EVICT_GRACE_MS: u64 = 180_000; // 3 minutes

/// Default cap on the learned-route table (DESIGN.md §27). Mobile-tier; cloud nodes
/// raise it via [`Node::set_route_capacity`] to become the long-memory backbone.
pub const DEFAULT_MAX_ROUTES: usize = 2_048;

/// Default cap on the "bundles I forwarded" memory used to correlate a returning
/// delivery-ACK with the forward path. Bounded; pruned by age in [`Node::tick`].
pub const DEFAULT_MAX_FORWARDED: usize = 4_096;

/// TTL for a published prekey advert (7 days). Re-publish before it lapses so peers
/// can always open a session (DESIGN.md §25).
pub const PREKEY_TTL_MS: u32 = 604_800_000;

/// Floor on a cached HNS record's lifetime (DESIGN.md §30): even a 0-TTL DNS answer is held
/// briefly so a burst of lookups for the same domain coalesces.
pub const MIN_HNS_TTL_MS: u64 = 1_000;

/// Ceiling on a cached HNS record's lifetime (1 day) — a stale endpoint address can't linger
/// forever even if DNS hands back an absurd TTL.
pub const MAX_HNS_TTL_MS: u64 = 86_400_000;

/// Delivery tracking for a message we originated (for status: Sending/Sent N/Delivered).
#[derive(Default)]
struct TxInfo {
    /// Distinct peers we've handed a copy to (the "Sent N" count).
    relayed: HashSet<PubKeyBytes>,
    /// The destination ACKed it back across the network.
    delivered: bool,
    /// Hops the returning ACK travelled (a proxy for the delivery path length).
    delivered_hops: u8,
}

/// A queued message for the UI: either ours awaiting send, or a peer's awaiting relay.
#[derive(Clone, Debug)]
pub struct QueuedMessage {
    pub id: BundleId,
    /// True if we originated it (pinned — never evicted). False = relaying for a peer.
    pub own: bool,
    /// Destination device address, if addressed to one.
    pub to: Option<PubKeyBytes>,
    pub priority: u8,
    /// Hops travelled so far.
    pub hops: u8,
}

/// The plaintext inside a forward-secret session message — what the ratchet
/// encrypts, so `content_type` rides end-to-end like the body.
#[derive(Serialize, Deserialize)]
struct SessionInner {
    content_type: String,
    body: Vec<u8>,
}

/// Per-peer forward-secret session state (DESIGN.md §25).
struct PeerSession {
    session: Session,
    /// For an initiator that hasn't heard back yet: the X3DH material to repeat in a
    /// `SessionInit` so any copy can bootstrap the peer. `None` once confirmed (we've
    /// received a message from them) or for a responder.
    init_material: Option<(XPubKeyBytes, XPubKeyBytes)>, // (ek_pub, spk_pub)
}

/// A decrypted user message ready for the inbox — uniform across static-sealed and
/// forward-secret session messages.
pub struct ReadMessage {
    pub from: PubKeyBytes,
    pub content_type: String,
    pub body: Vec<u8>,
}

/// An internet-egress HTTP request a gateway should fulfill (Use Case A, §9).
pub struct HttpReqItem {
    pub from: PubKeyBytes,
    pub id: BundleId,
    /// The domain this request targets. A `hops://` endpoint MUST validate this against the
    /// single domain it is authorized to serve and refuse anything else (no open proxy).
    pub host: String,
    pub method: String,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
    pub max_resp: u32,
}

/// A cached HNS record (DESIGN.md §30). `address` is `None` for a negative (no such hops
/// endpoint) entry. Both honor the DNS TTL via `expires_at_ms`.
#[derive(Clone, Copy)]
pub struct HnsEntry {
    pub address: Option<PubKeyBytes>,
    pub expires_at_ms: u64,
}

/// A finished HNS resolution surfaced to the app. `address` is `None` when the domain has no
/// `_hopaddress` record (resolution error — e.g. `hops://thisdoesnotexist.com`).
pub struct HnsResult {
    pub domain: String,
    pub address: Option<PubKeyBytes>,
}

/// The outcome of starting an HNS resolution (DESIGN.md §30).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HnsLookup {
    /// Served from a fresh cache entry. `Some(addr)` resolved; `None` is a cached negative.
    Cached(Option<PubKeyBytes>),
    /// A lookup was kicked off (real DNS via the host, or a mesh query); the result will
    /// arrive via [`Node::take_hns_results`].
    Pending,
    /// This node can't resolve on its own (no internet) and no resolver was given. Call
    /// [`Node::resolve_hns_via`] with a known internet-connected peer (e.g. a relay).
    NeedsResolver,
}

/// An HTTP response a gateway sealed back to the requester.
pub struct HttpRespItem {
    pub from: PubKeyBytes,
    pub for_id: BundleId,
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

/// The built-in identity service (DESIGN.md §29): call it on any address to learn that
/// node's display name + kind. Answered by the node itself, not the app.
pub const SERVICE_IDENTIFY: &str = "hop.identify";

/// What kind of node this is, reported by [`SERVICE_IDENTIFY`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum NodeKind {
    Device,
    Relay,
    Gateway,
    /// A `hops://` origin endpoint (DESIGN.md §30); its `name` is the domain it serves.
    Endpoint,
}

/// The reply body of [`SERVICE_IDENTIFY`]: who a node is. `name` is `None` when unset
/// (a device by default) — callers fall back to the short address. A relay sets its name
/// to its region domain. Carries the full `address` so a caller can resolve a short trace
/// hop it received against the responder.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct IdentityRecord {
    pub name: Option<String>,
    pub kind: NodeKind,
    pub address: PubKeyBytes,
}

/// A service request addressed to this node that the embedding app should fulfill
/// (built-in `hop.` services are answered by the node and never surface here).
pub struct ServiceReqItem {
    pub from: PubKeyBytes,
    /// The request bundle's id — pass it to [`Node::send_service_response`] to reply.
    pub id: BundleId,
    pub service: String,
    pub method: String,
    pub args: Vec<u8>,
}

/// A service response sealed back to us (as the caller).
pub struct ServiceRespItem {
    pub from: PubKeyBytes,
    pub for_id: BundleId,
    pub status: u16,
    pub body: Vec<u8>,
}

/// In-progress reassembly of an inbound **carrier stream** (DESIGN.md §20): a bundle too
/// large to send in one shot is split into ordered chunks; when they're all here the
/// original bundle bytes are reconstructed and re-processed as if received whole. Keyed
/// by `(sender, stream_id)`.
struct IncomingStream {
    reassembler: StreamReassembler,
    data: Vec<u8>,
    at: u64, // last activity, for pruning abandoned transfers
}

/// A bundle whose encoding exceeds this is carried as a stream of `STREAM_CHUNK`-sized
/// chunks (transparently); anything smaller goes as one bundle. Sized to fit comfortably
/// in one link record on every bearer (well under the 1 MiB frame cap).
const STREAM_CHUNK: usize = 48 * 1024;

/// A running Hop node, generic over its [`Store`] backend (in-memory by default;
/// `hop-store-sqlite` for persistence).
pub struct Node<S: Store = MemoryStore> {
    identity: Identity,
    pub store: S,
    router: SprayAndWait,
    pub directory: Directory,
    now_ms: u64,
    links: HashMap<LinkId, LinkState>,
    outgoing: Vec<(LinkId, Vec<u8>)>,
    inbox: Vec<Bundle>,
    /// Locally-originated bundles awaiting an ACK, retransmitted until acked/expired.
    pending: HashMap<BundleId, PendingTx>,
    retx_interval_ms: u64,
    /// Monotonic sequence for our own published adverts (supersession, §16).
    advert_seq: u64,
    /// Delivery status for messages we originated (Sending/Sent N/Delivered).
    tx: HashMap<BundleId, TxInfo>,
    /// Insertion order of relayed (not-ours) bundles, for capacity eviction.
    relay_order: Vec<BundleId>,
    max_relayed: usize,
    /// First time we relayed each not-ours bundle to a peer (custody policy, §6): eviction
    /// prefers bundles we've already handed off and held past [`EVICT_GRACE_MS`].
    relay_fwd: HashMap<BundleId, u64>,
    /// Our current signed prekey (published so peers can open sessions to us).
    prekey: SignedPreKey,
    /// Retained prekey secrets by public, so late session inits still resolve.
    spk_secrets: HashMap<XPubKeyBytes, [u8; 32]>,
    /// Forward-secret sessions, by peer address (DESIGN.md §25).
    sessions: HashMap<PubKeyBytes, PeerSession>,
    /// Bundle ids we've been "vaccinated" against by a passing delivery ACK — we
    /// drop them on sight so a delivered message stops propagating (epidemic
    /// recovery, DESIGN.md §6). Pruned by age in [`Node::tick`].
    immune: HashMap<BundleId, u64>,
    /// Egress HTTP requests addressed to us (as a gateway) awaiting fulfillment (§9).
    http_requests: Vec<HttpReqItem>,
    /// HTTP responses sealed back to us (as a requester).
    http_responses: Vec<HttpRespItem>,
    /// Learned reachability per endpoint, from observed deliveries (DESIGN.md §27):
    /// orders transmissions (best first) and eviction (flush unknown-dst first).
    routes: RouteTable,
    /// Device-addressed bundles we've forwarded/originated, `id → (src, dst, at)`. A
    /// returning delivery-ACK for one of these means we're on its path → learn the
    /// route. Bounded; pruned by age in [`Node::tick`].
    forwarded: HashMap<BundleId, (PubKeyBytes, PubKeyBytes, u64)>,
    /// This node's app identity, stamped into each trace hop so a route shows which
    /// app carried it (DESIGN.md §27). Defaults to the shared fabric; set by the
    /// embedding app (or [`crate::relay_app_id`] for a relay).
    app: AppId,
    /// This node's display name, returned by the built-in `hop.identify` service
    /// (DESIGN.md §29). `None` by default (a device) → callers show the short address;
    /// a relay sets it to its region domain.
    name: Option<String>,
    /// What kind of node this is, returned by `hop.identify`. Defaults to `Device`.
    kind: NodeKind,
    /// Egress service requests addressed to us that the app must fulfill (custom,
    /// non-`hop.` services). Built-in services are answered by the node itself.
    service_requests: Vec<ServiceReqItem>,
    /// Service responses sealed back to us as a caller.
    service_responses: Vec<ServiceRespItem>,
    /// In-progress inbound carrier-stream reassembly, keyed by `(sender, stream_id)` (§20).
    incoming_streams: HashMap<(PubKeyBytes, StreamId), IncomingStream>,
    /// Monotonic counter for our outbound stream ids.
    stream_seq: u64,
    /// Delivery-ACKs we originated, → the distinct peers we've handed each to. The ACK
    /// keeps riding to new contacts until it reaches [`ACK_REPLICATION_TARGET`] peers,
    /// then stops (DESIGN.md §7).
    ack_replicate: HashMap<BundleId, HashSet<PubKeyBytes>>,
    /// Last time we emitted a delivery-ACK for a given delivered message id — throttles
    /// re-ACKs so duplicate floods can't cause an ACK storm.
    last_ack: HashMap<BundleId, u64>,
    /// Whether this node can reach the public internet (and thus public DNS). Any node with
    /// this set resolves HNS itself — no relay round-trip required (DESIGN.md §30). Off by
    /// default; a relay or an internet-connected phone turns it on.
    internet: bool,
    /// HNS resolution cache: `domain → (address?, expires_at_ms)`. `None` is a negative
    /// (NXDOMAIN-like) cache entry. Honors the DNS TTL and propagates like a DNS resolver.
    hns_cache: HashMap<String, HnsEntry>,
    /// Domains we need the host to look up in real DNS (drained by [`Node::take_dns_lookups`]),
    /// with the in-flight set so we ask for each only once.
    dns_lookups: Vec<String>,
    dns_inflight: HashSet<String>,
    /// Remote HNS queries awaiting our DNS answer: `domain → [(asker, query_id)]`. When the
    /// host feeds the answer back we seal an [`Payload::HnsAnswer`] to each asker.
    dns_waiters: HashMap<String, Vec<(PubKeyBytes, BundleId)>>,
    /// Completed HNS resolutions for the app to consume ([`Node::take_hns_results`]).
    hns_results: Vec<HnsResult>,
}

impl Node<MemoryStore> {
    /// Create a node with an in-memory store.
    pub fn new(identity: Identity) -> Self {
        Self::with_store(identity, MemoryStore::new())
    }

    /// Construct a node from previously-saved identity secret bytes (see
    /// [`crate::crypto::Identity::to_secret_bytes`]) so the address is stable across
    /// restarts. Falls back to a fresh identity if the bytes are the wrong length.
    pub fn from_identity_secret(secret: &[u8]) -> Self {
        let identity = match <[u8; 32]>::try_from(secret) {
            Ok(b) => Identity::from_secret_bytes(&b),
            Err(_) => Identity::generate(),
        };
        Self::with_store(identity, MemoryStore::new())
    }
}

impl<S: Store> Node<S> {
    /// Create a node with an explicit store backend (e.g. a persistent one).
    pub fn with_store(identity: Identity, store: S) -> Self {
        // Deterministic so it survives restarts (peers cache our prekey advert).
        let prekey = identity.derive_prekey();
        let mut spk_secrets = HashMap::new();
        spk_secrets.insert(prekey.public, prekey.secret_bytes());
        let mut node = Self {
            identity,
            store,
            router: SprayAndWait::new(),
            directory: Directory::new(),
            now_ms: 0,
            links: HashMap::new(),
            outgoing: Vec::new(),
            inbox: Vec::new(),
            pending: HashMap::new(),
            retx_interval_ms: DEFAULT_RETX_INTERVAL_MS,
            advert_seq: 0,
            tx: HashMap::new(),
            relay_order: Vec::new(),
            max_relayed: DEFAULT_MAX_RELAYED,
            relay_fwd: HashMap::new(),
            prekey,
            spk_secrets,
            sessions: HashMap::new(),
            immune: HashMap::new(),
            http_requests: Vec::new(),
            http_responses: Vec::new(),
            routes: RouteTable::new(DEFAULT_MAX_ROUTES),
            forwarded: HashMap::new(),
            app: FABRIC_APP,
            name: None,
            kind: NodeKind::Device,
            service_requests: Vec::new(),
            service_responses: Vec::new(),
            incoming_streams: HashMap::new(),
            stream_seq: 0,
            ack_replicate: HashMap::new(),
            last_ack: HashMap::new(),
            internet: false,
            hns_cache: HashMap::new(),
            dns_lookups: Vec::new(),
            dns_inflight: HashSet::new(),
            dns_waiters: HashMap::new(),
            hns_results: Vec::new(),
        };
        node.rehydrate();
        node
    }

    /// Rebuild in-memory tracking from a (possibly persistent) store on startup, so a
    /// restart resumes cleanly: our own undelivered messages keep retransmitting, and
    /// relayed bundles re-enter the eviction order so the store stays bounded
    /// (DESIGN.md §5, §6). A no-op on an empty (fresh) store.
    fn rehydrate(&mut self) {
        let me = self.address();
        for id in self.store.have().ids {
            let Some(b) = self.store.get(&id) else { continue };
            if b.inner.src == me && !b.inner.flags.is_ack {
                // Our own message that wasn't yet ACKed (delivered ones were purged).
                self.tx.entry(id).or_default();
                if b.inner.flags.request_ack {
                    self.pending.insert(
                        id,
                        PendingTx {
                            copies: b.env.copies,
                            created_at: b.inner.created_at,
                            lifetime_ms: b.inner.lifetime_ms,
                            next_retx_at: 0, // re-offer on the next tick
                            retx_interval: self.retx_interval_ms,
                        },
                    );
                }
            } else {
                self.relay_order.push(id); // relayed: subject to eviction bound
            }
        }
        self.evict_relayed_if_needed();
    }

    /// Export this node's identity secret so it can be persisted and restored.
    pub fn identity_secret(&self) -> [u8; 32] {
        self.identity.to_secret_bytes()
    }

    pub fn address(&self) -> PubKeyBytes {
        self.identity.address()
    }

    /// Advance the node's advisory clock (used for advert expiry/discovery).
    pub fn set_time(&mut self, now_ms: u64) {
        self.now_ms = now_ms;
    }

    /// Raise (or lower) the learned-route table capacity (DESIGN.md §27). Cloud nodes
    /// set this high to become the long-memory backbone; mobile nodes keep the default.
    pub fn set_route_capacity(&mut self, cap: usize) {
        self.routes.set_capacity(cap);
    }

    /// Set the relayed-bundle custody window (`max_relayed`). With the forward-before-evict
    /// policy this is a *sliding window* of concurrent custody, not a transfer-size limit,
    /// so a cloud relay can run a large window for many in-flight chunked transfers.
    pub fn set_max_relayed(&mut self, cap: usize) {
        self.max_relayed = cap.max(1);
        self.evict_relayed_if_needed();
    }

    /// Set the app id this node **publicly stamps** into each trace hop (DESIGN.md §27).
    ///
    /// Privacy: this advertises "this node carries app X" to every relay on the path,
    /// so ONLY public infra nodes should set it — a relay sets [`crate::relay_app_id`]
    /// to show as "Hop Relay". **End-user devices must leave this at [`FABRIC_APP`]**
    /// (the default) so they never advertise which app they run. (The FFI deliberately
    /// exposes no setter for this.)
    pub fn set_app(&mut self, app: AppId) {
        self.app = app;
    }

    /// Decayed learned reachability toward `dst` (0.0 if no route is known). Higher
    /// means this node is a better path to `dst` right now.
    pub fn route_utility(&self, dst: &PubKeyBytes) -> f64 {
        self.routes.utility(dst, self.now_ms)
    }

    /// Whether this node has learned any live route toward `dst`.
    pub fn knows_route(&self, dst: &PubKeyBytes) -> bool {
        self.routes.knows(dst, self.now_ms)
    }

    /// Subscribe the local directory to a service topic.
    pub fn subscribe(&mut self, topic: impl Into<String>) {
        self.directory.subscribe(topic);
    }

    /// Submit a locally-originated bundle for delivery; offers it to live links.
    /// If it requests an ACK, it's tracked for retransmission until acked/expired.
    pub fn submit(&mut self, bundle: Bundle) {
        let id = bundle.id();
        let track = bundle.inner.flags.request_ack && !bundle.inner.flags.is_ack;
        let pend = PendingTx {
            copies: bundle.env.copies,
            created_at: bundle.inner.created_at,
            lifetime_ms: bundle.inner.lifetime_ms,
            next_retx_at: self.now_ms.saturating_add(self.retx_interval_ms),
            retx_interval: self.retx_interval_ms,
        };
        if self.store.put(bundle, self.now_ms) {
            if track {
                self.pending.insert(id, pend);
            }
            self.offer_bundles_to_all();
        }
    }

    /// Number of locally-originated bundles still awaiting an ACK.
    pub fn pending_count(&self) -> usize {
        self.pending.len()
    }

    /// Build, seal, and submit a peer message to `dst`. Uses a forward-secret
    /// session if one exists or can be opened from `dst`'s published prekey
    /// (DESIGN.md §25); otherwise falls back to a static seal to the address. Returns
    /// the new bundle's id.
    pub fn send_message(
        &mut self,
        dst: PubKeyBytes,
        content_type: String,
        body: Vec<u8>,
        request_ack: bool,
    ) -> Result<BundleId> {
        let payload = self.session_payload(&dst, content_type, body)?;
        let bundle = Bundle::create(
            &self.identity,
            Destination::Device(dst),
            &dst,
            &payload,
            BundleOpts {
                created_at: self.now_ms,
                flags: BundleFlags { request_ack, ..Default::default() },
                ..Default::default()
            },
        )?;
        let id = bundle.id();
        self.tx.entry(id).or_default(); // track delivery status for the UI
        // Remember our own send so the returning delivery-ACK teaches us the route (§27).
        self.forwarded.insert(id, (self.identity.address(), dst, self.now_ms));
        self.deliver(bundle);
        Ok(id)
    }

    /// Choose the payload for a peer message: an established session, a freshly
    /// opened one (from the peer's published prekey), or a static-seal fallback.
    fn session_payload(
        &mut self,
        dst: &PubKeyBytes,
        content_type: String,
        body: Vec<u8>,
    ) -> Result<Payload> {
        // Established session: ratchet-encrypt. Re-send as SessionInit until the peer
        // has replied (init_material present) so any copy can bootstrap them.
        if let Some(ps) = self.sessions.get_mut(dst) {
            let inner = postcard::to_allocvec(&SessionInner { content_type, body })?;
            let msg = ps.session.encrypt(&inner)?;
            return Ok(match ps.init_material {
                Some((ek_pub, spk_pub)) => Payload::SessionInit { ek_pub, spk_pub, msg },
                None => Payload::SessionMessage { msg },
            });
        }
        // No session yet: open one if the peer has published a prekey we've seen.
        if let Some(bundle) = self.directory.prekey(dst) {
            let inner = postcard::to_allocvec(&SessionInner { content_type, body })?;
            let (ek_pub, root) = crypto::x3dh_initiate(&self.identity, &bundle)?;
            let mut session = Session::init_initiator(root, bundle.spk_pub);
            let msg = session.encrypt(&inner)?;
            self.sessions
                .insert(*dst, PeerSession { session, init_material: Some((ek_pub, bundle.spk_pub)) });
            return Ok(Payload::SessionInit { ek_pub, spk_pub: bundle.spk_pub, msg });
        }
        // Fallback: static seal (no forward secrecy until we learn their prekey).
        Ok(Payload::PeerMessage { content_type, body })
    }

    /// Publish (and gossip) this node's signed prekey so peers can open forward-secret
    /// sessions to it without a live round-trip (DESIGN.md §25). Re-publish
    /// periodically to stay within the advert TTL. Returns the advert id.
    pub fn publish_prekey(&mut self) -> Result<AdvertId> {
        self.advert_seq += 1;
        let advert = Advert::publish(
            &self.identity,
            AdvertKind::PreKey { spk_pub: self.prekey.public, spk_sig: self.prekey.sig.to_vec() },
            self.now_ms,
            PREKEY_TTL_MS,
            self.advert_seq,
        )?;
        let id = advert.id;
        self.publish(advert);
        Ok(id)
    }

    /// Whether we hold a forward-secret session with `addr` — i.e. messages to/from
    /// it are ratchet-encrypted rather than static-sealed (DESIGN.md §25).
    pub fn has_session(&self, addr: &PubKeyBytes) -> bool {
        self.sessions.contains_key(addr)
    }

    /// Decrypt a bundle addressed to this node (e.g. an inbox item), raw payload.
    pub fn open(&self, bundle: &Bundle) -> Result<Payload> {
        bundle.open(&self.identity)
    }

    /// Read a user message addressed to this node — uniform across static-sealed
    /// (`PeerMessage`) and forward-secret session payloads. Establishes the responder
    /// side of a session on first `SessionInit`. Returns `None` for non-user payloads
    /// (HTTP/stream/ack). Mutates session state, so it must be called once per bundle.
    pub fn read_message(&mut self, bundle: &Bundle) -> Result<Option<ReadMessage>> {
        let from = bundle.inner.src;
        match bundle.open(&self.identity)? {
            Payload::PeerMessage { content_type, body } => {
                Ok(Some(ReadMessage { from, content_type, body }))
            }
            Payload::SessionInit { ek_pub, spk_pub, msg } => {
                if !self.sessions.contains_key(&from) {
                    let secret =
                        *self.spk_secrets.get(&spk_pub).ok_or(Error::Crypto("unknown prekey"))?;
                    let root = crypto::x3dh_respond(&self.identity, &secret, &from, &ek_pub)?;
                    let session = Session::init_responder(root, secret, spk_pub);
                    self.sessions.insert(from, PeerSession { session, init_material: None });
                }
                let ps = self.sessions.get_mut(&from).expect("just inserted");
                ps.init_material = None; // we've received from them → session confirmed
                let inner = ps.session.decrypt(&msg)?;
                let si: SessionInner = postcard::from_bytes(&inner)?;
                Ok(Some(ReadMessage { from, content_type: si.content_type, body: si.body }))
            }
            Payload::SessionMessage { msg } => {
                let ps =
                    self.sessions.get_mut(&from).ok_or(Error::Crypto("no session for peer"))?;
                ps.init_material = None;
                let inner = ps.session.decrypt(&msg)?;
                let si: SessionInner = postcard::from_bytes(&inner)?;
                Ok(Some(ReadMessage { from, content_type: si.content_type, body: si.body }))
            }
            _ => Ok(None),
        }
    }

    /// Send a `hops://` request to a specific endpoint (DESIGN.md §30): a normal HTTP
    /// request sealed and addressed to the endpoint's Hop address (not the open-web
    /// InternetEgress). The endpoint executes it against its own backend and the reply
    /// arrives as an [`HttpRespItem`] via [`Node::take_http_responses`]. Returns the
    /// request id (the response correlates by it).
    pub fn send_hops_request(
        &mut self,
        endpoint: PubKeyBytes,
        host: String,
        method: String,
        url: String,
        headers: Vec<(String, String)>,
        body: Vec<u8>,
        max_resp: u32,
    ) -> Result<BundleId> {
        let bundle = Bundle::create(
            &self.identity,
            Destination::Device(endpoint),
            &endpoint,
            &Payload::HttpRequest { host, method, url, headers, body, max_resp_bytes: max_resp },
            BundleOpts { created_at: self.now_ms, ..Default::default() },
        )?;
        let id = bundle.id();
        self.tx.entry(id).or_default();
        self.forwarded.insert(id, (self.identity.address(), endpoint, self.now_ms));
        self.deliver(bundle);
        Ok(id)
    }

    // ---- HNS: the Hop Name System (DESIGN.md §30) ----------------------------------------
    //
    // HNS maps a domain to its hops endpoint address via a `_hopaddress.<domain>` TXT record,
    // resolved against ordinary public DNS. Resolution is built into core and performed by
    // ANY internet-connected peer — no relay round-trip is required (a relay may answer too,
    // but need not). Records carry the DNS TTL and are cached + propagated like DNS.

    /// Declare whether this node can reach the public internet (and thus public DNS). When
    /// on, the node resolves HNS itself (surfacing real-DNS lookups via
    /// [`Node::take_dns_lookups`]) and can answer other peers' [`Payload::HnsQuery`].
    pub fn set_internet(&mut self, on: bool) {
        self.internet = on;
    }

    /// Whether this node is internet-connected (see [`Node::set_internet`]).
    pub fn is_internet(&self) -> bool {
        self.internet
    }

    /// A fresh cached HNS record for `domain`, if any: `Some(Some(addr))` resolved,
    /// `Some(None)` a cached negative, `None` not cached (or expired).
    pub fn cached_hns(&self, domain: &str) -> Option<Option<PubKeyBytes>> {
        let key = normalize_domain(domain);
        self.hns_cache
            .get(&key)
            .filter(|e| e.expires_at_ms > self.now_ms)
            .map(|e| e.address)
    }

    /// Resolve `domain` to its hops endpoint address (DESIGN.md §30). Serves from cache when
    /// fresh; otherwise, if this node is internet-connected, kicks off a real-DNS lookup
    /// (drained via [`Node::take_dns_lookups`]); otherwise returns [`HnsLookup::NeedsResolver`]
    /// so the caller can ask a known internet peer via [`Node::resolve_hns_via`]. Results
    /// arrive on [`Node::take_hns_results`].
    pub fn resolve_hns(&mut self, domain: &str) -> HnsLookup {
        let key = normalize_domain(domain);
        if let Some(addr) = self.cached_hns(&key) {
            return HnsLookup::Cached(addr);
        }
        if self.internet {
            self.queue_dns_lookup(&key);
            HnsLookup::Pending
        } else {
            HnsLookup::NeedsResolver
        }
    }

    /// Resolve `domain` by asking a specific internet-connected peer (e.g. a relay) over the
    /// mesh: seals an [`Payload::HnsQuery`] to `resolver`. The answer is cached and surfaced
    /// via [`Node::take_hns_results`]. Use when this node has no internet of its own.
    pub fn resolve_hns_via(&mut self, resolver: PubKeyBytes, domain: &str) -> Result<BundleId> {
        let key = normalize_domain(domain);
        let bundle = Bundle::create(
            &self.identity,
            Destination::Device(resolver),
            &resolver,
            &Payload::HnsQuery { domain: key },
            BundleOpts { created_at: self.now_ms, ..Default::default() },
        )?;
        let id = bundle.id();
        self.tx.entry(id).or_default();
        self.forwarded.insert(id, (self.identity.address(), resolver, self.now_ms));
        self.deliver(bundle);
        Ok(id)
    }

    /// Domains the host must look up in real DNS (the `_hopaddress.<domain>` TXT record),
    /// clearing the queue. The host feeds each result back via [`Node::provide_dns_answer`].
    pub fn take_dns_lookups(&mut self) -> Vec<String> {
        std::mem::take(&mut self.dns_lookups)
    }

    /// Feed back a real-DNS result for `domain` (DESIGN.md §30). `address` is `None` when the
    /// `_hopaddress` TXT record is absent (a resolution error — cached negatively so we don't
    /// hammer DNS). `ttl_secs` is the DNS TTL. Caches the record, surfaces an [`HnsResult`],
    /// and answers any peers whose [`Payload::HnsQuery`] was waiting on this domain.
    pub fn provide_dns_answer(&mut self, domain: &str, address: Option<PubKeyBytes>, ttl_secs: u32) {
        let key = normalize_domain(domain);
        self.dns_inflight.remove(&key);
        let ttl_ms = (ttl_secs as u64).clamp(MIN_HNS_TTL_MS / 1000, MAX_HNS_TTL_MS / 1000) * 1000;
        self.hns_cache.insert(
            key.clone(),
            HnsEntry { address, expires_at_ms: self.now_ms.saturating_add(ttl_ms) },
        );
        self.hns_results.push(HnsResult { domain: key.clone(), address });
        // Answer any mesh queries that were parked waiting for this domain.
        if let Some(waiters) = self.dns_waiters.remove(&key) {
            for (asker, query_id) in waiters {
                self.seal_hns_answer(asker, &key, address, ttl_secs, query_id);
            }
        }
    }

    /// Finished HNS resolutions (positive or negative), clearing the queue.
    pub fn take_hns_results(&mut self) -> Vec<HnsResult> {
        std::mem::take(&mut self.hns_results)
    }

    /// Queue a real-DNS lookup for the host, deduped while one is in flight.
    fn queue_dns_lookup(&mut self, key: &str) {
        if self.dns_inflight.insert(key.to_string()) {
            self.dns_lookups.push(key.to_string());
        }
    }

    /// Seal an [`Payload::HnsAnswer`] back to a querier.
    fn seal_hns_answer(
        &mut self,
        to: PubKeyBytes,
        domain: &str,
        address: Option<PubKeyBytes>,
        ttl_secs: u32,
        for_query: BundleId,
    ) {
        if let Ok(bundle) = Bundle::create(
            &self.identity,
            Destination::Device(to),
            &to,
            &Payload::HnsAnswer { domain: domain.to_string(), address, ttl_secs, for_query },
            BundleOpts { created_at: self.now_ms, ..Default::default() },
        ) {
            self.deliver(bundle);
        }
    }

    /// Seal an HTTP response back to a requester (gateway side).
    pub fn send_http_response(
        &mut self,
        to: PubKeyBytes,
        for_id: BundleId,
        status: u16,
        headers: Vec<(String, String)>,
        body: Vec<u8>,
    ) -> Result<BundleId> {
        let bundle = Bundle::create(
            &self.identity,
            Destination::Device(to),
            &to,
            &Payload::HttpResponse { status, headers, body, for_bundle_id: for_id },
            BundleOpts { created_at: self.now_ms, ..Default::default() },
        )?;
        let id = bundle.id();
        self.deliver(bundle);
        Ok(id)
    }

    /// Drain egress HTTP requests we (as a gateway) should fulfill.
    pub fn take_http_requests(&mut self) -> Vec<HttpReqItem> {
        std::mem::take(&mut self.http_requests)
    }

    /// Drain HTTP responses sealed back to us (as a requester).
    pub fn take_http_responses(&mut self) -> Vec<HttpRespItem> {
        std::mem::take(&mut self.http_responses)
    }

    // --- service calls (DESIGN.md §29) ----------------------------------------

    /// Set this node's display name (returned by `hop.identify`). `None` clears it.
    pub fn set_name(&mut self, name: Option<String>) {
        self.name = name;
    }

    /// This node's display name, if set.
    pub fn name(&self) -> Option<&str> {
        self.name.as_deref()
    }

    /// Set what kind of node this is (returned by `hop.identify`).
    pub fn set_kind(&mut self, kind: NodeKind) {
        self.kind = kind;
    }

    /// This node's identity record, as the built-in `hop.identify` service reports it.
    pub fn identity_record(&self) -> IdentityRecord {
        IdentityRecord { name: self.name.clone(), kind: self.kind, address: self.address() }
    }

    /// Call a service/command on `dst` (DESIGN.md §29). `service` is namespaced
    /// (`hop.identify` and other `hop.` names are answered by the destination node
    /// itself; anything else is dispatched to its app). The reply arrives as a
    /// [`ServiceRespItem`] via [`Node::take_service_responses`]. Returns the request id.
    pub fn send_service_request(
        &mut self,
        dst: PubKeyBytes,
        service: String,
        method: String,
        args: Vec<u8>,
    ) -> Result<BundleId> {
        let bundle = Bundle::create(
            &self.identity,
            Destination::Device(dst),
            &dst,
            &Payload::ServiceRequest { service, method, args },
            BundleOpts { created_at: self.now_ms, ..Default::default() },
        )?;
        let id = bundle.id();
        self.tx.entry(id).or_default();
        // Remember the send so a returning delivery learns the route (§27).
        self.forwarded.insert(id, (self.identity.address(), dst, self.now_ms));
        self.deliver(bundle);
        Ok(id)
    }

    /// Seal a service response back to a caller (app side, for a custom service). Reply
    /// to a [`ServiceReqItem`] using its `from` (as `to`) and `id` (as `for_id`).
    pub fn send_service_response(
        &mut self,
        to: PubKeyBytes,
        for_id: BundleId,
        status: u16,
        body: Vec<u8>,
    ) -> Result<BundleId> {
        let bundle = Bundle::create(
            &self.identity,
            Destination::Device(to),
            &to,
            &Payload::ServiceResponse { for_bundle_id: for_id, status, body },
            BundleOpts { created_at: self.now_ms, ..Default::default() },
        )?;
        let id = bundle.id();
        self.deliver(bundle);
        Ok(id)
    }

    /// Drain custom service requests addressed to us (built-in `hop.` services are
    /// answered by the node and never appear here).
    pub fn take_service_requests(&mut self) -> Vec<ServiceReqItem> {
        std::mem::take(&mut self.service_requests)
    }

    /// Drain service responses sealed back to us (as a caller).
    pub fn take_service_responses(&mut self) -> Vec<ServiceRespItem> {
        std::mem::take(&mut self.service_responses)
    }

    // --- transparent carrier streaming (DESIGN.md §20) ------------------------

    /// A fresh stream id, unique per this node.
    fn next_stream_id(&mut self) -> StreamId {
        self.stream_seq += 1;
        let mut id = [0u8; 16];
        id[..8].copy_from_slice(&self.stream_seq.to_be_bytes());
        id[8..].copy_from_slice(&short_addr(&self.identity.address()));
        id
    }

    /// Submit a locally-originated bundle, **auto-streaming if it's too large**. Small
    /// bundles go as one (the common case). A large one (e.g. an image message, or a big
    /// service request/response) is split into ordered `StreamData` chunks carrying its
    /// raw bytes, each sealed to the destination and ACK-tracked for reliable transport;
    /// the receiver reassembles and processes the original bundle as if it arrived whole —
    /// so id, request_ack, delivery status and dedup are all preserved. Transparent: every
    /// `send_*` path funnels through here, so any payload type streams when needed.
    fn deliver(&mut self, bundle: Bundle) {
        let encoded = match bundle.to_bytes() {
            Ok(b) if b.len() > STREAM_CHUNK => b,
            _ => return self.submit(bundle), // small, or un-encodable: send as one
        };
        let dst = match bundle.inner.dst {
            Destination::Device(d) | Destination::AckTo(d, _) => d,
            Destination::InternetEgress => return self.submit(bundle), // no single dst to stream to
        };
        let sid = self.next_stream_id();
        let opts = BundleOpts {
            created_at: self.now_ms,
            flags: BundleFlags { request_ack: true, ..Default::default() },
            ..Default::default()
        };
        let chunks: Vec<&[u8]> = encoded.chunks(STREAM_CHUNK).collect();
        let n = chunks.len();
        for (i, chunk) in chunks.into_iter().enumerate() {
            if let Ok(carrier) = Bundle::create(
                &self.identity,
                Destination::Device(dst),
                &dst,
                &Payload::Carrier { stream_id: sid, seq: i as u64, bytes: chunk.to_vec(), fin: i + 1 == n },
                opts,
            ) {
                self.submit(carrier); // request_ack → tracked in `pending` for retransmit
            }
        }
    }

    /// Feed one inbound carrier chunk into reassembly; returns the reconstructed original
    /// bundle bytes once the stream is complete (else `None`).
    fn accept_stream_chunk(
        &mut self,
        from: PubKeyBytes,
        stream_id: StreamId,
        seq: u64,
        bytes: Vec<u8>,
        fin: bool,
    ) -> Option<Vec<u8>> {
        let now = self.now_ms;
        let entry = self.incoming_streams.entry((from, stream_id)).or_insert_with(|| {
            IncomingStream { reassembler: StreamReassembler::new(), data: Vec::new(), at: now }
        });
        entry.at = now;
        for chunk in entry.reassembler.accept(seq, bytes, fin) {
            entry.data.extend_from_slice(&chunk);
        }
        if entry.reassembler.is_finished() {
            self.incoming_streams.remove(&(from, stream_id)).map(|s| s.data)
        } else {
            None
        }
    }

    /// Publish (and gossip) a signed service advert so others discover it across the
    /// mesh — even multiple hops away via relays (§15–§16). Returns the advert id so
    /// the caller can later revoke it with a tombstone. The advert carries this node's
    /// address as `publisher`, so a discoverer can seal a message straight back.
    ///
    /// Apps build presence and contacts on top of this: a chat app publishes a
    /// "presence" service whose `title` is the user's chosen display name, browses for
    /// it, and ties name↔address locally (DESIGN.md §4, §23).
    pub fn publish_service(
        &mut self,
        service: String,
        title: String,
        summary: String,
        tags: Vec<String>,
        ttl_ms: u32,
    ) -> Result<AdvertId> {
        self.advert_seq += 1;
        let advert = Advert::publish(
            &self.identity,
            AdvertKind::Service { service, title, summary, tags },
            self.now_ms,
            ttl_ms,
            self.advert_seq,
        )?;
        let id = advert.id;
        self.publish(advert);
        Ok(id)
    }

    /// Browse a service namespace (optionally filtered by tag) for adverts discovered
    /// across the mesh. Returns the live [`Advert`]s; `publisher` is the address to
    /// message, `hops` the closest known distance.
    pub fn browse(&self, service: &str, tag: Option<&str>) -> Vec<Advert> {
        self.directory.browse(service, tag)
    }

    /// Delivery status of a message we sent: `(peers_relayed_to, delivered,
    /// delivery_hops)`. Maps to Sending (0, false, _) / Sent N (N, false, _) /
    /// Delivered (_, true, hops). `delivery_hops` is the forward path length the
    /// destination observed (0 until delivered).
    pub fn message_status(&self, id: &BundleId) -> Option<(u32, bool, u8)> {
        self.tx.get(id).map(|i| (i.relayed.len() as u32, i.delivered, i.delivered_hops))
    }

    /// The relay queue for display: our messages awaiting send (pinned) and peer
    /// messages awaiting relay (subject to decay). Newest first.
    pub fn queue(&self) -> Vec<QueuedMessage> {
        let mut items: Vec<QueuedMessage> = self
            .store
            .have()
            .ids
            .iter()
            .filter_map(|id| self.store.get(id))
            .map(|b| QueuedMessage {
                id: b.id(),
                own: self.tx.contains_key(&b.id()),
                to: match b.inner.dst {
                    Destination::Device(a) | Destination::AckTo(a, _) => Some(a),
                    Destination::InternetEgress => None,
                },
                priority: b.inner.priority,
                hops: b.env.hops,
            })
            .collect();
        // Own (pinned) first, then by priority desc.
        items.sort_by(|a, b| b.own.cmp(&a.own).then(b.priority.cmp(&a.priority)));
        items
    }

    /// For the cloud backbone's cross-partition handoff (DESIGN.md §28): the
    /// device-addressed bundles we're holding whose destination is **not** currently
    /// connected to us, as `(id, dst, sealed bytes, expires_at_ms)`. The relay hands
    /// these into the destination region's Firestore mailbox so an offline device
    /// collects them when it next checks in (or that region cold-starts). Returns the
    /// sealed wire bytes untouched — the relay never opens what it forwards.
    pub fn undeliverable_device_bundles(&self) -> Vec<(BundleId, PubKeyBytes, Vec<u8>, u64)> {
        let connected: HashSet<PubKeyBytes> = self.peers().into_iter().collect();
        let mut out = Vec::new();
        for id in self.store.have().ids {
            let Some(b) = self.store.get(&id) else { continue };
            // Both user messages (Device) and delivery-ACKs (AckTo) are addressed to a
            // specific node, so both ride the handoff — otherwise an ACK back to an
            // offline cross-region sender would never arrive (no live peering, §28).
            let dst = match b.inner.dst {
                Destination::Device(d) | Destination::AckTo(d, _) => d,
                Destination::InternetEgress => continue,
            };
            if connected.contains(&dst) {
                continue; // deliverable directly on this node — no handoff needed
            }
            if let Ok(bytes) = b.to_bytes() {
                let expires = b.inner.created_at.saturating_add(b.inner.lifetime_ms as u64);
                out.push((id, dst, bytes, expires));
            }
        }
        out
    }

    /// Ingest a foreign (relayed) bundle pulled from durable storage — e.g. a
    /// cross-partition handoff written into our Firestore partition while we were
    /// already warm (DESIGN.md §28). Stores it for onward relay and offers it to live
    /// links, exactly as if a peer had handed it over. A cold-started node gets the same
    /// bundles for free via [`Node::with_store`]'s rehydrate.
    pub fn ingest(&mut self, bundle: Bundle) {
        // A phantom link id that matches no real connection, so the bundle is offered to
        // every live link (the offer step skips only the link it arrived on).
        self.on_bundle(LinkId::MAX, bundle);
    }

    /// Drop everything we're currently holding: our own undelivered messages (stop
    /// retransmitting them) and any bundles we're relaying for peers. Clears the relay
    /// queue shown in the UI. Delivery-status history (`tx`) is kept so already-sent
    /// messages still render their last state; sessions/directory are untouched.
    pub fn clear_queue(&mut self) {
        for id in self.store.have().ids {
            self.store.remove(&id);
        }
        self.relay_order.clear();
        self.relay_fwd.clear();
        self.ack_replicate.clear();
        self.pending.clear();
    }

    /// Addresses of currently-connected, authenticated peers (handshake complete).
    pub fn peers(&self) -> Vec<PubKeyBytes> {
        self.links
            .values()
            .filter_map(|s| match s {
                LinkState::Up(e) => Some(e.peer),
                _ => None,
            })
            .collect()
    }

    /// `(peer address, link id)` for every live link — lets the host map a direct
    /// neighbour to the transport(s) carrying it (the bearer owns the link-id → medium
    /// mapping). A peer may appear more than once if reachable over multiple bearers.
    pub fn peer_links(&self) -> Vec<(PubKeyBytes, LinkId)> {
        self.links
            .iter()
            .filter_map(|(id, s)| match s {
                LinkState::Up(e) => Some((e.peer, *id)),
                _ => None,
            })
            .collect()
    }

    /// Send a message to a directly-connected peer. Returns the bundle id, or `None`
    /// if not connected to that address. (Any address can be reached with
    /// [`Node::send_message`]; this just gates on a live link.)
    pub fn send_to(
        &mut self,
        address: &PubKeyBytes,
        content_type: String,
        body: Vec<u8>,
        request_ack: bool,
    ) -> Result<Option<BundleId>> {
        let connected = self
            .links
            .values()
            .any(|s| matches!(s, LinkState::Up(e) if e.peer == *address));
        if !connected {
            return Ok(None);
        }
        Ok(Some(self.send_message(*address, content_type, body, request_ack)?))
    }

    /// Advance time: expire stale adverts and retransmit unacked bundles whose
    /// retry timer is due, giving up on any past their lifetime (§7, §8).
    pub fn tick(&mut self, now_ms: u64) {
        self.now_ms = now_ms;
        self.directory.expire(now_ms);
        self.store.prune(now_ms);
        // Drop relay-queue entries whose bundles have been delivered or expired.
        self.relay_order.retain(|id| self.store.contains(id));
        self.relay_fwd.retain(|id, _| self.store.contains(id));
        // Expire vaccine immunity after a bundle could no longer be live (1h).
        self.immune.retain(|_, t| now_ms.saturating_sub(*t) < 3_600_000);
        // Forget forwarded-route memory for bundles that can no longer ACK back (§27).
        self.forwarded.retain(|_, (_, _, t)| now_ms.saturating_sub(*t) < 3_600_000);
        // Drop abandoned half-received carrier streams (sender vanished mid-transfer).
        self.incoming_streams.retain(|_, s| now_ms.saturating_sub(s.at) < 3_600_000);
        // ACK bookkeeping: forget replication tracking for ACKs no longer held, and age
        // out the re-ACK throttle map.
        self.ack_replicate.retain(|id, _| self.store.contains(id));
        self.last_ack.retain(|_, t| now_ms.saturating_sub(*t) < 3_600_000);
        // Expired HNS records leave the device entirely (DESIGN.md §30): once a cached
        // endpoint's DNS-derived TTL lapses it's dropped, so the next request re-resolves
        // all the way back to DNS rather than reusing a stale address.
        self.hns_cache.retain(|_, e| e.expires_at_ms > now_ms);

        let mut retransmit = false;
        for id in self.pending.keys().copied().collect::<Vec<_>>() {
            let p = self.pending[&id];
            if now_ms >= p.created_at.saturating_add(p.lifetime_ms as u64) {
                self.pending.remove(&id); // lifetime exhausted — give up
                self.store.remove(&id);
                continue;
            }
            if now_ms >= p.next_retx_at {
                // Refresh the copy budget and re-offer along every link.
                if !self.store.contains(&id) {
                    self.pending.remove(&id);
                    continue;
                }
                self.store.set_copies(&id, p.copies);
                for state in self.links.values_mut() {
                    if let LinkState::Up(est) = state {
                        est.sent_bundles.remove(&id);
                    }
                }
                if let Some(p) = self.pending.get_mut(&id) {
                    // Exponential backoff so a long-lived bundle retries a handful of
                    // times over its lifetime, not every 30s for days.
                    p.retx_interval = p.retx_interval.saturating_mul(2).min(MAX_RETX_INTERVAL_MS);
                    p.next_retx_at = now_ms.saturating_add(p.retx_interval);
                }
                retransmit = true;
            }
        }
        if retransmit {
            self.offer_bundles_to_all();
        }
    }

    /// Publish a locally-originated advert; gossips it to live links.
    pub fn publish(&mut self, advert: Advert) {
        if self.directory.ingest(advert, self.now_ms).unwrap_or(false) {
            self.offer_adverts_to_all();
        }
    }

    /// Bundles addressed to this node that have arrived since the last call.
    pub fn take_inbox(&mut self) -> Vec<Bundle> {
        std::mem::take(&mut self.inbox)
    }

    /// Opaque bytes to ship over the bearer, paired with their connection.
    pub fn drain_outgoing(&mut self) -> Vec<(LinkId, Vec<u8>)> {
        std::mem::take(&mut self.outgoing)
    }

    /// Feed one bearer event into the loop.
    pub fn handle(&mut self, event: BearerEvent) {
        match event {
            BearerEvent::Connected(link, role) => self.on_connected(link, role),
            BearerEvent::Disconnected(link) => {
                self.links.remove(&link);
            }
            BearerEvent::Data(link, bytes) => self.on_data(link, bytes),
        }
    }

    // --- connection lifecycle -------------------------------------------------

    fn auth_payload(&self) -> Vec<u8> {
        let auth = LinkAuth { address: self.identity.address() };
        postcard::to_allocvec(&auth).expect("auth encode")
    }

    fn on_connected(&mut self, link: LinkId, role: Role) {
        let Ok(mut hs) = (match role {
            Role::Initiator => LinkHandshake::initiator(&self.identity),
            Role::Responder => LinkHandshake::responder(&self.identity),
        }) else {
            return;
        };

        // The initiator sends the first handshake message immediately.
        if role == Role::Initiator {
            if let Ok(msg) = hs.write(&self.auth_payload()) {
                self.send_packet(link, LinkPacket::Handshake(msg));
            }
        }
        self.links
            .insert(link, LinkState::Handshaking(Box::new(Handshaking { hs, verified: None })));
    }

    fn on_data(&mut self, link: LinkId, bytes: Vec<u8>) {
        let Ok(packet) = postcard::from_bytes::<LinkPacket>(&bytes) else {
            return;
        };
        match packet {
            LinkPacket::Handshake(msg) => self.on_handshake_msg(link, &msg),
            LinkPacket::Data(ct) => self.on_record(link, &ct),
        }
    }

    fn on_handshake_msg(&mut self, link: LinkId, msg: &[u8]) {
        // Take the handshake out so we can both write and (later) consume it.
        let Some(LinkState::Handshaking(boxed)) = self.links.remove(&link) else {
            return; // unknown link or already established
        };
        let mut state = *boxed;

        let Ok(payload) = state.hs.read(msg) else {
            return; // drop link on bad handshake
        };

        // Bind the peer's claimed address to the Noise-authenticated static key:
        // they match iff the address's derived X25519 key equals `remote_static`.
        if let Some(remote_static) = state.hs.remote_static() {
            match postcard::from_bytes::<LinkAuth>(&payload) {
                Ok(auth) if crypto::address_to_x(&auth.address) == Some(remote_static) => {
                    state.verified = Some(auth.address);
                }
                Ok(_) => return, // address doesn't match the link key → drop
                Err(_) => {}     // no claim in this message (e.g. m1) → keep going
            }
        }

        if !state.hs.is_finished() {
            if let Ok(out) = state.hs.write(&self.auth_payload()) {
                self.send_packet(link, LinkPacket::Handshake(out));
            }
        }

        if state.hs.is_finished() {
            let (Some(peer), Ok(session)) = (state.verified, state.hs.into_session()) else {
                return; // finished without an authenticated peer → drop
            };
            self.links.insert(
                link,
                LinkState::Up(Box::new(Established {
                    session,
                    peer,
                    sent_bundles: HashSet::new(),
                    sent_adverts: HashSet::new(),
                })),
            );
            self.offer_bundles_to_link(link);
            self.offer_adverts_to_link(link);
        } else {
            self.links.insert(link, LinkState::Handshaking(Box::new(state)));
        }
    }

    // --- inbound records ------------------------------------------------------

    fn on_record(&mut self, link: LinkId, ct: &[u8]) {
        let Some(LinkState::Up(est)) = self.links.get_mut(&link) else {
            return;
        };
        let Ok(plaintext) = est.session.decrypt(ct) else {
            return;
        };
        let peer = est.peer;
        match postcard::from_bytes::<Wire>(&plaintext) {
            Ok(Wire::Bundle(b)) => self.on_bundle(link, b),
            Ok(Wire::Advert(a)) => self.on_advert(peer, a),
            Err(_) => {}
        }
    }

    fn on_bundle(&mut self, from_link: LinkId, bundle: Bundle) {
        if bundle.verify().is_err() {
            return; // never store/relay unverifiable bundles
        }
        let id = bundle.id();

        if is_for(&bundle, &self.address()) {
            if self.store.seen(&id) {
                // A duplicate of something we already delivered. If it wanted an ACK, our
                // ACK may have been lost — re-emit it (throttled) so the sender can stop
                // retransmitting. Never re-deliver to the inbox.
                if !bundle.inner.flags.is_ack && bundle.inner.flags.request_ack {
                    let due = match self.last_ack.get(&id) {
                        Some(&t) => self.now_ms.saturating_sub(t) >= REACK_MIN_INTERVAL_MS,
                        None => true,
                    };
                    if due {
                        self.emit_ack(&bundle);
                    }
                }
                return;
            }
            if bundle.inner.flags.is_ack {
                // An ACK for one of our sent bundles: stop tracking & carrying it,
                // and mark it Delivered for the UI.
                if let Ok(Payload::Ack { for_bundle_id, delivery_hops, .. }) =
                    bundle.open(&self.identity)
                {
                    self.pending.remove(&for_bundle_id);
                    self.store.remove(&for_bundle_id);
                    if let Some(info) = self.tx.get_mut(&for_bundle_id) {
                        info.delivered = true;
                        info.delivered_hops = delivery_hops;
                    }
                    // Our message reached its destination: learn the route (§27).
                    if let Some((s, d, _)) = self.forwarded.remove(&for_bundle_id) {
                        self.routes.learn(&s, &d, self.now_ms);
                    }
                }
            } else {
                // Route by payload: HTTP req/resp go to their own queues; peer/session
                // messages stay raw for read_message (sessions need stateful decrypt).
                match bundle.open(&self.identity) {
                    Ok(Payload::HttpResponse { status, headers, body, for_bundle_id }) => {
                        // The response answers our request → drop the request bundle so it
                        // stops being held/re-offered, and vaccinate any in-flight copies.
                        self.pending.remove(&for_bundle_id);
                        self.store.remove(&for_bundle_id);
                        self.relay_order.retain(|x| *x != for_bundle_id);
                        self.immune.insert(for_bundle_id, self.now_ms);
                        self.tx.remove(&for_bundle_id);
                        self.http_responses.push(HttpRespItem {
                            from: bundle.inner.src,
                            for_id: for_bundle_id,
                            status,
                            headers,
                            body,
                        });
                    }
                    // A hops:// request sealed to us (we're a hop-endpoint, §30): surface
                    // it for the operator's translator to execute against its backend.
                    Ok(Payload::HttpRequest { host, method, url, headers, body, max_resp_bytes }) => {
                        self.http_requests.push(HttpReqItem {
                            from: bundle.inner.src,
                            id,
                            host,
                            method,
                            url,
                            headers,
                            body,
                            max_resp: max_resp_bytes,
                        });
                    }
                    Ok(Payload::ServiceResponse { for_bundle_id, status, body }) => {
                        // A response is the return-path "delete" for our request: service
                        // calls carry no ACK-vaccine of their own, so without this the
                        // request bundle would sit pinned in our store forever. Drop it
                        // everywhere and vaccinate so any in-flight copy is dropped too.
                        self.pending.remove(&for_bundle_id);
                        self.store.remove(&for_bundle_id);
                        self.relay_order.retain(|x| *x != for_bundle_id);
                        self.immune.insert(for_bundle_id, self.now_ms);
                        self.tx.remove(&for_bundle_id);
                        self.service_responses.push(ServiceRespItem {
                            from: bundle.inner.src,
                            for_id: for_bundle_id,
                            status,
                            body,
                        });
                    }
                    Ok(Payload::ServiceRequest { service, method, args }) => {
                        let from = bundle.inner.src;
                        if service == SERVICE_IDENTIFY {
                            // Built-in: the node answers with its own identity record.
                            let body = postcard::to_allocvec(&self.identity_record())
                                .unwrap_or_default();
                            let _ = self.send_service_response(from, id, 0, body);
                        } else {
                            // Custom service: hand to the embedding app to fulfill.
                            self.service_requests.push(ServiceReqItem {
                                from,
                                id,
                                service,
                                method,
                                args,
                            });
                        }
                    }
                    // An HNS query sealed to us (a peer is asking us — an internet-connected
                    // node — to resolve a domain, §30). Answer from cache if fresh; else, if
                    // we have internet, park the asker and kick off a real-DNS lookup; if we
                    // can't help (no internet, not cached), stay silent and let it time out.
                    Ok(Payload::HnsQuery { domain }) => {
                        let key = normalize_domain(&domain);
                        let from = bundle.inner.src;
                        if let Some(addr) = self.cached_hns(&key) {
                            let ttl = self
                                .hns_cache
                                .get(&key)
                                .map(|e| ((e.expires_at_ms.saturating_sub(self.now_ms)) / 1000) as u32)
                                .unwrap_or(0);
                            self.seal_hns_answer(from, &key, addr, ttl, id);
                        } else if self.internet {
                            self.dns_waiters.entry(key.clone()).or_default().push((from, id));
                            self.queue_dns_lookup(&key);
                        }
                    }
                    // An HNS answer to a query we sent (§30): cache it (honoring the DNS TTL),
                    // surface the result, and purge the query bundle so it stops being held.
                    Ok(Payload::HnsAnswer { domain, address, ttl_secs, for_query }) => {
                        let key = normalize_domain(&domain);
                        let ttl_ms =
                            (ttl_secs as u64).clamp(MIN_HNS_TTL_MS / 1000, MAX_HNS_TTL_MS / 1000) * 1000;
                        self.hns_cache.insert(
                            key.clone(),
                            HnsEntry { address, expires_at_ms: self.now_ms.saturating_add(ttl_ms) },
                        );
                        self.hns_results.push(HnsResult { domain: key, address });
                        self.pending.remove(&for_query);
                        self.store.remove(&for_query);
                        self.relay_order.retain(|x| *x != for_query);
                        self.immune.insert(for_query, self.now_ms);
                        self.tx.remove(&for_query);
                    }
                    // A transport carrier chunk: reassemble (§20); once complete, reconstruct
                    // the original bundle and process it as if it had arrived whole.
                    // (Application streams use StreamData and are delivered progressively.)
                    Ok(Payload::Carrier { stream_id, seq, bytes, fin }) => {
                        let from = bundle.inner.src;
                        if let Some(inner_bytes) =
                            self.accept_stream_chunk(from, stream_id, seq, bytes, fin)
                        {
                            if let Ok(inner) = Bundle::from_bytes(&inner_bytes) {
                                self.on_bundle(from_link, inner);
                            }
                        }
                    }
                    _ => self.inbox.push(bundle.clone()),
                }
                if bundle.inner.flags.request_ack {
                    self.emit_ack(&bundle);
                }
            }
            // Mark seen (dedup) but don't hold — we never relay what's addressed to us.
            self.store.put(bundle, self.now_ms);
            self.store.remove(&id);
            return;
        }

        // Internet-egress request sealed to us (we're a gateway that can open it):
        // surface it for fulfillment. Still relayed below so other gateways can serve
        // it too; gateway-side dedup prevents double fulfillment (§9).
        if matches!(bundle.inner.dst, Destination::InternetEgress) && !self.store.seen(&id) {
            if let Ok(Payload::HttpRequest { host, method, url, headers, body, max_resp_bytes }) =
                bundle.open(&self.identity)
            {
                self.http_requests.push(HttpReqItem {
                    from: bundle.inner.src,
                    id,
                    host,
                    method,
                    url,
                    headers,
                    body,
                    max_resp: max_resp_bytes,
                });
            }
        }

        // A passing ACK vaccinates us: the bundle it acknowledges is delivered, so
        // drop our copy and remember to drop any future copy (epidemic recovery). The
        // acked id rides in the *unsealed* AckTo destination, so relays can read it.
        if bundle.inner.flags.is_ack {
            if let Destination::AckTo(_, delivered) = bundle.inner.dst {
                self.store.remove(&delivered);
                self.relay_order.retain(|x| *x != delivered);
                self.immune.insert(delivered, self.now_ms);
                // The ACK for a bundle we forwarded is passing back through us — we're
                // on a working path between its endpoints, in both directions (§27).
                if let Some((s, d, _)) = self.forwarded.remove(&delivered) {
                    self.routes.learn(&s, &d, self.now_ms);
                }
            }
        } else if self.immune.contains_key(&id) {
            return; // already delivered elsewhere — don't re-store or re-flood it
        }

        // Not ours: store for onward relay, then offer to every other live link.
        let relay_src = bundle.inner.src;
        let relay_dst = match bundle.inner.dst {
            Destination::Device(d) => Some(d),
            _ => None,
        };
        if self.store.put(bundle, self.now_ms) {
            self.relay_order.push(id);
            // Remember we're carrying this toward `dst` so a returning ACK teaches the
            // route (§27). `or_insert` keeps our own-send record if we have one.
            if let Some(d) = relay_dst {
                self.forwarded.entry(id).or_insert((relay_src, d, self.now_ms));
                self.prune_forwarded_if_needed();
            }
            self.evict_relayed_if_needed();
            let links: Vec<LinkId> =
                self.links.keys().copied().filter(|l| *l != from_link).collect();
            for l in links {
                self.offer_bundles_to_link(l);
            }
        }
    }

    /// Keep relayed (not-ours) bundles within `max_relayed`. Custody policy (DESIGN.md §6):
    /// **never drop a bundle we haven't relayed at least once if we can avoid it** — so a
    /// flood of big transfers can't evict legitimate, not-yet-forwarded messages, and so
    /// the cap acts as a *sliding window* (chunks flow through: relayed, then evicted after
    /// a grace window) rather than a hard limit on transfer size. Eviction therefore
    /// prefers already-relayed, past-grace bundles, and only falls back to dropping a
    /// not-yet-relayed (or in-grace) bundle when nothing else can be freed (to bound
    /// memory). Within a tier the victim is the lowest-utility (priority, then route,
    /// then oldest). Our own messages are never here.
    fn evict_relayed_if_needed(&mut self) {
        let now = self.now_ms;
        while self.relay_order.len() > self.max_relayed {
            let victim =
                self.pick_evict_victim(now, true).or_else(|| self.pick_evict_victim(now, false));
            let Some((idx, id)) = victim else { break };
            self.relay_order.remove(idx);
            self.store.remove(&id);
            self.relay_fwd.remove(&id);
        }
    }

    /// Choose an eviction victim by lowest utility (priority, route, oldest). When
    /// `settled_only`, consider only bundles we've already relayed once and held past
    /// [`EVICT_GRACE_MS`] — the preferred, safe-to-drop set.
    fn pick_evict_victim(&self, now: u64, settled_only: bool) -> Option<(usize, BundleId)> {
        self.relay_order
            .iter()
            .enumerate()
            .filter(|(_, id)| {
                !settled_only
                    || self
                        .relay_fwd
                        .get(*id)
                        .is_some_and(|t| now.saturating_sub(*t) >= EVICT_GRACE_MS)
            })
            .min_by(|(ia, a), (ib, b)| {
                self.bundle_utility(a, now)
                    .partial_cmp(&self.bundle_utility(b, now))
                    .unwrap_or(std::cmp::Ordering::Equal)
                    .then(ia.cmp(ib))
            })
            .map(|(idx, id)| (idx, *id))
    }

    /// Bound the forwarded-route memory (§27): drop the oldest entries past the cap.
    fn prune_forwarded_if_needed(&mut self) {
        if self.forwarded.len() <= DEFAULT_MAX_FORWARDED {
            return;
        }
        let drop_n = self.forwarded.len() - DEFAULT_MAX_FORWARDED;
        let mut by_age: Vec<(BundleId, u64)> =
            self.forwarded.iter().map(|(k, v)| (*k, v.2)).collect();
        by_age.sort_by_key(|(_, t)| *t);
        for (k, _) in by_age.into_iter().take(drop_n) {
            self.forwarded.remove(&k);
        }
    }

    /// Emit an ACK bundle back to the origin of `orig`, sealed to its address.
    fn emit_ack(&mut self, orig: &Bundle) {
        // The ACK should survive as long as the message it confirms (so the sender keeps
        // hearing it while it's still retransmitting over a long hop), capped, and ride a
        // notch above bulk traffic so confirmations aren't stuck behind big transfers.
        let lifetime = orig.inner.lifetime_ms.min(MAX_ACK_LIFETIME_MS);
        let ack = Bundle::create(
            &self.identity,
            Destination::AckTo(orig.inner.src, orig.id()),
            &orig.inner.src,
            &Payload::Ack { for_bundle_id: orig.id(), status: 0, delivery_hops: orig.env.hops },
            BundleOpts {
                created_at: self.now_ms,
                lifetime_ms: lifetime,
                priority: orig.inner.priority.saturating_add(1),
                flags: BundleFlags { is_ack: true, ..Default::default() },
                ..Default::default()
            },
        );
        if let Ok(ack) = ack {
            // Track this ACK for replication (ride to N peers, then stop) and remember we
            // just acked this message (re-ACK throttle on duplicates).
            self.ack_replicate.entry(ack.id()).or_default();
            self.last_ack.insert(orig.id(), self.now_ms);
            self.submit(ack);
        }
    }

    fn on_advert(&mut self, peer: PubKeyBytes, advert: Advert) {
        let _ = peer; // reserved for finer-grained relay scoring (DESIGN.md §18)
        // Service adverts flood the directory (subscribed → full retention, else the
        // bounded relay cache). Re-gossip only when newly accepted.
        if self.directory.ingest(advert, self.now_ms).unwrap_or(false) {
            self.offer_adverts_to_all();
        }
    }

    // --- outbound offers ------------------------------------------------------

    fn offer_bundles_to_all(&mut self) {
        let links: Vec<LinkId> = self.links.keys().copied().collect();
        for l in links {
            self.offer_bundles_to_link(l);
        }
    }

    fn offer_adverts_to_all(&mut self) {
        let links: Vec<LinkId> = self.links.keys().copied().collect();
        for l in links {
            self.offer_adverts_to_link(l);
        }
    }

    /// Utility of a stored bundle for transmit-ordering and eviction (DESIGN.md §27):
    /// service priority dominates (×100 keeps priority bands separate), and learned
    /// reachability toward the destination orders bundles *within* a band — so a bundle
    /// toward a destination we have a route to beats one toward an unknown destination.
    fn bundle_utility(&self, id: &BundleId, now: u64) -> f64 {
        let Some(b) = self.store.get(id) else { return 0.0 };
        let route = match b.inner.dst {
            Destination::Device(d) => self.routes.utility(&d, now),
            _ => 0.0,
        };
        b.inner.priority as f64 * 100.0 + route
    }

    /// Offer stored bundles to one link, applying binary spray-and-wait.
    fn offer_bundles_to_link(&mut self, link: LinkId) {
        let me_short = short_addr(&self.identity.address());
        let me_app = short_app(&self.app);
        let now = self.now_ms;
        // Snapshot ids, ordered by utility so the most-likely-to-deliver bundles go
        // first during a short contact (DESIGN.md §27).
        let mut ids = self.store.have().ids;
        ids.sort_by(|a, b| {
            self.bundle_utility(b, now)
                .partial_cmp(&self.bundle_utility(a, now))
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        for id in ids {
            let Some(LinkState::Up(est)) = self.links.get(&link) else {
                return;
            };
            if est.sent_bundles.contains(&id) {
                continue;
            }
            let peer = est.peer;
            let Some(b) = self.store.get(&id) else {
                continue;
            };
            let meta = BundleMeta::from(&b);
            let direct = is_for(&b, &peer);
            // If we can reach the destination directly right now, don't spray copies
            // to relays — direct delivery on the destination's own link completes it.
            let dest_here = self.dest_is_connected(&b);

            // Our own originated messages: keep until the delivery ACK arrives (or
            // they expire), so we can re-flood if undelivered — don't release on a
            // mere handoff (DESIGN.md §6, §7).
            let own = self.tx.contains_key(&id);

            let to_send: Option<Bundle> = match self.router.should_forward(&meta, &peer) {
                ForwardDecision::Drop => {
                    self.store.remove(&id);
                    None
                }
                ForwardDecision::Hold => None,
                ForwardDecision::Forward if direct => {
                    let mut copy = b.clone();
                    if copy.forwarded() {
                        copy.add_hop(me_short, me_app); // provenance (§27)
                        if !own {
                            self.store.remove(&id); // relayed: release custody on delivery
                        }
                        Some(copy)
                    } else {
                        None
                    }
                }
                // Destination is directly reachable on its own link — deliver there,
                // don't also flood it to relays (the dest would just dedup the copies).
                ForwardDecision::Forward if dest_here => None,
                ForwardDecision::Forward => {
                    // Epidemic flood: hand a full copy to this neighbour and keep ours
                    // so we keep flooding to other/future neighbours. Copies are bounded
                    // by the hop limit and reclaimed by the delivery-ACK vaccine.
                    let mut copy = b.clone();
                    if copy.forwarded() {
                        copy.add_hop(me_short, me_app); // provenance (§27)
                        Some(copy)
                    } else {
                        None
                    }
                }
            };

            if let Some(copy) = to_send {
                self.send_record(link, &Wire::Bundle(copy));
                if let Some(LinkState::Up(est)) = self.links.get_mut(&link) {
                    est.sent_bundles.insert(id);
                }
                // Record the first handoff of a not-ours bundle so eviction can prefer
                // already-relayed, settled bundles over ones we haven't relayed yet (§6).
                if !own {
                    self.relay_fwd.entry(id).or_insert(now);
                }
                // A delivery-ACK we originated: count distinct peers it's reached; once it
                // has spread to ACK_REPLICATION_TARGET, it's done — drop it so it stops
                // riding to every contact (DESIGN.md §7).
                if let Some(peers) = self.ack_replicate.get_mut(&id) {
                    peers.insert(peer);
                    if peers.len() >= ACK_REPLICATION_TARGET {
                        self.ack_replicate.remove(&id);
                        self.store.remove(&id);
                    }
                }
                // "Sent N peers" counts relay handoffs only — not direct delivery to
                // the destination itself (that shows as Delivered once the ACK is back).
                if !direct {
                    if let Some(info) = self.tx.get_mut(&id) {
                        info.relayed.insert(peer);
                    }
                }
            }
        }
    }

    /// Gossip directory adverts to one link, ranked by relay utility isn't wired
    /// here yet (needs a scorer); plain offer for now (DESIGN.md §16, §18).
    fn offer_adverts_to_link(&mut self, link: LinkId) {
        let already: HashSet<crate::discover::AdvertId> = match self.links.get(&link) {
            Some(LinkState::Up(est)) => est.sent_adverts.clone(),
            _ => return,
        };
        let offer = self.directory.gossip_offer(&already);
        for advert in offer {
            let aid = advert.id;
            // Increment hop distance so receivers can show "N hops away".
            let mut fwd = advert;
            fwd.hops = fwd.hops.saturating_add(1);
            self.send_record(link, &Wire::Advert(fwd));
            if let Some(LinkState::Up(est)) = self.links.get_mut(&link) {
                est.sent_adverts.insert(aid);
            }
        }
    }

    // --- wire helpers ---------------------------------------------------------

    fn send_packet(&mut self, link: LinkId, packet: LinkPacket) {
        if let Ok(bytes) = postcard::to_allocvec(&packet) {
            self.outgoing.push((link, bytes));
        }
    }

    fn send_record(&mut self, link: LinkId, record: &Wire) {
        let Some(LinkState::Up(est)) = self.links.get_mut(&link) else {
            return;
        };
        let Ok(plaintext) = postcard::to_allocvec(record) else {
            return;
        };
        let Ok(ct) = est.session.encrypt(&plaintext) else {
            return;
        };
        if let Ok(bytes) = postcard::to_allocvec(&LinkPacket::Data(ct)) {
            self.outgoing.push((link, bytes));
        }
    }
}

impl<S: Store> Node<S> {
    /// Is the bundle's destination one of our currently-connected, authenticated
    /// peers? If so we can deliver directly and need not spray copies to relays.
    fn dest_is_connected(&self, bundle: &Bundle) -> bool {
        let dst = match bundle.inner.dst {
            Destination::Device(a) | Destination::AckTo(a, _) => a,
            Destination::InternetEgress => return false,
        };
        self.links
            .values()
            .any(|s| matches!(s, LinkState::Up(e) if e.peer == dst))
    }
}

/// Canonicalize a domain for HNS cache keys/lookups: lowercase, no trailing dot, no
/// surrounding whitespace. (DNS is case-insensitive; the root dot is implicit.)
fn normalize_domain(domain: &str) -> String {
    domain.trim().trim_end_matches('.').to_ascii_lowercase()
}

/// Is this bundle destined for `addr` (direct delivery)?
fn is_for(bundle: &Bundle, addr: &PubKeyBytes) -> bool {
    use crate::bundle::Destination::*;
    match &bundle.inner.dst {
        Device(d) => d == addr,
        AckTo(d, _) => d == addr,
        InternetEgress => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bundle::{BundleOpts, Destination, Payload};
    use crate::discover::AdvertKind;

    /// In-memory test fabric: pump nodes until quiescent, routing each node's
    /// outgoing bytes to the peer on the matching link id.
    struct Wire2 {
        // For a connection between node A and node B: A uses link `ab`, B uses `ba`.
        // map: (node_index, link_id) -> (other_node_index, other_link_id)
        routes: HashMap<(usize, LinkId), (usize, LinkId)>,
    }

    impl Wire2 {
        fn new() -> Self {
            Self { routes: HashMap::new() }
        }

        /// Connect nodes `a` and `b` with the given link ids and run the handshake.
        fn connect(&mut self, nodes: &mut [Node], a: usize, la: LinkId, b: usize, lb: LinkId) {
            self.routes.insert((a, la), (b, lb));
            self.routes.insert((b, lb), (a, la));
            nodes[a].handle(BearerEvent::Connected(la, Role::Initiator));
            nodes[b].handle(BearerEvent::Connected(lb, Role::Responder));
            self.pump(nodes);
        }

        /// Deliver all queued bytes until the network is quiescent.
        fn pump(&mut self, nodes: &mut [Node]) {
            for _ in 0..1000 {
                let mut any = false;
                for i in 0..nodes.len() {
                    for (link, bytes) in nodes[i].drain_outgoing() {
                        any = true;
                        if let Some(&(j, jl)) = self.routes.get(&(i, link)) {
                            nodes[j].handle(BearerEvent::Data(jl, bytes));
                        }
                    }
                }
                if !any {
                    break;
                }
            }
        }
    }

    fn msg(from: &Node, to: &Node, body: &[u8]) -> Bundle {
        Bundle::create(
            &from.identity,
            Destination::Device(to.address()),
            &to.identity.address(),
            &Payload::PeerMessage { content_type: "t".into(), body: body.to_vec() },
            BundleOpts::default(),
        )
        .unwrap()
    }

    #[test]
    fn ingest_holds_offline_device_bundle_for_handoff() {
        // A relay ingests a foreign alice→bob bundle from durable storage. With neither
        // endpoint connected it reports the bundle as undeliverable (so the backbone can
        // hand it into bob's region's mailbox, §28), preserving the sealed bytes verbatim.
        let mut relay = Node::new(Identity::generate());
        let alice = Identity::generate();
        let bob = Identity::generate();
        let b = Bundle::create(
            &alice,
            Destination::Device(bob.address()),
            &bob.address(),
            &Payload::PeerMessage { content_type: "t".into(), body: b"hi".to_vec() },
            BundleOpts::default(),
        )
        .unwrap();
        let id = b.id();

        relay.ingest(b.clone());
        let u = relay.undeliverable_device_bundles();
        assert_eq!(u.len(), 1, "the held device bundle is undeliverable while bob is offline");
        assert_eq!(u[0].0, id);
        assert_eq!(u[0].1, bob.address());
        let round = Bundle::from_bytes(&u[0].2).expect("sealed bytes round-trip");
        assert_eq!(round.id(), id);

        // Re-ingesting the same bundle is a no-op (dedup), not a duplicate.
        relay.ingest(b);
        assert_eq!(relay.undeliverable_device_bundles().len(), 1);
    }

    #[test]
    fn identify_service_round_trips() {
        // Calling the built-in hop.identify on a peer returns its name/kind/address,
        // answered by the node itself — nothing surfaces to the responder's app (§29).
        let mut nodes = [Node::new(Identity::generate()), Node::new(Identity::generate())];
        let mut net = Wire2::new();
        net.connect(&mut nodes, 0, 1, 1, 1);
        nodes[1].set_name(Some("Bob's Phone".into()));

        nodes[0]
            .send_service_request(nodes[1].address(), SERVICE_IDENTIFY.into(), String::new(), vec![])
            .unwrap();
        net.pump(&mut nodes);

        assert!(nodes[1].take_service_requests().is_empty(), "built-in is auto-answered");
        let resps = nodes[0].take_service_responses();
        assert_eq!(resps.len(), 1);
        assert_eq!(resps[0].status, 0);
        let rec: IdentityRecord = postcard::from_bytes(&resps[0].body).unwrap();
        assert_eq!(rec.name.as_deref(), Some("Bob's Phone"));
        assert_eq!(rec.kind, NodeKind::Device);
        assert_eq!(rec.address, nodes[1].address());
    }

    #[test]
    fn unnamed_node_identifies_with_no_name() {
        // A device with no name set returns None — the caller falls back to its short
        // address. The full address still comes back so the caller can resolve it.
        let mut nodes = [Node::new(Identity::generate()), Node::new(Identity::generate())];
        let mut net = Wire2::new();
        net.connect(&mut nodes, 0, 1, 1, 1);

        nodes[0]
            .send_service_request(nodes[1].address(), SERVICE_IDENTIFY.into(), String::new(), vec![])
            .unwrap();
        net.pump(&mut nodes);

        let resps = nodes[0].take_service_responses();
        let rec: IdentityRecord = postcard::from_bytes(&resps[0].body).unwrap();
        assert_eq!(rec.name, None);
        assert_eq!(rec.address, nodes[1].address());
    }

    #[test]
    fn custom_service_dispatches_to_app_and_replies() {
        // A non-hop. service surfaces to the responder's app, which replies; the caller
        // gets the response correlated by the request id.
        let mut nodes = [Node::new(Identity::generate()), Node::new(Identity::generate())];
        let mut net = Wire2::new();
        net.connect(&mut nodes, 0, 1, 1, 1);

        let req_id = nodes[0]
            .send_service_request(nodes[1].address(), "app.echo".into(), "say".into(), b"hi".to_vec())
            .unwrap();
        net.pump(&mut nodes);

        let reqs = nodes[1].take_service_requests();
        assert_eq!(reqs.len(), 1);
        assert_eq!(reqs[0].service, "app.echo");
        assert_eq!(reqs[0].method, "say");
        assert_eq!(reqs[0].args, b"hi");
        assert_eq!(reqs[0].id, req_id);
        let (from, for_id) = (reqs[0].from, reqs[0].id);
        nodes[1].send_service_response(from, for_id, 0, b"hi back".to_vec()).unwrap();
        net.pump(&mut nodes);

        let resps = nodes[0].take_service_responses();
        assert_eq!(resps.len(), 1);
        assert_eq!(resps[0].for_id, req_id);
        assert_eq!(resps[0].body, b"hi back");
        // The response is the return-path delete: the request no longer lingers in our
        // store (service calls carry no ACK-vaccine, so without this it would pin forever).
        assert!(!nodes[0].store.contains(&req_id), "request purged once its response arrives");
    }

    #[test]
    fn large_message_auto_streams_and_arrives_whole() {
        // A big message (e.g. an image body) exceeds one bundle, so it's transparently
        // carried as a stream of chunks and reassembled — arriving as a normal inbox
        // message with the right content type and exact bytes (DESIGN.md §20).
        let mut nodes = [Node::new(Identity::generate()), Node::new(Identity::generate())];
        let mut net = Wire2::new();
        net.connect(&mut nodes, 0, 1, 1, 1);

        let body: Vec<u8> = (0..200_000u32).map(|i| (i % 251) as u8).collect(); // ~200KB → multi-chunk
        nodes[0]
            .send_message(nodes[1].address(), "image/jpeg".into(), body.clone(), true)
            .unwrap();
        net.pump(&mut nodes);

        let inbox = nodes[1].take_inbox();
        assert_eq!(inbox.len(), 1, "reassembled into exactly one message");
        match inbox[0].open(&nodes[1].identity).unwrap() {
            Payload::PeerMessage { content_type, body: got } => {
                assert_eq!(content_type, "image/jpeg");
                assert_eq!(got, body, "bytes reassembled exactly, in order");
            }
            _ => panic!("wrong payload"),
        }
    }

    #[test]
    fn hops_request_response_round_trips() {
        // A hops:// request sealed to an endpoint surfaces there as an HTTP request; the
        // endpoint replies and the client gets the response, correlated by request id (§30).
        let mut nodes = [Node::new(Identity::generate()), Node::new(Identity::generate())];
        let mut net = Wire2::new();
        net.connect(&mut nodes, 0, 1, 1, 1);
        let endpoint = nodes[1].address();

        let req = nodes[0]
            .send_hops_request(
                endpoint,
                "example.hopme.sh".into(),
                "GET".into(),
                "/hello".into(),
                vec![],
                vec![],
                64_000,
            )
            .unwrap();
        net.pump(&mut nodes);

        // Endpoint side: the request is surfaced for the operator's translator.
        let reqs = nodes[1].take_http_requests();
        assert_eq!(reqs.len(), 1);
        assert_eq!(reqs[0].host, "example.hopme.sh");
        assert_eq!(reqs[0].method, "GET");
        assert_eq!(reqs[0].url, "/hello");
        let (from, rid) = (reqs[0].from, reqs[0].id);
        nodes[1].send_http_response(from, rid, 200, vec![], b"world".to_vec()).unwrap();
        net.pump(&mut nodes);

        // Client side: the response arrives, correlated to the request.
        let resps = nodes[0].take_http_responses();
        assert_eq!(resps.len(), 1);
        assert_eq!(resps[0].for_id, req);
        assert_eq!(resps[0].status, 200);
        assert_eq!(resps[0].body, b"world");
        assert!(!nodes[0].store.contains(&req), "request purged once answered");
    }

    #[test]
    fn internet_peer_resolves_hns_locally_no_relay() {
        // An internet-connected node resolves HNS itself: resolve_hns surfaces a real-DNS
        // lookup for the host to perform; provide_dns_answer caches it and yields the result.
        // No bundle, no relay round-trip (DESIGN.md §30).
        let mut node = Node::new(Identity::generate());
        node.set_internet(true);

        assert_eq!(node.resolve_hns("Example.HopMe.sh."), HnsLookup::Pending);
        let lookups = node.take_dns_lookups();
        assert_eq!(lookups, vec!["example.hopme.sh".to_string()], "normalized + queued for host");

        let endpoint = Identity::generate().address();
        node.provide_dns_answer("example.hopme.sh", Some(endpoint), 300);

        let results = node.take_hns_results();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].domain, "example.hopme.sh");
        assert_eq!(results[0].address, Some(endpoint));

        // Now cached: a second resolve serves from cache with no new lookup.
        assert_eq!(node.resolve_hns("example.hopme.sh"), HnsLookup::Cached(Some(endpoint)));
        assert!(node.take_dns_lookups().is_empty());
    }

    #[test]
    fn hns_missing_record_is_a_negative_result() {
        // hops://thisdoesnotexist.com — no _hopaddress TXT. The host reports None; we cache
        // the negative and surface a resolution error (address None), so we don't hammer DNS.
        let mut node = Node::new(Identity::generate());
        node.set_internet(true);
        assert_eq!(node.resolve_hns("thisdoesnotexist.com"), HnsLookup::Pending);
        node.provide_dns_answer("thisdoesnotexist.com", None, 60);

        let results = node.take_hns_results();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].address, None, "no endpoint → resolution error");
        assert_eq!(node.resolve_hns("thisdoesnotexist.com"), HnsLookup::Cached(None));
    }

    #[test]
    fn offline_node_resolves_hns_via_internet_peer() {
        // A node with no internet asks an internet-connected peer (e.g. a relay) over the
        // mesh. The peer does the DNS lookup and seals the answer back; the asker caches it.
        let mut nodes = [Node::new(Identity::generate()), Node::new(Identity::generate())];
        let mut net = Wire2::new();
        net.connect(&mut nodes, 0, 1, 1, 1);
        nodes[1].set_internet(true); // node 1 is the resolver
        let resolver = nodes[1].address();

        // Offline node can't resolve on its own.
        assert_eq!(nodes[0].resolve_hns("example.hopme.sh"), HnsLookup::NeedsResolver);

        // ...so it asks the resolver over the mesh.
        nodes[0].resolve_hns_via(resolver, "example.hopme.sh").unwrap();
        net.pump(&mut nodes);

        // Resolver surfaced the lookup to its host; host answers.
        let endpoint = Identity::generate().address();
        let lookups = nodes[1].take_dns_lookups();
        assert_eq!(lookups, vec!["example.hopme.sh".to_string()]);
        nodes[1].provide_dns_answer("example.hopme.sh", Some(endpoint), 300);
        net.pump(&mut nodes);

        // Asker received and cached the record.
        let results = nodes[0].take_hns_results();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].address, Some(endpoint));
        assert_eq!(nodes[0].cached_hns("example.hopme.sh"), Some(Some(endpoint)));
    }

    #[test]
    fn duplicate_to_destination_re_acks_then_throttles() {
        // If our delivery-ACK is lost, the sender retransmits; a duplicate reaching the
        // destination must re-emit the ACK (so the sender can stop) — but throttled, so a
        // burst of duplicates can't cause an ACK storm (DESIGN.md §7).
        let mut nodes = [Node::new(Identity::generate()), Node::new(Identity::generate())];
        let mut net = Wire2::new();
        net.connect(&mut nodes, 0, 1, 1, 1);

        let id = nodes[0]
            .send_to(&nodes[1].address(), "t".into(), b"hi".to_vec(), true)
            .unwrap()
            .unwrap();
        let msg = nodes[0].store.get(&id).expect("our message is in the store");
        net.pump(&mut nodes);
        assert!(nodes[1].take_inbox().len() == 1, "delivered once");

        // A duplicate arrives after the throttle window → re-ACK (something to send).
        nodes[1].set_time(REACK_MIN_INTERVAL_MS + 1);
        let _ = nodes[1].drain_outgoing();
        nodes[1].ingest(msg.clone());
        assert!(!nodes[1].drain_outgoing().is_empty(), "re-acked the duplicate");
        assert!(nodes[1].take_inbox().is_empty(), "but did NOT re-deliver to the inbox");

        // Another duplicate immediately → within throttle → no new ACK.
        nodes[1].ingest(msg);
        assert!(nodes[1].drain_outgoing().is_empty(), "throttled: no ACK storm");
    }

    #[test]
    fn eviction_prefers_already_relayed_over_not_yet_relayed() {
        // Custody policy (§6): under cap pressure, a bundle we've already relayed (and held
        // past the grace window) is evicted before one we haven't relayed yet — so a flood
        // of big transfers can't push out legitimate, not-yet-forwarded messages.
        let mut nodes = [Node::new(Identity::generate()), Node::new(Identity::generate())];
        let mut net = Wire2::new();
        net.connect(&mut nodes, 0, 1, 1, 1);
        nodes[0].set_time(0);
        nodes[0].set_max_relayed(1);

        let third = Identity::generate().address();
        let mk = |b: &[u8]| {
            Bundle::create(
                &Identity::generate(),
                Destination::Device(third),
                &third,
                &Payload::PeerMessage { content_type: "t".into(), body: b.to_vec() },
                BundleOpts::default(),
            )
            .unwrap()
        };

        // A: relayed onward to node1, so it's "already relayed".
        let a = mk(b"a");
        let a_id = a.id();
        nodes[0].ingest(a);
        net.pump(&mut nodes);
        // Lose the peer so the next bundle has nowhere to go (stays not-yet-relayed), and
        // age A past the grace window.
        nodes[0].handle(BearerEvent::Disconnected(1));
        nodes[0].set_time(EVICT_GRACE_MS);

        // B: cannot be forwarded (no peer) → not-yet-relayed. Ingesting it trips the cap.
        let b = mk(b"b");
        let b_id = b.id();
        nodes[0].ingest(b);

        assert!(!nodes[0].store.contains(&a_id), "already-relayed, past-grace bundle is evicted");
        assert!(nodes[0].store.contains(&b_id), "not-yet-relayed bundle is kept");
    }

    #[test]
    fn handshake_then_direct_delivery() {
        let mut nodes = [Node::new(Identity::generate()), Node::new(Identity::generate())];
        let mut net = Wire2::new();
        net.connect(&mut nodes, 0, 1, 1, 1);

        let b = msg(&nodes[0], &nodes[1], b"hello neighbor");
        nodes[0].submit(b);
        net.pump(&mut nodes);

        let inbox = nodes[1].take_inbox();
        assert_eq!(inbox.len(), 1);
        match inbox[0].open(&nodes[1].identity).unwrap() {
            Payload::PeerMessage { body, .. } => assert_eq!(body, b"hello neighbor"),
            _ => panic!("wrong payload"),
        }
    }

    #[test]
    fn send_to_connected_peer_uses_handshake_key() {
        // No keys exchanged out of band — the sender messages a peer it just met,
        // sealing with the key learned during the Noise handshake.
        let mut nodes = [Node::new(Identity::generate()), Node::new(Identity::generate())];
        let mut net = Wire2::new();
        net.connect(&mut nodes, 0, 1, 1, 1);

        let peers = nodes[0].peers();
        assert_eq!(peers, vec![nodes[1].address()]);

        let sent = nodes[0]
            .send_to(&nodes[1].address(), "text/plain".into(), b"hello peer".to_vec(), false)
            .unwrap();
        assert!(sent.is_some());
        net.pump(&mut nodes);

        let inbox = nodes[1].take_inbox();
        assert_eq!(inbox.len(), 1);
        match inbox[0].open(&nodes[1].identity).unwrap() {
            Payload::PeerMessage { body, .. } => assert_eq!(body, b"hello peer"),
            _ => panic!("wrong payload"),
        }

        // Sending to an unconnected address yields None, not an error.
        assert!(nodes[0]
            .send_to(&[9u8; 32], "t".into(), vec![], false)
            .unwrap()
            .is_none());
    }

    #[test]
    fn message_status_progresses_to_delivered() {
        let mut nodes = [Node::new(Identity::generate()), Node::new(Identity::generate())];
        let mut net = Wire2::new();
        net.connect(&mut nodes, 0, 1, 1, 1);

        let id = nodes[0]
            .send_to(&nodes[1].address(), "text/plain".into(), b"yo".to_vec(), true)
            .unwrap()
            .unwrap();
        // Direct delivery to the destination isn't a relay handoff, so the relay
        // count stays 0 (it shows as Delivered once the ACK returns, not "Sent N").
        assert_eq!(nodes[0].message_status(&id), Some((0, false, 0)));

        net.pump(&mut nodes);

        let (relayed, delivered, hops) = nodes[0].message_status(&id).unwrap();
        assert_eq!(relayed, 0, "direct delivery is not counted as a relay peer");
        assert!(delivered, "ACK came back across the network → Delivered");
        assert_eq!(hops, 1, "direct delivery → 1 forward hop");
    }

    #[test]
    fn direct_destination_is_not_sprayed_to_a_present_relay() {
        // 0 is directly linked to BOTH the destination (1) and a relay (2). Sending
        // 0→1 must deliver directly and NOT strand a sprayed copy in 2's relay queue.
        let mut nodes = [
            Node::new(Identity::generate()),
            Node::new(Identity::generate()),
            Node::new(Identity::generate()),
        ];
        let mut net = Wire2::new();
        net.connect(&mut nodes, 0, 1, 1, 2); // 0 <-> 1 (destination)
        net.connect(&mut nodes, 0, 3, 2, 4); // 0 <-> 2 (relay)

        let id = nodes[0]
            .send_message(nodes[1].address(), "text/plain".into(), b"hi".to_vec(), true)
            .unwrap();
        net.pump(&mut nodes);

        // Destination got it; the relay holds nothing for it.
        assert_eq!(nodes[1].take_inbox().len(), 1, "destination received directly");
        assert!(
            nodes[2].queue().is_empty(),
            "relay should not be holding a needless sprayed copy"
        );
        let (relayed, delivered, hops) = nodes[0].message_status(&id).unwrap();
        assert_eq!(relayed, 0, "no relay handoffs — delivered directly");
        assert!(delivered);
        assert_eq!(hops, 1);
    }

    #[test]
    fn forward_secret_session_end_to_end() {
        let mut nodes = [Node::new(Identity::generate()), Node::new(Identity::generate())];
        let mut net = Wire2::new();
        net.connect(&mut nodes, 0, 1, 1, 1);
        net.pump(&mut nodes);

        // Both advertise prekeys; gossip distributes them to each other.
        nodes[0].publish_prekey().unwrap();
        nodes[1].publish_prekey().unwrap();
        net.pump(&mut nodes);

        // 0 → 1 should open a forward-secret session (prekey known), not a static seal.
        let id = nodes[0]
            .send_message(nodes[1].address(), "text/plain".into(), b"secret hi".to_vec(), true)
            .unwrap();
        net.pump(&mut nodes);

        let inbox = nodes[1].take_inbox();
        assert_eq!(inbox.len(), 1);
        assert!(
            matches!(nodes[1].open(&inbox[0]).unwrap(), Payload::SessionInit { .. }),
            "should ride a session, not a static PeerMessage"
        );
        let msg = nodes[1].read_message(&inbox[0]).unwrap().unwrap();
        assert_eq!(msg.body, b"secret hi");
        assert_eq!(msg.from, nodes[0].address());

        // The ACK returned across the network → Delivered.
        let (_, delivered, _) = nodes[0].message_status(&id).unwrap();
        assert!(delivered, "session message should still ACK back");

        // 1 → 0 reply rides the same session (responder now has a sending chain).
        nodes[1]
            .send_message(nodes[0].address(), "text/plain".into(), b"reply".to_vec(), false)
            .unwrap();
        net.pump(&mut nodes);
        let inbox0 = nodes[0].take_inbox();
        assert_eq!(inbox0.len(), 1);
        let reply = nodes[0].read_message(&inbox0[0]).unwrap().unwrap();
        assert_eq!(reply.body, b"reply");
    }

    #[test]
    fn relays_across_an_intermediate_node() {
        // 0 <-> 1 <-> 2; 0 and 2 never connect directly. Message 0 -> 2.
        let mut nodes = [
            Node::new(Identity::generate()),
            Node::new(Identity::generate()),
            Node::new(Identity::generate()),
        ];
        let mut net = Wire2::new();
        net.connect(&mut nodes, 0, 10, 1, 11);
        net.connect(&mut nodes, 1, 12, 2, 13);

        let b = msg(&nodes[0], &nodes[2], b"relay me");
        nodes[0].submit(b);
        net.pump(&mut nodes);

        assert!(nodes[1].take_inbox().is_empty(), "relay must not absorb the bundle");
        let inbox = nodes[2].take_inbox();
        assert_eq!(inbox.len(), 1);
        match inbox[0].open(&nodes[2].identity).unwrap() {
            Payload::PeerMessage { body, .. } => assert_eq!(body, b"relay me"),
            _ => panic!("wrong payload"),
        }
    }

    #[test]
    fn delivery_ack_vaccinates_relays() {
        // 0 <-> 1 <-> 2. 0 → 2 (request ack). After delivery, the ACK floods back and
        // purges the relay's (1) copy and releases the source's (0) copy.
        let mut nodes = [
            Node::new(Identity::generate()),
            Node::new(Identity::generate()),
            Node::new(Identity::generate()),
        ];
        let mut net = Wire2::new();
        net.connect(&mut nodes, 0, 10, 1, 11);
        net.connect(&mut nodes, 1, 12, 2, 13);

        let id = nodes[0]
            .send_message(nodes[2].address(), "text/plain".into(), b"relay me".to_vec(), true)
            .unwrap();
        net.pump(&mut nodes);

        let (_, delivered, _) = nodes[0].message_status(&id).unwrap();
        assert!(delivered, "should be delivered across the relay");
        assert!(nodes[1].queue().is_empty(), "relay copy purged by the delivery-ACK vaccine");
        assert!(nodes[0].queue().is_empty(), "source releases its copy on ACK");
    }

    #[test]
    fn trace_records_each_relay_hop() {
        // 0 <-> 1 <-> 2; a message 0 → 2 should arrive carrying the short address of
        // each node that forwarded it (DESIGN.md §27).
        let mut nodes = [
            Node::new(Identity::generate()),
            Node::new(Identity::generate()),
            Node::new(Identity::generate()),
        ];
        let mut net = Wire2::new();
        net.connect(&mut nodes, 0, 10, 1, 11);
        net.connect(&mut nodes, 1, 12, 2, 13);
        let s0 = short_addr(&nodes[0].address());
        let s1 = short_addr(&nodes[1].address());

        let b = msg(&nodes[0], &nodes[2], b"trace me");
        nodes[0].submit(b);
        net.pump(&mut nodes);

        let inbox = nodes[2].take_inbox();
        assert_eq!(inbox.len(), 1);
        let trace = inbox[0].trace();
        assert!(trace.iter().any(|h| h.node == s0), "source's hop recorded");
        assert!(trace.iter().any(|h| h.node == s1), "relay's hop recorded");
        assert_eq!(trace.len(), 2, "exactly the two forwarders, in order");
        // App defaults to the shared fabric here (no set_app), stamped on each hop.
        assert!(trace.iter().all(|h| h.app == short_app(&FABRIC_APP)), "carrier app stamped");
    }

    #[test]
    fn relay_and_source_learn_route_from_returning_ack() {
        // 0 <-> 1 <-> 2. After 0 → 2 is delivered and the ACK floods back, the relay (1)
        // has learned it sits on the 0↔2 route — in both directions — and the source (0)
        // has learned it can reach 2 (DESIGN.md §27).
        let mut nodes = [
            Node::new(Identity::generate()),
            Node::new(Identity::generate()),
            Node::new(Identity::generate()),
        ];
        let mut net = Wire2::new();
        net.connect(&mut nodes, 0, 10, 1, 11);
        net.connect(&mut nodes, 1, 12, 2, 13);
        let a0 = nodes[0].address();
        let a2 = nodes[2].address();

        assert!(!nodes[1].knows_route(&a2), "relay starts with no learned route");
        nodes[0]
            .send_message(a2, "text/plain".into(), b"learn me".to_vec(), true)
            .unwrap();
        net.pump(&mut nodes);

        assert!(nodes[1].knows_route(&a0), "relay learned the route toward the source");
        assert!(nodes[1].knows_route(&a2), "relay learned the route toward the destination");
        assert!(nodes[0].knows_route(&a2), "source learned it can reach the destination");
    }

    #[test]
    fn link_is_encrypted_on_the_wire() {
        // The plaintext must never appear in the bytes crossing the bearer.
        let mut nodes = [Node::new(Identity::generate()), Node::new(Identity::generate())];
        let a = 0;
        nodes[a].handle(BearerEvent::Connected(1, Role::Initiator));
        nodes[1].handle(BearerEvent::Connected(1, Role::Responder));

        // Shuttle handshake by hand and capture all bytes.
        let mut captured: Vec<u8> = Vec::new();
        for _ in 0..8 {
            let out0 = nodes[0].drain_outgoing();
            let out1 = nodes[1].drain_outgoing();
            for (_, b) in &out0 {
                captured.extend_from_slice(b);
            }
            for (_, b) in &out1 {
                captured.extend_from_slice(b);
            }
            for (_, b) in out0 {
                nodes[1].handle(BearerEvent::Data(1, b));
            }
            for (_, b) in out1 {
                nodes[0].handle(BearerEvent::Data(1, b));
            }
        }

        let secret = b"top secret payload bytes";
        let bundle = msg(&nodes[0], &nodes[1], secret);
        nodes[0].submit(bundle);
        for (_, b) in nodes[0].drain_outgoing() {
            captured.extend_from_slice(&b);
            nodes[1].handle(BearerEvent::Data(1, b));
        }

        assert_eq!(nodes[1].take_inbox().len(), 1);
        assert!(
            !captured.windows(secret.len()).any(|w| w == secret),
            "plaintext leaked onto the wire"
        );
    }

    fn msg_ack(from: &Node, to: &Node, body: &[u8]) -> Bundle {
        Bundle::create(
            &from.identity,
            Destination::Device(to.address()),
            &to.identity.address(),
            &Payload::PeerMessage { content_type: "t".into(), body: body.to_vec() },
            BundleOpts {
                flags: BundleFlags { request_ack: true, ..Default::default() },
                ..Default::default()
            },
        )
        .unwrap()
    }

    #[test]
    fn ack_returns_and_clears_sender_pending() {
        let mut nodes = [Node::new(Identity::generate()), Node::new(Identity::generate())];
        let mut net = Wire2::new();
        net.connect(&mut nodes, 0, 1, 1, 1);

        let b = msg_ack(&nodes[0], &nodes[1], b"please confirm");
        nodes[0].submit(b);
        assert_eq!(nodes[0].pending_count(), 1, "sender tracks the unacked bundle");
        net.pump(&mut nodes);

        assert_eq!(nodes[1].take_inbox().len(), 1, "recipient got the message");
        assert!(nodes[0].take_inbox().is_empty(), "the ACK is consumed, not inboxed");
        assert_eq!(nodes[0].pending_count(), 0, "ACK cleared the sender's pending entry");
        assert_eq!(nodes[1].pending_count(), 0, "ACKs are not themselves tracked");
    }

    #[test]
    fn unacked_bundle_expires_after_its_lifetime() {
        let mut node = Node::new(Identity::generate());
        let other = Node::new(Identity::generate());
        // No links: nothing can deliver, so the bundle stays pending until expiry.
        let b = Bundle::create(
            &node.identity,
            Destination::Device(other.address()),
            &other.identity.address(),
            &Payload::PeerMessage { content_type: "t".into(), body: b"x".to_vec() },
            BundleOpts {
                created_at: 0,
                lifetime_ms: 1_000,
                flags: BundleFlags { request_ack: true, ..Default::default() },
                ..Default::default()
            },
        )
        .unwrap();
        node.submit(b);
        assert_eq!(node.pending_count(), 1);
        node.tick(500); // before lifetime — still pending
        assert_eq!(node.pending_count(), 1);
        node.tick(2_000); // past lifetime — given up
        assert_eq!(node.pending_count(), 0);
    }

    #[test]
    fn discover_presence_two_hops_away_and_message_it() {
        // 0 <-> 1 <-> 2. 0 and 2 never connect directly. 0 publishes an app-level
        // "presence" service carrying its display name; 2 discovers it via 1's gossip,
        // then messages 0's address — routed through 1. (The name↔address tie is an
        // app concern; the protocol only knows the service advert — DESIGN.md §4.)
        let mut nodes = [
            Node::new(Identity::generate()),
            Node::new(Identity::generate()),
            Node::new(Identity::generate()),
        ];
        let mut net = Wire2::new();
        net.connect(&mut nodes, 0, 10, 1, 11);
        net.connect(&mut nodes, 1, 12, 2, 13);

        nodes[0]
            .publish_service("presence".into(), "Alice".into(), String::new(), vec![], 600_000)
            .unwrap();
        net.pump(&mut nodes);

        let found = nodes[2].browse("presence", None);
        let alice = found.iter().find(|a| a.body.publisher == nodes[0].address());
        let alice = alice.expect("2 should discover Alice's presence via 1");
        assert!(matches!(&alice.body.kind, AdvertKind::Service { title, .. } if title == "Alice"));
        assert_eq!(alice.hops, 2, "Alice is two hops away via node 1");
        let addr = alice.body.publisher;

        nodes[2]
            .send_message(addr, "text/plain".into(), b"hi Alice".to_vec(), false)
            .unwrap();
        net.pump(&mut nodes);

        let inbox = nodes[0].take_inbox();
        assert_eq!(inbox.len(), 1);
        match inbox[0].open(&nodes[0].identity).unwrap() {
            Payload::PeerMessage { body, .. } => assert_eq!(body, b"hi Alice"),
            _ => panic!("wrong payload"),
        }
    }

    #[test]
    fn discovery_gossips_over_links() {
        // 0 publishes a market advert; 2 discovers it transitively through 1.
        let mut nodes = [
            Node::new(Identity::generate()),
            Node::new(Identity::generate()),
            Node::new(Identity::generate()),
        ];
        let mut net = Wire2::new();
        net.connect(&mut nodes, 0, 10, 1, 11);
        net.connect(&mut nodes, 1, 12, 2, 13);

        let advert = Advert::publish(
            &nodes[0].identity,
            AdvertKind::Service {
                service: "market".into(),
                title: "Bike for sale".into(),
                summary: "blue".into(),
                tags: vec!["bicycle".into()],
            },
            0,
            600_000,
            1,
        )
        .unwrap();
        nodes[0].publish(advert);
        net.pump(&mut nodes);

        let hits = nodes[2].directory.browse("market", Some("bicycle"));
        assert_eq!(hits.len(), 1, "advert should reach node 2 via node 1");
        assert_eq!(hits[0].body.publisher, nodes[0].address());
    }
}
