//! # hop-relay
//!
//! The internet-assisted relay (DESIGN.md §19). When any carrier touches the
//! internet, Hop can leap continents: an online node deposits the sealed bundles
//! it's carrying into a shared **mailbox** keyed by destination, and a different
//! online node near the destination fetches them and re-injects them into its
//! local BLE mesh. The internet becomes one very long store-and-forward hop.
//!
//! The mailbox is an **untrusted, best-effort** store: bundles are already sealed
//! end to end (DESIGN.md §4), so it holds ciphertext it cannot read — it only
//! indexes by `(AppId, destination)` and enforces TTL + capacity. This crate is
//! the protocol logic; a TCP/QUIC transport just serializes [`RelayMsg`] over a
//! socket (out of scope here).

pub mod backbone;
pub mod region;

use std::collections::HashMap;

use hop_core::bundle::{Bundle, BundleId, Destination};
use hop_core::crypto::PubKeyBytes;
use hop_core::AppId;
use serde::{Deserialize, Serialize};

/// Where a deposited bundle is filed for retrieval.
#[derive(Clone, PartialEq, Eq, Hash)]
enum MailKey {
    /// Addressed to a specific device (a peer message, response, or ACK).
    Device(PubKeyBytes),
    /// An internet-egress request — fetchable by any gateway-capable node.
    Egress,
}

fn mail_key(dst: &Destination) -> MailKey {
    match dst {
        Destination::Device(a) | Destination::AckTo(a, _) => MailKey::Device(*a),
        // Broadcasts flood live; they are not parked in a mailbox. Vaccines flood the same way —
        // they exist to chase down relay copies, so they must never park.
        Destination::Broadcast | Destination::Vaccine(..) => MailKey::Egress,
    }
}

struct Stored {
    id: BundleId,
    bundle: Bundle,
    expires_at: u64,
}

/// Capacity limits that keep an untrusted mailbox bounded.
#[derive(Clone, Copy, Debug)]
pub struct MailboxConfig {
    pub max_total: usize,
    pub max_per_dest: usize,
}

impl Default for MailboxConfig {
    fn default() -> Self {
        Self {
            max_total: 100_000,
            max_per_dest: 1_000,
        }
    }
}

/// The online store. Holds sealed bundles keyed by `(AppId, destination)`, bounded
/// by TTL and capacity, deduped by bundle id.
pub struct Mailbox {
    config: MailboxConfig,
    buckets: HashMap<(AppId, MailKey), Vec<Stored>>,
    index: HashMap<BundleId, (AppId, MailKey)>,
    order: Vec<BundleId>, // global FIFO for total-capacity eviction
}

impl Default for Mailbox {
    fn default() -> Self {
        Self::new(MailboxConfig::default())
    }
}

impl Mailbox {
    pub fn new(config: MailboxConfig) -> Self {
        Self {
            config,
            buckets: HashMap::new(),
            index: HashMap::new(),
            order: Vec::new(),
        }
    }

    /// Number of bundles currently held.
    pub fn len(&self) -> usize {
        self.index.len()
    }

    pub fn is_empty(&self) -> bool {
        self.index.is_empty()
    }

    /// Park a bundle for later retrieval. Verifies it (relays never carry forgeries),
    /// dedups by id, and enforces capacity. Returns false if invalid or a duplicate.
    pub fn deposit(&mut self, bundle: Bundle, now_ms: u64) -> bool {
        if bundle.verify().is_err() {
            return false;
        }
        let id = bundle.id();
        if self.index.contains_key(&id) {
            return false; // already held
        }
        let key = (bundle.inner.app, mail_key(&bundle.inner.dst));
        let expires_at = bundle
            .inner
            .created_at
            .saturating_add(bundle.inner.lifetime_ms as u64);
        if expires_at <= now_ms {
            return false; // already dead on arrival — don't park it
        }

        self.buckets.entry(key.clone()).or_default().push(Stored {
            id,
            bundle,
            expires_at,
        });
        self.index.insert(id, key.clone());
        self.order.push(id);

        // Per-destination cap: evict this bucket's oldest beyond the limit.
        while self.buckets.get(&key).map(|b| b.len()).unwrap_or(0) > self.config.max_per_dest {
            let oldest = self.buckets[&key][0].id;
            self.evict(oldest);
        }
        // Global cap: evict oldest overall.
        while self.index.len() > self.config.max_total {
            let oldest = self.order[0];
            self.evict(oldest);
        }
        true
    }

