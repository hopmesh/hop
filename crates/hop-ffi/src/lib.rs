//! # hop-ffi
//!
//! The cross-platform binding surface (DESIGN.md §12): a thin, UniFFI-exported
//! wrapper around [`hop_core::node::Node`]. The host app links this (as a
//! `cdylib`/`staticlib`), runs the BLE bearer natively, and drives the node loop
//! through [`HopNode`] — feeding connection/data events in, draining outgoing
//! bytes out, and reading the inbox.
//!
//! Native bindings (Swift/Kotlin) are generated from this crate with the
//! `uniffi-bindgen` CLI; the exported types below are what those bindings expose.
//! Everything here is also callable from Rust, so the loop is testable end to end
//! without a device (see the tests).

use std::sync::{Arc, Mutex};

use hop_core::prelude::*;
use hop_store_sqlite::SqliteStore;

uniffi::setup_scaffolding!();

/// Build an identity from saved secret bytes, or a fresh one if absent/invalid.
fn identity_from(secret: &[u8]) -> Identity {
    match <[u8; 32]>::try_from(secret) {
        Ok(b) => Identity::from_secret_bytes(&b),
        Err(_) => Identity::generate(),
    }
}

/// Render an address as base58 (compact, copy/paste/QR-friendly).
#[uniffi::export]
pub fn address_base58(address: Vec<u8>) -> String {
    bs58::encode(address).into_string()
}

/// Decode a base58 address back to bytes (empty on invalid input).
#[uniffi::export]
pub fn address_from_base58(text: String) -> Vec<u8> {
    bs58::decode(text).into_vec().unwrap_or_default()
}

/// Opaque bytes to ship over the bearer on a given connection.
#[derive(uniffi::Record)]
pub struct OutPacket {
    pub link: u64,
    pub bytes: Vec<u8>,
}

/// A decrypted message delivered to this node.
#[derive(uniffi::Record)]
pub struct InboxMessage {
    /// Sender's hop address (Ed25519 public key).
    pub from: Vec<u8>,
    pub content_type: String,
    pub body: Vec<u8>,
    /// How many hops it travelled to reach us (A→B path length).
    pub hops: u8,
    /// Sender's clock (ms) when the message was created — signed by the sender.
    /// Subtract from local receive time for an end-to-end latency estimate.
    pub created_at: u64,
}

/// A service advert discovered via gossip (direct or relayed). The `publisher` is
/// the address to message — its sealing key is derived from it. Apps build presence
/// and contacts on this (e.g. a "presence" service whose `title` is a display name).
#[derive(uniffi::Record)]
pub struct ServiceHit {
    /// Publisher's hop address (Ed25519 public key) — message this to reach them.
    pub publisher: Vec<u8>,
    pub service: String,
    pub title: String,
    pub summary: String,
    pub tags: Vec<String>,
    /// Hops away through the mesh (1 = direct neighbour, ≥2 = via relays; 0 = unknown).
    pub hops: u8,
    /// Publisher clock (ms) when this advert was created — lets the app pick the
    /// freshest record per publisher (e.g. current foreground/background state).
    pub created_at: u64,
}

/// An egress HTTP request a gateway should fulfill (Use Case A, §9).
#[derive(uniffi::Record)]
pub struct HttpReq {
    /// Requester's address (seal the response back to this).
    pub from: Vec<u8>,
    /// The request bundle id (pass back as `for_request_id`).
    pub request_id: Vec<u8>,
    pub method: String,
    pub url: String,
    pub body: Vec<u8>,
    pub max_resp: u32,
}

/// An HTTP response sealed back to the requester.
#[derive(uniffi::Record)]
pub struct HttpResp {
    pub from: Vec<u8>,
    pub for_request_id: Vec<u8>,
    pub status: u16,
    pub body: Vec<u8>,
}

/// A live link to a directly-connected peer: its address + the bearer link id. The
/// host maps the link id to a transport (e.g. < 10000 = Bluetooth, ≥ 10000 = Wi-Fi).
#[derive(uniffi::Record)]
pub struct PeerLink {
    pub address: Vec<u8>,
    pub link: u64,
}

/// Delivery status of a message we sent (Sending / Sent N / Delivered).
#[derive(uniffi::Record)]
pub struct MessageStatus {
    /// Distinct peers we've handed a copy to ("Sent N").
    pub relayed: u32,
    /// The destination confirmed receipt back across the network.
    pub delivered: bool,
    /// Forward path length the destination observed (hops to delivery; 0 until delivered).
    pub delivery_hops: u8,
}

