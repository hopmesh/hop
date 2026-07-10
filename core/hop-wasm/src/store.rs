//! `JsStore`, a hop-core [`Store`] backed by a host-provided **synchronous** JS bridge.
//!
//! This is hop's pluggable storage used exactly as intended (DESIGN.md §25: the host owns storage).
//! A browser deployment backs the bridge with SQLite on an OPFS sync-access VFS in a Worker, so held
//! bundles live on disk instead of wasm linear memory, the thing that OOMs a many-node tab. The core
//! keeps its real behavior: real per-bundle TTL, real dedup, real `prune`. Nothing is faked here.
//!
//! It mirrors `hop-store-sqlite`'s two-table model: a `seen` dedup index (id → expiry) plus a `bundles`
//! data table. `remove` drops only the data (the dedup entry lingers so late duplicates are rejected);
//! `prune` drops both by the seen expiry. The bridge object supplies those operations; this type only
//! (de)serializes bundles (postcard, via `Bundle::to_bytes`/`from_bytes`) and mutates copy budgets.

use hop_core::bundle::{Bundle, BundleId};
use hop_core::store::{HaveSet, Store};
use wasm_bindgen::prelude::*;

/// Clamp on a retained dedup window (F-07): an attacker-set (and, for §39 private bundles,
/// unauthenticated) `lifetime_ms` can't pin a `seen` row open for longer than a week.
const MAX_SEEN_LIFETIME_MS: u64 = 7 * 24 * 60 * 60 * 1000;

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

/// The exact byte-level storage operations `JsStore` invokes on its host object. In production this
/// is the wasm-bindgen [`StoreBridge`] (SQLite/OPFS in a Worker); the trait exists so the same
/// `JsStore` logic can run on the host target against an in-memory fake for unit tests. Every method
/// mirrors a `StoreBridge` method one-to-one, so the real impl below is a pure forward with no
/// behavior change.
pub(crate) trait Bridge {
    fn put(&self, id: &[u8], data: &[u8], expires_at: f64) -> bool;
    fn get(&self, id: &[u8]) -> Option<Vec<u8>>;
    fn remove(&self, id: &[u8]) -> Option<Vec<u8>>;
    fn seen(&self, id: &[u8]) -> bool;
    fn contains(&self, id: &[u8]) -> bool;
    fn have(&self) -> Vec<u8>;
    fn prune(&self, now_ms: f64);
    fn set_data(&self, id: &[u8], data: &[u8]);
    fn kv_put(&self, key: &str, value: &[u8]);
    fn kv_get(&self, key: &str) -> Option<Vec<u8>>;
    fn kv_remove(&self, key: &str);
    fn kv_list(&self, prefix: &str) -> Vec<u8>;
}

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

/// A `Store` that delegates every operation to a host [`Bridge`] (one per node). In production the
/// bridge is a [`StoreBridge`]; the type is generic only so host unit tests can substitute an
/// in-memory fake with identical semantics.
pub struct JsStore<B: Bridge = StoreBridge> {
    bridge: B,
}

impl<B: Bridge> JsStore<B> {
    pub fn new(bridge: B) -> Self {
        Self { bridge }
    }
}

impl<B: Bridge> Store for JsStore<B> {
    fn put(&mut self, bundle: Bundle, now_ms: u64) -> bool {
        let id = bundle.id();
        let Ok(data) = bundle.to_bytes() else {
            return false;
        };
        let lifetime = (bundle.inner.lifetime_ms as u64).min(MAX_SEEN_LIFETIME_MS);
        let expires_at = now_ms.saturating_add(lifetime);
        self.bridge.put(&id, &data, expires_at as f64)
    }

    fn get(&self, id: &BundleId) -> Option<Bundle> {
        self.bridge
            .get(id)
            .and_then(|d| Bundle::from_bytes(&d).ok())
    }

    fn remove(&mut self, id: &BundleId) -> Option<Bundle> {
        self.bridge
            .remove(id)
            .and_then(|d| Bundle::from_bytes(&d).ok())
    }

    fn seen(&self, id: &BundleId) -> bool {
        self.bridge.seen(id)
    }

    fn contains(&self, id: &BundleId) -> bool {
        self.bridge.contains(id)
    }

    fn have(&self) -> HaveSet {
        let flat = self.bridge.have();
        let ids = flat
            .chunks_exact(32)
            .filter_map(|c| <[u8; 32]>::try_from(c).ok())
            .collect();
        HaveSet { ids }
    }

