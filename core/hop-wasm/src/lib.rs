//! Browser wrapper over the **real** `hop-core` node.
//!
//! Each `WasmNode` is a genuine `Node<JsStore>`, the same store-and-forward, crypto, and
//! spray-and-wait routing that runs on device, over a host-provided persistent store (SQLite/OPFS
//! in the Worker; see [`store`]). JavaScript owns the "bearer": it decides which nodes are in range,
//! calls [`WasmNode::connected`], pumps [`WasmNode::drain`] → peer [`WasmNode::receive`] each frame,
//! and reads delivered messages via [`WasmNode::inbox`]. An actual mesh of real Hop instances.
//!
//! ## What runs where (coverage map)
//!
//! Two of this crate's three source files are host-testable and unit-tested here:
//! * [`store`] - the `JsStore<B>` [`Store`](hop_core::store::Store) contract over an in-memory
//!   `Bridge` fake (postcard round-trips, the F-07 TTL clamp, copy-budget writes, the kv flat codec,
//!   plus the wasm-facing `Node` surface exercised through the exact `Node<JsStore<FakeBridge>>` the
//!   glue wraps).
//! * this file - the flat binary codecs shared with `sim/mesh.js` and the value-struct getters.
//!
//! The third file, [`wasm_glue`], is the genuinely wasm-only surface (`WasmNode` + the `StoreBridge`
//! JS bridge). It cannot execute under a host `cargo test` (its bridge calls panic off-wasm and a
//! `StoreBridge` value cannot even be constructed), so it is excluded from the host coverage
//! denominator (`tarpaulin.toml`) and covered instead by `node sim/scenario-check.mjs` driving all 15
//! homepage scenarios through the real wasm build. This mirrors the driver layer's device-code split.

mod store;
mod wasm_glue;

use wasm_bindgen::prelude::*;
pub use wasm_glue::{StoreBridge, WasmNode};

/// Decode and verify one committed bundle vector through the WASM boundary. The returned fixed-width
/// metadata lets JavaScript independently compare stable fields rather than merely reading a fixture.
/// The exact input bytes must also be the bundle's canonical re-encoding.
#[wasm_bindgen]
pub fn validate_wire_bundle(bytes: &[u8], expected_id: &[u8]) -> Result<Vec<u8>, JsValue> {
    let bundle = hop_core::bundle::Bundle::from_bytes(bytes)
        .map_err(|error| JsValue::from_str(&format!("bundle decode failed: {error}")))?;
    bundle
        .verify()
        .map_err(|error| JsValue::from_str(&format!("bundle verify failed: {error}")))?;
    let canonical = bundle
        .to_bytes()
        .map_err(|error| JsValue::from_str(&format!("bundle encode failed: {error}")))?;
    if canonical != bytes {
        return Err(JsValue::from_str("bundle bytes are not canonical"));
    }
    if expected_id != bundle.id() {
        return Err(JsValue::from_str("bundle id does not match the vector"));
    }

    let destination = match &bundle.inner.dst {
        hop_core::bundle::Destination::Device(_) => 0,
        hop_core::bundle::Destination::AckTo(_, _) => 1,
        hop_core::bundle::Destination::Broadcast => 2,
        hop_core::bundle::Destination::Vaccine(_) => 3,
    };
    let wire_len = u32::try_from(bytes.len())
        .map_err(|_| JsValue::from_str("bundle length does not fit metadata"))?;
    let ciphertext_len = u32::try_from(bundle.inner.payload.ciphertext.len())
        .map_err(|_| JsValue::from_str("ciphertext length does not fit metadata"))?;
    let trace_len = u8::try_from(bundle.trace().len())
        .map_err(|_| JsValue::from_str("trace length does not fit metadata"))?;
    let signature_len = u16::try_from(bundle.sig.len())
        .map_err(|_| JsValue::from_str("signature length does not fit metadata"))?;
    if bundle.sig.len() > 64 {
        return Err(JsValue::from_str(
            "bundle signature exceeds metadata capacity",
        ));
    }

    let mut metadata = vec![0u8; 211];
    metadata[0] = bundle.inner.version;
    metadata[1] = destination;
    metadata[2] = u8::from(bundle.is_private());
    metadata[3] = u8::from(bundle.inner.flags.is_ack);
    metadata[4..8].copy_from_slice(&wire_len.to_le_bytes());
    metadata[8..12].copy_from_slice(&ciphertext_len.to_le_bytes());
    metadata[12..14].copy_from_slice(&bundle.env.copies.to_le_bytes());
    metadata[14] = bundle.env.hops;
    metadata[15] = trace_len;
    metadata[16..24].copy_from_slice(&bundle.inner.created_at.to_le_bytes());
    metadata[24..28].copy_from_slice(&bundle.inner.lifetime_ms.to_le_bytes());
    metadata[28] = bundle.env.hop_limit;
    metadata[29..61].copy_from_slice(&bundle.id());
    if let Some(content_id) = bundle.private_content_id() {
        metadata[61..93].copy_from_slice(&content_id);
    }
    if let Some(header) = &bundle.inner.private {
        metadata[93..109].copy_from_slice(&header.tag);
        metadata[109..141].copy_from_slice(&header.ephemeral);
        if let Some(mailbox) = header.mailbox {
            metadata[141] = 1;
            metadata[142..144].copy_from_slice(&mailbox);
        }
        metadata[144] = 1;
    } else if matches!(&bundle.inner.dst, hop_core::bundle::Destination::Vaccine(_)) {
        metadata[144] = 2;
    }
    metadata[145..147].copy_from_slice(&signature_len.to_le_bytes());
    metadata[147..147 + bundle.sig.len()].copy_from_slice(&bundle.sig);
    Ok(metadata)
}

