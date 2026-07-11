//! The genuinely wasm-only surface of this crate: the `#[wasm_bindgen]` `WasmNode` export and the
//! `StoreBridge` JS-callback bridge. **None of this can execute under a host `cargo test`.**
//!
//! `StoreBridge` is a wasm-bindgen `extern "C"` import: on any non-wasm32 target its methods compile
//! to stubs that panic ("cannot call wasm-bindgen imported functions on non-wasm targets"). You also
//! cannot construct a `StoreBridge` value on the host at all (it is an opaque JS handle). So every
//! `WasmNode` method (each drives a real `Node<JsStore<StoreBridge>>`, which reads/writes the bridge)
//! and the `impl Bridge for StoreBridge` forwards are only ever reachable in a browser/node wasm
//! runtime.
//!
//! This mirrors the driver layer's device-code exclusion (`HopBearer+Radios.swift` / `HopLink.swift`
//! are split out and dropped from the Swift coverage denominator because they need real radios). This
//! file is likewise **excluded from the host coverage denominator** (see `tarpaulin.toml`), because it
//! is structurally unrunnable on the host. It is exercised for real by `node sim/scenario-check.mjs`,
//! which builds this exact crate to wasm and drives all 15 homepage scenarios through `WasmNode` +
//! `StoreBridge` end to end (each scripted send delivers and its ACK returns), plus the CI `wasm` job's
//! `cargo build -p hop-wasm --target wasm32-unknown-unknown`.
//!
//! The host-testable logic these thin wrappers call lives in `store.rs` (the `JsStore<B>` `Store`
//! contract over an in-memory `Bridge`) and `lib.rs` (the flat codecs + value-struct getters), each
//! covered by real unit tests there. `WasmNode`'s methods are one-line forwards onto `Node`, whose
//! behavior is unit-tested in `store.rs` against the exact `Node<JsStore<FakeBridge>>` they wrap.

use crate::store::{Bridge, JsStore};
use crate::{encode_gradient, encode_sends_status};
use crate::{ChannelMsg, Delivered, OutPacket, Transfer};
use hop_core::crypto::{Identity, PubKeyBytes};
use hop_core::link::{BearerEvent, Role};
use hop_core::node::Node;
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
extern "C" {
    /// A per-node host object implementing synchronous bundle storage. In the browser Worker this is
    /// SQLite/OPFS; in Node tests a Map or better-sqlite3. Ids are 32 bytes; data is postcard bundle
    /// bytes. All methods are synchronous (OPFS sync-access handles make this possible in a Worker).
    pub type StoreBridge;

    /// Insert if this id is not already `seen`. Returns false if it was a duplicate (dedup).
    #[wasm_bindgen(method)]
    fn put(this: &StoreBridge, id: &[u8], data: &[u8], expires_at: f64) -> bool;
    /// The held bundle bytes for `id`, or undefined.
    #[wasm_bindgen(method)]
    fn get(this: &StoreBridge, id: &[u8]) -> Option<Vec<u8>>;
    /// Drop the held data for `id` (keep its dedup entry); return the removed bytes if any.
    #[wasm_bindgen(method)]
    fn remove(this: &StoreBridge, id: &[u8]) -> Option<Vec<u8>>;
    /// Still deduping this id (seen and not expired)?
    #[wasm_bindgen(method)]
    fn seen(this: &StoreBridge, id: &[u8]) -> bool;
    /// The receiver-anchored dedup expiry (epoch-ms) stamped for `id` at `put` time, or undefined if
    /// not tracked. This is the `expires_at` column of the `seen` row (stores-r3-01): a wasm relay's
    /// handoff/spool re-mirror anchors Firestore's `expireAt` to this receiver-clock deadline, never
    /// the sender's advisory `created_at`.
    #[wasm_bindgen(method, js_name = seenExpiry)]
    fn seen_expiry(this: &StoreBridge, id: &[u8]) -> Option<f64>;
    /// Currently holding this id (not just seen)?
    #[wasm_bindgen(method)]
    fn contains(this: &StoreBridge, id: &[u8]) -> bool;
    /// All held ids, concatenated as 32-byte chunks.
    #[wasm_bindgen(method)]
    fn have(this: &StoreBridge) -> Vec<u8>;
    /// Drop held bundles + dedup entries whose window has closed at `now_ms`.
    #[wasm_bindgen(method)]
    fn prune(this: &StoreBridge, now_ms: f64);
    /// Overwrite the held data for `id` (copy-budget mutation). No-op if not held.
    #[wasm_bindgen(method, js_name = setData)]
    fn set_data(this: &StoreBridge, id: &[u8], data: &[u8]);
    #[wasm_bindgen(method, js_name = kvPut)]
    fn kv_put(this: &StoreBridge, key: &str, value: &[u8]);
    #[wasm_bindgen(method, js_name = kvGet)]
    fn kv_get(this: &StoreBridge, key: &str) -> Option<Vec<u8>>;
    #[wasm_bindgen(method, js_name = kvRemove)]
    fn kv_remove(this: &StoreBridge, key: &str);
    /// Every `(key, value)` whose key starts with `prefix`, flat-encoded as repeated
    /// `[u32 LE keylen][key utf8][u32 LE vallen][val]` records.
    #[wasm_bindgen(method, js_name = kvList)]
    fn kv_list(this: &StoreBridge, prefix: &str) -> Vec<u8>;
}

