//! # hop-store-sqlite
//!
//! A persistent [`Store`](hop_core::store::Store) backend for Hop, on SQLite via
//! `rusqlite` (bundled) — the decided backend in DESIGN.md §13.2. Survives
//! restarts, dedups across them, and supports the spray-and-wait copy mutations.
//!
//! Two tables: `bundles(id, data)` holds the currently-held bundles (postcard
//! encoded), and `seen(id)` is the dedup set — retained after a bundle is removed
//! so a re-offered duplicate is still rejected. The copy budget lives inside the
//! encoded `data` (re-encoded on mutation) so a read always reflects current state.
//!
//! Encryption at rest (SQLCipher or app-supplied page encryption) is layered at
//! open time and is out of scope for this crate's logic.

use hop_core::bundle::{Bundle, BundleId};
use hop_core::store::{HaveSet, Store};
use rusqlite::{params, Connection};

/// A SQLite-backed bundle store.
pub struct SqliteStore {
    conn: Connection,
}

impl SqliteStore {
    /// Open (creating if needed) a store at `path`.
    pub fn open(path: &str) -> rusqlite::Result<Self> {
        Self::from_conn(Connection::open(path)?)
    }

    /// Open an ephemeral in-memory store (for tests).
    pub fn open_in_memory() -> rusqlite::Result<Self> {
        Self::from_conn(Connection::open_in_memory()?)
    }

    fn from_conn(conn: Connection) -> rusqlite::Result<Self> {
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS bundles (id BLOB PRIMARY KEY, data BLOB NOT NULL);
             CREATE TABLE IF NOT EXISTS seen (id BLOB PRIMARY KEY, expires_at INTEGER NOT NULL);",
        )?;
        Ok(Self { conn })
    }

    fn write_data(&self, id: &BundleId, bundle: &Bundle) -> rusqlite::Result<()> {
        let data = bundle.to_bytes().map_err(to_sqlite_err)?;
        self.conn.execute(
            "INSERT OR REPLACE INTO bundles (id, data) VALUES (?1, ?2)",
            params![&id[..], data],
        )?;
        Ok(())
    }
}

fn to_sqlite_err<E: std::error::Error + Send + Sync + 'static>(e: E) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(e))
}

impl Store for SqliteStore {
    fn put(&mut self, bundle: Bundle, now_ms: u64) -> bool {
        let id = bundle.id();
        if self.seen(&id) {
            return false; // dedup within the id's window
        }
        let expires_at = now_ms.saturating_add(bundle.inner.lifetime_ms as u64);
        let result = (|| -> rusqlite::Result<()> {
            self.conn.execute(
                "INSERT OR IGNORE INTO seen (id, expires_at) VALUES (?1, ?2)",
                params![&id[..], expires_at as i64],
            )?;
            self.write_data(&id, &bundle)
        })();
        result.is_ok()
    }

    fn get(&self, id: &BundleId) -> Option<Bundle> {
        self.conn
            .query_row(
                "SELECT data FROM bundles WHERE id = ?1",
                params![&id[..]],
                |row| row.get::<_, Vec<u8>>(0),
            )
            .ok()
            .and_then(|data| Bundle::from_bytes(&data).ok())
    }

    fn remove(&mut self, id: &BundleId) -> Option<Bundle> {
        let existing = self.get(id);
        let _ = self
            .conn
            .execute("DELETE FROM bundles WHERE id = ?1", params![&id[..]]);
        existing
    }

    fn seen(&self, id: &BundleId) -> bool {
        self.conn
            .query_row("SELECT 1 FROM seen WHERE id = ?1", params![&id[..]], |_| Ok(()))
            .is_ok()
    }

    fn contains(&self, id: &BundleId) -> bool {
        self.conn
            .query_row("SELECT 1 FROM bundles WHERE id = ?1", params![&id[..]], |_| Ok(()))
            .is_ok()
    }

    fn have(&self) -> HaveSet {
        let ids = (|| -> rusqlite::Result<Vec<BundleId>> {
            let mut stmt = self.conn.prepare("SELECT id FROM bundles")?;
            let rows = stmt.query_map([], |row| row.get::<_, Vec<u8>>(0))?;
            let mut out = Vec::new();
            for r in rows {
                if let Ok(id) = <[u8; 32]>::try_from(r?.as_slice()) {
                    out.push(id);
                }
            }
            Ok(out)
        })()
        .unwrap_or_default();
        HaveSet { ids }
    }

