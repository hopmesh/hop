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
//! is structurally unrunnable on the host. It is exercised for real, against this exact crate compiled
//! to wasm, by two node scripts:
//!
//! - `node sim/scenario-check.mjs` drives all 15 homepage scenarios through `WasmNode` + `StoreBridge`
//!   end to end (each scripted send delivers and its ACK returns): construction, `tick`/`connected`/
//!   `disconnected`/`receive`/`drain`/`drain_transfers`, `send`, `inbox`, `sends_status`, `held_ids`,
//!   the `hps://` channel methods, and (indirectly, via `Node::tick`'s own 30s auto-republish timer)
//!   the §39 P4 receiver-beacon's *effect* on `gradient`/`mailbox_tag`/`drain_beaconed`.
//! - `node sim/wasm-glue-check.mjs` directly drives the four methods no scenario script ever calls
//!   (F-5): `publish_recv_beacon` (an explicit call, not the tick timer, the §39 P4 receiver-beacon
//!   itself), `send_traced`, `set_default_lifetime_ms`, and `inbox_debug`, each asserted against a real
//!   observable effect (a formed gradient, a real delivery, a shortened-TTL prune, an accepted inbox).
//!
//! Both run in CI's `web` job (see `.github/workflows/ci.yml`) plus the Pages deploy workflow, against
//! the same `core/hop-wasm/pkg-node` build the CI `wasm` job's
//! `cargo build -p hop-wasm --target wasm32-unknown-unknown` also proves still compiles.
//!
//! The host-testable logic these thin wrappers call lives in `store.rs` (the `JsStore<B>` `Store`
//! contract over an in-memory `Bridge`) and `lib.rs` (the flat codecs + value-struct getters), each
//! covered by real unit tests there. `WasmNode`'s methods are one-line forwards onto `Node`, whose
//! behavior is unit-tested in `store.rs` against the exact `Node<JsStore<FakeBridge>>` they wrap.

use crate::store::{Bridge, JsStore};
use crate::{encode_gradient, encode_sends_status};
use crate::{ChannelMsg, Delivered, OutPacket, Transfer};
use hop_core::bundle::BundleId;
use hop_core::crypto::{Identity, PubKeyBytes};
use hop_core::link::{BearerEvent, Role};
use hop_core::node::Node;
use hop_core::store::KvMutation;
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
    #[wasm_bindgen(method, catch, js_name = kvPut)]
    fn kv_put(this: &StoreBridge, key: &str, value: &[u8]) -> Result<bool, JsValue>;
    /// Atomically apply flat-encoded bundle custody and KV mutations. Returns only after the host
    /// transaction commits the entire batch.
    #[wasm_bindgen(method, catch, js_name = kvBatch)]
    fn kv_batch(this: &StoreBridge, mutations: &[u8]) -> Result<bool, JsValue>;
    #[wasm_bindgen(method, js_name = kvGet)]
    fn kv_get(this: &StoreBridge, key: &str) -> Option<Vec<u8>>;
    #[wasm_bindgen(method, catch, js_name = kvRemove)]
    fn kv_remove(this: &StoreBridge, key: &str) -> Result<bool, JsValue>;
    /// One ordered page of `(key, value)` rows after the exclusive `after` cursor, flat-encoded as
    /// repeated `[u32 LE keylen][key utf8][u32 LE vallen][val]` records.
    #[wasm_bindgen(method, js_name = kvListPage)]
    fn kv_list_page(this: &StoreBridge, prefix: &str, after: &str, limit: u32) -> Vec<u8>;
}