/// The production [`Bridge`]: a pure forward onto the wasm-bindgen [`StoreBridge`] host object
/// (SQLite/OPFS in a Worker). Every method is a one-to-one passthrough, no behavior change, so the
/// host tests against an in-memory `Bridge` fake exercise identical `JsStore` logic.
impl Bridge for StoreBridge {
    fn put(&self, id: &[u8], data: &[u8], expires_at: f64) -> bool {
        StoreBridge::put(self, id, data, expires_at)
    }
    fn get(&self, id: &[u8]) -> Option<Vec<u8>> {
        StoreBridge::get(self, id)
    }
    fn remove(&self, id: &[u8]) -> Option<Vec<u8>> {
        StoreBridge::remove(self, id)
    }
    fn seen(&self, id: &[u8]) -> bool {
        StoreBridge::seen(self, id)
    }
    fn seen_expiry(&self, id: &[u8]) -> Option<f64> {
        StoreBridge::seen_expiry(self, id)
    }
    fn contains(&self, id: &[u8]) -> bool {
        StoreBridge::contains(self, id)
    }
    fn have(&self) -> Vec<u8> {
        StoreBridge::have(self)
    }
    fn prune(&self, now_ms: f64) {
        StoreBridge::prune(self, now_ms)
    }
    fn set_data(&self, id: &[u8], data: &[u8]) {
        StoreBridge::set_data(self, id, data)
    }
    fn kv_put(&self, key: &str, value: &[u8]) {
        StoreBridge::kv_put(self, key, value)
    }
    fn kv_get(&self, key: &str) -> Option<Vec<u8>> {
        StoreBridge::kv_get(self, key)
    }
    fn kv_remove(&self, key: &str) {
        StoreBridge::kv_remove(self, key)
    }
    fn kv_list(&self, prefix: &str) -> Vec<u8> {
        StoreBridge::kv_list(self, prefix)
    }
}

/// A real Hop node, one per person on the map.
#[wasm_bindgen]
pub struct WasmNode {
    node: Node<JsStore>,
    addr: Vec<u8>,
}

#[wasm_bindgen]
impl WasmNode {
    /// Build a node from a 32-byte identity seed (deterministic address across reloads) and a host
    /// storage `bridge` (SQLite/OPFS in the Worker, a Map in Node tests), bundles live there, not
    /// in wasm memory, so a many-node tab doesn't OOM while the core runs unchanged.
    #[wasm_bindgen(constructor)]
    pub fn new(secret: &[u8], bridge: StoreBridge) -> WasmNode {
        let identity = <[u8; 32]>::try_from(secret)
            .map(|b| Identity::from_secret_bytes(&b))
            .unwrap_or_else(|_| Identity::generate());
        let node = Node::with_store(identity, JsStore::new(bridge));
        let addr = node.address().to_vec();
        WasmNode { node, addr }
    }

    /// This node's 32-byte public address, use it as a `dst` for `send`.
    #[wasm_bindgen(getter)]
    pub fn address(&self) -> Vec<u8> {
        self.addr.clone()
    }

    /// Advance the node's clock (ms). Expires adverts, retransmits, prunes routing state.
    pub fn tick(&mut self, now_ms: f64) {
        self.node.tick(now_ms as u64);
    }

    /// A bearer link came up. One side is the initiator; JS decides (e.g. lower id dials).
    pub fn connected(&mut self, link: u32, initiator: bool) {
        let role = if initiator {
            Role::Initiator
        } else {
            Role::Responder
        };
        self.node.handle(BearerEvent::Connected(link as u64, role));
    }

