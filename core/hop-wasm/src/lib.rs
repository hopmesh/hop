//! Browser wrapper over the **real** `hop-core` node.
//!
//! Each `WasmNode` is a genuine `Node<JsStore>` — the same store-and-forward, crypto, and
//! spray-and-wait routing that runs on device — over a host-provided persistent store (SQLite/OPFS
//! in the Worker; see [`store`]). JavaScript owns the "bearer": it decides which nodes are in range,
//! calls [`WasmNode::connected`], pumps [`WasmNode::drain`] → peer [`WasmNode::receive`] each frame,
//! and reads delivered messages via [`WasmNode::inbox`]. An actual mesh of real Hop instances.

mod store;

use hop_core::crypto::{Identity, PubKeyBytes};
use hop_core::link::{BearerEvent, Role};
use hop_core::node::Node;
use store::{JsStore, StoreBridge};
use wasm_bindgen::prelude::*;

/// One frame's worth of bytes a node wants to ship to a peer, tagged with the link.
#[wasm_bindgen]
pub struct OutPacket {
    link: u32,
    data: Vec<u8>,
}
#[wasm_bindgen]
impl OutPacket {
    #[wasm_bindgen(getter)]
    pub fn link(&self) -> u32 {
        self.link
    }
    #[wasm_bindgen(getter)]
    pub fn data(&self) -> Vec<u8> {
        self.data.clone()
    }
}

/// One real bundle crossing one link this frame — lets the visualizer color the hop by bundle.
#[wasm_bindgen]
pub struct Transfer {
    link: u32,
    bundle: Vec<u8>,
    delivered: bool,
}
#[wasm_bindgen]
impl Transfer {
    #[wasm_bindgen(getter)]
    pub fn link(&self) -> u32 {
        self.link
    }
    #[wasm_bindgen(getter)]
    pub fn bundle(&self) -> Vec<u8> {
        self.bundle.clone()
    }
    /// True when this hop delivered the bundle to its final destination.
    #[wasm_bindgen(getter)]
    pub fn delivered(&self) -> bool {
        self.delivered
    }
}

/// A message that arrived for this node and decrypted successfully.
#[wasm_bindgen]
pub struct Delivered {
    from: Vec<u8>,
    content_type: String,
    body: Vec<u8>,
    bundle: Vec<u8>,
    hops: u8,
}
#[wasm_bindgen]
impl Delivered {
    #[wasm_bindgen(getter)]
    pub fn from(&self) -> Vec<u8> {
        self.from.clone()
    }
    #[wasm_bindgen(getter)]
    pub fn content_type(&self) -> String {
        self.content_type.clone()
    }
    #[wasm_bindgen(getter)]
    pub fn body(&self) -> Vec<u8> {
        self.body.clone()
    }
    /// The delivered bundle's id — matches the ids from `drain_transfers`, so the sim can
    /// solid-color exactly the path that arrived.
    #[wasm_bindgen(getter)]
    pub fn bundle(&self) -> Vec<u8> {
        self.bundle.clone()
    }
    /// How many relay hops the bundle took to arrive (`env.hops` on the wire) — the real count.
    #[wasm_bindgen(getter)]
    pub fn hops(&self) -> u8 {
        self.hops
    }
}