/// One frame's worth of bytes a node wants to ship to a peer, tagged with the link.
#[wasm_bindgen]
pub struct OutPacket {
    pub(crate) link: u32,
    pub(crate) data: Vec<u8>,
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

/// One real bundle crossing one link this frame, lets the visualizer color the hop by bundle.
#[wasm_bindgen]
pub struct Transfer {
    pub(crate) link: u32,
    pub(crate) bundle: Vec<u8>,
    pub(crate) delivered: bool,
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
    pub(crate) from: Vec<u8>,
    pub(crate) content_type: String,
    pub(crate) body: Vec<u8>,
    pub(crate) bundle: Vec<u8>,
    pub(crate) hops: u8,
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
    /// The delivered bundle's id, matches the ids from `drain_transfers`, so the sim can
    /// solid-color exactly the path that arrived.
    #[wasm_bindgen(getter)]
    pub fn bundle(&self) -> Vec<u8> {
        self.bundle.clone()
    }
    /// How many relay hops the bundle took to arrive (`env.hops` on the wire), the real count.
    #[wasm_bindgen(getter)]
    pub fn hops(&self) -> u8 {
        self.hops
    }
}

/// A channel (hps://) post that arrived for this node, group messaging (§32).
#[wasm_bindgen]
pub struct ChannelMsg {
    pub(crate) id: Vec<u8>,
    pub(crate) path: String,
    pub(crate) body: Vec<u8>,
    pub(crate) sender: Vec<u8>,
}
#[wasm_bindgen]
impl ChannelMsg {
    #[wasm_bindgen(getter)]
    pub fn id(&self) -> Vec<u8> {
        self.id.clone()
    }
    #[wasm_bindgen(getter)]
    pub fn path(&self) -> String {
        self.path.clone()
    }
    #[wasm_bindgen(getter)]
    pub fn body(&self) -> Vec<u8> {
        self.body.clone()
    }
    /// The POSTING member's address, every post is verified against its writer (§32).
    #[wasm_bindgen(getter)]
    pub fn sender(&self) -> Vec<u8> {
        self.sender.clone()
    }
}

// ---- Flat binary codecs shared with the JS decoders in sim/mesh.js ----
//
// These are the exact byte layouts the JS visualizer parses back. They are factored out of the
// `#[wasm_bindgen]` methods (see `wasm_glue`) so they can be unit-tested on the host (the wasm methods
// are just thin wrappers). A one-byte layout drift here silently corrupts the sim's gradient arrows /
// send status, so the round-trip tests below pin the record widths and field order that mesh.js:161-166,
// 177-180 assume.

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
    use super::validate_wire_bundle;
    use super::{encode_gradient, encode_sends_status, ChannelMsg, Delivered, OutPacket, Transfer};

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

    #[test]
    fn kv_pairs_non_utf8_key_stops_cleanly() {
        // A key length that frames invalid UTF-8 must abort decoding, not panic or emit garbage.
        let mut bad = 2u32.to_le_bytes().to_vec();
        bad.extend_from_slice(&[0xff, 0xfe]); // not valid UTF-8
        bad.extend_from_slice(&0u32.to_le_bytes()); // a well-formed (empty) value follows
        assert!(
            decode_kv_pairs(&bad).is_empty(),
            "an invalid-UTF8 key must halt decoding rather than yield a corrupt pair"
        );
    }

    #[test]
    fn kv_pairs_key_without_room_for_value_length_stops_cleanly() {
        // A complete, valid key whose record ends before the 4-byte value-length header must stop at
        // the "no room for vlen" guard rather than read past the end (decode_kv_pairs line 252).
        let mut buf = 3u32.to_le_bytes().to_vec();
        buf.extend_from_slice(b"abc");
        // ...and nothing else: only 3 of the needed 4 value-length bytes could ever follow.
        buf.extend_from_slice(&[0u8; 3]);
        assert!(
            decode_kv_pairs(&buf).is_empty(),
            "a key with fewer than 4 trailing bytes has no value-length header, so no pair decodes"
        );
    }