    /// A bearer link dropped.
    pub fn disconnected(&mut self, link: u32) {
        self.node.handle(BearerEvent::Disconnected(link as u64));
    }

    /// Feed in bytes that arrived on a link from the peer.
    pub fn receive(&mut self, link: u32, data: &[u8]) {
        self.node
            .handle(BearerEvent::Data(link as u64, data.to_vec()));
    }

    /// Pull the bytes this node wants to send out this frame (deliver each to its link's peer).
    pub fn drain(&mut self) -> Vec<OutPacket> {
        self.node
            .drain_outgoing()
            .into_iter()
            .map(|(link, data)| OutPacket {
                link: link as u32,
                data,
            })
            .collect()
    }

    /// Turn on real-bundle-per-link observability so `drain_transfers` reports hops.
    pub fn set_observe(&mut self, on: bool) {
        self.node.set_observe(on);
    }

    /// The `(link, bundle_id, is_final_delivery)` transfers this node made since the last call,
    /// one per real bundle handed over a link. Color legs by `bundle`, solid when `delivered`.
    pub fn drain_transfers(&mut self) -> Vec<Transfer> {
        self.node
            .drain_transfers()
            .into_iter()
            .map(|(link, id, delivered)| Transfer {
                link: link as u32,
                bundle: id.to_vec(),
                delivered,
            })
            .collect()
    }

    /// Ids of our own sends confirmed delivered (by a returning ACK) since the last call, flat 32-byte
    /// ids. The sender only learns delivery this way, a per-device UI shows "delivered" off this.
    pub fn drain_delivered(&mut self) -> Vec<u8> {
        self.node
            .drain_delivered()
            .into_iter()
            .flat_map(|id| id.to_vec())
            .collect()
    }

    /// Set the lifetime (ms) stamped on messages/ACKs this node sends, the sender's real per-bundle
    /// TTL choice. The store prunes on it, so relay copies of delivered messages expire on schedule.
    pub fn set_default_lifetime_ms(&mut self, ms: f64) {
        self.node.set_default_lifetime_ms(ms as u32);
    }

    /// Per-message send status, flat-encoded as repeated [32-byte id][u16 LE peers][u8 delivered].
    /// Mirrors the debug app's Sending / Sent·N / Delivered.
    pub fn sends_status(&self) -> Vec<u8> {
        encode_sends_status(self.node.sends_status())
    }

    /// Which bundles this node currently holds, as a flat concatenation of 32-byte ids (display ids,
    /// so a deferred send's copies still match the id `send` returned). The sim intersects this with
    /// the message bundles to draw only hops whose copy still exists.
    pub fn held_ids(&self) -> Vec<u8> {
        self.node
            .held_bundle_ids_display()
            .into_iter()
            .flat_map(|id| id.to_vec())
            .collect()
    }

    /// Publish this node's prekey advert so peers can open forward-secret sessions to it.
    /// Must be called (and gossiped over a link) before `send` can seal to this node.
    pub fn publish_prekey(&mut self) -> Result<(), JsValue> {
        self.node
            .publish_prekey()
            .map(|_| ())
            .map_err(|e| JsValue::from_str(&format!("{e:?}")))
    }

    /// Publish a §39 receive beacon so relays lay a gradient toward this node's mailbox-tag, turning
    /// blind flood into directed route-toward (§39 P4). Re-publish before the 90s soft-state TTL lapses.
    pub fn publish_recv_beacon(&mut self) -> Result<(), JsValue> {
        self.node
            .publish_recv_beacon()
            .map(|_| ())
            .map_err(|e| JsValue::from_str(&format!("{e:?}")))
    }

    /// Which mailbox-tags this node currently holds a gradient toward, and the inbound link to forward
    /// down for each, flat `[16-byte tag][u32 LE link][u8 hops]` records. Lets the sim draw the
    /// distributed routing tree (each device holds a slice) + which way a private bundle would steer.
    pub fn gradient(&self) -> Vec<u8> {
        encode_gradient(self.node.recv_gradient_view())
    }

    /// This node's current §39 mailbox-tag (16 bytes), the key a relay's gradient points toward, so
    /// the sim can find the routing tree steering a private bundle to this recipient.
    pub fn mailbox_tag(&self) -> Vec<u8> {
        self.node.current_mailbox_tag().to_vec()
    }

    /// Did this node just emit a §39 recv-beacon? Lets the sim ripple a node as it advertises reachability.
    pub fn drain_beaconed(&mut self) -> bool {
        self.node.drain_beaconed()
    }