    fn prune(&mut self, now_ms: u64) {
        self.bridge.prune(now_ms as f64);
    }

    fn split_copies(&mut self, id: &BundleId) -> u16 {
        let Some(mut bundle) = self.get(id) else {
            return 0;
        };
        let give = bundle.split_copies();
        if give > 0 {
            if let Ok(d) = bundle.to_bytes() {
                self.bridge.set_data(id, &d);
            }
        }
        give
    }

    fn set_copies(&mut self, id: &BundleId, copies: u16) {
        if let Some(mut bundle) = self.get(id) {
            bundle.env.copies = copies;
            if let Ok(d) = bundle.to_bytes() {
                self.bridge.set_data(id, &d);
            }
        }
    }

    fn put_kv(&mut self, key: &str, value: Vec<u8>) {
        self.bridge.kv_put(key, &value);
    }

    fn get_kv(&self, key: &str) -> Option<Vec<u8>> {
        self.bridge.kv_get(key)
    }

    fn remove_kv(&mut self, key: &str) {
        self.bridge.kv_remove(key);
    }

    fn list_kv(&self, prefix: &str) -> Vec<(String, Vec<u8>)> {
        decode_kv_pairs(&self.bridge.kv_list(prefix))
    }
}

/// Decode the flat `[u32 LE keylen][key][u32 LE vallen][val]...` encoding from `kvList`.
pub(crate) fn decode_kv_pairs(flat: &[u8]) -> Vec<(String, Vec<u8>)> {
    let mut out = Vec::new();
    let mut i = 0usize;
    while i + 4 <= flat.len() {
        let klen = u32::from_le_bytes([flat[i], flat[i + 1], flat[i + 2], flat[i + 3]]) as usize;
        i += 4;
        if i + klen > flat.len() {
            break;
        }
        let key = match std::str::from_utf8(&flat[i..i + klen]) {
            Ok(s) => s.to_string(),
            Err(_) => break,
        };
        i += klen;
        if i + 4 > flat.len() {
            break;
        }
        let vlen = u32::from_le_bytes([flat[i], flat[i + 1], flat[i + 2], flat[i + 3]]) as usize;
        i += 4;
        if i + vlen > flat.len() {
            break;
        }
        out.push((key, flat[i..i + vlen].to_vec()));
        i += vlen;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use hop_core::crypto::Identity;
    use hop_core::link::{BearerEvent, Role};
    use hop_core::node::Node;
    use std::cell::RefCell;
    use std::collections::HashMap;

    /// Host-side stand-in for the real `StoreBridge`, faithful to its documented two-table model:
    /// a `seen` dedup index (id -> expiry ms) plus a `bundles` data table. It exists only so the
    /// exact `JsStore` -> `Bridge` code path (postcard (de)serialize, TTL clamp, copy-budget writes,
    /// kv flat encoding) runs on the host. Semantics mirror `store.rs`'s module doc and
    /// `hop-store-sqlite`: `put` dedups, `remove` keeps the dedup row, `prune` drops both by expiry.
    #[derive(Default)]
    struct FakeBridge {
        inner: RefCell<Fake>,
    }
    #[derive(Default)]
    struct Fake {
        seen: HashMap<Vec<u8>, u64>,
        bundles: HashMap<Vec<u8>, Vec<u8>>,
        kv: HashMap<String, Vec<u8>>,
    }

    impl Bridge for FakeBridge {
        fn put(&self, id: &[u8], data: &[u8], expires_at: f64) -> bool {
            let mut f = self.inner.borrow_mut();
            // Dedup purely on the `seen` window: if the id is still tracked as seen, reject as a
            // duplicate. This matches the real bridge, where `remove` keeps the `seen` row so a
            // late re-flood of an already-delivered bundle is still rejected.
            if f.seen.contains_key(id) {
                return false;
            }
            f.seen.insert(id.to_vec(), expires_at as u64);
            f.bundles.insert(id.to_vec(), data.to_vec());
            true
        }
        fn get(&self, id: &[u8]) -> Option<Vec<u8>> {
            self.inner.borrow().bundles.get(id).cloned()
        }
        fn remove(&self, id: &[u8]) -> Option<Vec<u8>> {
            // Drop only the held data; the dedup (`seen`) entry lingers.
            self.inner.borrow_mut().bundles.remove(id)
        }
        fn seen(&self, id: &[u8]) -> bool {
            self.inner.borrow().seen.contains_key(id)
        }
        fn contains(&self, id: &[u8]) -> bool {
            self.inner.borrow().bundles.contains_key(id)
        }
        fn have(&self) -> Vec<u8> {
            let f = self.inner.borrow();
            let mut out = Vec::with_capacity(f.bundles.len() * 32);
            for k in f.bundles.keys() {
                out.extend_from_slice(k);
            }
            out
        }
        fn prune(&self, now_ms: f64) {
            let now = now_ms as u64;
            let mut f = self.inner.borrow_mut();
            let expired: Vec<Vec<u8>> = f
                .seen
                .iter()
                .filter(|(_, &exp)| exp <= now)
                .map(|(k, _)| k.clone())
                .collect();
            for k in expired {
                f.seen.remove(&k);
                f.bundles.remove(&k);
            }
        }
        fn set_data(&self, id: &[u8], data: &[u8]) {
            let mut f = self.inner.borrow_mut();
            if f.bundles.contains_key(id) {
                f.bundles.insert(id.to_vec(), data.to_vec());
            }
        }
        fn kv_put(&self, key: &str, value: &[u8]) {
            self.inner
                .borrow_mut()
                .kv
                .insert(key.to_string(), value.to_vec());
        }
        fn kv_get(&self, key: &str) -> Option<Vec<u8>> {
            self.inner.borrow().kv.get(key).cloned()
        }
        fn kv_remove(&self, key: &str) {
            self.inner.borrow_mut().kv.remove(key);
        }
        fn kv_list(&self, prefix: &str) -> Vec<u8> {
            // Same flat [u32 LE klen][key][u32 LE vlen][val] layout the real bridge emits.
            let f = self.inner.borrow();
            let mut out = Vec::new();
            for (k, v) in f.kv.iter() {
                if k.starts_with(prefix) {
                    out.extend_from_slice(&(k.len() as u32).to_le_bytes());
                    out.extend_from_slice(k.as_bytes());
                    out.extend_from_slice(&(v.len() as u32).to_le_bytes());
                    out.extend_from_slice(v);
                }
            }
            out
        }
    }

    fn store() -> JsStore<FakeBridge> {
        JsStore::new(FakeBridge::default())
    }

    // ---- JsStore <-> Store contract over a real bridge -------------------------------------

    #[test]
    fn kv_round_trips_through_flat_encoding() {
        // put_kv -> get_kv identity, and list_kv decodes the same flat buffer the bridge produced.
        let mut s = store();
        s.put_kv("session/alice", vec![1, 2, 3]);
        s.put_kv("session/bob", vec![9]);
        s.put_kv("prekey/self", vec![]);
        assert_eq!(s.get_kv("session/alice"), Some(vec![1, 2, 3]));
        assert_eq!(s.get_kv("prekey/self"), Some(vec![]));
        assert_eq!(s.get_kv("missing"), None);

        let mut listed = s.list_kv("session/");
        listed.sort();
        assert_eq!(
            listed,
            vec![
                ("session/alice".to_string(), vec![1, 2, 3]),
                ("session/bob".to_string(), vec![9]),
            ]
        );
        // Prefix isolation: the prekey row is not in the session slice.
        assert!(!s
            .list_kv("session/")
            .iter()
            .any(|(k, _)| k == "prekey/self"));

        s.remove_kv("session/alice");
        assert_eq!(s.get_kv("session/alice"), None);
        assert_eq!(s.list_kv("session/").len(), 1);
    }

    #[test]
    fn put_get_remove_and_have_track_a_real_bundle() {
        use hop_core::bundle::{Bundle, BundleOpts, Destination, Payload};
        let alice = Identity::generate();
        let bob = Identity::generate();
        let bundle = Bundle::create(
            &alice,
            Destination::Device(bob.address()),
            &bob.address(),
            &Payload::PeerMessage {
                content_type: "t".into(),
                body: b"hello".to_vec(),
            },
            BundleOpts::default(),
        )
        .unwrap();
        let id = bundle.id();

        let mut s = store();
        assert!(!s.contains(&id));
        assert!(s.put(bundle.clone(), 1_000), "first put must be accepted");
        assert!(s.contains(&id));
        assert!(s.seen(&id));

        // The stored bytes round-trip back to an identical bundle (postcard through the bridge).
        let got = s.get(&id).expect("held bundle must be readable");
        assert_eq!(got.id(), id);
        assert_eq!(got.to_bytes().unwrap(), bundle.to_bytes().unwrap());

        // have() reports exactly this id.
        let have = s.have();
        assert_eq!(have.ids.len(), 1);
        assert_eq!(have.ids[0], id);

        // Duplicate put inside the dedup window is rejected.
        assert!(
            !s.put(bundle.clone(), 1_000),
            "second put of same id within window is a dedup reject"
        );

        // remove drops the data but the dedup entry lingers (late duplicates still rejected).
        let removed = s.remove(&id).expect("remove returns the held bytes");
        assert_eq!(removed.id(), id);
        assert!(!s.contains(&id), "data gone after remove");
        assert!(s.seen(&id), "dedup entry retained after remove");
        assert!(
            !s.put(bundle, 1_000),
            "re-put after remove is still deduped by the retained seen entry"
        );
    }

    #[test]
    fn prune_drops_expired_seen_and_data_only_after_expiry() {
        use hop_core::bundle::{Bundle, BundleOpts, Destination, Payload};
        let alice = Identity::generate();
        let bob = Identity::generate();
        let mk = |body: &[u8]| {
            Bundle::create(
                &alice,
                Destination::Device(bob.address()),
                &bob.address(),
                &Payload::PeerMessage {
                    content_type: "t".into(),
                    body: body.to_vec(),
                },
                BundleOpts {
                    lifetime_ms: 10_000,
                    ..Default::default()
                },
            )
            .unwrap()
        };
        let b = mk(b"payload");
        let id = b.id();
        let mut s = store();
        assert!(s.put(b, 1_000)); // expires at 1_000 + 10_000 = 11_000
        s.prune(5_000);
        assert!(s.contains(&id), "not yet expired: survives prune");
        s.prune(11_001);
        assert!(!s.contains(&id), "past expiry: data pruned");
        assert!(!s.seen(&id), "past expiry: dedup entry pruned too");
    }

    #[test]
    fn ttl_is_clamped_to_the_max_seen_window() {
        use hop_core::bundle::{Bundle, BundleOpts, Destination, Payload};
        // A hostile ~49-day lifetime must not pin the dedup window past the one-week clamp (F-07).
        let alice = Identity::generate();
        let bob = Identity::generate();
        let b = Bundle::create(
            &alice,
            Destination::Device(bob.address()),
            &bob.address(),
            &Payload::PeerMessage {
                content_type: "t".into(),
                body: b"x".to_vec(),
            },
            BundleOpts {
                lifetime_ms: u32::MAX, // ~49 days
                ..Default::default()
            },
        )
        .unwrap();
        let id = b.id();
        let mut s = store();
        assert!(s.put(b, 0));
        // Just past the clamp: the seen entry must be prunable, proving the lifetime was clamped.
        s.prune(MAX_SEEN_LIFETIME_MS + 1);
        assert!(
            !s.seen(&id),
            "seen window must be clamped to MAX_SEEN_LIFETIME_MS, not ~49 days"
        );
    }

    #[test]
    fn split_copies_halves_the_stored_budget() {
        use hop_core::bundle::{Bundle, BundleOpts, Destination, Payload};
        let alice = Identity::generate();
        let bob = Identity::generate();
        let b = Bundle::create(
            &alice,
            Destination::Device(bob.address()),
            &bob.address(),
            &Payload::PeerMessage {
                content_type: "t".into(),
                body: b"x".to_vec(),
            },
            BundleOpts {
                copies: 8,
                ..Default::default()
            },
        )
        .unwrap();
        let id = b.id();
        let mut s = store();
        s.put(b, 0);
        // Binary spray-and-wait: give floor(n/2), keep the rest, and the write persists via set_data.
        let give = s.split_copies(&id);
        assert_eq!(give, 4, "floor(8/2) handed to the peer");
        let kept = s.get(&id).unwrap().env.copies;
        assert_eq!(
            kept, 4,
            "remaining budget persisted back through the bridge"
        );

        // set_copies overwrites the stored budget.
        s.set_copies(&id, 1);
        assert_eq!(s.get(&id).unwrap().env.copies, 1);
        // At 1 copy, nothing more to split.
        assert_eq!(s.split_copies(&id), 0);
    }

    #[test]
    fn split_copies_absent_bundle_is_zero() {
        let missing: hop_core::bundle::BundleId = [7u8; 32];
        let mut s = store();
        assert_eq!(s.split_copies(&missing), 0);
        assert!(s.get(&missing).is_none());
    }

    // ---- The wasm-facing node surface, exercised on the host through Node<JsStore<Fake>> -----
    //
    // WasmNode is a thin `#[wasm_bindgen]` wrapper whose methods each call one Node method over a
    // JsStore. #[wasm_bindgen] forbids generics, so we can't instantiate WasmNode itself on the
    // host, but we CAN build the exact `Node<JsStore<B>>` it wraps and drive the same code paths.

    type TestNode = Node<JsStore<FakeBridge>>;

    fn node(seed: u8) -> TestNode {
        let id = Identity::from_secret_bytes(&[seed; 32]);
        Node::with_store(id, JsStore::new(FakeBridge::default()))
    }

    /// Deliver queued bytes between exactly two linked nodes until quiescent (mirrors the sim loop:
    /// drain -> peer.receive each frame).
    fn pump(a: &mut TestNode, la: u64, b: &mut TestNode, lb: u64) {
        for _ in 0..1000 {
            let mut any = false;
            for (l, bytes) in a.drain_outgoing() {
                any = true;
                if l == la {
                    b.handle(BearerEvent::Data(lb, bytes));
                }
            }
            for (l, bytes) in b.drain_outgoing() {
                any = true;
                if l == lb {
                    a.handle(BearerEvent::Data(la, bytes));
                }
            }
            if !any {
                break;
            }
        }
    }

    #[test]
    fn identity_seed_is_deterministic() {
        // Same 32-byte seed -> same address (WasmNode::new relies on this for stable addresses).
        assert_eq!(node(3).address(), node(3).address());
        assert_ne!(node(3).address(), node(4).address());
    }

    #[test]
    fn a_message_sent_over_a_link_is_retrievable_and_decrypts() {
        // The core invariant behind WasmNode::send + WasmNode::inbox: a private (§39) message
        // sealed to a peer over a real link arrives, decrypts, and reports the right sender/body.
        let mut a = node(1);
        let mut b = node(2);
        let (la, lb) = (10u64, 11u64);

        a.handle(BearerEvent::Connected(la, Role::Initiator));
        b.handle(BearerEvent::Connected(lb, Role::Responder));
        pump(&mut a, la, &mut b, lb);

        // Both publish + gossip prekeys so a forward-secret session can open (content is never
        // static-sealed).
        a.publish_prekey().unwrap();
        b.publish_prekey().unwrap();
        pump(&mut a, la, &mut b, lb);

        assert!(
            a.knows_prekey(&b.address()),
            "a must hold b's gossiped prekey before it can seal"
        );

        let body = b"meet at the docks";
        let sent_id = a
            .send_message(b.address(), "text/plain".into(), body.to_vec(), true)
            .expect("send_message succeeds once the prekey is known");
        pump(&mut a, la, &mut b, lb);

        // b's inbox: exactly the one message, from a, with the right body (this is what
        // WasmNode::inbox surfaces).
        let inbox = b.take_inbox();
        let mut delivered = Vec::new();
        for bundle in &inbox {
            if let Ok(Some(rm)) = b.read_message(bundle) {
                delivered.push((rm.from, rm.content_type, rm.body, bundle.id()));
            }
        }
        assert_eq!(delivered.len(), 1, "exactly one message delivered to b");
        assert_eq!(delivered[0].0, a.address(), "sender is a");
        assert_eq!(delivered[0].1, "text/plain");
        assert_eq!(delivered[0].2, body);

        // The bundle actually lived in b's JsStore (the whole point of the host-owned store).
        assert!(
            b.store.have().ids.contains(&delivered[0].3),
            "delivered bundle is held in b's JsStore-backed have-set"
        );

        // a's send is tracked, and its returned id is a real 32-byte bundle id.
        assert_eq!(sent_id.len(), 32);
        assert!(
            a.sends_status().iter().any(|(id, _, _)| *id == sent_id),
            "a tracks the send it just made"
        );
    }

    #[test]
    fn send_without_a_prekey_defers_then_flushes_when_the_prekey_arrives() {
        // Content is never static-sealed (§25): a send to a peer whose prekey we don't hold yet is
        // deferred ("Securing…") and returns a stable handle, then flushes and delivers the moment
        // the prekey is gossiped in. This is exactly WasmNode::send's deferral/flush contract.
        let mut a = node(5);
        let mut b = node(6);
        let (la, lb) = (20u64, 21u64);
        a.handle(BearerEvent::Connected(la, Role::Initiator));
        b.handle(BearerEvent::Connected(lb, Role::Responder));
        pump(&mut a, la, &mut b, lb);

        assert!(!a.knows_prekey(&b.address()), "no prekey held yet");
        let handle = a
            .send_message(
                b.address(),
                "text/plain".into(),
                b"deferred hi".to_vec(),
                true,
            )
            .expect("send is accepted (deferred) even without a prekey");
        assert_eq!(handle.len(), 32, "a stable 32-byte handle is returned");
        // The deferred send is tracked but not delivered: the "Securing…" state.
        assert!(
            a.sends_status()
                .iter()
                .any(|(id, _, delivered)| *id == handle && !*delivered),
            "the deferred send is tracked as not-yet-delivered"
        );

        // Now b publishes + gossips its prekey; a's deferred content must flush and deliver.
        b.publish_prekey().unwrap();
        pump(&mut a, la, &mut b, lb);
        assert!(
            a.knows_prekey(&b.address()),
            "a learned b's prekey via gossip"
        );
        pump(&mut a, la, &mut b, lb);

        let inbox = b.take_inbox();
        let mut bodies = Vec::new();
        for bundle in &inbox {
            if let Ok(Some(rm)) = b.read_message(bundle) {
                bodies.push(rm.body);
            }
        }
        assert!(
            bodies.iter().any(|body| body == b"deferred hi"),
            "the once-deferred message flushed and was delivered after the prekey arrived"
        );
    }

    #[test]
    fn traced_send_with_a_prekey_holds_a_forwardable_bundle() {
        // WasmNode::send_traced also requires a prekey (never static-seals); given one, it creates a
        // real held bundle the node can spray.
        let mut a = node(7);
        let mut b = node(8);
        let (la, lb) = (30u64, 31u64);
        a.handle(BearerEvent::Connected(la, Role::Initiator));
        b.handle(BearerEvent::Connected(lb, Role::Responder));
        pump(&mut a, la, &mut b, lb);
        a.publish_prekey().unwrap();
        b.publish_prekey().unwrap();
        pump(&mut a, la, &mut b, lb);
        assert!(a.knows_prekey(&b.address()));

        let before = a.held_bundle_ids_display().len();
        a.send_message_traced(b.address(), "text/plain".into(), b"pos".to_vec(), true)
            .expect("traced send with a known prekey succeeds");
        let after = a.held_bundle_ids_display().len();
        assert!(
            after > before,
            "traced send created a real held bundle to spray (not just a deferral handle)"
        );
    }

    #[test]
    fn mailbox_tag_is_stable_16_bytes_and_gradient_view_starts_empty() {
        // Backs WasmNode::mailbox_tag (16-byte tag a relay's gradient points toward) and
        // WasmNode::gradient (empty until beacons lay a gradient).
        let n = node(9);
        let tag = n.current_mailbox_tag();
        assert_eq!(tag.len(), 16);
        assert_eq!(tag, node(9).current_mailbox_tag(), "tag is deterministic");
        assert!(
            n.recv_gradient_view().is_empty(),
            "a fresh node holds no gradient toward any mailbox"
        );
    }

    #[test]
    fn a_delivered_message_persists_a_forward_secret_session_in_the_kv_store() {
        // The whole reason JsStore exposes a kv surface (§25): a forward-secret session must survive
        // a restart. After a real delivery, the receiver has opened a session and persisted it under
        // the `session/` prefix through the bridge's put_kv (decoded back via list_kv).
        let mut a = node(40);
        let mut b = node(41);
        let (la, lb) = (50u64, 51u64);
        a.handle(BearerEvent::Connected(la, Role::Initiator));
        b.handle(BearerEvent::Connected(lb, Role::Responder));
        pump(&mut a, la, &mut b, lb);
        a.publish_prekey().unwrap();
        b.publish_prekey().unwrap();
        pump(&mut a, la, &mut b, lb);

        assert!(
            b.store.list_kv("session/").is_empty(),
            "no session persisted before any message opens one"
        );

        a.send_message(
            b.address(),
            "text/plain".into(),
            b"open a session".to_vec(),
            true,
        )
        .unwrap();
        pump(&mut a, la, &mut b, lb);
        // Force b to decrypt (which establishes + persists the session).
        for bundle in b.take_inbox() {
            let _ = b.read_message(&bundle);
        }

        let sessions = b.store.list_kv("session/");
        assert!(
            !sessions.is_empty(),
            "decrypting a delivered message must persist a forward-secret session via the bridge kv"
        );
        assert!(
            sessions.iter().all(|(k, _)| k.starts_with("session/")),
            "list_kv prefix filtering returns only session rows"
        );
    }
}
