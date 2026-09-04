// Per-node synchronous storage bridges for hop-wasm's `JsStore` (see core/hop-wasm/src/store.rs).
//
// The core calls these methods synchronously; each returns/accepts raw bytes. Two backends share the
// identical interface so the same JsStore runs everywhere:
//   • makeMapBridge(), in-memory (JS heap). Proves the architecture + runs in Node for validation.
//   • makeOpfsBridge(), SQLite on an OPFS sync-access VFS (browser Worker only). Real disk storage,
//                        so held bundles leave the wasm heap and a many-node tab stops OOMing.
//
// Contract (mirrors hop-store-sqlite's two-table model, a `seen` dedup index + a `bundles` data set):
//   put(id, data, expiresAt) -> bool   insert unless already seen (dedup); false if duplicate
//   get(id) -> Uint8Array|undefined    held bundle bytes
//   remove(id) -> Uint8Array|undefined drop held data (keep dedup entry); return removed bytes
//   seen(id) -> bool                    seen and not yet expired
//   seenExpiry(id) -> number|undefined  the seen row's receiver-anchored expires_at (epoch-ms)
//   contains(id) -> bool                currently held
//   have() -> Uint8Array                all held ids, concatenated 32-byte chunks
//   prune(nowMs)                        drop held + dedup entries whose window closed
//   kvPut/kvRemove(key[,val]) -> bool   synchronously acknowledged durable key→bytes mutation
//   kvBatch(bytes) -> bool               atomically commit bundle custody + KV mutations
//   kvGet(key) -> Uint8Array|undefined  durable key→bytes lookup
//   kvListPage(prefix,after,limit)       one ordered, bounded page of encoded KV records

const _hex = u => { let s = ''; for (const b of u) s += b.toString(16).padStart(2, '0'); return s; };
const _idBytes = h => { const a = new Uint8Array(32); for (let i = 0; i < 32; i++) a[i] = parseInt(h.substr(i * 2, 2), 16); return a; };