/// A channel (hps://) post that arrived for this node — group messaging (§32).
#[wasm_bindgen]
pub struct ChannelMsg {
    path: String,
    body: Vec<u8>,
    sender: Vec<u8>,
}
#[wasm_bindgen]
impl ChannelMsg {
    #[wasm_bindgen(getter)]
    pub fn path(&self) -> String {
        self.path.clone()
    }
    #[wasm_bindgen(getter)]
    pub fn body(&self) -> Vec<u8> {
        self.body.clone()
    }
    /// The POSTING member's address — every post is verified against its writer (§32).
    #[wasm_bindgen(getter)]
    pub fn sender(&self) -> Vec<u8> {
        self.sender.clone()
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
    /// storage `bridge` (SQLite/OPFS in the Worker, a Map in Node tests) — bundles live there, not
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

    /// This node's 32-byte public address — use it as a `dst` for `send`.
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

    /// The `(link, bundle_id, is_final_delivery)` transfers this node made since the last call —
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
    /// ids. The sender only learns delivery this way — a per-device UI shows "delivered" off this.
    pub fn drain_delivered(&mut self) -> Vec<u8> {
        self.node
            .drain_delivered()
            .into_iter()
            .flat_map(|id| id.to_vec())
            .collect()
    }

    /// Set the lifetime (ms) stamped on messages/ACKs this node sends — the sender's real per-bundle
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

    /// Publish a §39 receive beacon so relays lay a gradient toward this node's mailbox-tag — turning
    /// blind flood into directed route-toward (§39 P4). Re-publish before the 90s soft-state TTL lapses.
    pub fn publish_recv_beacon(&mut self) -> Result<(), JsValue> {
        self.node
            .publish_recv_beacon()
            .map(|_| ())
            .map_err(|e| JsValue::from_str(&format!("{e:?}")))
    }

    /// Which mailbox-tags this node currently holds a gradient toward, and the inbound link to forward
    /// down for each — flat `[16-byte tag][u32 LE link][u8 hops]` records. Lets the sim draw the
    /// distributed routing tree (each device holds a slice) + which way a private bundle would steer.
    pub fn gradient(&self) -> Vec<u8> {
        encode_gradient(self.node.recv_gradient_view())
    }

    /// This node's current §39 mailbox-tag (16 bytes) — the key a relay's gradient points toward, so
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

    /// Post to a channel we're a member of — ONE message, every member receives it (real fan-out).
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

    /// Send via the opt-in TRACED path (cleartext src/dst, directed routing) — no prekey needed.
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

// ---- Flat binary codecs shared with the JS decoders in sim/mesh.js ----
//
// These are the exact byte layouts the JS visualizer parses back. They are factored out of the
// `#[wasm_bindgen]` methods so they can be unit-tested on the host (the wasm methods are just thin
// wrappers). A one-byte layout drift here silently corrupts the sim's gradient arrows / send status,
// so the round-trip tests below pin the record widths and field order that mesh.js:161-166,177-180
// assume.

/// Encode `(BundleId, peers, delivered)` records as repeated `[32-byte id][u16 LE peers][u8 delivered]`
/// (35 bytes each). Decoded in JS at sim/mesh.js:177-180.
pub(crate) fn encode_sends_status(rows: Vec<([u8; 32], u16, bool)>) -> Vec<u8> {
    let mut out = Vec::with_capacity(rows.len() * 35);
    for (id, peers, delivered) in rows {
        out.extend_from_slice(&id);
        out.extend_from_slice(&peers.to_le_bytes());
        out.push(delivered as u8);
    }
    out
}

/// Encode `(tag, link, hops)` records as repeated `[16-byte tag][u32 LE link][u8 hops]` (21 bytes each).
/// `link` is a `u64` LinkId narrowed to `u32` (sim link ids stay small). Decoded in JS at
/// sim/mesh.js:161-166.
pub(crate) fn encode_gradient(rows: Vec<([u8; 16], u64, u8)>) -> Vec<u8> {
    let mut out = Vec::with_capacity(rows.len() * 21);
    for (tag, link, hops) in rows {
        out.extend_from_slice(&tag);
        out.extend_from_slice(&(link as u32).to_le_bytes());
        out.push(hops);
    }
    out
}

#[cfg(test)]
mod codec_tests {
    use super::store::decode_kv_pairs;
    use super::{encode_gradient, encode_sends_status};

    // Reference JS decoders re-implemented in Rust, matching sim/mesh.js byte-for-byte, so a layout
    // drift on the encoder side fails the round-trip here instead of only in the browser.

    fn js_decode_sends_status(flat: &[u8]) -> Vec<([u8; 32], u16, bool)> {
        // mirrors mesh.js statusMap(): i += 35; id=[0..32]; peers = d[32]|d[33]<<8; delivered=!!d[34]
        let mut out = Vec::new();
        let mut i = 0;
        while i + 35 <= flat.len() {
            let mut id = [0u8; 32];
            id.copy_from_slice(&flat[i..i + 32]);
            let peers = (flat[i + 32] as u16) | ((flat[i + 33] as u16) << 8);
            let delivered = flat[i + 34] != 0;
            out.push((id, peers, delivered));
            i += 35;
        }
        out
    }

    fn js_decode_gradient(flat: &[u8]) -> Vec<([u8; 16], u32, u8)> {
        // mirrors mesh.js gradientTo(): i += 21; tag=[0..16]; link = 4 LE bytes at 16; hops = byte 20
        let mut out = Vec::new();
        let mut i = 0;
        while i + 21 <= flat.len() {
            let mut tag = [0u8; 16];
            tag.copy_from_slice(&flat[i..i + 16]);
            let link = (flat[i + 16] as u32)
                | ((flat[i + 17] as u32) << 8)
                | ((flat[i + 18] as u32) << 16)
                | ((flat[i + 19] as u32) << 24);
            let hops = flat[i + 20];
            out.push((tag, link, hops));
            i += 21;
        }
        out
    }

    #[test]
    fn sends_status_record_is_35_bytes() {
        let flat = encode_sends_status(vec![([1u8; 32], 0, false)]);
        assert_eq!(
            flat.len(),
            35,
            "one send-status record must be exactly 35 bytes"
        );
    }

    #[test]
    fn sends_status_round_trip() {
        let rows = vec![
            ([0u8; 32], 0u16, false),
            ([7u8; 32], 1u16, true),
            (
                {
                    let mut a = [0u8; 32];
                    a[0] = 0xde;
                    a[31] = 0xad;
                    a
                },
                0xBEEFu16,
                true,
            ),
            ([255u8; 32], u16::MAX, false),
        ];
        let flat = encode_sends_status(rows.clone());
        assert_eq!(flat.len(), rows.len() * 35);
        assert_eq!(js_decode_sends_status(&flat), rows);
    }

    #[test]
    fn sends_status_peers_little_endian() {
        // peers=0x0102 must serialize as [0x02, 0x01] right after the 32-byte id.
        let flat = encode_sends_status(vec![([0u8; 32], 0x0102, false)]);
        assert_eq!(flat[32], 0x02);
        assert_eq!(flat[33], 0x01);
    }

    #[test]
    fn gradient_record_is_21_bytes() {
        let flat = encode_gradient(vec![([2u8; 16], 5, 3)]);
        assert_eq!(
            flat.len(),
            21,
            "one gradient record must be exactly 21 bytes"
        );
    }

    #[test]
    fn gradient_round_trip() {
        let rows = vec![
            ([0u8; 16], 0u64, 0u8),
            ([9u8; 16], 42u64, 7u8),
            (
                {
                    let mut t = [0u8; 16];
                    t[0] = 0xab;
                    t[15] = 0xcd;
                    t
                },
                0x0102_0304u64,
                255u8,
            ),
        ];
        let flat = encode_gradient(rows.clone());
        assert_eq!(flat.len(), rows.len() * 21);
        let decoded = js_decode_gradient(&flat);
        for (i, (tag, link, hops)) in rows.iter().enumerate() {
            assert_eq!(&decoded[i].0, tag);
            assert_eq!(decoded[i].1 as u64, *link);
            assert_eq!(decoded[i].2, *hops);
        }
    }

    #[test]
    fn gradient_link_little_endian_narrows_u64_to_u32() {
        // A LinkId (u64) is narrowed to u32 LE; JS reads the low 4 bytes.
        let flat = encode_gradient(vec![([0u8; 16], 0x0000_0001_0203_0405, 1)]);
        // low 32 bits = 0x02030405 → LE bytes [05,04,03,02] at offset 16.
        assert_eq!(&flat[16..20], &[0x05, 0x04, 0x03, 0x02]);
    }

    #[test]
    fn kv_pairs_round_trip() {
        // The encoder side lives in JS (store-bridge.js kvList); here we pin the decoder against a
        // hand-built buffer matching the documented [u32 LE keylen][key][u32 LE vallen][val] layout.
        fn enc(pairs: &[(&str, &[u8])]) -> Vec<u8> {
            let mut out = Vec::new();
            for (k, v) in pairs {
                out.extend_from_slice(&(k.len() as u32).to_le_bytes());
                out.extend_from_slice(k.as_bytes());
                out.extend_from_slice(&(v.len() as u32).to_le_bytes());
                out.extend_from_slice(v);
            }
            out
        }
        let pairs: &[(&str, &[u8])] = &[
            ("session/abc", &[1, 2, 3]),
            ("hps/room", &[]),
            ("prekey", &[0xff; 40]),
        ];
        let flat = enc(pairs);
        let decoded = decode_kv_pairs(&flat);
        assert_eq!(decoded.len(), pairs.len());
        for (i, (k, v)) in pairs.iter().enumerate() {
            assert_eq!(decoded[i].0, *k);
            assert_eq!(decoded[i].1.as_slice(), *v);
        }
    }

    #[test]
    fn kv_pairs_empty_and_truncated_are_safe() {
        assert!(decode_kv_pairs(&[]).is_empty());
        // A truncated buffer (klen claims more than is present) must stop cleanly, not panic.
        let mut bad = 100u32.to_le_bytes().to_vec();
        bad.extend_from_slice(b"short");
        assert!(decode_kv_pairs(&bad).is_empty());
    }
}
