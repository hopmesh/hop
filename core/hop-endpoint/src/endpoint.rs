//! [`Endpoint`]: a `hop_core::Node` plus endpoint clustering, built only on the node's PUBLIC API.
//!
//! `Endpoint<S>` owns a `Node<S>` and `Deref`s to it, so every node call still works unchanged; it
//! adds a handful of shadowing methods that fold in the cluster coordinator ([`crate::cluster`]):
//!
//! - `cluster_join` registers the derived, pre-shared-key `hps://` cluster topic on the node
//!   (`hps_register_keyed`) and reloads the durable HANDLED set from the store.
//! - `tick` advances the node, then drains inbound cluster gossip and emits due gossip.
//! - `take_service_requests` shadows the node's: it drops any request a sibling already handled.
//! - `send_service_response` / `cluster_mark_done` mark completion so siblings drop their copies.
//! - `take_hps_messages` returns only the app's (non-cluster) `hps://` messages.
//!
//! No `hop-core` internals are touched: the gate is a post-filter, gossip rides `hps_publish` /
//! `take_hps_messages`, and the HANDLED set persists through the store's KV. DESIGN.md §40.

use std::ops::{Deref, DerefMut};

use rand_core::{OsRng, RngCore};

use hop_core::bundle::BundleId;
use hop_core::crypto::PubKeyBytes;
use hop_core::node::{HpsMessage, HttpReqItem, Node, ServiceReqItem};
use hop_core::store::Store;
use hop_core::Result;

use crate::cluster::{claim_key, ClaimKey, Cluster, ClusterMsg};

/// Store-KV prefix under which the durable HANDLED set is persisted (one entry per key, value = the
/// raw 32-byte [`ClaimKey`]), so a restarted replica still dedups.
const HANDLED_PREFIX: &str = "hop.cluster.handled.";

/// The `hps://` topic path the cluster gossips on, derived from the secret so outsiders cannot even
/// guess where to publish (defence in depth; the derived content key is the real gate).
fn cluster_topic_path(secret: &[u8; 32]) -> String {
    let d = blake3::derive_key("hop.cluster.path.v1", secret);
    let mut s = String::from("_hop.cluster/");
    push_hex(&mut s, &d[..8]);
    s
}

/// The symmetric content key every replica derives identically from the shared cluster secret.
fn content_key(secret: &[u8; 32]) -> [u8; 32] {
    blake3::derive_key("hop.cluster.content.v1", secret)
}

/// The KV key for one persisted HANDLED [`ClaimKey`] (prefix + lowercase hex).
fn handled_kv(k: &ClaimKey) -> String {
    let mut s = String::with_capacity(HANDLED_PREFIX.len() + 64);
    s.push_str(HANDLED_PREFIX);
    push_hex(&mut s, k);
    s
}

fn push_hex(s: &mut String, bytes: &[u8]) {
    for b in bytes {
        s.push(char::from_digit((b >> 4) as u32, 16).unwrap());
        s.push(char::from_digit((b & 0xf) as u32, 16).unwrap());
    }
}

/// A `hop_core::Node` with endpoint clustering. `Deref`s to the node, so `subscribe`, `handle`,
/// `drain_outgoing`, addressing, etc. are used exactly as before; the methods defined here shadow
/// the node's to fold in the cluster coordinator.
pub struct Endpoint<S: Store> {
    node: Node<S>,
    cluster: Option<Cluster>,
    /// The derived cluster topic path (present iff joined).
    cluster_path: Option<String>,
    /// Non-cluster `hps://` messages, separated out for the app on the way through.
    passthrough_hps: Vec<HpsMessage>,
}

impl<S: Store> Deref for Endpoint<S> {
    type Target = Node<S>;
    fn deref(&self) -> &Node<S> {
        &self.node
    }
}

impl<S: Store> DerefMut for Endpoint<S> {
    fn deref_mut(&mut self) -> &mut Node<S> {
        &mut self.node
    }
}

impl<S: Store> Endpoint<S> {
    /// Wrap a node as an endpoint. Not yet clustered until [`cluster_join`](Self::cluster_join).
    pub fn new(node: Node<S>) -> Self {
        Self {
            node,
            cluster: None,
            cluster_path: None,
            passthrough_hps: Vec::new(),
        }
    }

    /// Borrow the underlying node (for calls this wrapper does not shadow).
    pub fn node(&self) -> &Node<S> {
        &self.node
    }

    /// Mutably borrow the underlying node.
    pub fn node_mut(&mut self) -> &mut Node<S> {
        &mut self.node
    }

    /// Unwrap back to the plain node.
    pub fn into_inner(self) -> Node<S> {
        self.node
    }