/// An item in the relay queue: ours awaiting send, or a peer's awaiting relay.
#[derive(uniffi::Record)]
pub struct QueueItem {
    pub id: Vec<u8>,
    /// True = our own message (pinned). False = relaying for a peer (decays).
    pub own: bool,
    /// Destination address (empty if internet-egress).
    pub to: Vec<u8>,
    pub priority: u8,
    pub hops: u8,
}

/// Errors crossing the FFI boundary.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FfiError {
    #[error("invalid key length (want 32 bytes)")]
    BadKey,
    #[error("hop error: {0}")]
    Hop(String),
}

fn to32(v: &[u8]) -> std::result::Result<[u8; 32], FfiError> {
    v.try_into().map_err(|_| FfiError::BadKey)
}

/// A running Hop node the host drives. Thread-safe (interior `Mutex`), handed to
/// the foreign side as a reference-counted object.
#[derive(uniffi::Object)]
pub struct HopNode {
    inner: Mutex<Node<SqliteStore>>,
}

#[uniffi::export]
impl HopNode {
    /// Create a node with a fresh identity and ephemeral in-memory storage.
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        let store = SqliteStore::open_in_memory().expect("in-memory sqlite");
        Arc::new(Self { inner: Mutex::new(Node::with_store(Identity::generate(), store)) })
    }

    /// Restore a node from a saved identity secret with ephemeral storage. Pass
    /// empty/invalid bytes to get a fresh identity.
    #[uniffi::constructor]
    pub fn with_secret(secret: Vec<u8>) -> Arc<Self> {
        let store = SqliteStore::open_in_memory().expect("in-memory sqlite");
        Arc::new(Self { inner: Mutex::new(Node::with_store(identity_from(&secret), store)) })
    }

    /// Open a node with **persistent** storage at `db_path` (messages survive
    /// restarts; bounded — older relayed messages are evicted to make room) and a
    /// saved identity secret. Falls back to in-memory if the path can't be opened.
    #[uniffi::constructor]
    pub fn open(db_path: String, secret: Vec<u8>) -> Arc<Self> {
        let store = SqliteStore::open(&db_path)
            .or_else(|_| SqliteStore::open_in_memory())
            .expect("sqlite store");
        Arc::new(Self { inner: Mutex::new(Node::with_store(identity_from(&secret), store)) })
    }

    /// Export this node's identity secret to persist (store it in the Keychain).
    pub fn secret(&self) -> Vec<u8> {
        self.inner.lock().unwrap().identity_secret().to_vec()
    }

    /// This node's hop address (Ed25519 public key).
    pub fn address(&self) -> Vec<u8> {
        self.inner.lock().unwrap().address().to_vec()
    }

    /// A bearer connection came up; `initiator` = we dialed it (BLE central).
    pub fn connected(&self, link: u64, initiator: bool) {
        let role = if initiator { Role::Initiator } else { Role::Responder };
        self.inner.lock().unwrap().handle(BearerEvent::Connected(link, role));
    }

    /// A bearer connection dropped.
    pub fn disconnected(&self, link: u64) {
        self.inner.lock().unwrap().handle(BearerEvent::Disconnected(link));
    }

    /// Bytes arrived on a connection.
    pub fn received(&self, link: u64, bytes: Vec<u8>) {
        self.inner.lock().unwrap().handle(BearerEvent::Data(link, bytes));
    }

    /// Bytes the host must send over the bearer (then clears them).
    pub fn drain_outgoing(&self) -> Vec<OutPacket> {
        self.inner
            .lock()
            .unwrap()
            .drain_outgoing()
            .into_iter()
            .map(|(link, bytes)| OutPacket { link, bytes })
            .collect()
    }

    /// Advance time: expire adverts, retransmit unacked bundles, prune dedup.
    pub fn tick(&self, now_ms: u64) {
        self.inner.lock().unwrap().tick(now_ms);
    }

    /// Subscribe the directory to a service topic.
    pub fn subscribe(&self, topic: String) {
        self.inner.lock().unwrap().subscribe(topic);
    }

    /// Send a peer message to `dst` (an address — sealing key is derived from it).
    /// Returns the bundle id. Set `request_ack` to track delivery confirmation.
    pub fn send_message(
        &self,
        dst: Vec<u8>,
        content_type: String,
        body: Vec<u8>,
        request_ack: bool,
    ) -> std::result::Result<Vec<u8>, FfiError> {
        let dst = to32(&dst)?;
        let id = self
            .inner
            .lock()
            .unwrap()
            .send_message(dst, content_type, body, request_ack)
            .map_err(|e| FfiError::Hop(e.to_string()))?;
        Ok(id.to_vec())
    }

    /// Publish a signed service advert that gossips across the mesh (even multiple
    /// hops away). Returns the advert id. Apps build presence on this — e.g. publish
    /// a "presence" service whose `title` is the user's display name. `ttlMs` bounds
    /// how long the record lives before it must be refreshed.
    pub fn publish_service(
        &self,
        service: String,
        title: String,
        summary: String,
        tags: Vec<String>,
        ttl_ms: u32,
    ) -> std::result::Result<Vec<u8>, FfiError> {
        let id = self
            .inner
            .lock()
            .unwrap()
            .publish_service(service, title, summary, tags, ttl_ms)
            .map_err(|e| FfiError::Hop(e.to_string()))?;
        Ok(id.to_vec())
    }

    /// Browse a service namespace (optionally filtered by tag) for adverts discovered
    /// across the mesh, with hop distance. Pass an empty `tag` for no filter.
    pub fn browse(&self, service: String, tag: String) -> Vec<ServiceHit> {
        let tag = if tag.is_empty() { None } else { Some(tag) };
        self.inner
            .lock()
            .unwrap()
            .browse(&service, tag.as_deref())
            .into_iter()
            .filter_map(|a| match a.body.kind {
                AdvertKind::Service { service, title, summary, tags } => Some(ServiceHit {
                    publisher: a.body.publisher.to_vec(),
                    service,
                    title,
                    summary,
                    tags,
                    hops: a.hops,
                    created_at: a.body.created_at,
                }),
                _ => None,
            })
            .collect()
    }

    /// Delivery status of a message we sent, by its bundle id.
    pub fn message_status(&self, id: Vec<u8>) -> MessageStatus {
        let blank = MessageStatus { relayed: 0, delivered: false, delivery_hops: 0 };
        let id = match to32(&id) {
            Ok(i) => i,
            Err(_) => return blank,
        };
        match self.inner.lock().unwrap().message_status(&id) {
            Some((relayed, delivered, delivery_hops)) => {
                MessageStatus { relayed, delivered, delivery_hops }
            }
            None => blank,
        }
    }

    /// The relay queue: our messages awaiting send (pinned) + peers' awaiting relay.
    pub fn queue(&self) -> Vec<QueueItem> {
        self.inner
            .lock()
            .unwrap()
            .queue()
            .into_iter()
            .map(|q| QueueItem {
                id: q.id.to_vec(),
                own: q.own,
                to: q.to.map(|a| a.to_vec()).unwrap_or_default(),
                priority: q.priority,
                hops: q.hops,
            })
            .collect()
    }

    /// Whether messaging `address` is forward-secret (a ratchet session exists)
    /// rather than static-sealed (DESIGN.md §25). Drives a lock indicator in the UI.
    pub fn is_secured(&self, address: Vec<u8>) -> bool {
        match to32(&address) {
            Ok(a) => self.inner.lock().unwrap().has_session(&a),
            Err(_) => false,
        }
    }

    /// Addresses of currently-connected, authenticated peers.
    pub fn peers(&self) -> Vec<Vec<u8>> {
        self.inner.lock().unwrap().peers().iter().map(|a| a.to_vec()).collect()
    }

    /// Live links `(address, link id)` — the host maps link ids to transports to show
    /// the route to each direct neighbour.
    pub fn peer_links(&self) -> Vec<PeerLink> {
        self.inner
            .lock()
            .unwrap()
            .peer_links()
            .into_iter()
            .map(|(address, link)| PeerLink { address: address.to_vec(), link })
            .collect()
    }

    /// Send a message to a directly-connected peer (sealed with the key learned at
    /// handshake). Returns the bundle id; errors if not connected to that address.
    pub fn send_to(
        &self,
        address: Vec<u8>,
        content_type: String,
        body: Vec<u8>,
        request_ack: bool,
    ) -> std::result::Result<Vec<u8>, FfiError> {
        let address = to32(&address)?;
        match self
            .inner
            .lock()
            .unwrap()
            .send_to(&address, content_type, body, request_ack)
            .map_err(|e| FfiError::Hop(e.to_string()))?
        {
            Some(id) => Ok(id.to_vec()),
            None => Err(FfiError::Hop("peer not connected".into())),
        }
    }

    /// Drain decrypted messages addressed to this node since the last call. Handles
    /// both static-sealed and forward-secret session messages uniformly.
    pub fn take_inbox(&self) -> Vec<InboxMessage> {
        let mut node = self.inner.lock().unwrap();
        let bundles = node.take_inbox();
        bundles
            .iter()
            .filter_map(|b| match node.read_message(b) {
                Ok(Some(m)) => Some(InboxMessage {
                    from: m.from.to_vec(),
                    content_type: m.content_type,
                    body: m.body,
                    hops: b.env.hops,
                    created_at: b.inner.created_at,
                }),
                _ => None,
            })
            .collect()
    }

    /// Publish this node's prekey so peers can open forward-secret sessions to it
    /// (DESIGN.md §25). Call at startup and re-publish periodically. Returns the
    /// advert id.
    pub fn publish_prekey(&self) -> std::result::Result<Vec<u8>, FfiError> {
        let id = self
            .inner
            .lock()
            .unwrap()
            .publish_prekey()
            .map_err(|e| FfiError::Hop(e.to_string()))?;
        Ok(id.to_vec())
    }

    /// Number of locally-sent bundles still awaiting an ACK.
    pub fn pending_count(&self) -> u32 {
        self.inner.lock().unwrap().pending_count() as u32
    }

    /// Send an internet-egress HTTP request, sealed to `gateway`'s address (Use Case
    /// A, §9). Returns the request bundle id. The response arrives via
    /// [`take_http_responses`].
    pub fn send_http_request(
        &self,
        gateway: Vec<u8>,
        method: String,
        url: String,
        body: Vec<u8>,
        max_resp: u32,
    ) -> std::result::Result<Vec<u8>, FfiError> {
        let gw = to32(&gateway)?;
        let id = self
            .inner
            .lock()
            .unwrap()
            .send_http_request(gw, method, url, vec![], body, max_resp)
            .map_err(|e| FfiError::Hop(e.to_string()))?;
        Ok(id.to_vec())
    }

    /// Seal an HTTP response back to a requester (gateway side).
    pub fn send_http_response(
        &self,
        to: Vec<u8>,
        for_request_id: Vec<u8>,
        status: u16,
        body: Vec<u8>,
    ) -> std::result::Result<(), FfiError> {
        let to = to32(&to)?;
        let for_id = to32(&for_request_id)?;
        self.inner
            .lock()
            .unwrap()
            .send_http_response(to, for_id, status, vec![], body)
            .map_err(|e| FfiError::Hop(e.to_string()))?;
        Ok(())
    }

    /// Drain egress HTTP requests addressed to this node as a gateway.
    pub fn take_http_requests(&self) -> Vec<HttpReq> {
        self.inner
            .lock()
            .unwrap()
            .take_http_requests()
            .into_iter()
            .map(|r| HttpReq {
                from: r.from.to_vec(),
                request_id: r.id.to_vec(),
                method: r.method,
                url: r.url,
                body: r.body,
                max_resp: r.max_resp,
            })
            .collect()
    }

    /// Drain HTTP responses sealed back to this node as a requester.
    pub fn take_http_responses(&self) -> Vec<HttpResp> {
        self.inner
            .lock()
            .unwrap()
            .take_http_responses()
            .into_iter()
            .map(|r| HttpResp {
                from: r.from.to_vec(),
                for_request_id: r.for_id.to_vec(),
                status: r.status,
                body: r.body,
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pump both nodes over a single symmetric link (id 1) until quiescent.
    fn pump(a: &HopNode, b: &HopNode) {
        for _ in 0..1000 {
            let oa = a.drain_outgoing();
            let ob = b.drain_outgoing();
            if oa.is_empty() && ob.is_empty() {
                break;
            }
            for p in oa {
                b.received(p.link, p.bytes);
            }
            for p in ob {
                a.received(p.link, p.bytes);
            }
        }
    }

    #[test]
    fn identity_secret_round_trips_address() {
        let a = HopNode::new();
        let addr = a.address();
        let sec = a.secret();
        assert_eq!(sec.len(), 32, "secret is the 32-byte Ed25519 seed");
        // Restoring from the saved secret MUST reproduce the same address.
        let b = HopNode::with_secret(sec.clone());
        assert_eq!(b.address(), addr, "restored identity keeps the same address");
        // And the persistent constructor must do the same.
        let c = HopNode::open(":memory:".into(), sec);
        assert_eq!(c.address(), addr, "persistent restore keeps the same address");
    }

    #[test]
    fn two_nodes_handshake_and_message_over_ffi() {
        let a = HopNode::new();
        let b = HopNode::new();

        a.connected(1, true);
        b.connected(1, false);
        pump(&a, &b);

        a.send_message(b.address(), "text/plain".into(), b"hi over ffi".to_vec(), false)
            .unwrap();
        pump(&a, &b);

        let inbox = b.take_inbox();
        assert_eq!(inbox.len(), 1);
        assert_eq!(inbox[0].body, b"hi over ffi");
        assert_eq!(inbox[0].from, a.address());
    }

    #[test]
    fn rejects_bad_key_length() {
        let a = HopNode::new();
        let err = a.send_message(vec![0u8; 10], "t".into(), vec![], false);
        assert!(matches!(err, Err(FfiError::BadKey)));
    }
}