    /// Diagnostics: deferred sends still waiting on a prekey ("Securing…").
    pub fn pending_count(&self) -> usize {
        self.node.pending_count()
    }

    /// Diagnostics: do we hold `addr`'s prekey (could we seal to them right now)?
    pub fn knows_prekey(&self, addr: &[u8]) -> bool {
        match <[u8; 32]>::try_from(addr) {
            Ok(a) => self.node.knows_prekey(&a),
            Err(_) => false,
        }
    }

    /// Host a group CHANNEL at `path` (hps://, §32): any member holding the content key reads and
    /// writes; every post is verified against its writer's own address.
    pub fn register_channel(&mut self, path: &str) {
        let _ = self.node.register_service(
            path,
            hop_core::hps::ServiceKind::Channel,
            hop_core::hps::AccessMode::Open,
            hop_core::hps::Visibility::Private,
        );
    }

    /// Join `host`'s channel at `path` (requests the content key over the mesh).
    pub fn channel_subscribe(&mut self, host: &[u8], path: &str) -> Result<(), JsValue> {
        let h: PubKeyBytes = host
            .try_into()
            .map_err(|_| JsValue::from_str("host must be 32 bytes"))?;
        self.node
            .hps_subscribe(h, path)
            .map(|_| ())
            .map_err(|e| JsValue::from_str(&format!("{e:?}")))
    }

    /// Post to a channel we're a member of, ONE message, every member receives it (real fan-out).
    /// Returns the broadcast bundle's id so the sim can trace its flood.
    pub fn channel_publish(&mut self, path: &str, body: &[u8]) -> Result<Vec<u8>, JsValue> {
        self.node
            .hps_publish(path, body)
            .map(|id| id.to_vec())
            .map_err(|e| JsValue::from_str(&format!("{e:?}")))
    }

    /// Channel posts that arrived since the last call (decrypted + writer-verified).
    pub fn take_channel(&mut self) -> Vec<ChannelMsg> {
        self.node
            .take_hps_messages()
            .into_iter()
            .map(|m| ChannelMsg {
                path: m.path,
                body: m.body,
                sender: m.sender.to_vec(),
            })
            .collect()
    }

    /// Send a real message to a 32-byte destination address (private/untraceable path, ACK requested).
    /// Returns the created bundle's id so the sim can track just THIS message's flood (not gossip/ACKs).
    pub fn send(&mut self, dst: &[u8], body: &[u8]) -> Result<Vec<u8>, JsValue> {
        let d: PubKeyBytes = dst
            .try_into()
            .map_err(|_| JsValue::from_str("dst must be 32 bytes"))?;
        self.node
            .send_message(d, "text/plain".to_string(), body.to_vec(), true)
            .map(|id| id.to_vec())
            .map_err(|e| JsValue::from_str(&format!("{e:?}")))
    }

    /// Send via the opt-in TRACED path (cleartext src/dst, directed routing), no prekey needed.
    pub fn send_traced(&mut self, dst: &[u8], body: &[u8]) -> Result<(), JsValue> {
        let d: PubKeyBytes = dst
            .try_into()
            .map_err(|_| JsValue::from_str("dst must be 32 bytes"))?;
        self.node
            .send_message_traced(d, "text/plain".to_string(), body.to_vec(), true)
            .map(|_| ())
            .map_err(|e| JsValue::from_str(&format!("{e:?}")))
    }

    /// Debug: take the inbox and report raw bundle count + per-bundle read result.
    pub fn inbox_debug(&mut self) -> String {
        let bundles = self.node.take_inbox();
        let mut s = format!("n={}", bundles.len());
        for b in &bundles {
            match self.node.read_message(b) {
                Ok(Some(rm)) => s.push_str(&format!(
                    " [ok type={} len={}]",
                    rm.content_type,
                    rm.body.len()
                )),
                Ok(None) => s.push_str(" [None]"),
                Err(e) => s.push_str(&format!(" [Err {e:?}]")),
            }
        }
        s
    }

    /// Messages addressed to this node that arrived since the last call (decrypted).
    pub fn inbox(&mut self) -> Vec<Delivered> {
        let bundles = self.node.take_inbox();
        let mut out = Vec::new();
        for b in &bundles {
            if let Ok(Some(rm)) = self.node.read_message(b) {
                out.push(Delivered {
                    from: rm.from.to_vec(),
                    content_type: rm.content_type,
                    body: rm.body,
                    bundle: b.id().to_vec(),
                    hops: b.env.hops,
                });
            }
        }
        out
    }
}