    /// Join the endpoint cluster from a human passphrase (an env var / config value): the 32-byte
    /// cluster secret is derived from it, so every replica configured with the same passphrase joins
    /// the same cluster. Convenience over [`cluster_join`](Self::cluster_join).
    pub fn cluster_join_passphrase(&mut self, passphrase: &[u8]) {
        self.cluster_join(blake3::derive_key("hop.cluster.passphrase.v1", passphrase));
    }

    /// Join the endpoint cluster keyed by `secret` (every replica of one endpoint passes the same
    /// secret). Registers the derived pre-shared-key cluster topic on the node and reloads the
    /// durable HANDLED set, so dedup applies from the next poll on. A fresh random member id
    /// distinguishes this process from its siblings (which all share the endpoint identity).
    pub fn cluster_join(&mut self, secret: [u8; 32]) {
        let mut member = [0u8; 16];
        OsRng.fill_bytes(&mut member);
        let path = cluster_topic_path(&secret);
        self.node.hps_register_keyed(&path, content_key(&secret));
        let mut cluster = Cluster::new(member);
        let loaded: Vec<ClaimKey> = self
            .node
            .store
            .list_kv(HANDLED_PREFIX)
            .into_iter()
            .filter_map(|(_, v)| <[u8; 32]>::try_from(v.as_slice()).ok())
            .collect();
        cluster.load_handled(loaded);
        self.cluster = Some(cluster);
        self.cluster_path = Some(path);
    }

    /// True once [`cluster_join`](Self::cluster_join) has run.
    pub fn cluster_joined(&self) -> bool {
        self.cluster.is_some()
    }

    /// Live replica count (self + peers beaconing within the membership TTL); `1` if not clustered.
    pub fn cluster_members(&self) -> usize {
        match &self.cluster {
            Some(c) => c.member_count(self.node.now_ms()),
            None => 1,
        }
    }

    /// Whether request `(from, id)` would be dropped as already handled by a sibling replica.
    pub fn cluster_would_drop(&self, from: &PubKeyBytes, id: &BundleId) -> bool {
        match &self.cluster {
            Some(c) => c.is_handled(&claim_key(from, id)),
            None => false,
        }
    }

    /// Explicit completion for a fire-and-forget handler (no response to infer it from): mark the
    /// request handled and gossip it so siblings drop their copies.
    pub fn cluster_mark_done(&mut self, from: &PubKeyBytes, id: &BundleId) {
        self.mark_handled(from, id);
    }

    /// Advance the node, then apply inbound cluster gossip and emit any due gossip. Shadows
    /// `Node::tick`, so an endpoint driven the usual way clusters automatically.
    pub fn tick(&mut self, now_ms: u64) {
        self.node.tick(now_ms);
        self.pump_cluster(now_ms);
    }

    /// Drain custom service requests, dropping any a sibling replica already handled. Shadows
    /// `Node::take_service_requests`, so every caller gets dedup with no code change.
    pub fn take_service_requests(&mut self) -> Vec<ServiceReqItem> {
        let now = self.node.now_ms();
        self.pump_cluster(now);
        let reqs = self.node.take_service_requests();
        if self.cluster.is_none() {
            return reqs;
        }
        reqs.into_iter()
            .filter(|r| !self.cluster_would_drop(&r.from, &r.id))
            .collect()
    }

    /// Send a response AND record the request handled (responding is completion), so sibling
    /// replicas drop their copies. Shadows `Node::send_service_response`.
    pub fn send_service_response(
        &mut self,
        to: PubKeyBytes,
        for_id: BundleId,
        status: u16,
        body: Vec<u8>,
    ) -> Result<BundleId> {
        let id = self.node.send_service_response(to, for_id, status, body)?;
        self.mark_handled(&to, &for_id);
        Ok(id)
    }

    /// Drain HTTP-over-mesh requests, dropping any a sibling replica already handled (so a clustered
    /// origin endpoint proxies each request once). Shadows `Node::take_http_requests`.
    pub fn take_http_requests(&mut self) -> Vec<HttpReqItem> {
        let now = self.node.now_ms();
        self.pump_cluster(now);
        let reqs = self.node.take_http_requests();
        if self.cluster.is_none() {
            return reqs;
        }
        reqs.into_iter()
            .filter(|r| !self.cluster_would_drop(&r.from, &r.id))
            .collect()
    }