    #[test]
    fn wire_vector_validator_returns_fixed_metadata() {
        let bundle = hop_core::bundle::Bundle::create_vaccine(
            [7u8; 32],
            hop_core::bundle::BundleOpts {
                created_at: 123,
                copies: 5,
                hop_limit: 6,
                ..Default::default()
            },
        );
        let bytes = bundle.to_bytes().unwrap();
        let metadata = validate_wire_bundle(&bytes, &bundle.id()).unwrap();
        assert_eq!(metadata.len(), 211);
        assert_eq!(metadata[0], hop_core::bundle::BUNDLE_VERSION);
        assert_eq!(metadata[1], 3);
        assert_eq!(metadata[2], 0);
        assert_eq!(metadata[3], 1);
        assert_eq!(&metadata[29..61], &bundle.id());
        assert_eq!(metadata[144], 2);
        assert_eq!(u16::from_le_bytes([metadata[145], metadata[146]]), 0);
    }

    #[test]
    fn kv_pairs_truncated_value_length_drops_trailing_record() {
        // A valid key but a value-length that overruns the buffer must drop that trailing record
        // rather than read past the end.
        let mut buf = Vec::new();
        // one complete pair
        buf.extend_from_slice(&3u32.to_le_bytes());
        buf.extend_from_slice(b"key");
        buf.extend_from_slice(&1u32.to_le_bytes());
        buf.push(0x42);
        // a second key with a value length that claims 99 bytes we don't have
        buf.extend_from_slice(&2u32.to_le_bytes());
        buf.extend_from_slice(b"k2");
        buf.extend_from_slice(&99u32.to_le_bytes());
        buf.push(0x00);
        let decoded = decode_kv_pairs(&buf);
        assert_eq!(
            decoded.len(),
            1,
            "only the complete leading pair is decoded"
        );
        assert_eq!(decoded[0].0, "key");
        assert_eq!(decoded[0].1, vec![0x42]);
    }

    // ---- Value-struct getters -------------------------------------------------------------------
    //
    // These `#[wasm_bindgen(getter)]` accessors are what the JS visualizer reads off each returned
    // object (out.link/out.data, transfer.bundle/.delivered, delivered.from/.body/.hops,
    // channelMsg.path/.sender). They are pure field reads, so they run and are asserted on the host
    // even though only `wasm_glue` constructs them in production.

    #[test]
    fn out_packet_getters_return_the_fields() {
        let p = OutPacket {
            link: 7,
            data: vec![1, 2, 3, 4],
        };
        assert_eq!(p.link(), 7);
        assert_eq!(p.data(), vec![1, 2, 3, 4]);
        // The getter clones, so a second read is independent of the first.
        assert_eq!(p.data(), vec![1, 2, 3, 4]);
    }

    #[test]
    fn transfer_getters_return_the_fields() {
        let t = Transfer {
            link: 42,
            bundle: vec![9u8; 32],
            delivered: true,
        };
        assert_eq!(t.link(), 42);
        assert_eq!(t.bundle(), vec![9u8; 32]);
        assert!(t.delivered());

        let undelivered = Transfer {
            link: 0,
            bundle: vec![],
            delivered: false,
        };
        assert!(!undelivered.delivered());
        assert!(undelivered.bundle().is_empty());
    }

    #[test]
    fn delivered_getters_return_the_fields() {
        let d = Delivered {
            from: vec![0xaa; 32],
            content_type: "text/plain".to_string(),
            body: b"meet at the docks".to_vec(),
            bundle: vec![0xbb; 32],
            hops: 3,
        };
        assert_eq!(d.from(), vec![0xaa; 32]);
        assert_eq!(d.content_type(), "text/plain");
        assert_eq!(d.body(), b"meet at the docks".to_vec());
        assert_eq!(d.bundle(), vec![0xbb; 32]);
        assert_eq!(d.hops(), 3);
    }

    #[test]
    fn channel_msg_getters_return_the_fields() {
        let m = ChannelMsg {
            id: vec![0xdd; 32],
            path: "hps://room".to_string(),
            body: b"gm".to_vec(),
            sender: vec![0xcc; 32],
        };
        assert_eq!(m.id(), vec![0xdd; 32]);
        assert_eq!(m.path(), "hps://room");
        assert_eq!(m.body(), b"gm".to_vec());
        assert_eq!(m.sender(), vec![0xcc; 32]);
    }
}
