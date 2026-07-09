// Per-node synchronous storage bridges for hop-wasm's `JsStore` (see core/hop-wasm/src/store.rs).
//
// The core calls these methods synchronously; each returns/accepts raw bytes. Two backends share the
// identical interface so the same JsStore runs everywhere:
//   • makeMapBridge()  — in-memory (JS heap). Proves the architecture + runs in Node for validation.
//   • makeOpfsBridge() — SQLite on an OPFS sync-access VFS (browser Worker only). Real disk storage,
//                        so held bundles leave the wasm heap and a many-node tab stops OOMing.
//
// Contract (mirrors hop-store-sqlite's two-table model — a `seen` dedup index + a `bundles` data set):
//   put(id, data, expiresAt) -> bool   insert unless already seen (dedup); false if duplicate
//   get(id) -> Uint8Array|undefined    held bundle bytes
//   remove(id) -> Uint8Array|undefined drop held data (keep dedup entry); return removed bytes
//   seen(id) -> bool                    seen and not yet expired
//   contains(id) -> bool                currently held
//   have() -> Uint8Array                all held ids, concatenated 32-byte chunks
//   prune(nowMs)                        drop held + dedup entries whose window closed
//   setData(id, data)                   overwrite held data (copy-budget mutation)
//   kvPut/kvGet/kvRemove(key[,val])     durable key→bytes
//   kvList(prefix) -> Uint8Array        [u32LE keylen][key][u32LE vallen][val]... records

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

// In-memory backend — one Map set per node.
export function makeMapBridge() {
  const seen = new Map();   // idHex -> expiresAt
  const held = new Map();   // idHex -> Uint8Array
  const kv = new Map();     // key -> Uint8Array
  return {
    put(id, data, expiresAt) { const h = _hex(id); if (seen.has(h)) return false; seen.set(h, expiresAt); held.set(h, data.slice()); return true; },
    get(id) { return held.get(_hex(id)); },
    remove(id) { const h = _hex(id); const d = held.get(h); held.delete(h); return d; },
    seen(id) { return seen.has(_hex(id)); },
    contains(id) { return held.has(_hex(id)); },
    have() { const out = new Uint8Array(held.size * 32); let o = 0; for (const h of held.keys()) { out.set(_idBytes(h), o); o += 32; } return out; },
    prune(nowMs) { for (const [h, e] of seen) if (e <= nowMs) { seen.delete(h); held.delete(h); } },
    setData(id, data) { const h = _hex(id); if (held.has(h)) held.set(h, data.slice()); },
    kvPut(key, value) { kv.set(key, value.slice()); },
    kvGet(key) { return kv.get(key); },
    kvRemove(key) { kv.delete(key); },
    kvList(prefix) { const out = []; for (const [k, v] of kv) if (k.startsWith(prefix)) out.push([k, v]); return _encodeKv(out); },
  };
}

// SQLite/OPFS backend — one DB (an in-memory-mirrored, disk-persisted OPFS file) per node. `db` is an
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
      db.exec({ sql: `INSERT INTO seen(ns,id,expires_at) VALUES(?,?,?)`, bind: [ns, idc, expiresAt] });
      db.exec({ sql: `INSERT OR REPLACE INTO bundles(ns,id,data) VALUES(?,?,?)`, bind: [ns, idc, data.slice()] });
      return true;
    },
    get(id) { const r = one(`SELECT data FROM bundles WHERE ns=? AND id=?`, [ns, id.slice()]); return r ? new Uint8Array(r[0]) : undefined; },
    remove(id) { const idc = id.slice(); const r = one(`SELECT data FROM bundles WHERE ns=? AND id=?`, [ns, idc]); db.exec({ sql: `DELETE FROM bundles WHERE ns=? AND id=?`, bind: [ns, idc] }); return r ? new Uint8Array(r[0]) : undefined; },
    seen(id) { return !!one(`SELECT 1 FROM seen WHERE ns=? AND id=?`, [ns, id.slice()]); },
    contains(id) { return !!one(`SELECT 1 FROM bundles WHERE ns=? AND id=?`, [ns, id.slice()]); },
    have() { const rows = []; db.exec({ sql: `SELECT id FROM bundles WHERE ns=?`, bind: [ns], rowMode: 'array', callback: r => rows.push(new Uint8Array(r[0])) });
             const out = new Uint8Array(rows.length * 32); let o = 0; for (const r of rows) { out.set(r, o); o += 32; } return out; },
    prune(nowMs) {
      db.exec({ sql: `DELETE FROM bundles WHERE ns=? AND id IN (SELECT id FROM seen WHERE ns=? AND expires_at<=?)`, bind: [ns, ns, nowMs] });
      db.exec({ sql: `DELETE FROM seen WHERE ns=? AND expires_at<=?`, bind: [ns, nowMs] });
    },
    setData(id, data) { db.exec({ sql: `UPDATE bundles SET data=? WHERE ns=? AND id=?`, bind: [data.slice(), ns, id.slice()] }); },
    kvPut(key, value) { db.exec({ sql: `INSERT OR REPLACE INTO kv(ns,key,value) VALUES(?,?,?)`, bind: [ns, key, value.slice()] }); },
    kvGet(key) { const r = one(`SELECT value FROM kv WHERE ns=? AND key=?`, [ns, key]); return r ? new Uint8Array(r[0]) : undefined; },
    kvRemove(key) { db.exec({ sql: `DELETE FROM kv WHERE ns=? AND key=?`, bind: [ns, key] }); },
    kvList(prefix) { const out = []; db.exec({ sql: `SELECT key,value FROM kv WHERE ns=? AND key LIKE ?`, bind: [ns, prefix + '%'], rowMode: 'array', callback: r => out.push([r[0], new Uint8Array(r[1])]) }); return _encodeKv(out); },
  };
}