    fn prune(&mut self, now_ms: u64) {
        let _ = self.conn.execute(
            "DELETE FROM bundles WHERE id IN (SELECT id FROM seen WHERE expires_at <= ?1)",
            params![now_ms as i64],
        );
        let _ = self
            .conn
            .execute("DELETE FROM seen WHERE expires_at <= ?1", params![now_ms as i64]);
    }

    fn split_copies(&mut self, id: &BundleId) -> u16 {
        let Some(mut bundle) = self.get(id) else {
            return 0;
        };
        let give = bundle.split_copies();
        if give > 0 {
            let _ = self.write_data(id, &bundle);
        }
        give
    }

    fn set_copies(&mut self, id: &BundleId, copies: u16) {
        if let Some(mut bundle) = self.get(id) {
            bundle.env.copies = copies;
            let _ = self.write_data(id, &bundle);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hop_core::prelude::*;

    fn sample(copies: u16) -> Bundle {
        let from = Identity::generate();
        let to = Identity::generate();
        Bundle::create(
            &from,
            Destination::Device(to.address()),
            &to.address(),
            &Payload::PeerMessage { content_type: "t".into(), body: b"persist me".to_vec() },
            BundleOpts { copies, ..Default::default() },
        )
        .unwrap()
    }

    #[test]
    fn put_get_dedup_remove() {
        let mut s = SqliteStore::open_in_memory().unwrap();
        let b = sample(8);
        let id = b.id();

        assert!(s.put(b.clone(), 0));
        assert!(!s.put(b.clone(), 0), "duplicate rejected");
        assert!(s.seen(&id) && s.contains(&id));

        let got = s.get(&id).unwrap();
        got.verify().unwrap();
        assert_eq!(got, b);
        assert_eq!(s.have().ids, vec![id]);

        s.remove(&id);
        assert!(s.get(&id).is_none());
        assert!(!s.contains(&id));
        assert!(s.seen(&id), "seen is retained after removal for dedup");
        assert!(!s.put(b, 0), "a removed-but-seen bundle is not re-accepted");
    }

    #[test]
    fn copy_budget_mutations_persist() {
        let mut s = SqliteStore::open_in_memory().unwrap();
        let b = sample(8);
        let id = b.id();
        s.put(b, 0);

        assert_eq!(s.split_copies(&id), 4); // 8 -> keep 4, give 4
        assert_eq!(s.get(&id).unwrap().env.copies, 4);
        assert_eq!(s.split_copies(&id), 2); // 4 -> keep 2, give 2
        assert_eq!(s.get(&id).unwrap().env.copies, 2);

        s.set_copies(&id, 8); // retransmit reset
        assert_eq!(s.get(&id).unwrap().env.copies, 8);
    }

    #[test]
    fn survives_reopen() {
        let path = format!("{}/hop-sqlite-reopen-test.db", std::env::temp_dir().display());
        let _ = std::fs::remove_file(&path);

        let b = sample(8);
        let id = b.id();
        {
            let mut s = SqliteStore::open(&path).unwrap();
            s.put(b.clone(), 0);
        } // drop closes the connection

        let s = SqliteStore::open(&path).unwrap();
        let got = s.get(&id).expect("bundle persisted across reopen");
        assert_eq!(got, b);
        got.verify().unwrap();

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn prune_closes_dedup_window() {
        let mut s = SqliteStore::open_in_memory().unwrap();
        let from = Identity::generate();
        let to = Identity::generate();
        let b = Bundle::create(
            &from,
            Destination::Device(to.address()),
            &to.address(),
            &Payload::PeerMessage { content_type: "t".into(), body: vec![1] },
            BundleOpts { lifetime_ms: 1_000, ..Default::default() },
        )
        .unwrap();
        let id = b.id();

        s.put(b.clone(), 0); // dedup window closes at 1000
        s.prune(500);
        assert!(s.seen(&id) && s.contains(&id));
        s.prune(2_000);
        assert!(!s.seen(&id) && !s.contains(&id), "window closed, entry pruned");
        assert!(s.put(b, 2_000), "re-accepted after window");
    }

    #[test]
    fn drives_a_node_as_a_backend() {
        // The whole point: Node runs on the persistent store.
        let sender = Identity::generate();
        let you = Identity::generate();
        let bundle = Bundle::create(
            &sender,
            Destination::Device(you.address()),
            &you.address(),
            &Payload::PeerMessage { content_type: "t".into(), body: b"hi".to_vec() },
            BundleOpts::default(),
        )
        .unwrap();
        let bid = bundle.id();

        let mut node = Node::with_store(Identity::generate(), SqliteStore::open_in_memory().unwrap());
        node.submit(bundle);
        assert!(node.store.contains(&bid), "submitted bundle is in the sqlite store");
    }
}
