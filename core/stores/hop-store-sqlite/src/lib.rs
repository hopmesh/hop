//! # hop-store-sqlite
//!
//! A persistent [`Store`](hop_core::store::Store) backend for Hop, on SQLite via
//! `rusqlite` (bundled), the decided backend in DESIGN.md §13.2. Survives
//! restarts and dedups across them.
//!
//! Two tables: `bundles(id, data)` holds the currently-held bundles (postcard
//! encoded), and `seen(id)` is the dedup set, retained after a bundle is removed
//! so a re-offered duplicate is still rejected. `Envelope.copies` rides inside the encoded
//! `data` and must round-trip byte-exactly: it is reserved wire capacity that routing ignores
//! (DESIGN.md §6), not a budget this store mutates.
//!
//! Encryption at rest (F-25): available via the `sqlcipher` cargo feature + [`SqliteStore::open_keyed`].
//! The default build uses plain `bundled` SQLite (cleartext on disk, ratchet keys, hps content keys,
//! queued message bodies), so a plain-feature build must still rely on iOS file protection + the app
//! sandbox. Build with `--features sqlcipher` (SQLite + SQLCipher, vendored OpenSSL) and open the store
//! with a 32-byte key from the platform Keychain/Keystore to encrypt every page at rest (DESIGN.md §13.2).

use hop_core::bundle::{Bundle, BundleId};
use hop_core::store::{HaveSet, KvMutation, Store};
use rusqlite::{params, Connection};
use zeroize::Zeroize;

/// stores-12: format the raw key bytes as lowercase hex into a heap `String` that is zeroized on
/// drop. The at-rest SQLCipher key would otherwise linger in an unzeroized allocation for the
/// process lifetime; wrapping it means the hex spelling is wiped as soon as it goes out of scope.
struct HexKey(String);

impl HexKey {
    fn new(key: &[u8]) -> Self {
        let mut hex = String::with_capacity(key.len() * 2);
        for b in key {
            // Manual nibble->hex so we never route the bytes through a throwaway `format!`
            // allocation that we couldn't zeroize.
            const NIBBLES: &[u8; 16] = b"0123456789abcdef";
            hex.push(NIBBLES[(b >> 4) as usize] as char);
            hex.push(NIBBLES[(b & 0x0f) as usize] as char);
        }
        HexKey(hex)
    }

    fn as_str(&self) -> &str {
        &self.0
    }
}

impl Drop for HexKey {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

/// Hard cap on how long a `seen` dedup row is retained, regardless of a bundle's claimed
/// `lifetime_ms` (F-07). The field is attacker-controlled (a `u32` ms, ~49 days max) and, for an
/// unsigned §39 private bundle, unauthenticated, so a flood of long-lived ids could bloat the
/// dedup set for weeks. We clamp the retained window to a week; a duplicate past that is re-accepted
/// (harmless: it re-floods and is re-deduped) but the table cannot be pinned open indefinitely.
const MAX_SEEN_LIFETIME_MS: u64 = 7 * 24 * 60 * 60 * 1000;

/// Row cap on the `seen` dedup table (F-07). Past this we evict the nearest-to-expiry rows so a
/// bundle flood can't grow it without bound. Generous enough that legitimate traffic never trips it.
const MAX_SEEN_ROWS: i64 = 200_000;

/// An OS-level advisory file lock using flock on a sidecar `{path}.lock` file.
/// Held for the lifetime of SqliteStore to prevent concurrent processes from deriving
/// or mutating the same identity's cryptographic state (STORE-002).
struct FileLock {
    _file: std::fs::File,
}

impl FileLock {
    fn acquire(db_path: &str) -> rusqlite::Result<Self> {
        let lock_path = std::path::PathBuf::from(format!("{db_path}.lock"));
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(&lock_path)
            .map_err(|e| {
                rusqlite::Error::SqliteFailure(
                    rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_CANTOPEN),
                    Some(format!(
                        "failed to open lock file {}: {e}",
                        lock_path.display()
                    )),
                )
            })?;

        #[cfg(unix)]
        {
            use std::os::unix::io::AsRawFd;
            let fd = file.as_raw_fd();
            let ret = unsafe { libc::flock(fd, libc::LOCK_EX | libc::LOCK_NB) };
            if ret != 0 {
                let err = std::io::Error::last_os_error();
                return Err(rusqlite::Error::SqliteFailure(
                    rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_BUSY),
                    Some(format!(
                        "database is locked by another live writer (flock on {} unavailable: {err})",
                        lock_path.display()
                    )),
                ));
            }
        }

        Ok(Self { _file: file })
    }
}

impl Drop for FileLock {
    fn drop(&mut self) {
        #[cfg(unix)]
        {
            use std::os::unix::io::AsRawFd;
            unsafe {
                libc::flock(self._file.as_raw_fd(), libc::LOCK_UN);
            }
        }
    }
}

static LIVE_OPEN_PATHS: std::sync::Mutex<Option<std::collections::HashSet<std::path::PathBuf>>> =
    std::sync::Mutex::new(None);

fn canonical_db_key(path: &str) -> std::path::PathBuf {
    let p = std::path::Path::new(path);
    if let Ok(canon) = p.canonicalize() {
        canon
    } else {
        let absolute = if p.is_absolute() {
            p.to_path_buf()
        } else {
            std::env::current_dir()
                .map(|cwd| cwd.join(p))
                .unwrap_or_else(|_| p.to_path_buf())
        };
        if let Some(parent) = absolute.parent() {
            if let Ok(canon_parent) = parent.canonicalize() {
                if let Some(file_name) = absolute.file_name() {
                    return canon_parent.join(file_name);
                }
            }
        }
        absolute
    }
}

/// An in-process single-writer lease preventing multiple HopNode / SqliteStore instances
/// in the same process from opening the same on-disk database path (STORE-002).
struct ProcessPathLease {
    path: std::path::PathBuf,
}

impl ProcessPathLease {
    fn acquire(path: &str) -> rusqlite::Result<Self> {
        let canon = canonical_db_key(path);
        let mut guard = LIVE_OPEN_PATHS.lock().unwrap();
        let set = guard.get_or_insert_with(std::collections::HashSet::new);
        if set.contains(&canon) {
            return Err(rusqlite::Error::SqliteFailure(
                rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_BUSY),
                Some(format!(
                    "database is already open in this process: {}",
                    canon.display()
                )),
            ));
        }
        set.insert(canon.clone());
        Ok(Self { path: canon })
    }
}

impl Drop for ProcessPathLease {
    fn drop(&mut self) {
        let mut guard = LIVE_OPEN_PATHS.lock().unwrap();
        if let Some(set) = guard.as_mut() {
            set.remove(&self.path);
        }
    }
}

/// A SQLite-backed bundle store.
pub struct SqliteStore {
    conn: Connection,
    /// stores-10: in-memory count of `seen` rows so `put` does not run `SELECT COUNT(*)` (a full
    /// table scan) on every insert under the node Mutex. Seeded once at open, then kept in step with
    /// every insert/evict/prune.
    seen_rows: std::cell::Cell<i64>,
    _file_lock: Option<FileLock>,
    _process_lease: Option<ProcessPathLease>,
}

impl SqliteStore {
    pub const SCHEMA_VERSION: i64 = 2;

    /// Checks if a rusqlite error indicates an unsupported on-disk schema version.
    pub fn is_unsupported_schema(err: &rusqlite::Error) -> Option<i64> {
        if let rusqlite::Error::SqliteFailure(_, Some(msg)) = err {
            if let Some(rest) = msg.strip_prefix("unsupported schema version ") {
                if let Some(ver_str) = rest.split(';').next() {
                    return ver_str.trim().parse::<i64>().ok();
                }
            }
        }
        None
    }

    /// Helper for tests to set on-disk schema version without going through from_conn.
    #[doc(hidden)]
    pub fn set_user_version_for_test(path: &str, version: i64) -> rusqlite::Result<()> {
        let conn = Connection::open(path)?;
        conn.pragma_update(None, "user_version", version)
    }

    /// Open (creating if needed) a store at `path`.
    pub fn open(path: &str) -> rusqlite::Result<Self> {
        Self::open_keyed(path, &[])
    }

    /// Open an ENCRYPTED store at `path`, keyed by a raw 32-byte `key` (F-25). The key is used
    /// directly (no passphrase KDF); the host derives + stores it in the platform Keychain/Keystore.
    /// Under the `sqlcipher` cargo feature this encrypts every page at rest (SQLCipher). Without that
    /// feature the `PRAGMA key` is silently ignored by plain SQLite, so build with `--features
    /// sqlcipher` for real at-rest encryption. An empty key opens unencrypted (same as `open`).
    pub fn open_keyed(path: &str, key: &[u8]) -> rusqlite::Result<Self> {
        let is_in_memory = path == ":memory:" || path.is_empty();
        let (process_lease, file_lock) = if is_in_memory {
            (None, None)
        } else {
            (
                Some(ProcessPathLease::acquire(path)?),
                Some(FileLock::acquire(path)?),
            )
        };
        let conn = Connection::open(path)?;
        if !key.is_empty() {
            // SQLCipher raw-key form: `PRAGMA key = "x'<hex>'"` uses the bytes directly. Must run
            // BEFORE any table access (from_conn), which SQLCipher requires to derive the page cipher.
            // stores-12: both the hex spelling and the assembled PRAGMA text are zeroized after use.
            let hex = HexKey::new(key);
            let mut pragma = format!("PRAGMA key = \"x'{}'\";", hex.as_str());
            let res = conn.execute_batch(&pragma);
            pragma.zeroize();
            res?;
        }
        Self::from_conn_with_locks(conn, process_lease, file_lock)
    }

