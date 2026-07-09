// Web Worker: runs the ENTIRE real-node mesh off the main thread.
//
// The main thread owns movement + rendering (so the map stays 60fps no matter how hard the
// nodes work) and just posts node positions + commands here. This worker runs every real
// hop-core WasmNode, and posts back the recent relay legs + deliveries (with reconstructed
// paths). All the crypto lives here, isolated from the UI thread and its memory.

import initWasm, { WasmNode } from './pkg/hop_wasm.js';
import { makeMesh } from './mesh.js';
import { makeMapBridge, makeSqliteBridge } from './store-bridge.js';

const RANGE = { ble: 35, wifi: 90 };   // realistic: BLE phone-to-phone ~10-35m; Wi-Fi Direct ~50-100m
// SOAK = dwell time (sim-ms ≈ simulated real seconds) a pair must stay in range before the link is usable.
// Real connection setup: BLE discovery+GATT ~4s, Wi-Fi Direct group negotiation ~8s, AP association ~2s,
// cell/relay attach ~3s. A fast passer-by that doesn't dwell this long never links (physically honest).
const SOAK = { ble: 4000, wifi: 8000, ap: 2000, relay: 3000, lora: 1500 };
const RELAY_ID = 'relay';
let mesh = null;
let caps = {};            // id -> { platform, bt, wifiP2P }
let st = {};              // id -> { p:[lng,lat], c:hasCell }  (updated every tick from the main thread)
let lastHolders = 0, holderCache = {}, statusCache = {}, gradientCache = [], focusRecip = null, lastMem = 0;   // throttles + which recipient's gradient tree to expose
let lastTickNow = 0;   // previous tick's sim clock, for sub-tick slicing at high time compression
let congested = false;   // scenario: the cell net is up but oversubscribed — the backbone is unusable
let wasmMem = null, simDb = null, sqliteMod = null;   // for the memory diagnostic
// Total bundles held across the whole mesh — the real store size, backend-agnostic (SQLite COUNT, or
// summed from each node's in-memory store). Drops as the vaccine + TTL purge delivered messages.
function dbRows() {
  if (!mesh) return 0;
  // Copies of MESSAGE bundles held across the whole mesh. RISES as a send floods, FALLS as it's
  // delivered + the vaccine purges relay copies (and on TTL). Should breathe, not climb forever.
  let n = 0; const mb = mesh.msgBundles;
  for (const { node } of mesh.nodes.values()) { const b = node.held_ids();
    for (let i = 0; i + 32 <= b.length; i += 32) { let h = ''; for (let j = i; j < i + 32; j++) h += b[j].toString(16).padStart(2, '0'); if (mb.has(h)) n++; } }
  return n;
}
function sqliteBytes() { try { return sqliteMod ? sqliteMod.wasm.heap8u().byteLength : 0; } catch (_) { return 0; } }

function hav(a, b) { const t = Math.PI / 180, dLa = (b[1] - a[1]) * t, dLo = (b[0] - a[0]) * t;
  const h = Math.sin(dLa / 2) ** 2 + Math.cos(a[1] * t) * Math.cos(b[1] * t) * Math.sin(dLo / 2) ** 2;
  return 6371000 * 2 * Math.asin(Math.sqrt(h)); }
// linkInfo(a,b): the connection SOAK (ms) for the best available transport, or -1 if they can't connect.
function linkInfo(a, b) {
  if (a === RELAY_ID) return (!congested && st[b] && st[b].c) ? SOAK.relay : -1;   // backbone: cell OR a connected AP
  if (b === RELAY_ID) return (!congested && st[a] && st[a].c) ? SOAK.relay : -1;
  const A = st[a], B = st[b], ca = caps[a], cb = caps[b];
  if (A && B && ca && cb) { const d = hav(A.p, B.p);
    if (ca.bt && cb.bt && d <= RANGE.ble) return SOAK.ble;   // BLE first: shorter range, quicker connect
    if (ca.wifiP2P && cb.wifiP2P && ca.platform === cb.platform && d <= RANGE.wifi) return SOAK.wifi;
  }
  if (A && B && A.ap && A.ap === B.ap) return SOAK.ap;   // same Wi-Fi NETWORK (LAN mesh; multi-AP nets share a name), internet or not
  if (ca && cb && ca.lora && ca.lora === cb.lora) return SOAK.lora;   // Hop Bridges bonded by a sub-GHz LoRa net — just another bearer link to the core
  return -1;
}
function seedFor(i) { const s = new Uint8Array(32); s[0] = (i + 1) & 0xff; s[1] = ((i + 1) >> 8) & 0xff; s[2] = 0xa5; s[3] = 0x5a; return s; }