    /// Send an HTTP-over-mesh response AND mark the request handled, so sibling replicas drop their
    /// copies (the proxied origin call fires once). Shadows `Node::send_http_response`.
    pub fn send_http_response(
        &mut self,
        to: PubKeyBytes,
        for_id: BundleId,
        status: u16,
        headers: Vec<(String, String)>,
        body: Vec<u8>,
    ) -> Result<BundleId> {
        let id = self
            .node
            .send_http_response(to, for_id, status, headers, body)?;
        self.mark_handled(&to, &for_id);
        Ok(id)
    }

    /// Drain the app's `hps://` messages (cluster-internal gossip is filtered out). Shadows
    /// `Node::take_hps_messages`.
    pub fn take_hps_messages(&mut self) -> Vec<HpsMessage> {
        if self.cluster.is_none() {
            return self.node.take_hps_messages();
        }
        self.pump_cluster(self.node.now_ms());
        std::mem::take(&mut self.passthrough_hps)
    }

    fn mark_handled(&mut self, from: &PubKeyBytes, id: &BundleId) {
        let key = claim_key(from, id);
        let newly = match &mut self.cluster {
            Some(c) => c.mark_handled(key),
            None => false,
        };
        if newly {
            self.node.store.put_kv(&handled_kv(&key), key.to_vec());
        }
    }

