//! # hop-store-firestore
//!
//! A durable [`Store`](hop_core::store::Store) for a relay node, backed by Firestore
//! so the mailbox survives scale-to-zero (DESIGN.md §19/§21). **Per node**, not a
//! global store: each relay owns the subcollection
//! `relays/{node}/bundles`, so there's no cross-region contention.
//!
//! The relay's driver loop is synchronous and single-owner, so we never block it on
//! a Firestore round-trip: a [`MemoryStore`] is the hot path and a **background
//! writer thread** mirrors writes/deletes to Firestore (a FIFO channel preserves
//! per-id order). On startup we **load** the held bundles back from Firestore into
//! memory; the node's `rehydrate` then resumes them. Only *bundles* are persisted —
//! the dedup `seen` set is in-memory (losing it across a scale cycle costs at most
//! some re-flooding, which the receiver dedups; §7).
//!
//! Durable cleanup of expired bundles is left to a **Firestore TTL policy** on the
//! `expiresAt` field (a one-time setup), so `prune` stays a fast in-memory op.
//!
//! Auth: a Bearer token from the GCE/Cloud Run **metadata server** (workload
//! identity), or the `FIRESTORE_ACCESS_TOKEN` env var for local runs.

use std::sync::mpsc::{self, Sender};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use base64::Engine;
use hop_core::bundle::{Bundle, BundleId};
use hop_core::store::{HaveSet, MemoryStore, Store};

/// A bundle write/delete to mirror to Firestore.
enum Op {
    Write { id: BundleId, data: Vec<u8>, expires_at: u64 },
    Delete { id: BundleId },
}

/// Durable per-node store: in-memory hot path + Firestore mirror.
pub struct FirestoreStore {
    inner: MemoryStore,
    tx: Sender<Op>,
}

impl FirestoreStore {
    /// Open the store for `node_addr` in `project`, loading any held bundles back
    /// into memory. Spawns the background writer thread.
    pub fn open(project: &str, node_addr: &[u8]) -> Result<Self, String> {
        let client = FirestoreClient::new(project, node_addr);
        let mut inner = MemoryStore::new();

        // Rehydrate held bundles from Firestore into memory (mark seen so dedup holds).
        for (data, _expires) in client.list_bundles()? {
            if let Ok(bundle) = Bundle::from_bytes(&data) {
                inner.put(bundle, 0);
            }
        }

        let (tx, rx) = mpsc::channel::<Op>();
        std::thread::spawn(move || {
            for op in rx {
                // Best-effort with a couple of retries; the hot path never blocks here.
                for attempt in 0..3 {
                    let ok = match &op {
                        Op::Write { id, data, expires_at } => client.put_bundle(id, data, *expires_at),
                        Op::Delete { id } => client.delete_bundle(id),
                    };
                    if ok.is_ok() {
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(200 * (attempt + 1)));
                }
            }
        });

        Ok(Self { inner, tx })
    }
}

impl Store for FirestoreStore {
    fn put(&mut self, bundle: Bundle, now_ms: u64) -> bool {
        let id = bundle.id();
        let expires_at = now_ms.saturating_add(bundle.inner.lifetime_ms as u64);
        let data = match bundle.to_bytes() {
            Ok(d) => d,
            Err(_) => return false,
        };
        if self.inner.put(bundle, now_ms) {
            let _ = self.tx.send(Op::Write { id, data, expires_at });
            true
        } else {
            false
        }
    }

    fn get(&self, id: &BundleId) -> Option<Bundle> {
        self.inner.get(id)
    }

    fn remove(&mut self, id: &BundleId) -> Option<Bundle> {
        let removed = self.inner.remove(id);
        if removed.is_some() {
            let _ = self.tx.send(Op::Delete { id: *id });
        }
        removed
    }

    fn seen(&self, id: &BundleId) -> bool {
        self.inner.seen(id)
    }

    fn contains(&self, id: &BundleId) -> bool {
        self.inner.contains(id)
    }

    fn have(&self) -> HaveSet {
        self.inner.have()
    }

    fn prune(&mut self, now_ms: u64) {
        // In-memory only; the durable copies are reaped by a Firestore TTL policy on
        // `expiresAt` (one-time setup), keeping prune off the network.
        self.inner.prune(now_ms);
    }

    fn split_copies(&mut self, id: &BundleId) -> u16 {
        let give = self.inner.split_copies(id);
        if give > 0 {
            if let Some(b) = self.inner.get(id) {
                if let Ok(data) = b.to_bytes() {
                    let expires_at = b.inner.created_at.saturating_add(b.inner.lifetime_ms as u64);
                    let _ = self.tx.send(Op::Write { id: *id, data, expires_at });
                }
            }
        }
        give
    }