    /// Fetch (without removing) the non-expired bundles addressed to `address` in
    /// `app`. The fetcher re-injects them into its local mesh; downstream dedup
    /// handles any overlap, and `ack` can remove ones confirmed delivered.
    pub fn fetch(&mut self, app: AppId, address: &PubKeyBytes, now_ms: u64) -> Vec<Bundle> {
        self.prune_expired(now_ms);
        self.bundles_in(&(app, MailKey::Device(*address)))
    }

    /// Fetch internet-egress requests — for gateway-capable online nodes.
    pub fn fetch_egress(&mut self, app: AppId, now_ms: u64) -> Vec<Bundle> {
        self.prune_expired(now_ms);
        self.bundles_in(&(app, MailKey::Egress))
    }

    /// Drop a bundle that's been confirmed delivered onward.
    pub fn ack(&mut self, id: &BundleId) {
        self.evict(*id);
    }

    /// Remove every expired bundle.
    pub fn prune_expired(&mut self, now_ms: u64) {
        let expired: Vec<BundleId> = self
            .order
            .iter()
            .filter(|id| {
                self.index
                    .get(*id)
                    .and_then(|k| self.buckets.get(k))
                    .map(|b| b.iter().any(|s| s.id == **id && s.expires_at <= now_ms))
                    .unwrap_or(false)
            })
            .copied()
            .collect();
        for id in expired {
            self.evict(id);
        }
    }

    fn bundles_in(&self, key: &(AppId, MailKey)) -> Vec<Bundle> {
        self.buckets
            .get(key)
            .map(|b| b.iter().map(|s| s.bundle.clone()).collect())
            .unwrap_or_default()
    }

    fn evict(&mut self, id: BundleId) {
        if let Some(key) = self.index.remove(&id) {
            if let Some(bucket) = self.buckets.get_mut(&key) {
                bucket.retain(|s| s.id != id);
                if bucket.is_empty() {
                    self.buckets.remove(&key);
                }
            }
        }
        self.order.retain(|x| *x != id);
    }
}

/// The relay wire protocol between online peers. A TCP/QUIC transport serializes
/// these (e.g. postcard) over a socket; [`RelayServer`] processes them.
#[derive(Serialize, Deserialize)]
pub enum RelayMsg {
    /// Park a bundle in the mailbox. Boxed — a bundle dwarfs the other variants.
    Deposit(Box<Bundle>),
    /// Request bundles addressed to a device.
    Fetch {
        app: AppId,
        address: PubKeyBytes,
    },
    /// Request internet-egress bundles (for a gateway-capable node).
    FetchEgress {
        app: AppId,
    },
    /// Confirm a bundle was delivered onward; the mailbox may drop it.
    Ack(BundleId),
    /// A batch of bundles in response to a fetch.
    Bundles(Vec<Bundle>),
    Ok,
    Err(String),
}

/// Drives a [`Mailbox`] from [`RelayMsg`]s — the transport-agnostic relay server.
pub struct RelayServer {
    pub mailbox: Mailbox,
}

impl RelayServer {
    pub fn new(mailbox: Mailbox) -> Self {
        Self { mailbox }
    }