function _encodeKv(pairs) {
  const parts = [];
  for (const [k, v] of pairs) {
    const kb = new TextEncoder().encode(k);
    const klen = new Uint8Array(4); new DataView(klen.buffer).setUint32(0, kb.length, true);
    const vlen = new Uint8Array(4); new DataView(vlen.buffer).setUint32(0, v.length, true);
    parts.push(klen, kb, vlen, v);
  }
  let total = 0; for (const p of parts) total += p.length;
  const out = new Uint8Array(total); let o = 0; for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

function _decodeKvBatch(encoded) {
  const bytes = encoded instanceof Uint8Array ? encoded : new Uint8Array(encoded);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const out = [];
  const versioned = bytes[0] === 0x84;
  let offset = versioned ? 1 : 0;
  while (offset < bytes.length) {
    if (offset + 5 > bytes.length) throw new Error('truncated kvBatch header');
    const kind = bytes[offset++];
    const keyLen = view.getUint32(offset, true); offset += 4;
    if (offset + keyLen + 4 > bytes.length) throw new Error('truncated kvBatch key');
    const key = bytes.slice(offset, offset + keyLen); offset += keyLen;
    const valueLen = view.getUint32(offset, true); offset += 4;
    if (offset + valueLen > bytes.length) throw new Error('truncated kvBatch value');
    const value = bytes.slice(offset, offset + valueLen); offset += valueLen;
    let expiresAt = 0;
    if (versioned) {
      if (offset + 8 > bytes.length) throw new Error('truncated kvBatch expiry');
      expiresAt = Number(view.getBigUint64(offset, true)); offset += 8;
    }
    if (kind < 0 || kind > (versioned ? 3 : 1)) throw new Error('invalid kvBatch operation');
    if ((kind === 0 || kind === 3) && valueLen !== 0) throw new Error('kvBatch remove carried a value');
    if ((kind === 2 || kind === 3) && keyLen !== 32) throw new Error('kvBatch bundle id must be 32 bytes');
    out.push({ kind, key, value, expiresAt });
  }
  return out;
}

const _kvKey = bytes => new TextDecoder('utf-8', { fatal: true }).decode(bytes);

// In-memory backend, one Map set per node.
export function makeMapBridge({ failBatchMutation = -1 } = {}) {
  const seen = new Map();   // idHex -> expiresAt
  const held = new Map();   // idHex -> Uint8Array
  const kv = new Map();     // key -> Uint8Array
  return {
    put(id, data, expiresAt) { const h = _hex(id); if (seen.has(h)) return false; seen.set(h, expiresAt); held.set(h, data.slice()); return true; },
    get(id) { return held.get(_hex(id)); },
    remove(id) { const h = _hex(id); const d = held.get(h); held.delete(h); return d; },
    seen(id) { return seen.has(_hex(id)); },
    seenExpiry(id) { return seen.get(_hex(id)); },
    contains(id) { return held.has(_hex(id)); },
    have() { const out = new Uint8Array(held.size * 32); let o = 0; for (const h of held.keys()) { out.set(_idBytes(h), o); o += 32; } return out; },
    prune(nowMs) { for (const [h, e] of seen) if (e <= nowMs) { seen.delete(h); held.delete(h); } },
    kvPut(key, value) { kv.set(key, value.slice()); return true; },
    kvBatch(encoded) {
      const candidateSeen = new Map(seen);
      const candidateHeld = new Map(held);
      const candidateKv = new Map(kv);
      const operations = _decodeKvBatch(encoded);
      for (let index = 0; index < operations.length; index++) {
        if (index === failBatchMutation) throw new Error(`injected kvBatch failure at mutation ${index}`);
        const op = operations[index];
        if (op.kind === 1) candidateKv.set(_kvKey(op.key), op.value);
        else if (op.kind === 0) candidateKv.delete(_kvKey(op.key));
        else {
          const id = _hex(op.key);
          if (op.kind === 2) {
            if (candidateSeen.has(id)) return false;
            candidateSeen.set(id, op.expiresAt);
            candidateHeld.set(id, op.value);
          } else candidateHeld.delete(id);
        }
      }
      seen.clear(); for (const [key, value] of candidateSeen) seen.set(key, value);
      held.clear(); for (const [key, value] of candidateHeld) held.set(key, value);
      kv.clear(); for (const [key, value] of candidateKv) kv.set(key, value);
      return true;
    },
    kvGet(key) { return kv.get(key); },
    kvRemove(key) { kv.delete(key); return true; },
    kvList(prefix) { const out = []; for (const [k, v] of kv) if (k.startsWith(prefix)) out.push([k, v]); return _encodeKv(out); },
    kvListPage(prefix, after, limit) {
      const out = [...kv]
        .filter(([key]) => key.startsWith(prefix) && key > after)
        .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
        .slice(0, limit);
      return _encodeKv(out);
    },
  };
}

// SQLite/OPFS backend, one DB (an in-memory-mirrored, disk-persisted OPFS file) per node. `db` is an
// open @sqlite.org/sqlite-wasm database (opfs VFS) with the schema already created. Held bundles live
// on disk, so wasm memory stays flat regardless of how many bundles the mesh floods.
// One shared SQLite DB for the whole mesh, every row namespaced by node id `ns`. A single DB means a
// single OPFS sync-access handle (opening one-DB-per-node pre-opens dozens of handles and the browser
// closes them under it → "access handle already closed" / disk I/O errors). Held bundles still live on
// disk; only the rollback journal is in memory (set by the caller for fewer files + speed).
export function makeSqliteBridge(db, ns) {
  db.exec(`CREATE TABLE IF NOT EXISTS seen(ns TEXT, id BLOB, expires_at INTEGER, PRIMARY KEY(ns,id));
           CREATE TABLE IF NOT EXISTS bundles(ns TEXT, id BLOB, data BLOB, PRIMARY KEY(ns,id));
           CREATE TABLE IF NOT EXISTS kv(ns TEXT, key TEXT, value BLOB, PRIMARY KEY(ns,key));`);
  const one = (sql, bind) => { let r; db.exec({ sql, bind, rowMode: 'array', callback: row => { r = row; } }); return r; };
  return {
    put(id, data, expiresAt) {
      const idc = id.slice();
      if (one(`SELECT 1 FROM seen WHERE ns=? AND id=?`, [ns, idc])) return false;
      db.exec('BEGIN IMMEDIATE');
      try {
        db.exec({ sql: `INSERT INTO seen(ns,id,expires_at) VALUES(?,?,?)`, bind: [ns, idc, expiresAt] });
        db.exec({ sql: `INSERT INTO bundles(ns,id,data) VALUES(?,?,?)`, bind: [ns, idc, data.slice()] });
        db.exec('COMMIT');
        return true;
      } catch (error) {
        try { db.exec('ROLLBACK'); } catch (_) {}
        throw error;
      }
    },
    get(id) { const r = one(`SELECT data FROM bundles WHERE ns=? AND id=?`, [ns, id.slice()]); return r ? new Uint8Array(r[0]) : undefined; },
    remove(id) { const idc = id.slice(); const r = one(`SELECT data FROM bundles WHERE ns=? AND id=?`, [ns, idc]); db.exec({ sql: `DELETE FROM bundles WHERE ns=? AND id=?`, bind: [ns, idc] }); return r ? new Uint8Array(r[0]) : undefined; },
    seen(id) { return !!one(`SELECT 1 FROM seen WHERE ns=? AND id=?`, [ns, id.slice()]); },
    seenExpiry(id) { const r = one(`SELECT expires_at FROM seen WHERE ns=? AND id=?`, [ns, id.slice()]); return r ? r[0] : undefined; },
    contains(id) { return !!one(`SELECT 1 FROM bundles WHERE ns=? AND id=?`, [ns, id.slice()]); },
    have() { const rows = []; db.exec({ sql: `SELECT id FROM bundles WHERE ns=?`, bind: [ns], rowMode: 'array', callback: r => rows.push(new Uint8Array(r[0])) });
             const out = new Uint8Array(rows.length * 32); let o = 0; for (const r of rows) { out.set(r, o); o += 32; } return out; },
    prune(nowMs) {
      db.exec({ sql: `DELETE FROM bundles WHERE ns=? AND id IN (SELECT id FROM seen WHERE ns=? AND expires_at<=?)`, bind: [ns, ns, nowMs] });
      db.exec({ sql: `DELETE FROM seen WHERE ns=? AND expires_at<=?`, bind: [ns, nowMs] });
    },
    kvPut(key, value) { db.exec({ sql: `INSERT OR REPLACE INTO kv(ns,key,value) VALUES(?,?,?)`, bind: [ns, key, value.slice()] }); return true; },
    kvBatch(encoded) {
      const operations = _decodeKvBatch(encoded);
      db.exec('BEGIN IMMEDIATE');
      try {
        for (const op of operations) {
          if (op.kind === 1) db.exec({ sql: `INSERT OR REPLACE INTO kv(ns,key,value) VALUES(?,?,?)`, bind: [ns, _kvKey(op.key), op.value] });
          else if (op.kind === 0) db.exec({ sql: `DELETE FROM kv WHERE ns=? AND key=?`, bind: [ns, _kvKey(op.key)] });
          else if (op.kind === 2) {
            if (one(`SELECT 1 FROM seen WHERE ns=? AND id=?`, [ns, op.key])) throw new Error('critical bundle put was deduplicated');
            db.exec({ sql: `INSERT INTO seen(ns,id,expires_at) VALUES(?,?,?)`, bind: [ns, op.key, op.expiresAt] });
            db.exec({ sql: `INSERT INTO bundles(ns,id,data) VALUES(?,?,?)`, bind: [ns, op.key, op.value] });
          } else db.exec({ sql: `DELETE FROM bundles WHERE ns=? AND id=?`, bind: [ns, op.key] });
        }
        db.exec('COMMIT');
        return true;
      } catch (error) {
        try { db.exec('ROLLBACK'); } catch (_) {}
        throw error;
      }
    },
    kvGet(key) { const r = one(`SELECT value FROM kv WHERE ns=? AND key=?`, [ns, key]); return r ? new Uint8Array(r[0]) : undefined; },
    kvRemove(key) { db.exec({ sql: `DELETE FROM kv WHERE ns=? AND key=?`, bind: [ns, key] }); return true; },
    kvList(prefix) { const out = []; db.exec({ sql: `SELECT key,value FROM kv WHERE ns=? AND key LIKE ?`, bind: [ns, prefix + '%'], rowMode: 'array', callback: r => out.push([r[0], new Uint8Array(r[1])]) }); return _encodeKv(out); },
    kvListPage(prefix, after, limit) {
      const out = [];
      db.exec({ sql: `SELECT key,value FROM kv WHERE ns=? AND substr(key,1,length(?))=? AND key>? ORDER BY key LIMIT ?`, bind: [ns, prefix, prefix, after, limit], rowMode: 'array', callback: r => out.push([r[0], new Uint8Array(r[1])]) });
      return _encodeKv(out);
    },
  };
}

let activeSimDb = null;
let activeSimPool = null;

export function getSimDb() {
  return activeSimDb;
}

export function getSimPool() {
  return activeSimPool;
}

export function closeSimStorage() {
  if (activeSimDb) {
    try { if (typeof activeSimDb.close === 'function') activeSimDb.close(); } catch (_) {}
    activeSimDb = null;
  }
  if (activeSimPool) {
    try { if (typeof activeSimPool.close === 'function') activeSimPool.close(); } catch (_) {}
    activeSimPool = null;
  }
}

/**
 * Creates an OPFS SQLite bridge factory with robust timeout and cancellation handling (PLAT-012).
 * If the OPFS acquisition times out or is abandoned, any late-resolving pool or database handle
 * is closed immediately to prevent stranding the exclusive SAHPool lock.
 */
export async function createOpfsBridgeFactory(options = {}) {
  const {
    timeoutMs = 4000,
    importSqlite = async () => {
      const { default: sqlite3InitModule } = await import('./sqlite-wasm/sqlite3.mjs');
      return sqlite3InitModule();
    },
    poolName = 'hop-sim-1',
    initialCapacity = 8,
    onStorage = null,
  } = options;

  let abandoned = false;
  let timer = null;

  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => {
      abandoned = true;
      reject(new Error('OPFS init timed out, another tab may hold the store; close extra tabs'));
    }, timeoutMs);
  });

  const setup = (async () => {
    let pool = null;
    let db = null;
    try {
      const sqlite3 = await importSqlite();
      if (abandoned) return null;

      pool = await sqlite3.installOpfsSAHPoolVfs({ name: poolName, initialCapacity });
      if (abandoned) {
        if (pool && typeof pool.close === 'function') {
          try { pool.close(); } catch (_) {}
        }
        return null;
      }

      db = new pool.OpfsSAHPoolDb('/hop-sim.sqlite');
      if (abandoned) {
        if (db && typeof db.close === 'function') {
          try { db.close(); } catch (_) {}
        }
        if (pool && typeof pool.close === 'function') {
          try { pool.close(); } catch (_) {}
        }
        return null;
      }

      db.exec(`PRAGMA journal_mode=MEMORY; PRAGMA synchronous=OFF;
               DROP TABLE IF EXISTS seen; DROP TABLE IF EXISTS bundles; DROP TABLE IF EXISTS kv;`);

      if (abandoned) {
        if (db && typeof db.close === 'function') {
          try { db.close(); } catch (_) {}
        }
        if (pool && typeof pool.close === 'function') {
          try { pool.close(); } catch (_) {}
        }
        return null;
      }

      return { pool, db, bridgeFor: (id) => makeSqliteBridge(db, id) };
    } catch (err) {
      if (db && typeof db.close === 'function') {
        try { db.close(); } catch (_) {}
      }
      if (pool && typeof pool.close === 'function') {
        try { pool.close(); } catch (_) {}
      }
      throw err;
    }
  })();

  try {
    const res = await Promise.race([setup, timeout]);
    clearTimeout(timer);
    if (!res || abandoned) {
      if (onStorage) onStorage({ backend: 'memory' });
      return () => makeMapBridge();
    }
    activeSimPool = res.pool;
    activeSimDb = res.db;
    if (onStorage) onStorage({ backend: 'opfs-sqlite' });
    return res.bridgeFor;
  } catch (err) {
    clearTimeout(timer);
    abandoned = true;
    setup.then((res) => {
      if (res) {
        if (res.db && typeof res.db.close === 'function') {
          try { res.db.close(); } catch (_) {}
        }
        if (res.pool && typeof res.pool.close === 'function') {
          try { res.pool.close(); } catch (_) {}
        }
      }
    }).catch(() => {});

    if (onStorage) onStorage({ backend: 'memory', error: String((err && err.message) || err) });
    return () => makeMapBridge();
  }
}