    fn set_copies(&mut self, id: &BundleId, copies: u16) {
        self.inner.set_copies(id, copies);
        if let Some(b) = self.inner.get(id) {
            if let Ok(data) = b.to_bytes() {
                let expires_at = b.inner.created_at.saturating_add(b.inner.lifetime_ms as u64);
                let _ = self.tx.send(Op::Write { id: *id, data, expires_at });
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Firestore REST client (blocking; runs only on the background thread + open()).
// ---------------------------------------------------------------------------

struct FirestoreClient {
    http: reqwest::blocking::Client,
    collection_url: String, // .../documents/relays/{node}/bundles
    token: Mutex<Option<(String, Instant)>>,
}

impl FirestoreClient {
    fn new(project: &str, node_addr: &[u8]) -> Self {
        let node = bs58::encode(node_addr).into_string();
        let base = "https://firestore.googleapis.com/v1";
        let collection_url =
            format!("{base}/projects/{project}/databases/(default)/documents/relays/{node}/bundles");
        Self {
            http: reqwest::blocking::Client::builder()
                .timeout(Duration::from_secs(15))
                .build()
                .expect("http client"),
            collection_url,
            token: Mutex::new(None),
        }
    }

    /// A cached OAuth token: metadata server (Cloud Run/GCE) or `FIRESTORE_ACCESS_TOKEN`.
    fn token(&self) -> Result<String, String> {
        if let Some((tok, at)) = self.token.lock().unwrap().clone() {
            if at.elapsed() < Duration::from_secs(3000) {
                return Ok(tok);
            }
        }
        let tok = self.fetch_token()?;
        *self.token.lock().unwrap() = Some((tok.clone(), Instant::now()));
        Ok(tok)
    }

    fn fetch_token(&self) -> Result<String, String> {
        if let Ok(t) = std::env::var("FIRESTORE_ACCESS_TOKEN") {
            if !t.is_empty() {
                return Ok(t);
            }
        }
        let url = "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token";
        let resp = self
            .http
            .get(url)
            .header("Metadata-Flavor", "Google")
            .send()
            .map_err(|e| e.to_string())?;
        let v: serde_json::Value = resp.json().map_err(|e| e.to_string())?;
        v["access_token"].as_str().map(|s| s.to_string()).ok_or_else(|| "no access_token".into())
    }

    fn put_bundle(&self, id: &BundleId, data: &[u8], expires_at: u64) -> Result<(), String> {
        let doc = bs58::encode(id).into_string();
        let url = format!("{}/{doc}", self.collection_url);
        let body = doc_json(data, expires_at);
        let token = self.token()?;
        let resp = self
            .http
            .patch(&url)
            .bearer_auth(token)
            .json(&body)
            .send()
            .map_err(|e| e.to_string())?;
        if resp.status().is_success() {
            Ok(())
        } else {
            Err(format!("put {}", resp.status()))
        }
    }

    fn delete_bundle(&self, id: &BundleId) -> Result<(), String> {
        let doc = bs58::encode(id).into_string();
        let url = format!("{}/{doc}", self.collection_url);
        let token = self.token()?;
        let resp = self.http.delete(&url).bearer_auth(token).send().map_err(|e| e.to_string())?;
        // 404 is fine — already gone.
        if resp.status().is_success() || resp.status().as_u16() == 404 {
            Ok(())
        } else {
            Err(format!("delete {}", resp.status()))
        }
    }

    fn list_bundles(&self) -> Result<Vec<(Vec<u8>, u64)>, String> {
        let token = self.token()?;
        let mut out = Vec::new();
        let mut page_token: Option<String> = None;
        loop {
            let mut url = format!("{}?pageSize=300", self.collection_url);
            if let Some(t) = &page_token {
                url.push_str(&format!("&pageToken={t}"));
            }
            let resp = self
                .http
                .get(&url)
                .bearer_auth(&token)
                .send()
                .map_err(|e| e.to_string())?;
            if resp.status().as_u16() == 404 {
                return Ok(out); // collection doesn't exist yet
            }
            if !resp.status().is_success() {
                return Err(format!("list {}", resp.status()));
            }
            let v: serde_json::Value = resp.json().map_err(|e| e.to_string())?;
            if let Some(docs) = v["documents"].as_array() {
                for d in docs {
                    if let Some((data, expires)) = parse_doc(d) {
                        out.push((data, expires));
                    }
                }
            }
            match v["nextPageToken"].as_str() {
                Some(t) if !t.is_empty() => page_token = Some(t.to_string()),
                _ => break,
            }
        }
        Ok(out)
    }
}

/// Build a Firestore document body for a bundle.
fn doc_json(data: &[u8], expires_at: u64) -> serde_json::Value {
    let b64 = base64::engine::general_purpose::STANDARD.encode(data);
    serde_json::json!({
        "fields": {
            "data": { "bytesValue": b64 },
            "expiresAt": { "integerValue": expires_at.to_string() },
        }
    })
}

/// Parse a Firestore document into `(bundle bytes, expires_at)`.
fn parse_doc(d: &serde_json::Value) -> Option<(Vec<u8>, u64)> {
    let fields = d.get("fields")?;
    let b64 = fields["data"]["bytesValue"].as_str()?;
    let data = base64::engine::general_purpose::STANDARD.decode(b64).ok()?;
    let expires = fields["expiresAt"]["integerValue"].as_str().and_then(|s| s.parse().ok()).unwrap_or(0);
    Some((data, expires))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn doc_round_trips_through_firestore_encoding() {
        let data = b"sealed bundle bytes \x00\x01\xff".to_vec();
        let json = doc_json(&data, 123_456);
        // Re-shape as a Firestore document (the API nests fields under "fields").
        let doc = serde_json::json!({ "name": "x", "fields": json["fields"] });
        let (got, expires) = parse_doc(&doc).expect("parse");
        assert_eq!(got, data);
        assert_eq!(expires, 123_456);
    }

    #[test]
    fn parse_doc_rejects_garbage() {
        assert!(parse_doc(&serde_json::json!({"name": "x"})).is_none());
    }
}