    /// Process one request, returning the response.
    pub fn handle(&mut self, msg: RelayMsg, now_ms: u64) -> RelayMsg {
        match msg {
            RelayMsg::Deposit(b) => {
                if self.mailbox.deposit(*b, now_ms) {
                    RelayMsg::Ok
                } else {
                    RelayMsg::Err("rejected or duplicate".into())
                }
            }
            RelayMsg::Fetch { app, address } => {
                RelayMsg::Bundles(self.mailbox.fetch(app, &address, now_ms))
            }
            RelayMsg::FetchEgress { app } => {
                RelayMsg::Bundles(self.mailbox.fetch_egress(app, now_ms))
            }
            RelayMsg::Ack(id) => {
                self.mailbox.ack(&id);
                RelayMsg::Ok
            }
            RelayMsg::Bundles(_) | RelayMsg::Ok | RelayMsg::Err(_) => {
                RelayMsg::Err("not a request".into())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hop_core::prelude::*;

    fn to_device(from: &Identity, to: &Identity, body: &[u8], lifetime_ms: u32) -> Bundle {
        Bundle::create(
            from,
            Destination::Device(to.address()),
            &to.address(),
            &Payload::PeerMessage {
                content_type: "t".into(),
                body: body.to_vec(),
            },
            BundleOpts {
                lifetime_ms,
                ..Default::default()
            },
        )
        .unwrap()
    }

    #[test]
    fn deposit_then_fetch_delivers_sealed_bundle() {
        // Origin and recipient never meet; the mailbox bridges them.
        let origin = Identity::generate();
        let recipient = Identity::generate();
        let mut mb = Mailbox::default();

        let b = to_device(&origin, &recipient, b"across the world", 600_000);
        assert!(mb.deposit(b.clone(), 0));

        // Anyone can fetch by destination address, but only the recipient can read.
        let fetched = mb.fetch(FABRIC_APP, &recipient.address(), 1);
        assert_eq!(fetched.len(), 1);
        fetched[0].verify().unwrap();
        match fetched[0].open(&recipient).unwrap() {
            Payload::PeerMessage { body, .. } => assert_eq!(body, b"across the world"),
            _ => panic!("wrong payload"),
        }
        // The mailbox itself holds ciphertext it cannot read.
        assert!(fetched[0].open(&origin).is_err());
    }

    #[test]
    fn dedups_and_isolates_by_destination() {
        let origin = Identity::generate();
        let a = Identity::generate();
        let b = Identity::generate();
        let mut mb = Mailbox::default();

        let m = to_device(&origin, &a, b"hi", 600_000);
        assert!(mb.deposit(m.clone(), 0));
        assert!(!mb.deposit(m, 0), "duplicate rejected");

        assert_eq!(mb.fetch(FABRIC_APP, &a.address(), 1).len(), 1);
        assert_eq!(mb.fetch(FABRIC_APP, &b.address(), 1).len(), 0, "not for b");
    }

    #[test]
    fn expired_bundles_are_pruned() {
        let origin = Identity::generate();
        let to = Identity::generate();
        let mut mb = Mailbox::default();
        // created_at 0, lifetime 1000 → expires at 1000.
        mb.deposit(to_device(&origin, &to, b"x", 1_000), 0);
        assert_eq!(mb.fetch(FABRIC_APP, &to.address(), 500).len(), 1);
        assert_eq!(mb.fetch(FABRIC_APP, &to.address(), 2_000).len(), 0);
        assert!(mb.is_empty());
    }

    #[test]
    fn per_destination_capacity_evicts_oldest() {
        let origin = Identity::generate();
        let to = Identity::generate();
        let mut mb = Mailbox::new(MailboxConfig {
            max_total: 100,
            max_per_dest: 2,
        });
        for i in 0..5u8 {
            mb.deposit(to_device(&origin, &to, &[i], 600_000), 0);
        }
        assert_eq!(
            mb.fetch(FABRIC_APP, &to.address(), 1).len(),
            2,
            "bucket capped"
        );
    }

    #[test]
    fn egress_requests_are_filed_separately() {
        let client = Identity::generate();
        let gw = Identity::generate();
        let mut mb = Mailbox::default();
        let req = Bundle::create(
            &client,
            Destination::Broadcast,
            &gw.address(),
            &Payload::HttpRequest {
                host: String::new(),
                method: "GET".into(),
                url: "https://example.com".into(),
                headers: vec![],
                body: vec![],
                max_resp_bytes: 1024,
            },
            BundleOpts::default(),
        )
        .unwrap();
        mb.deposit(req, 0);

        assert_eq!(mb.fetch_egress(FABRIC_APP, 1).len(), 1);
        assert_eq!(mb.fetch(FABRIC_APP, &client.address(), 1).len(), 0);
    }

    #[test]
    fn relay_server_protocol_roundtrip() {
        let origin = Identity::generate();
        let recipient = Identity::generate();
        let mut server = RelayServer::new(Mailbox::default());

        let b = to_device(&origin, &recipient, b"via protocol", 600_000);
        let id = b.id();
        assert!(matches!(
            server.handle(RelayMsg::Deposit(Box::new(b)), 0),
            RelayMsg::Ok
        ));

        let resp = server.handle(
            RelayMsg::Fetch {
                app: FABRIC_APP,
                address: recipient.address(),
            },
            1,
        );
        let RelayMsg::Bundles(bundles) = resp else {
            panic!("expected bundles")
        };
        assert_eq!(bundles.len(), 1);
        assert_eq!(bundles[0].id(), id);

        // Ack removes it from the mailbox.
        assert!(matches!(server.handle(RelayMsg::Ack(id), 2), RelayMsg::Ok));
        let resp = server.handle(
            RelayMsg::Fetch {
                app: FABRIC_APP,
                address: recipient.address(),
            },
            3,
        );
        assert!(matches!(resp, RelayMsg::Bundles(v) if v.is_empty()));
    }
}