/// The production [`Bridge`]: a thin forward onto the wasm-bindgen [`StoreBridge`] host object
/// (SQLite/OPFS in a Worker). KV mutations normalize the host's boolean acknowledgement or thrown
/// exception into a Rust result; host tests exercise the same `JsStore` result handling.
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
    fn kv_put(&self, key: &str, value: &[u8]) -> std::result::Result<(), String> {
        match StoreBridge::kv_put(self, key, value) {
            Ok(true) => Ok(()),
            Ok(false) => Err("JavaScript kvPut rejected the write".into()),
            Err(e) => Err(format!("JavaScript kvPut failed: {e:?}")),
        }
    }
    fn kv_batch(&self, mutations: &[KvMutation]) -> std::result::Result<(), String> {
        // Version marker keeps the source bridge compatible with the committed pre-regeneration wasm,
        // whose KV-only batches begin directly with operation kind 0/1 and carry no expiry trailer.
        let mut encoded = vec![0x84];
        for mutation in mutations {
            let (kind, key, value, expires_at): (u8, Vec<u8>, Vec<u8>, u64) = match mutation {
                KvMutation::Put { key, value } => (1, key.as_bytes().to_vec(), value.clone(), 0),
                KvMutation::Remove { key } => (0, key.as_bytes().to_vec(), Vec::new(), 0),
                KvMutation::PutBundle { bundle, now_ms } => {
                    let lifetime = (bundle.inner.lifetime_ms as u64)
                        .min(hop_core::store::MAX_SEEN_LIFETIME_MS);
                    (
                        2,
                        bundle.id().to_vec(),
                        bundle.to_bytes().map_err(|e| e.to_string())?,
                        now_ms.saturating_add(lifetime),
                    )
                }
                KvMutation::RemoveBundle { id } => (3, id.to_vec(), Vec::new(), 0),
            };
            let key_len = u32::try_from(key.len())
                .map_err(|_| "JavaScript kvBatch key is too large".to_string())?;
            let value_len = u32::try_from(value.len())
                .map_err(|_| "JavaScript kvBatch value is too large".to_string())?;
            encoded.push(kind);
            encoded.extend_from_slice(&key_len.to_le_bytes());
            encoded.extend_from_slice(&key);
            encoded.extend_from_slice(&value_len.to_le_bytes());
            encoded.extend_from_slice(&value);
            encoded.extend_from_slice(&expires_at.to_le_bytes());
        }
        match StoreBridge::kv_batch(self, &encoded) {
            Ok(true) => Ok(()),
            Ok(false) => Err("JavaScript kvBatch rejected the transaction".into()),
            Err(e) => Err(format!("JavaScript kvBatch failed: {e:?}")),
        }
    }
    fn kv_get(&self, key: &str) -> Option<Vec<u8>> {
        StoreBridge::kv_get(self, key)
    }
    fn kv_remove(&self, key: &str) -> std::result::Result<(), String> {
        match StoreBridge::kv_remove(self, key) {
            Ok(true) => Ok(()),
            Ok(false) => Err("JavaScript kvRemove rejected the delete".into()),
            Err(e) => Err(format!("JavaScript kvRemove failed: {e:?}")),
        }
    }
    fn kv_list_page(&self, prefix: &str, after: &str, limit: u32) -> Vec<u8> {
        StoreBridge::kv_list_page(self, prefix, after, limit)
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

    /// Emit a §39 receive beacon so directly-connected peers lay a gradient toward this node's
    /// mailbox route PREFIX, turning blind flood into directed route-toward (§39 P4). Re-emit before
    /// the 90s soft-state TTL lapses. Infallible: it writes a link-local record to each live link
    /// (nothing to sign, nothing to publish, so nothing to fail).
    pub fn publish_recv_beacon(&mut self) {
        self.node.publish_recv_beacon()
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

    /// Poll channel posts. Rows repeat until `accept_channel` durably removes them.
    pub fn take_channel(&mut self) -> Vec<ChannelMsg> {
        self.node
            .take_hps_messages()
            .into_iter()
            .map(|m| ChannelMsg {
                id: m.id.to_vec(),
                path: m.path,
                body: m.body,
                sender: m.sender.to_vec(),
            })
            .collect()
    }

    pub fn accept_channel(&mut self, id: &[u8]) -> Result<bool, JsValue> {
        let id: BundleId = id
            .try_into()
            .map_err(|_| JsValue::from_str("publication id must be 32 bytes"))?;
        self.node
            .accept_hps_message(&id)
            .map_err(|e| JsValue::from_str(&e.to_string()))
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

    /// Debug: report and accept every durable decrypted inbox item.
    pub fn inbox_debug(&mut self) -> String {
        let items = self.node.inbox_items();
        let mut s = format!("n={}", items.len());
        for item in items {
            s.push_str(&format!(
                " [ok type={} len={}]",
                item.content_type,
                item.body.len()
            ));
            if let Err(error) = self.node.accept_inbox(&item.id) {
                s.push_str(&format!(" [accept Err {error:?}]"));
            }
        }
        s
    }

    /// Durable decrypted messages awaiting host processing. Non-destructive until `accept_inbox`.
    pub fn inbox(&self) -> Vec<Delivered> {
        self.node
            .inbox_items()
            .into_iter()
            .map(|item| Delivered {
                from: item.from.to_vec(),
                content_type: item.content_type,
                body: item.body,
                bundle: item.id.to_vec(),
                hops: item.hops,
            })
            .collect()
    }

    /// Accept a processed durable inbox item. ACK/vaccine emission follows only after persistence.
    pub fn accept_inbox(&mut self, id: &[u8]) -> Result<bool, JsValue> {
        let id: [u8; 32] = id
            .try_into()
            .map_err(|_| JsValue::from_str("inbox id must be 32 bytes"))?;
        self.node
            .accept_inbox(&id)
            .map_err(|e| JsValue::from_str(&format!("{e:?}")))
    }
}
