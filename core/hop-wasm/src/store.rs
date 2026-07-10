//! `JsStore` — a hop-core [`Store`] backed by a host-provided **synchronous** JS bridge.
//!
//! This is hop's pluggable storage used exactly as intended (DESIGN.md §25: the host owns storage).
//! A browser deployment backs the bridge with SQLite on an OPFS sync-access VFS in a Worker, so held
//! bundles live on disk instead of wasm linear memory — the thing that OOMs a many-node tab. The core
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

/// A `Store` that delegates every operation to a host [`StoreBridge`] (one per node).
pub struct JsStore {
    bridge: StoreBridge,
}

impl JsStore {
    pub fn new(bridge: StoreBridge) -> Self {
        Self { bridge }
    }
}

impl Store for JsStore {
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