    /// True iff the file at `path` opens as an UNENCRYPTED SQLite database (its header reads as a
    /// plain db). Used to tell "existing plaintext db, we now have a key" (migrate) apart from
    /// "wrong key / genuine corruption" (fail closed) so a keyed open never silently wipes state.
    /// Without the `sqlcipher` feature `PRAGMA key` is a no-op, so a keyed open of a plain file
    /// already succeeds and this path is not exercised.
    pub fn opens_as_plaintext(path: &str) -> bool {
        use std::io::Read;
        let mut header = [0u8; 16];
        let Ok(mut f) = std::fs::File::open(path) else {
            return false;
        };
        if f.read_exact(&mut header).is_err() {
            return false;
        }
        &header == b"SQLite format 3\0"
    }

    /// Migrate an existing PLAINTEXT db at `path` to a SQLCipher-encrypted db keyed with `key`,
    /// in place, via `sqlcipher_export` (the standard SQLCipher plaintext->encrypted recipe): open
    /// the plain db, ATTACH a fresh keyed sidecar, export into it, then atomically replace the
    /// original. Preserves all rows (sessions, prekeys, queued sends) instead of wiping them.
    #[cfg(feature = "sqlcipher")]
    pub fn migrate_plaintext_to_keyed(path: &str, key: &[u8]) -> rusqlite::Result<Self> {
        if key.is_empty() {
            return Self::open_keyed(path, key); // nothing to encrypt to
        }
        let process_lease = ProcessPathLease::acquire(path)?;
        let file_lock = FileLock::acquire(path)?;
        let sidecar = format!("{path}.migrating");
        let _ = std::fs::remove_file(&sidecar);
        // stores-r2-02: the sidecar itself may also carry stale WAL/SHM from a crashed prior attempt.
        let _ = std::fs::remove_file(format!("{sidecar}-wal"));
        let _ = std::fs::remove_file(format!("{sidecar}-shm"));
        // stores-12: hex spelling zeroized on drop; the assembled ATTACH batch is zeroized after use.
        let hex = HexKey::new(key);
        {
            let conn = Connection::open(path)?; // plaintext source
                                                // stores-r2-02: the plaintext db was created via from_conn, which sets journal_mode=WAL,
                                                // so `{path}-wal`/`{path}-shm` sidecars exist beside it. If we rename only the main file
                                                // over the destination, those plaintext WAL/SHM files are left orphaned next to the new
                                                // SQLCipher db; when open_keyed re-enables WAL, SQLite can try to recover against a -wal
                                                // that belongs to a DIFFERENT (unencrypted) database -> open failure or corruption on the
                                                // exact already-installed devices this migration exists to protect. Checkpoint and switch
                                                // the source to journal_mode=DELETE so it folds the WAL back into the main file and drops
                                                // the sidecars BEFORE we export + rename. (No-op if the source was never WAL.)
            conn.execute_batch(
                "PRAGMA wal_checkpoint(TRUNCATE);
                 PRAGMA journal_mode=DELETE;",
            )?;
            let mut batch = format!(
                "ATTACH DATABASE '{sidecar}' AS enc KEY \"x'{}'\";\
                 SELECT sqlcipher_export('enc');\
                 DETACH DATABASE enc;",
                hex.as_str()
            );
            let res = conn.execute_batch(&batch);
            batch.zeroize();
            res?;
        } // conn dropped -> sidecar flushed + closed
          // Atomically replace the plaintext original with the encrypted sidecar.
        std::fs::rename(&sidecar, path).map_err(|e| {
            rusqlite::Error::SqliteFailure(
                rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_IOERR),
                Some(format!("sqlcipher migrate rename failed: {e}")),
            )
        })?;
        // stores-r2-02: belt-and-suspenders. Remove any plaintext WAL/SHM that lingered (e.g. the
        // journal_mode switch was a no-op on an older SQLite, or a sidecar the checkpoint didn't
        // fold). These belong to the now-gone plaintext db; the new SQLCipher db will create its own.
        let _ = std::fs::remove_file(format!("{path}-wal"));
        let _ = std::fs::remove_file(format!("{path}-shm"));
        let conn = Connection::open(path)?;
        let hex = HexKey::new(key);
        let mut pragma = format!("PRAGMA key = \"x'{}'\";", hex.as_str());
        let res = conn.execute_batch(&pragma);
        pragma.zeroize();
        res?;
        Self::from_conn_with_locks(conn, Some(process_lease), Some(file_lock))
    }

    /// Open an ephemeral in-memory store (for tests).
    pub fn open_in_memory() -> rusqlite::Result<Self> {
        Self::from_conn(Connection::open_in_memory()?)
    }

    /// Injected fault helper for tests: installs an abort trigger on `kv` table for keys matching `pattern`.
    pub fn inject_kv_failure(&self, pattern: &str) -> Result<(), String> {
        let sql = format!(
            "CREATE TRIGGER IF NOT EXISTS fail_kv_injected BEFORE INSERT ON kv
             WHEN NEW.key LIKE '{pattern}'
             BEGIN SELECT RAISE(ABORT, 'injected sqlite failure'); END;"
        );
        self.conn
            .execute_batch(&sql)
            .map_err(|e| format!("inject_kv_failure: {e}"))
    }

    fn from_conn(conn: Connection) -> rusqlite::Result<Self> {
        Self::from_conn_with_locks(conn, None, None)
    }

    fn from_conn_with_locks(
        conn: Connection,
        process_lease: Option<ProcessPathLease>,
        file_lock: Option<FileLock>,
    ) -> rusqlite::Result<Self> {
        // D7: schema/format version, tracked in SQLite's built-in `user_version`. Bump on any
        // incompatible on-disk change (table shape OR row encoding). A fresh db (user_version 0)
        // just adopts the current version.
        //
        // stores-06: migrate keyed on the OLD `user_version` instead of amnesia-ing the whole store.
        // The only incompatible bump to date (v1 -> v2, the §39 wire change F-06) re-encodes the
        // `bundles`/`seen` rows but does NOT touch the `kv` schema. `kv` holds the device's durable,
        // wire-format-INDEPENDENT state: forward-secret ratchet sessions, prekey secrets, the queued
        // send buffer, and hosted hps keys. Dropping those forced a full re-secure with every peer
        // (historically the fragile path) and lost queued sends on every upgrade. So we drop only the
        // wire-format-dependent tables and PRESERVE `kv`.
        let uv: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        if uv != 0 && uv != Self::SCHEMA_VERSION {
            if uv == 1 {
                // v1 -> v2: only the bundle/seen row encoding changed; keep `kv` intact.
                // Transactional: either the migration succeeds and user_version is stamped,
                // or the database remains at v1 without partial schema modification.
                eprintln!(
                    "hop-store-sqlite: migrating schema v{uv} -> v{} \
                     (re-encoding bundles/seen; preserving kv sessions/queued sends)",
                    Self::SCHEMA_VERSION
                );
                conn.execute_batch(
                    "BEGIN IMMEDIATE;
                     DROP TABLE IF EXISTS bundles;
                     DROP TABLE IF EXISTS seen;
                     CREATE TABLE IF NOT EXISTS bundles (id BLOB PRIMARY KEY, data BLOB NOT NULL);
                     CREATE TABLE IF NOT EXISTS seen (id BLOB PRIMARY KEY, expires_at INTEGER NOT NULL);
                     CREATE INDEX IF NOT EXISTS idx_seen_expires_at ON seen (expires_at);
                     PRAGMA user_version = 2;
                     COMMIT;",
                )?;
            } else {
                // STORE-007: An unknown or future schema version must NEVER drop or reset irreplaceable
                // KV security state (ratchets, prekeys, queued sends). Refuse to open, preserving
                // the database and all sidecars byte-exactly.
                return Err(rusqlite::Error::SqliteFailure(
                    rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_SCHEMA),
                    Some(format!(
                        "unsupported schema version {uv}; supported is {}",
                        Self::SCHEMA_VERSION
                    )),
                ));
            }
        }
        // STORE-001 / STORE-002:
        // WAL mode with synchronous=FULL ensures that critical transactions are power-loss durable
        // (WAL frames fsynced on commit). busy_timeout=0 and locking_mode=EXCLUSIVE enforce an immediate
        // failure on any competing writer without polling or lock accommodation.
        conn.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA synchronous=FULL;
             PRAGMA busy_timeout=0;
             PRAGMA locking_mode=EXCLUSIVE;",
        )?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS bundles (id BLOB PRIMARY KEY, data BLOB NOT NULL);
             CREATE TABLE IF NOT EXISTS seen (id BLOB PRIMARY KEY, expires_at INTEGER NOT NULL);
             CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value BLOB NOT NULL);
             -- stores-10: index expires_at so the cap-eviction ORDER BY and both prune predicates
             -- (WHERE expires_at <= ?) are index range scans, not full-table scans under the Mutex.
             CREATE INDEX IF NOT EXISTS idx_seen_expires_at ON seen (expires_at);",
        )?;
        // D7: stamp the current schema/format version so a future incompatible bump is detected.
        conn.pragma_update(None, "user_version", Self::SCHEMA_VERSION)?;
        // stores-10: seed the in-memory row count once (the only COUNT(*) we run) so puts never scan.
        let seen_rows: i64 = conn.query_row("SELECT COUNT(*) FROM seen", [], |r| r.get(0))?;
        Ok(Self {
            conn,
            seen_rows: std::cell::Cell::new(seen_rows),
            _file_lock: file_lock,
            _process_lease: process_lease,
        })
    }

    /// Keep the `seen` dedup table under [`MAX_SEEN_ROWS`] by evicting the nearest-to-expiry rows
    /// (F-07). Cheap: only runs the delete when the count is actually over the cap. Any held bundle
    /// for an evicted id is deleted in the same step (stores-04): prune deletes bundles only via the
    /// `seen` join, so an evicted seen row would otherwise orphan its bundle past its lifetime.
    fn enforce_seen_cap(&self) -> rusqlite::Result<()> {
        // stores-10: gate on the tracked count so the common case (under the cap) does no query at
        // all - the previous per-put `SELECT COUNT(*)` was a full-table scan under the node Mutex.
        let n = self.seen_rows.get();
        if n > MAX_SEEN_ROWS {
            // Materialize the victim ids once so we delete the same set from both tables. The
            // ORDER BY now rides idx_seen_expires_at instead of scanning + sorting the whole table.
            let victims: Vec<Vec<u8>> = {
                let mut stmt = self
                    .conn
                    .prepare("SELECT id FROM seen ORDER BY expires_at ASC LIMIT ?1")?;
                let rows =
                    stmt.query_map(params![n - MAX_SEEN_ROWS], |r| r.get::<_, Vec<u8>>(0))?;
                rows.filter_map(|r| r.ok()).collect()
            };
            // stores-r2-04: evict from `bundles` and `seen` inside ONE transaction, matching put()'s
            // atomicity. Previously each victim did two separate un-enclosed DELETEs and bumped
            // `seen_rows` only after the seen delete; a mid-loop failure (bundles deleted, seen delete
            // errors, or vice versa) drifted the tracked count from the table and could orphan a
            // held bundle without its seen row (or a seen row without its bundle) until reopen
            // re-seeded the count. Now either every victim is removed from both tables or none is, and
            // `seen_rows` is decremented only from the COMMITTED seen-delete count. `unchecked_`
            // because enforce runs behind `&self` (interior-mutable count); the node Mutex serializes
            // all store access, so there is no concurrent writer on this single connection.
            let tx = self.conn.unchecked_transaction()?;
            let mut removed_total: i64 = 0;
            for id in &victims {
                tx.execute("DELETE FROM bundles WHERE id = ?1", params![id])?;
                removed_total += tx.execute("DELETE FROM seen WHERE id = ?1", params![id])? as i64;
            }
            tx.commit()?;
            self.seen_rows.set(self.seen_rows.get() - removed_total);
        }
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
        // Clamp the retained dedup window so an attacker-set (and, for private bundles,
        // unauthenticated) lifetime_ms can't pin a `seen` row open for weeks (F-07).
        let lifetime = (bundle.inner.lifetime_ms as u64).min(MAX_SEEN_LIFETIME_MS);
        let expires_at = now_ms.saturating_add(lifetime);
        // Transactional (stores-03): the seen row and the bundle write must commit together. Without
        // this, a failed bundle write (disk full, encode error) would leave the id poisoned in `seen`
        // for up to a week, permanently rejecting every re-offer of a bundle we never actually stored.
        let result = (|| -> rusqlite::Result<usize> {
            let tx = self.conn.transaction()?;
            let inserted = tx.execute(
                "INSERT OR IGNORE INTO seen (id, expires_at) VALUES (?1, ?2)",
                params![&id[..], expires_at as i64],
            )?;
            let data = bundle.to_bytes().map_err(to_sqlite_err)?;
            tx.execute(
                "INSERT OR REPLACE INTO bundles (id, data) VALUES (?1, ?2)",
                params![&id[..], data],
            )?;
            tx.commit()?;
            Ok(inserted)
        })();
        // stores-10: keep the tracked count in step with the actual seen insert (0 if the id was
        // already present) so cap enforcement never runs a COUNT(*). Only bump on a committed tx.
        if let Ok(inserted) = result {
            self.seen_rows.set(self.seen_rows.get() + inserted as i64);
        }
        // Cap enforcement is a separate best-effort maintenance step outside the put transaction.
        let _ = self.enforce_seen_cap();
        result.is_ok()
    }

    fn rehydrate(&mut self, bundle: Bundle, now_ms: u64) -> bool {
        // relay-A audit: re-hold an evicted-but-durable bundle even though its `seen` row survives (a
        // mailbox re-pull / handoff re-ingest). Same transactional write as put, but WITHOUT the seen
        // gate: INSERT OR IGNORE keeps the existing dedup expiry, INSERT OR REPLACE re-holds the bundle.
        let id = bundle.id();
        let lifetime = (bundle.inner.lifetime_ms as u64).min(MAX_SEEN_LIFETIME_MS);
        let expires_at = now_ms.saturating_add(lifetime);
        let result = (|| -> rusqlite::Result<usize> {
            let tx = self.conn.transaction()?;
            let inserted = tx.execute(
                "INSERT OR IGNORE INTO seen (id, expires_at) VALUES (?1, ?2)",
                params![&id[..], expires_at as i64],
            )?;
            let data = bundle.to_bytes().map_err(to_sqlite_err)?;
            tx.execute(
                "INSERT OR REPLACE INTO bundles (id, data) VALUES (?1, ?2)",
                params![&id[..], data],
            )?;
            tx.commit()?;
            Ok(inserted)
        })();
        if let Ok(inserted) = result {
            self.seen_rows.set(self.seen_rows.get() + inserted as i64);
        }
        let _ = self.enforce_seen_cap();
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
            .query_row("SELECT 1 FROM seen WHERE id = ?1", params![&id[..]], |_| {
                Ok(())
            })
            .is_ok()
    }

    fn contains(&self, id: &BundleId) -> bool {
        self.conn
            .query_row(
                "SELECT 1 FROM bundles WHERE id = ?1",
                params![&id[..]],
                |_| Ok(()),
            )
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
        // stores-10: both deletes now ride idx_seen_expires_at; keep the tracked count in step.
        if let Ok(removed) = self.conn.execute(
            "DELETE FROM seen WHERE expires_at <= ?1",
            params![now_ms as i64],
        ) {
            self.seen_rows.set(self.seen_rows.get() - removed as i64);
        }
    }

    fn put_kv(&mut self, key: &str, value: Vec<u8>) {
        let _ = self.put_kv_critical(key, value);
    }

    fn apply_kv_batch(&mut self, mutations: &[KvMutation]) -> std::result::Result<(), String> {
        let bundle_puts = mutations
            .iter()
            .filter(|mutation| matches!(mutation, KvMutation::PutBundle { .. }))
            .count() as i64;
        if self.seen_rows.get().saturating_add(bundle_puts) > MAX_SEEN_ROWS {
            return Err("critical batch would exceed SQLite bundle custody capacity".into());
        }
        // STORE-001: Ensure critical commits are power-loss durable via synchronous=FULL.
        // In WAL mode, synchronous=FULL forces SQLite to fsync the WAL file on transaction commit,
        // preventing cryptographic state rollback / message key reuse across OS crash or power loss.
        self.conn
            .execute_batch("PRAGMA synchronous = FULL;")
            .map_err(|e| e.to_string())?;
        let tx = self.conn.transaction().map_err(|e| e.to_string())?;
        let mut inserted_seen = 0i64;
        for mutation in mutations {
            match mutation {
                KvMutation::Put { key, value } => tx
                    .execute(
                        "INSERT OR REPLACE INTO kv (key, value) VALUES (?1, ?2)",
                        params![key, value],
                    )
                    .map_err(|e| e.to_string())?,
                KvMutation::Remove { key } => tx
                    .execute("DELETE FROM kv WHERE key = ?1", params![key])
                    .map_err(|e| e.to_string())?,
                KvMutation::PutBundle { bundle, now_ms } => {
                    let id = bundle.id();
                    let lifetime = (bundle.inner.lifetime_ms as u64).min(MAX_SEEN_LIFETIME_MS);
                    let expires_at = now_ms.saturating_add(lifetime);
                    let inserted = tx
                        .execute(
                            "INSERT OR IGNORE INTO seen (id, expires_at) VALUES (?1, ?2)",
                            params![&id[..], expires_at as i64],
                        )
                        .map_err(|e| e.to_string())?;
                    if inserted == 0 {
                        return Err("critical batch bundle put was deduplicated".into());
                    }
                    let data = bundle.to_bytes().map_err(|e| e.to_string())?;
                    tx.execute(
                        "INSERT INTO bundles (id, data) VALUES (?1, ?2)",
                        params![&id[..], data],
                    )
                    .map_err(|e| e.to_string())?;
                    inserted_seen += 1;
                    inserted
                }
                KvMutation::RemoveBundle { id } => tx
                    .execute("DELETE FROM bundles WHERE id = ?1", params![&id[..]])
                    .map_err(|e| e.to_string())?,
            };
        }
        tx.commit().map_err(|e| e.to_string())?;
        self.seen_rows
            .set(self.seen_rows.get().saturating_add(inserted_seen));
        Ok(())
    }

    fn put_kv_critical(&mut self, key: &str, value: Vec<u8>) -> std::result::Result<(), String> {
        self.apply_kv_batch(&[KvMutation::Put {
            key: key.to_string(),
            value,
        }])
    }

    fn get_kv(&self, key: &str) -> Option<Vec<u8>> {
        self.conn
            .query_row("SELECT value FROM kv WHERE key = ?1", params![key], |r| {
                r.get::<_, Vec<u8>>(0)
            })
            .ok()
    }

    fn remove_kv(&mut self, key: &str) {
        let _ = self.remove_kv_critical(key);
    }

    fn remove_kv_critical(&mut self, key: &str) -> std::result::Result<(), String> {
        self.apply_kv_batch(&[KvMutation::Remove {
            key: key.to_string(),
        }])
    }

    fn flush(&self, _timeout: std::time::Duration) -> bool {
        // STORE-001: Checkpoint WAL frames back to the database file and fsync.
        self.conn
            .execute_batch("PRAGMA wal_checkpoint(PASSIVE);")
            .is_ok()
    }

    fn list_kv_page(
        &self,
        prefix: &str,
        after: Option<&str>,
        limit: usize,
    ) -> Vec<(String, Vec<u8>)> {
        if limit == 0 {
            return Vec::new();
        }
        let after = after.unwrap_or("");
        let Ok(mut stmt) = self.conn.prepare(
            "SELECT key, value FROM kv
                 WHERE substr(key, 1, length(?1)) = ?1 AND key > ?2
                 ORDER BY key ASC LIMIT ?3",
        ) else {
            return Vec::new();
        };
        let rows = stmt.query_map(
            params![prefix, after, limit.min(i64::MAX as usize) as i64],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, Vec<u8>>(1)?)),
        );
        match rows {
            Ok(it) => it.filter_map(|r| r.ok()).collect(),
            Err(_) => Vec::new(),
        }
    }

    fn seen_expiry(&self, id: &BundleId) -> Option<u64> {
        // stores-r3-01: the durable, receiver-anchored dedup deadline for `id` (the clamped
        // now+lifetime stamped at put time). Callers use this as the authoritative expiry for a
        // handoff/spool re-mirror instead of the sender's advisory created_at.
        self.conn
            .query_row(
                "SELECT expires_at FROM seen WHERE id = ?1",
                params![&id[..]],
                |row| row.get::<_, i64>(0),
            )
            .ok()
            .map(|e| e as u64)
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
            &Payload::PeerMessage {
                content_type: "t".into(),
                body: b"persist me".to_vec(),
            },
            BundleOpts {
                copies,
                ..Default::default()
            },
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
    fn reserved_copy_budget_survives_a_store_round_trip() {
        // `Envelope.copies` is RESERVED wire capacity for a future routing policy (DESIGN.md §6):
        // the shipped router is epidemic + vaccine and never reads it. The mutation API that used
        // to drive it (Store::split_copies / set_copies) was removed as dead surface imposed on
        // every Store implementor. The FIELD stays, so this pins the one property that still has
        // to hold: a store must round-trip it byte-exactly rather than normalizing it away.
        let mut s = SqliteStore::open_in_memory().unwrap();
        let b = sample(8);
        let id = b.id();
        s.put(b, 0);
        assert_eq!(
            s.get(&id).unwrap().env.copies,
            8,
            "a store must not silently drop or rewrite reserved envelope state"
        );
    }

    #[test]
    fn critical_kv_operations_return_the_sqlite_write_error() {
        let mut s = SqliteStore::open_in_memory().unwrap();
        s.conn.execute_batch("DROP TABLE kv").unwrap();

        let put = s
            .put_kv_critical("session/alice", vec![1])
            .expect_err("missing kv table must fail");
        assert!(put.contains("no such table"), "real SQLite error: {put}");

        let remove = s
            .remove_kv_critical("session/alice")
            .expect_err("missing kv table must fail");
        assert!(
            remove.contains("no such table"),
            "real SQLite error: {remove}"
        );
    }

    #[test]
    fn critical_kv_batch_rolls_back_every_key_on_failure() {
        let mut store = SqliteStore::open_in_memory().unwrap();
        store.put_kv_critical("session/alice", vec![1]).unwrap();
        store
            .conn
            .execute_batch(
                "CREATE TRIGGER fail_inbox BEFORE INSERT ON kv
                 WHEN NEW.key = 'inbox/fail'
                 BEGIN SELECT RAISE(ABORT, 'injected inbox failure'); END;",
            )
            .unwrap();

        let result = store.apply_kv_batch(&[
            KvMutation::Put {
                key: "session/alice".into(),
                value: vec![2],
            },
            KvMutation::Put {
                key: "inbox/fail".into(),
                value: vec![3],
            },
            KvMutation::Put {
                key: "inbox-seen/fail".into(),
                value: vec![4],
            },
        ]);

        assert!(result.is_err());
        assert_eq!(store.get_kv("session/alice"), Some(vec![1]));
        assert_eq!(store.get_kv("inbox/fail"), None);
        assert_eq!(store.get_kv("inbox-seen/fail"), None);
    }

    #[test]
    fn mixed_bundle_and_session_batch_rolls_back_when_the_second_mutation_fails() {
        let mut store = SqliteStore::open_in_memory().unwrap();
        store
            .conn
            .execute_batch(
                "CREATE TRIGGER fail_session BEFORE INSERT ON kv
                 WHEN NEW.key = 'session/fail'
                 BEGIN SELECT RAISE(ABORT, 'injected session failure'); END;",
            )
            .unwrap();
        let bundle = sample(8);
        let id = bundle.id();

        let result = store.apply_kv_batch(&[
            KvMutation::PutBundle {
                bundle: Box::new(bundle),
                now_ms: 1_000,
            },
            KvMutation::Put {
                key: "session/fail".into(),
                value: vec![1, 2, 3],
            },
        ]);

        assert!(result.is_err(), "the injected second mutation must fail");
        assert!(!store.contains(&id), "bundle insert rolled back");
        assert!(!store.seen(&id), "seen insert rolled back with custody");
        assert_eq!(store.get_kv("session/fail"), None);
        assert_eq!(store.seen_rows.get(), 0, "tracked seen count did not drift");
    }

    #[test]
    fn survives_reopen() {
        let path = format!(
            "{}/hop-sqlite-reopen-test.db",
            std::env::temp_dir().display()
        );
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(format!("{path}.lock"));
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
        let _ = std::fs::remove_file(format!("{path}.lock"));
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
            &Payload::PeerMessage {
                content_type: "t".into(),
                body: vec![1],
            },
            BundleOpts {
                lifetime_ms: 1_000,
                ..Default::default()
            },
        )
        .unwrap();
        let id = b.id();

        s.put(b.clone(), 0); // dedup window closes at 1000
        s.prune(500);
        assert!(s.seen(&id) && s.contains(&id));
        s.prune(2_000);
        assert!(
            !s.seen(&id) && !s.contains(&id),
            "window closed, entry pruned"
        );
        assert!(s.put(b, 2_000), "re-accepted after window");
    }

    #[test]
    fn seen_lifetime_is_clamped_against_a_hostile_lifetime_ms() {
        // F-07: a bundle claiming a ~49-day lifetime must not pin its `seen` row open that long;
        // the retained window is clamped to MAX_SEEN_LIFETIME_MS (one week).
        let mut s = SqliteStore::open_in_memory().unwrap();
        let from = Identity::generate();
        let to = Identity::generate();
        let b = Bundle::create(
            &from,
            Destination::Device(to.address()),
            &to.address(),
            &Payload::PeerMessage {
                content_type: "t".into(),
                body: vec![1],
            },
            BundleOpts {
                lifetime_ms: u32::MAX,
                ..Default::default()
            }, // hostile: ~49 days
        )
        .unwrap();
        let id = b.id();
        s.put(b, 0);
        // Just past the clamp, the dedup row is gone (would still be present if lifetime_ms won).
        s.prune(MAX_SEEN_LIFETIME_MS + 1);
        assert!(
            !s.seen(&id),
            "seen row must be clamped to the max window, not the claimed lifetime"
        );
    }

    #[test]
    fn seen_cap_evicts_bundle_with_its_seen_row() {
        // stores-04: when the seen cap evicts a row, its held bundle must go too, or prune (which
        // joins on seen) can never reclaim it and it outlives its lifetime on disk.
        let mut s = SqliteStore::open_in_memory().unwrap();
        // Insert one real held bundle with a near expiry so it is the eviction target.
        let b = sample(8);
        let id = b.id();
        s.put(b, 0);
        // Directly stuff the seen table past the cap with far-future expiries so our real bundle's
        // seen row (expiry = default lifetime) is among the nearest-to-expiry and gets evicted.
        {
            let tx = s.conn.transaction().unwrap();
            for i in 0..(MAX_SEEN_ROWS + 10) {
                let mut fake = [0u8; 32];
                fake[..8].copy_from_slice(&(i as u64 + 1).to_le_bytes());
                fake[31] = 0xAA; // avoid colliding with the real id namespace
                tx.execute(
                    "INSERT OR IGNORE INTO seen (id, expires_at) VALUES (?1, ?2)",
                    params![&fake[..], i64::MAX],
                )
                .unwrap();
            }
            tx.commit().unwrap();
        }
        // The direct INSERTs above bypass put()'s tracked count; re-seed it from the table so the
        // cap gate reflects the rows we just stuffed in (matches the from_conn seed at open time).
        s.seen_rows.set(
            s.conn
                .query_row("SELECT COUNT(*) FROM seen", [], |r| r.get::<_, i64>(0))
                .unwrap(),
        );
        s.enforce_seen_cap().unwrap();
        // The real bundle's seen row (nearest expiry) was evicted; its held bundle must be gone too.
        assert!(!s.seen(&id), "seen row evicted under the cap");
        assert!(
            !s.contains(&id),
            "held bundle must be evicted with its seen row, not orphaned"
        );
    }

    #[cfg(feature = "sqlcipher")]
    #[test]
    fn sqlcipher_encrypts_at_rest() {
        // F-25: with the sqlcipher feature, a keyed store is unreadable without the key, proving the
        // pages are actually encrypted on disk (a plain or wrong-key open fails to even read the schema).
        let path = format!("{}/hop-sqlcipher-test.db", std::env::temp_dir().display());
        let _ = std::fs::remove_file(&path);
        let key = [7u8; 32];
        let b = sample(8);
        let id = b.id();
        {
            let mut s = SqliteStore::open_keyed(&path, &key).unwrap();
            assert!(s.put(b, 0));
        }
        assert!(
            SqliteStore::open(&path).is_err(),
            "plain (unkeyed) open of an encrypted db must fail"
        );
        assert!(
            SqliteStore::open_keyed(&path, &[9u8; 32]).is_err(),
            "wrong key must fail"
        );
        let s = SqliteStore::open_keyed(&path, &key).unwrap();
        assert!(s.contains(&id), "the right key decrypts and reads the data");
        let _ = std::fs::remove_file(&path);
    }

    #[cfg(feature = "sqlcipher")]
    #[test]
    fn plaintext_db_migrates_to_keyed_without_losing_data() {
        // android-01: an existing PLAINTEXT hop.db plus a newly-supplied key must migrate in place
        // (plaintext -> SQLCipher) preserving every row, never wipe. Proves the recovery path the
        // config-divergence fix relies on for already-installed devices.
        let path = format!("{}/hop-migrate-test.db", std::env::temp_dir().display());
        let _ = std::fs::remove_file(&path);
        let key = [5u8; 32];
        let b = sample(11);
        let id = b.id();
        {
            let mut plain = SqliteStore::open(&path).unwrap(); // unencrypted, with data
            assert!(plain.put(b, 0));
        }
        assert!(
            SqliteStore::opens_as_plaintext(&path),
            "starts as a plain db"
        );
        let migrated = SqliteStore::migrate_plaintext_to_keyed(&path, &key).unwrap();
        assert!(migrated.contains(&id), "data survives the migration");
        assert!(
            SqliteStore::open(&path).is_err(),
            "after migration a plain open fails: it is now SQLCipher-encrypted"
        );
        assert!(
            !SqliteStore::opens_as_plaintext(&path),
            "no longer readable as plaintext"
        );
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn v1_to_v2_migration_drops_bundles_but_preserves_kv() {
        // stores-06: a v1 db migrated to v2 re-encodes bundles/seen (the §39 wire change) but must
        // PRESERVE `kv` (ratchet sessions, prekey secrets, queued sends), not amnesia the device.
        let path = format!(
            "{}/hop-sqlite-schema-test.db",
            std::env::temp_dir().display()
        );
        let _ = std::fs::remove_file(&path);
        let b = sample(8);
        let id = b.id();
        {
            let mut s = SqliteStore::open(&path).unwrap();
            s.put(b, 0);
            s.put_kv("session/peerX", b"ratchet-state".to_vec()); // durable device state
                                                                  // Simulate an older (v1) on-disk schema.
            s.conn.pragma_update(None, "user_version", 1i64).unwrap();
        }
        let s = SqliteStore::open(&path).unwrap();
        assert!(
            !s.contains(&id),
            "wire-format-dependent bundle rows are dropped on the v1->v2 migration"
        );
        assert!(!s.seen(&id), "seen table dropped too (re-encoded)");
        assert_eq!(
            s.get_kv("session/peerX"),
            Some(b"ratchet-state".to_vec()),
            "kv (sessions/queued sends) survives the migration"
        );
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn unknown_schema_version_refuses_open_and_preserves_state() {
        // STORE-007: an unknown on-disk schema version must refuse to open rather than
        // silently dropping tables or wiping irreplaceable KV security state.
        let path = format!(
            "{}/hop-sqlite-schema-unknown-test.db",
            std::env::temp_dir().display()
        );
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(format!("{path}.lock"));
        {
            let mut s = SqliteStore::open(&path).unwrap();
            s.put_kv("session/peerX", b"ratchet-state".to_vec());
            // A version we have no migration for.
            s.conn.pragma_update(None, "user_version", 99i64).unwrap();
        }
        let res = SqliteStore::open(&path);
        assert!(res.is_err(), "unknown schema version must fail open");
        let err = res.err().unwrap();
        assert_eq!(SqliteStore::is_unsupported_schema(&err), Some(99));

        // State must remain intact:
        let raw = rusqlite::Connection::open(&path).unwrap();
        let val: Vec<u8> = raw
            .query_row(
                "SELECT value FROM kv WHERE key = ?1",
                params!["session/peerX"],
                |r| r.get(0),
            )
            .expect("kv row preserved");
        assert_eq!(val, b"ratchet-state");
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(format!("{path}.lock"));
    }
    #[test]
    fn unknown_future_schema_version_refuses_open_and_preserves_state() {
        let path = format!(
            "{}/hop-sqlite-schema-future-preserve-test.db",
            std::env::temp_dir().display()
        );
        let _ = std::fs::remove_file(&path);
        let b = sample(4);
        {
            let mut s = SqliteStore::open(&path).unwrap();
            s.put(b.clone(), 1_000);
            s.put_kv_critical("session/peer-v3", b"ratchet-v3-secret".to_vec())
                .unwrap();
            // Simulate future app version migrating to schema v3
            s.conn.pragma_update(None, "user_version", 3i64).unwrap();
        }

        // Downgrade / reopen attempt: must refuse with an unsupported schema error
        let res = SqliteStore::open(&path);
        assert!(
            res.is_err(),
            "must refuse to open an unknown future schema version"
        );
        let err = res.err().unwrap();
        assert!(
            err.to_string().contains("unsupported schema version"),
            "error message must clearly identify unsupported schema: {err}"
        );

        // Original database and data must be byte-preserved: inspect directly via raw connection
        let raw = rusqlite::Connection::open(&path).unwrap();
        let val: Vec<u8> = raw
            .query_row(
                "SELECT value FROM kv WHERE key = ?1",
                params!["session/peer-v3"],
                |r| r.get(0),
            )
            .expect("kv row must be preserved across refused open");
        assert_eq!(val, b"ratchet-v3-secret", "ratchet state preserved");
        let raw_uv: i64 = raw
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(raw_uv, 3, "user_version must remain untouched at v3");

        let _ = std::fs::remove_file(&path);
    }
    #[test]
    fn second_live_opener_on_same_path_fails_exclusive_lease() {
        let path = format!(
            "{}/hop-sqlite-single-writer-lease-test.db",
            std::env::temp_dir().display()
        );
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(format!("{path}.lock"));

        // First opener acquires exclusive single-writer lease
        let s1 = SqliteStore::open(&path).expect("first opener succeeds");

        // Second opener on the same database path must fail immediately before any protocol use
        let s2 = SqliteStore::open(&path);
        assert!(
            s2.is_err(),
            "second opener on active database must fail with exclusive lease error"
        );

        // After first opener drops, the lease is released and a new opener succeeds
        drop(s1);
        let s3 = SqliteStore::open(&path);
        assert!(s3.is_ok(), "reopening after drop succeeds");

        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(format!("{path}.lock"));
    }
    #[test]
    fn critical_commit_barrier_enforces_wal_durability_and_flush_checkpoints() {
        let path = format!(
            "{}/hop-sqlite-durability-wal-test.db",
            std::env::temp_dir().display()
        );
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(format!("{path}-wal"));
        let _ = std::fs::remove_file(format!("{path}-shm"));
        let _ = std::fs::remove_file(format!("{path}.lock"));

        let mut s = SqliteStore::open(&path).expect("open succeeds");

        // 1. Flush must perform a real WAL checkpoint rather than defaulting to a no-op true.
        s.put_kv_critical("session/baseline", b"init".to_vec())
            .unwrap();
        assert!(
            s.flush(std::time::Duration::from_millis(500)),
            "flush must succeed"
        );

        // Check that synchronous mode on critical commits is FULL (2) to ensure WAL commits
        // are power-loss durable, not NORMAL (1).
        // The unfixed code uniformly sets PRAGMA synchronous=NORMAL and never sets FULL.
        let sync_mode: i64 = s
            .conn
            .query_row("PRAGMA synchronous", [], |r| r.get(0))
            .unwrap();
        // We require that SqliteStore critical commits use FULL (2)
        assert_eq!(
            sync_mode, 2,
            "SqliteStore must enforce synchronous=FULL (2) for critical durability, found NORMAL (1)"
        );

        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(format!("{path}-wal"));
        let _ = std::fs::remove_file(format!("{path}-shm"));
        let _ = std::fs::remove_file(format!("{path}.lock"));
    }

    #[test]
    fn wal_fault_injection_proves_unsynced_rollback_vs_synced_barrier() {
        // STORE-001: Demonstrate that committing with synchronous=NORMAL admits rollback
        // when unsynced WAL frames are withheld across power loss, whereas SqliteStore's
        // critical barrier (synchronous=FULL) flushes frames to disk and prevents rollback.
        let path = format!(
            "{}/hop-sqlite-fault-injection-test.db",
            std::env::temp_dir().display()
        );
        let src = format!("{path}.src");
        let cleanup = |p: &str| {
            for suf in ["", "-wal", "-shm", ".lock"] {
                let _ = std::fs::remove_file(format!("{p}{suf}"));
            }
        };
        cleanup(&path);
        cleanup(&src);

        // 1. Establish durable initial ratchet state (session at index 0) on src
        {
            let mut s = SqliteStore::open(&src).unwrap();
            s.put_kv_critical("session/peer", b"ratchet-index-0-key-k0".to_vec())
                .unwrap();
            assert!(s.flush(std::time::Duration::from_millis(500)));
        }

        let src_wal = format!("{src}-wal");
        let initial_wal_len = std::fs::metadata(&src_wal).map(|m| m.len()).unwrap_or(0);

        // 2. Simulate vulnerable NORMAL commit with power loss:
        // Raw connection opens in WAL + synchronous=NORMAL (unfixed behavior)
        {
            let raw = rusqlite::Connection::open(&src).unwrap();
            raw.execute_batch(
                "PRAGMA journal_mode=WAL;
                 PRAGMA synchronous=NORMAL;
                 PRAGMA wal_autocheckpoint=0;",
            )
            .unwrap();
            raw.execute(
                "INSERT OR REPLACE INTO kv (key, value) VALUES (?1, ?2)",
                params!["session/peer", &b"ratchet-index-1-key-k1"[..]],
            )
            .unwrap();
            // Truncate the WAL back to the initial synced length before close to simulate
            // power loss that prevented trailing unsynced frames from reaching disk
            let file = std::fs::OpenOptions::new()
                .write(true)
                .open(&src_wal)
                .unwrap();
            file.set_len(initial_wal_len).unwrap();
            drop(file);
        }

        // Snapshot onto test target path (releases all locks, like process death would)
        std::fs::copy(&src, &path).unwrap();
        std::fs::copy(&src_wal, format!("{path}-wal")).unwrap();

        // Reopening demonstrates that index 1 rolled back to index 0 (vulnerability reproduced!)
        {
            let s = SqliteStore::open(&path).unwrap();
            let rolled_back = s.get_kv("session/peer").unwrap();
            assert_eq!(
                rolled_back, b"ratchet-index-0-key-k0",
                "withheld unsynced WAL frames roll state backward to index 0"
            );
        }
        cleanup(&src);

        // 3. Now test the fix: critical commit barrier with SqliteStore
        // Advance to index 1 using put_kv_critical (synchronous=FULL)
        {
            let mut s = SqliteStore::open(&path).unwrap();
            s.put_kv_critical("session/peer", b"ratchet-index-1-key-k1".to_vec())
                .unwrap();
            assert!(s.flush(std::time::Duration::from_millis(500)));
        }

        // Reopening recovers index 1 cleanly without rolling back!
        {
            let s = SqliteStore::open(&path).unwrap();
            let recovered = s.get_kv("session/peer").unwrap();
            assert_eq!(
                recovered, b"ratchet-index-1-key-k1",
                "critical barrier ensures committed ratchet index 1 survives across reopen"
            );
        }

        cleanup(&path);
    }

    #[cfg(feature = "sqlcipher")]
    #[test]
    fn wal_fault_injection_sqlcipher_critical_barrier_survives_crash() {
        let path = format!(
            "{}/hop-sqlite-sqlcipher-durability-test.db",
            std::env::temp_dir().display()
        );
        let cleanup = |p: &str| {
            for suf in ["", "-wal", "-shm", ".lock"] {
                let _ = std::fs::remove_file(format!("{p}{suf}"));
            }
        };
        cleanup(&path);
        let key = [42u8; 32];

        // 1. Initial write
        {
            let mut s = SqliteStore::open_keyed(&path, &key).unwrap();
            s.put_kv_critical("session/bob", b"sqlcipher-ratchet-k0".to_vec())
                .unwrap();
            assert!(s.flush(std::time::Duration::from_millis(500)));
        }

        // 2. Critical commit under SQLCipher
        {
            let mut s = SqliteStore::open_keyed(&path, &key).unwrap();
            s.put_kv_critical("session/bob", b"sqlcipher-ratchet-k1".to_vec())
                .unwrap();
            assert!(s.flush(std::time::Duration::from_millis(500)));
        }

        // Reopen encrypted db with key: state is fully recovered at k1
        {
            let s = SqliteStore::open_keyed(&path, &key).unwrap();
            let recovered = s.get_kv("session/bob").unwrap();
            assert_eq!(
                recovered, b"sqlcipher-ratchet-k1",
                "SQLCipher critical barrier survives across reopen"
            );
        }

        cleanup(&path);
    }

    #[cfg(unix)]
    #[test]
    fn single_writer_fence_multi_process_and_crash_recovery() {
        let path = format!(
            "{}/hop-sqlite-multi-proc-lease-test.db",
            std::env::temp_dir().display()
        );
        let lock_path = format!("{path}.lock");
        let cleanup = |p: &str| {
            for suf in ["", "-wal", "-shm", ".lock"] {
                let _ = std::fs::remove_file(format!("{p}{suf}"));
            }
        };
        cleanup(&path);

        // 1. Parent process opens store and acquires lease
        let s1 = SqliteStore::open(&path).expect("parent acquires single-writer lease");

        // 2. Subprocess attempts to open while parent holds lease: must be rejected
        let probe_script = format!(
            "import os, fcntl, sys\n\
             try:\n    \
                 fd = os.open('{lock_path}', os.O_CREAT | os.O_RDWR, 0o600)\n    \
                 fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)\n    \
                 sys.exit(0)\n\
             except Exception:\n    \
                 sys.exit(42)\n"
        );
        let status = std::process::Command::new("python3")
            .arg("-c")
            .arg(&probe_script)
            .status()
            .expect("probe subprocess must run");
        assert_eq!(
            status.code(),
            Some(42),
            "concurrent process opener must be rejected while parent holds lease"
        );

        // 3. Parent drops store (call-versus-close)
        drop(s1);

        // Now probe subprocess succeeds in acquiring lock
        let status_after_drop = std::process::Command::new("python3")
            .arg("-c")
            .arg(&probe_script)
            .status()
            .expect("probe subprocess must run");
        assert_eq!(
            status_after_drop.code(),
            Some(0),
            "process opener succeeds after parent closes store"
        );

        // 4. Stale-lock recovery after process crash:
        // Spawn a background process that acquires the lock and holds it
        let hold_script = format!(
            "import os, fcntl, sys, time\n\
             fd = os.open('{lock_path}', os.O_CREAT | os.O_RDWR, 0o600)\n\
             fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)\n\
             sys.stdout.write('LOCKED\\n')\n\
             sys.stdout.flush()\n\
             time.sleep(60)\n"
        );
        let mut child = std::process::Command::new("python3")
            .arg("-c")
            .arg(&hold_script)
            .stdout(std::process::Stdio::piped())
            .spawn()
            .expect("spawn lock holder");

        use std::io::BufRead;
        let mut reader = std::io::BufReader::new(child.stdout.take().unwrap());
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        assert_eq!(line.trim(), "LOCKED");

        // Verify parent is rejected while child holds lock
        assert!(
            SqliteStore::open(&path).is_err(),
            "parent must be rejected while child holds lock"
        );

        // Kill child abruptly with SIGKILL (simulating process crash while holding lease)
        child.kill().expect("kill child process");
        let _ = child.wait();

        // Stale-lock recovery: parent opens immediately without manual recovery
        let s_recovered = SqliteStore::open(&path);
        assert!(
            s_recovered.is_ok(),
            "stale lock recovery must succeed immediately after child process crash"
        );

        cleanup(&path);
    }

    #[cfg(feature = "sqlcipher")]
    #[test]
    fn downgrade_future_version_leaves_database_and_wal_byte_preserved_sqlcipher() {
        let path = format!(
            "{}/hop-sqlite-sqlcipher-downgrade-test.db",
            std::env::temp_dir().display()
        );
        let cleanup = |p: &str| {
            for suf in ["", "-wal", "-shm", ".lock"] {
                let _ = std::fs::remove_file(format!("{p}{suf}"));
            }
        };
        cleanup(&path);
        let key = [77u8; 32];

        {
            let mut s = SqliteStore::open_keyed(&path, &key).unwrap();
            s.put_kv_critical("session/future", b"encrypted-ratchet-v3".to_vec())
                .unwrap();
            // Simulate migration to v3
            s.conn.pragma_update(None, "user_version", 3i64).unwrap();
        }

        // Reopening with v2 code must refuse open
        let res = SqliteStore::open_keyed(&path, &key);
        assert!(
            res.is_err(),
            "future schema version in SQLCipher must refuse open"
        );
        let err = res.err().unwrap();
        assert_eq!(SqliteStore::is_unsupported_schema(&err), Some(3));

        // State must remain intact and recoverable:
        // Set user_version back to 2 (simulating upgrade back to supported version)
        {
            let raw = rusqlite::Connection::open(&path).unwrap();
            let hex = HexKey::new(&key);
            let pragma = format!("PRAGMA key = \"x'{}'\";", hex.as_str());
            raw.execute_batch(&pragma).unwrap();
            raw.pragma_update(None, "user_version", 2i64).unwrap();
        }
        let s = SqliteStore::open_keyed(&path, &key).unwrap();
        assert_eq!(
            s.get_kv("session/future"),
            Some(b"encrypted-ratchet-v3".to_vec()),
            "encrypted state byte-preserved across refused downgrade"
        );

        cleanup(&path);
    }

    #[test]
    fn migration_v1_to_v2_rolls_back_atomically_on_interruption() {
        let path = format!(
            "{}/hop-sqlite-migration-rollback-test.db",
            std::env::temp_dir().display()
        );
        let cleanup = |p: &str| {
            for suf in ["", "-wal", "-shm", ".lock"] {
                let _ = std::fs::remove_file(format!("{p}{suf}"));
            }
        };
        cleanup(&path);

        // Build a v1 database where `seen` is a VIEW, causing DROP TABLE IF EXISTS seen to fail
        // and abort the atomic migration transaction
        {
            let mut s = SqliteStore::open(&path).unwrap();
            s.put_kv("session/vital", b"vital-session-state".to_vec());
            s.conn.pragma_update(None, "user_version", 1i64).unwrap();
            // Replace seen table with a view so DROP TABLE fails
            s.conn
                .execute_batch(
                    "DROP TABLE seen;
                     CREATE VIEW seen AS SELECT 1;",
                )
                .unwrap();
        }

        // Reopen attempts v1 -> v2 migration, which fails when dropping seen view
        let res = SqliteStore::open(&path);
        assert!(res.is_err(), "migration failure must return error");

        // Verify that transaction rolled back and database remains at v1 with all state preserved
        let raw = rusqlite::Connection::open(&path).unwrap();
        let uv: i64 = raw
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(uv, 1, "interrupted migration must roll back to v1");
        let val: Vec<u8> = raw
            .query_row(
                "SELECT value FROM kv WHERE key = ?1",
                params!["session/vital"],
                |r| r.get(0),
            )
            .expect("kv row preserved after rollback");
        assert_eq!(val, b"vital-session-state");

        cleanup(&path);
    }

    #[test]
    fn tracked_seen_count_stays_in_step_with_the_table() {
        // stores-10: the in-memory seen_rows count must match COUNT(*) across put (new + dup),
        // prune, and reopen - it is what gates cap enforcement without a per-put full scan.
        let path = format!(
            "{}/hop-sqlite-count-test.db",
            std::env::temp_dir().display()
        );
        let _ = std::fs::remove_file(&path);
        let true_count = |s: &SqliteStore| -> i64 {
            s.conn
                .query_row("SELECT COUNT(*) FROM seen", [], |r| r.get::<_, i64>(0))
                .unwrap()
        };
        {
            let mut s = SqliteStore::open(&path).unwrap();
            assert_eq!(s.seen_rows.get(), 0);

            let a = sample(4);
            let a_bundle = a.clone();
            s.put(a, 0);
            assert_eq!(s.seen_rows.get(), 1);
            // A duplicate does not bump the count (INSERT OR IGNORE inserted 0 rows).
            s.put(a_bundle, 0);
            assert_eq!(s.seen_rows.get(), 1);
            assert_eq!(s.seen_rows.get(), true_count(&s));

            // A short-lived bundle we can prune out.
            let from = Identity::generate();
            let to = Identity::generate();
            let short = Bundle::create(
                &from,
                Destination::Device(to.address()),
                &to.address(),
                &Payload::PeerMessage {
                    content_type: "t".into(),
                    body: vec![9],
                },
                BundleOpts {
                    lifetime_ms: 1_000,
                    ..Default::default()
                },
            )
            .unwrap();
            s.put(short, 0);
            assert_eq!(s.seen_rows.get(), 2);
            s.prune(2_000); // drops the short-lived seen row only
            assert_eq!(s.seen_rows.get(), 1);
            assert_eq!(s.seen_rows.get(), true_count(&s));
        }
        // Reopen re-seeds the count from the table (the one COUNT(*) we ever run).
        let s = SqliteStore::open(&path).unwrap();
        assert_eq!(s.seen_rows.get(), 1);
        assert_eq!(s.seen_rows.get(), true_count(&s));
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn seen_expires_at_index_exists() {
        // stores-10: the expires_at index must be created so prune predicates and the cap-eviction
        // ORDER BY are index scans, not full-table scans under the node Mutex.
        let s = SqliteStore::open_in_memory().unwrap();
        let has_index: bool = s
            .conn
            .query_row(
                "SELECT 1 FROM sqlite_master WHERE type='index' AND name='idx_seen_expires_at'",
                [],
                |_| Ok(()),
            )
            .is_ok();
        assert!(has_index, "idx_seen_expires_at must exist");
    }

    #[test]
    fn hex_key_wipes_the_backing_buffer() {
        // stores-12: the hex spelling of the at-rest key must be zeroized, not left lingering in a
        // heap allocation. We drive the exact wipe that Drop performs (String::zeroize) in place,
        // while the allocation is still owned by us, and read the SAME backing buffer through a raw
        // pointer captured before the wipe. This proves the volatile zeroing actually cleared the
        // bytes, without the UB of reading a freed allocation.
        let key = [0xABu8; 32];
        let mut hex = HexKey::new(&key);
        assert_eq!(hex.as_str(), "ab".repeat(32));
        let ptr = hex.0.as_ptr();
        let len = hex.0.len();
        hex.0.zeroize(); // same call the Drop impl makes; buffer stays allocated (owned by us)
                         // Safe: `hex` (and thus its backing allocation) is still alive for this read.
        let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
        assert!(
            bytes.iter().all(|&b| b == 0),
            "hex key material must be zeroized, found non-zero bytes"
        );
        // And the exact same wipe happens automatically on drop.
        drop(hex);
    }

    #[test]
    fn seen_cap_eviction_keeps_tracked_count_in_step_and_never_orphans() {
        // stores-r2-04: the cap eviction now runs its two-table DELETEs inside ONE transaction.
        // After it runs, the tracked seen_rows MUST equal COUNT(*) (no drift), and no held bundle may
        // be left without its seen row (nor a seen row without its bundle). Previously the two DELETEs
        // were un-enclosed and seen_rows was bumped only after the seen delete, so a mid-loop failure
        // could drift the count and orphan a bundle; this asserts the transactional invariant.
        let mut s = SqliteStore::open_in_memory().unwrap();
        // A handful of REAL held bundles with the default (near) expiry (the eviction targets).
        let mut real_ids = Vec::new();
        for _ in 0..5 {
            let b = sample(8);
            real_ids.push(b.id());
            s.put(b, 0);
        }
        // Stuff the seen table well past the cap with far-future expiries so the real bundles (nearer
        // expiry) are the eviction victims.
        {
            let tx = s.conn.transaction().unwrap();
            for i in 0..(MAX_SEEN_ROWS + 20) {
                let mut fake = [0u8; 32];
                fake[..8].copy_from_slice(&(i as u64 + 1).to_le_bytes());
                fake[31] = 0xBB;
                tx.execute(
                    "INSERT OR IGNORE INTO seen (id, expires_at) VALUES (?1, ?2)",
                    params![&fake[..], i64::MAX],
                )
                .unwrap();
            }
            tx.commit().unwrap();
        }
        // Re-seed the tracked count from the table (the direct INSERTs bypass put()'s bump).
        let true_count = |s: &SqliteStore| -> i64 {
            s.conn
                .query_row("SELECT COUNT(*) FROM seen", [], |r| r.get::<_, i64>(0))
                .unwrap()
        };
        s.seen_rows.set(true_count(&s));

        s.enforce_seen_cap().unwrap();

        // Invariant 1: the tracked count exactly matches the table after the transactional eviction.
        assert_eq!(
            s.seen_rows.get(),
            true_count(&s),
            "tracked seen_rows must equal COUNT(*) after a transactional eviction (no drift)"
        );
        assert_eq!(
            true_count(&s),
            MAX_SEEN_ROWS,
            "seen table trimmed back to exactly the cap"
        );
        // Invariant 2: no held bundle is orphaned (every remaining held id still has a seen row).
        let orphans: i64 = s
            .conn
            .query_row(
                "SELECT COUNT(*) FROM bundles b LEFT JOIN seen s ON b.id = s.id WHERE s.id IS NULL",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(orphans, 0, "no held bundle left without its seen row");
        // The real (near-expiry) bundles were the victims: gone from BOTH tables together.
        for id in &real_ids {
            assert!(!s.seen(id), "victim seen row evicted");
            assert!(
                !s.contains(id),
                "victim held bundle evicted with its seen row"
            );
        }
    }

    #[test]
    fn seen_cap_eviction_is_atomic_across_a_mid_loop_failure() {
        // stores-r2-04 (the actual before/after): inject a failure on the SECOND (seen) DELETE so a
        // victim's bundle DELETE lands but its seen DELETE errors mid-loop. The OLD code ran the two
        // DELETEs OUTSIDE a transaction and bumped seen_rows only after the seen delete, so this left
        // an orphaned bundle (deleted from `bundles`, still in `seen`) AND drifted the tracked count.
        // The FIX wraps the loop in one transaction, so the failure rolls the bundle DELETE back too:
        // no orphan, and seen_rows stays in step with the (unchanged) table.
        let mut s = SqliteStore::open_in_memory().unwrap();
        let mut real_ids = Vec::new();
        for _ in 0..3 {
            let b = sample(8);
            real_ids.push(b.id());
            s.put(b, 0);
        }
        {
            let tx = s.conn.transaction().unwrap();
            for i in 0..(MAX_SEEN_ROWS + 10) {
                let mut fake = [0u8; 32];
                fake[..8].copy_from_slice(&(i as u64 + 1).to_le_bytes());
                fake[31] = 0xCC;
                tx.execute(
                    "INSERT OR IGNORE INTO seen (id, expires_at) VALUES (?1, ?2)",
                    params![&fake[..], i64::MAX],
                )
                .unwrap();
            }
            tx.commit().unwrap();
        }
        let true_count = |s: &SqliteStore| -> i64 {
            s.conn
                .query_row("SELECT COUNT(*) FROM seen", [], |r| r.get::<_, i64>(0))
                .unwrap()
        };
        s.seen_rows.set(true_count(&s));
        let count_before = true_count(&s);
        let held_before: i64 = s
            .conn
            .query_row("SELECT COUNT(*) FROM bundles", [], |r| r.get(0))
            .unwrap();

        // Fault injection: a trigger that aborts every DELETE FROM seen. With a single enclosing
        // transaction the whole eviction (including the bundles DELETE) rolls back on this error.
        s.conn
            .execute_batch(
                "CREATE TRIGGER fail_seen_delete BEFORE DELETE ON seen \
                 BEGIN SELECT RAISE(ABORT, 'injected'); END;",
            )
            .unwrap();

        let res = s.enforce_seen_cap();
        assert!(res.is_err(), "the injected seen-delete failure surfaces");

        // Remove the trigger so our assertions can read freely.
        s.conn
            .execute_batch("DROP TRIGGER fail_seen_delete;")
            .unwrap();

        // Atomicity: the failed eviction rolled back entirely, so table counts are UNCHANGED and no
        // bundle was orphaned and the tracked count did not drift from the table.
        assert_eq!(
            true_count(&s),
            count_before,
            "seen count unchanged: the transaction rolled back the whole eviction"
        );
        let held_after: i64 = s
            .conn
            .query_row("SELECT COUNT(*) FROM bundles", [], |r| r.get(0))
            .unwrap();
        assert_eq!(
            held_after, held_before,
            "no bundle DELETE leaked: bundles table unchanged after the rolled-back eviction"
        );
        let orphans: i64 = s
            .conn
            .query_row(
                "SELECT COUNT(*) FROM bundles b LEFT JOIN seen s ON b.id = s.id WHERE s.id IS NULL",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            orphans, 0,
            "no orphaned held bundle after the failed eviction"
        );
        for id in &real_ids {
            assert!(s.contains(id), "victim bundle preserved by the rollback");
            assert!(s.seen(id), "victim seen row preserved by the rollback");
        }
    }

    #[cfg(feature = "sqlcipher")]
    #[test]
    fn migration_folds_and_clears_a_lingering_plaintext_wal() {
        // stores-r2-02: the plaintext db runs in journal_mode=WAL (from_conn), so a device that was
        // killed before a checkpoint leaves a REAL plaintext `-wal` with committed frames NOT yet
        // folded into the main file, plus a `-shm`. The old migration opened the plaintext source,
        // exported the MAIN FILE ONLY (missing the WAL-resident rows), and renamed just the main db
        // over the destination, leaving the plaintext `-wal`/`-shm` orphaned next to the new
        // SQLCipher db, where open_keyed re-enabling WAL can try to recover against a foreign WAL.
        //
        // The fix checkpoints + switches the source to journal_mode=DELETE before export, so the
        // WAL-resident rows are folded in (captured by the encrypted export) and the sidecars are
        // gone. This test creates that exact lingering-WAL state (a forgotten connection with
        // autocheckpoint off) and proves both: (a) the WAL-only row survives into the encrypted db,
        // and (b) no plaintext sidecar with real frames is left behind.
        use rusqlite::Connection;
        let tmp = std::env::temp_dir();
        // Source db (where we build the lingering-WAL state) and the test target we migrate. We build
        // the state on `src`, then COPY the three files to `path` so the target has a real plaintext
        // WAL on disk with NO process holding an OS lock (mirrors a device snapshot after a crash).
        let src = format!("{}/hop-migrate-lingering-src.db", tmp.display());
        let path = format!("{}/hop-migrate-lingering-wal-test.db", tmp.display());
        let cleanup = |base: &str| {
            for suf in ["", "-wal", "-shm"] {
                let _ = std::fs::remove_file(format!("{base}{suf}"));
            }
        };
        cleanup(&src);
        cleanup(&path);
        let wal = format!("{path}-wal");
        let shm = format!("{path}-shm");
        let key = [3u8; 32];
        let b = sample(9);
        let id = b.id();
        {
            let mut plain = SqliteStore::open(&src).unwrap();
            assert!(plain.put(b, 0)); // lands in the main file
        }
        // Raw connection: WAL, no autocheckpoint, write a kv row, then LEAK the connection so it never
        // checkpoints. The row now lives only in `{src}-wal`.
        {
            let raw = Connection::open(&src).unwrap();
            raw.execute_batch(
                "PRAGMA journal_mode=WAL;
                 PRAGMA wal_autocheckpoint=0;",
            )
            .unwrap();
            raw.execute(
                "INSERT OR REPLACE INTO kv (key, value) VALUES (?1, ?2)",
                params!["session/wal-resident", &b"secret-ratchet-in-the-wal"[..]],
            )
            .unwrap();
            std::mem::forget(raw); // no clean close -> WAL frames persist on disk for `src`
        }
        // Snapshot the three files onto the test target (releasing any lock, like process death would).
        std::fs::copy(&src, &path).unwrap();
        std::fs::copy(format!("{src}-wal"), &wal).unwrap();
        let _ = std::fs::copy(format!("{src}-shm"), &shm); // -shm may be absent; fine
        assert!(
            std::fs::metadata(&wal)
                .map(|m| m.len() > 0)
                .unwrap_or(false),
            "a real plaintext WAL with frames lingers on the target before migration"
        );

        let migrated = SqliteStore::migrate_plaintext_to_keyed(&path, &key).unwrap();
        // (a) both the main-file bundle AND the WAL-resident kv row are captured in the encrypted db.
        assert!(
            migrated.contains(&id),
            "main-file bundle survives the migration"
        );
        assert_eq!(
            migrated.get_kv("session/wal-resident"),
            Some(b"secret-ratchet-in-the-wal".to_vec()),
            "the WAL-resident row was folded in and captured by the encrypted export"
        );
        drop(migrated);

        // (b) no plaintext sidecar with the WAL-resident secret survives beside the encrypted db.
        for p in [&wal, &shm] {
            if let Ok(bytes) = std::fs::read(p) {
                assert!(
                    !bytes
                        .windows(b"secret-ratchet-in-the-wal".len())
                        .any(|w| w == b"secret-ratchet-in-the-wal"),
                    "plaintext WAL-resident secret must not linger in sidecar {p}"
                );
            }
        }
        // And the encrypted db reopens cleanly with the key (no foreign-WAL recovery failure).
        let reopened = SqliteStore::open_keyed(&path, &key).unwrap();
        assert!(reopened.contains(&id), "keyed reopen reads cleanly");
        assert!(
            !SqliteStore::opens_as_plaintext(&path),
            "db is genuinely SQLCipher-encrypted"
        );
        drop(reopened);
        cleanup(&src);
        cleanup(&path);
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
            &Payload::PeerMessage {
                content_type: "t".into(),
                body: b"hi".to_vec(),
            },
            BundleOpts::default(),
        )
        .unwrap();
        let bid = bundle.id();

        let mut node =
            Node::with_store(Identity::generate(), SqliteStore::open_in_memory().unwrap());
        node.submit(bundle);
        assert!(
            node.store.contains(&bid),
            "submitted bundle is in the sqlite store"
        );
    }
}