// Per-node storage: SQLite on an OPFS sync-access VFS (real disk → bundles leave wasm memory, so a
// many-node tab stops OOMing). Falls back to an in-memory Map if OPFS/sqlite-wasm isn't available, so
// the sim always runs. Each node gets its own DB file in the pool.
async function makeBridgeFactory() {
  try {
    // Race OPFS setup against a timeout: the SAHPool VFS takes an EXCLUSIVE lock, so another (stale) tab
    // holding it makes installOpfsSAHPoolVfs block forever — which would hang "booting real nodes". If it
    // doesn't come up quickly, fall back to in-memory so the sim always boots.
    const timeout = new Promise((_, rej) => setTimeout(() => rej(new Error('OPFS init timed out — another tab may hold the store; close extra tabs')), 4000));
    const setup = (async () => {
      const { default: sqlite3InitModule } = await import('./sqlite-wasm/sqlite3.mjs');
      const sqlite3 = await sqlite3InitModule(); sqliteMod = sqlite3;
      // ONE db for the whole mesh → ONE OPFS sync-access handle. Fresh pool name so we don't reuse an
      // old, larger pool (initialCapacity is a minimum, not a cap). Memory journal keeps files minimal.
      const pool = await sqlite3.installOpfsSAHPoolVfs({ name: 'hop-sim-1', initialCapacity: 8 });
      const db = new pool.OpfsSAHPoolDb('/hop-sim.sqlite');
      db.exec(`PRAGMA journal_mode=MEMORY; PRAGMA synchronous=OFF;
               DROP TABLE IF EXISTS seen; DROP TABLE IF EXISTS bundles; DROP TABLE IF EXISTS kv;`);  // fresh session
      simDb = db;
      return (id) => makeSqliteBridge(db, id);
    })();
    const bridgeFor = await Promise.race([setup, timeout]);
    postMessage({ type: 'storage', backend: 'opfs-sqlite' });
    return bridgeFor;
  } catch (err) {
    postMessage({ type: 'storage', backend: 'memory', error: String((err && err.message) || err) });
    return () => makeMapBridge();
  }
}