    /// Drain inbound `hps://` messages, route cluster gossip into the coordinator (persisting newly
    /// learned keys) and set the rest aside for the app, then publish any due outbound gossip.
    fn pump_cluster(&mut self, now_ms: u64) {
        let path = match &self.cluster_path {
            Some(p) => p.clone(),
            None => return,
        };
        let msgs = self.node.take_hps_messages();
        let mut learned: Vec<ClaimKey> = Vec::new();
        let mut passthrough: Vec<HpsMessage> = Vec::new();
        let mut outbound: Vec<ClusterMsg> = Vec::new();
        if let Some(cluster) = self.cluster.as_mut() {
            for m in msgs {
                if m.path == path {
                    if let Ok(cm) = postcard::from_bytes::<ClusterMsg>(&m.body) {
                        learned.extend(cluster.on_gossip(&cm, now_ms));
                    }
                } else {
                    passthrough.push(m);
                }
            }
            outbound = cluster.tick(now_ms);
        }
        self.passthrough_hps.append(&mut passthrough);
        for k in learned {
            self.node.store.put_kv(&handled_kv(&k), k.to_vec());
        }
        for cm in outbound {
            if let Ok(bytes) = postcard::to_allocvec(&cm) {
                let _ = self.node.hps_publish(&path, &bytes);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hop_core::link::{BearerEvent, LinkId, Role};
    use hop_core::prelude::Identity;
    use hop_core::store::MemoryStore;
    use std::collections::HashMap;

    /// Minimal in-memory fabric over `Endpoint`s (which deref to `Node`), mirroring hop-core's
    /// `Wire2`: route each endpoint's outgoing bytes to the peer on the matching link id.
    struct Wire {
        routes: HashMap<(usize, LinkId), (usize, LinkId)>,
    }
    impl Wire {
        fn new() -> Self {
            Self {
                routes: HashMap::new(),
            }
        }
        fn connect(
            &mut self,
            eps: &mut [Endpoint<MemoryStore>],
            a: usize,
            la: LinkId,
            b: usize,
            lb: LinkId,
        ) {
            self.routes.insert((a, la), (b, lb));
            self.routes.insert((b, lb), (a, la));
            eps[a].handle(BearerEvent::Connected(la, Role::Initiator));
            eps[b].handle(BearerEvent::Connected(lb, Role::Responder));
            self.pump(eps);
        }
        fn pump(&mut self, eps: &mut [Endpoint<MemoryStore>]) {
            for _ in 0..1000 {
                let mut any = false;
                for i in 0..eps.len() {
                    for (link, bytes) in eps[i].drain_outgoing() {
                        any = true;
                        if let Some(&(j, jl)) = self.routes.get(&(i, link)) {
                            eps[j].handle(BearerEvent::Data(jl, bytes));
                        }
                    }
                }
                if !any {
                    break;
                }
            }
        }
    }

    fn ep(secret: Option<&[u8; 32]>) -> Endpoint<MemoryStore> {
        let id = match secret {
            Some(s) => Identity::from_secret_bytes(s),
            None => Identity::generate(),
        };
        Endpoint::new(Node::with_store(id, MemoryStore::new()))
    }

    #[test]
    fn a_handles_gossips_and_a_sibling_replica_will_dedup() {
        // Two replicas share ONE identity (so both can open the statically-sealed request) but no
        // shared store. A handles a request and gossips HANDLED over the private hps:// cluster
        // topic; B learns it and will now DROP that same request. Proven over the real transport.
        let e = [42u8; 32];
        let mut eps = [ep(Some(&e)), ep(Some(&e)), ep(None)]; // A, B, sender S
        assert_eq!(eps[0].address(), eps[1].address());
        let csecret = [7u8; 32];
        eps[0].cluster_join(csecret);
        eps[1].cluster_join(csecret);
        for e in eps.iter_mut() {
            e.set_time(1_000);
        }

        let mut net = Wire::new();
        net.connect(&mut eps, 0, 10, 1, 10); // A <-> B: cluster gossip link
        net.connect(&mut eps, 2, 1, 0, 1); // S -> A

        let a_addr = eps[0].address();
        let req_id = eps[2]
            .send_service_request(a_addr, "app.order".into(), "create".into(), b"{}".to_vec())
            .unwrap();
        net.pump(&mut eps);

        let reqs = eps[0].take_service_requests();
        assert_eq!(reqs.len(), 1, "A received the request");
        let (from, id) = (reqs[0].from, reqs[0].id);
        assert_eq!(id, req_id);
        assert!(
            !eps[1].cluster_would_drop(&from, &id),
            "B has not learned it"
        );

        eps[0]
            .send_service_response(from, id, 0, b"ok".to_vec())
            .unwrap();
        eps[0].tick(2_000);
        net.pump(&mut eps);
        eps[1].tick(2_000); // B drains + applies the inbound gossip on its own tick

        assert!(
            eps[1].cluster_would_drop(&from, &id),
            "B learned HANDLED over the cluster topic"
        );
        assert!(eps[1].cluster_members() >= 2, "B sees A as a live peer");
        assert!(
            !eps[1].cluster_would_drop(&from, &[9u8; 32]),
            "unrelated not dropped"
        );
    }

    #[test]
    fn dedup_gate_drops_the_sibling_handled_copy_end_to_end() {
        // Full path through the actual gate. A completes the request fire-and-forget (no response,
        // so the sender keeps its copies), gossips HANDLED to B, THEN the sender reaches B and
        // sprays it the SAME request bundle, which B must drop instead of surfacing to its app.
        let e = [42u8; 32];
        let mut eps = [ep(Some(&e)), ep(Some(&e)), ep(None)]; // A, B, sender S
        let csecret = [7u8; 32];
        eps[0].cluster_join(csecret);
        eps[1].cluster_join(csecret);
        for e in eps.iter_mut() {
            e.set_time(1_000);
        }

        let mut net = Wire::new();
        net.connect(&mut eps, 0, 10, 1, 10); // A <-> B: cluster gossip
        net.connect(&mut eps, 2, 1, 0, 1); // S -> A (S -> B comes later)

        let a_addr = eps[0].address();
        let req_id = eps[2]
            .send_service_request(a_addr, "app.order".into(), "create".into(), b"{}".to_vec())
            .unwrap();
        net.pump(&mut eps);

        let reqs = eps[0].take_service_requests();
        assert_eq!(reqs.len(), 1, "A received the request");
        let (from, id) = (reqs[0].from, reqs[0].id);

        eps[0].cluster_mark_done(&from, &id); // fire-and-forget: no response, sender keeps copies
        eps[0].tick(2_000);
        net.pump(&mut eps);
        eps[1].tick(2_000); // B drains + applies the inbound gossip

        assert!(
            eps[1].cluster_would_drop(&from, &id),
            "B learned HANDLED before its own copy arrives"
        );

        net.connect(&mut eps, 2, 2, 1, 2); // S -> B: sprays the SAME request bundle
        net.pump(&mut eps);

        assert!(
            eps[1].store.seen(&req_id),
            "B actually received the request bundle (guards against a vacuous pass)"
        );
        assert!(
            eps[1].take_service_requests().is_empty(),
            "B dropped the sibling-handled copy at the gate"
        );
    }

    #[test]
    fn unclustered_endpoint_is_a_transparent_passthrough() {
        // Without cluster_join, the endpoint behaves exactly like the bare node.
        let mut eps = [ep(None), ep(None)];
        let mut net = Wire::new();
        net.connect(&mut eps, 0, 1, 1, 1);
        let to = eps[1].address();
        let req_id = eps[0]
            .send_service_request(to, "s".into(), "m".into(), b"x".to_vec())
            .unwrap();
        net.pump(&mut eps);
        let reqs = eps[1].take_service_requests();
        assert_eq!(reqs.len(), 1);
        assert_eq!(reqs[0].id, req_id);
        assert_eq!(eps[1].cluster_members(), 1, "solo when unclustered");
        assert!(!eps[1].cluster_would_drop(&reqs[0].from, &reqs[0].id));
    }
}