onmessage = async (e) => {
  const m = e.data;
  if (m.type === 'init') {
    congested = !!m.congested;
    const out = await initWasm(); wasmMem = out && out.memory;   // hop-core nodes' wasm linear memory
    // Storage: in-memory by default (reliable, and a valid host Store just like MemoryStore). OPFS/SQLite
    // is opt-in via ?opfs — it's disk-backed but finicky across tabs (exclusive access-handle locks).
    let bridgeFor;
    if (m.useOpfs) { bridgeFor = await makeBridgeFactory(); }
    else { postMessage({ type: 'storage', backend: 'memory' }); bridgeFor = () => makeMapBridge(); }
    mesh = makeMesh(WasmNode, bridgeFor);
    m.nodes.forEach((n, i) => { caps[n.id] = { platform: n.platform, bt: n.bt, wifiP2P: n.wifiP2P, lora: n.lora || null }; mesh.add(n.id, seedFor(i)); });
    caps[RELAY_ID] = { platform: 'relay', bt: true, wifiP2P: false };
    mesh.add(RELAY_ID, seedFor(900));
    if (m.channel) mesh.setupChannel(m.channel.host, m.channel.path, m.channel.members);   // key handshakes ride the warmup
    // warm up: connect everyone to the relay so every prekey gossips, then clear the warmup traffic.
    // Warmup: instant relay links gossip prekeys — legitimate pre-event/pre-disaster contact (under
    // congestion, everyone attached fine BEFORE the crowd peaked; the jam hits afterwards, and the
    // congested relay is severed for the whole run below).
    const ids = Object.keys(caps), warmIn = (a, b) => (a === RELAY_ID || b === RELAY_ID) ? 0 : -1;
    let t = 0; for (let k = 0; k < 45; k++) { t += 100; mesh.tick(t, ids, warmIn); }
    mesh.legs.length = 0; mesh.deliveries.length = 0; mesh.parent.clear();
    postMessage({ type: 'ready' });
  } else if (m.type === 'tick') {
    if (!mesh) return;
    st = m.state;
    // SUB-TICK: at high time compression one snapshot spans many sim-seconds, so a passing contact
    // would be sampled once or twice and the connection SOAK could never mature — links wouldn't form
    // at exactly the speeds where carries matter. Slice the jump into ≤2.5 sim-s steps (capped, so a
    // hidden-tab catch-up can't cause a tick storm); positions hold at the latest snapshot, which is
    // the same continuous-contact assumption a real BLE scanner makes between scans.
    const ids = Object.keys(caps), target = m.nowMs;
    if (lastTickNow && target > lastTickNow) {
      const n = Math.min(8, Math.max(1, Math.ceil((target - lastTickNow) / 2500)));
      for (let i = 1; i <= n; i++) mesh.tick(Math.round(lastTickNow + (target - lastTickNow) * i / n), ids, linkInfo);
    } else mesh.tick(target, ids, linkInfo);
    lastTickNow = target;
    const dels = mesh.deliveries.splice(0);   // take + clear the new deliveries
    if (mesh.legs.length > 900) mesh.legs.splice(0, mesh.legs.length - 900);
    // holderMap scans every node's held set (a store query) — throttle it off the per-frame path.
    const nowReal = performance.now();
    if (nowReal - lastHolders > 700) { lastHolders = nowReal; holderCache = mesh.holderMap(); statusCache = mesh.statusMap(); gradientCache = focusRecip ? mesh.gradientTo(focusRecip) : []; }
    postMessage({ type: 'frame', legs: mesh.legs.slice(), dels, holders: holderCache, status: statusCache, gradient: gradientCache, acks: mesh.senderAcks.splice(0), beacons: mesh.beaconEvents.splice(0), hps: mesh.hpsDeliveries.splice(0) });
    if (nowReal - lastMem > 1000) { lastMem = nowReal; postMessage({ type: 'mem', used: (performance.memory && performance.memory.usedJSHeapSize) || 0, wasm: wasmMem ? wasmMem.buffer.byteLength : 0, sqlite: sqliteBytes(), dbRows: dbRows() }); }
  } else if (m.type === 'send') {
    if (mesh) { const bid = mesh.send(m.from, m.to, m.text); postMessage({ type: 'sent', mid: m.mid, bundle: bid }); }
  } else if (m.type === 'probe') {   // diagnostics: prekey knowledge + queue depths between two nodes
    if (mesh) { const A = mesh.nodes.get(m.a), B = mesh.nodes.get(m.b);
      postMessage({ type: 'probe', a: m.a, b: m.b,
        aKnowsB: A && B ? A.node.knows_prekey(B.addr) : null,
        bKnowsA: A && B ? B.node.knows_prekey(A.addr) : null,
        aPending: A ? A.node.pending_count() : null, bPending: B ? B.node.pending_count() : null,
        aHeld: A ? A.node.held_ids().length / 32 : null, bHeld: B ? B.node.held_ids().length / 32 : null }); }
  } else if (m.type === 'publish') {
    if (mesh) { const bid = mesh.publish(m.from, m.path, m.text); postMessage({ type: 'sent', mid: m.mid, bundle: bid }); }
  } else if (m.type === 'focus') {
    focusRecip = m.recip; gradientCache = (mesh && focusRecip) ? mesh.gradientTo(focusRecip) : [];   // recompute the tree now
  } else if (m.type === 'caps') {
    if (caps[m.id]) caps[m.id][m.field] = m.value;
  }
};
