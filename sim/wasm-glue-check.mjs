// Direct WasmNode API and storage check (F-5): exercises the four `#[wasm_bindgen]` WasmNode methods that
// scenario-check.mjs's scripted scenarios never call: `publish_recv_beacon` (the §39 P4 receiver-
// beacon, DESIGN.md §39), `send_traced`, `set_default_lifetime_ms`, and `inbox_debug`, against the
// REAL compiled wasm (the same core/hop-wasm/pkg-node build scenario-check.mjs uses), asserting an
// observable effect for each. Before this file, `wasm_glue.rs`'s own header comment claimed full
// coverage from scenario-check.mjs, but `grep` found zero JS call sites for these four; the flagship
// receiver-beacon path in particular was never driven through wasm at all. See wasm_glue.rs's header
// comment for the honest coverage split between the two files. It also locks the Map bridge's paged
// key ordering to the same binary comparison used by its exclusive cursor.
//
// Deliberately NOT layered on sim/mesh.js: mesh.tick() polls and accepts each node's inbox internally
// (to build mesh.deliveries), which would remove the very bundle inbox_debug() needs to see. Driving
// raw WasmNode calls here keeps every assertion unambiguous about what produced the observed effect.
//
// Run: node sim/wasm-glue-check.mjs   (after sim/build-wasm.sh has produced core/hop-wasm/pkg-node)
import { createRequire } from 'module';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { makeMapBridge } from './store-bridge.js';

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const { WasmNode } = require(join(here, '../core/hop-wasm/pkg-node/hop_wasm.js'));

const enc = s => new TextEncoder().encode(s);
const dec = b => new TextDecoder().decode(b);

let seedSeq = 0;
function seed() {
  seedSeq++;
  const s = new Uint8Array(32);
  s[0] = seedSeq & 0xff; s[1] = (seedSeq >> 8) & 0xff; s[2] = 0xc0; s[3] = 0xde;
  return s;
}

let failed = 0;
function check(label, cond) {
  if (cond) console.log(`  ok ${label}`);
  else { failed++; console.log(`  FAIL ${label}`); }
}

function containsId(flat, id) {
  for (let i = 0; i + 32 <= flat.length; i += 32) {
    let match = true;
    for (let j = 0; j < 32; j++) if (flat[i + j] !== id[j]) { match = false; break; }
    if (match) return true;
  }
  return false;
}

function addrEq(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

function firstKvKey(flat) {
  if (flat.length < 4) return null;
  const length = new DataView(flat.buffer, flat.byteOffset, flat.byteLength).getUint32(0, true);
  if (flat.length < 4 + length) return null;
  return dec(flat.slice(4, 4 + length));
}

function encodeBatchOperation(kind, key, value, expiresAt = 0n) {
  const out = new Uint8Array(1 + 4 + key.length + 4 + value.length + 8);
  const view = new DataView(out.buffer);
  let offset = 0;
  out[offset++] = kind;
  view.setUint32(offset, key.length, true); offset += 4;
  out.set(key, offset); offset += key.length;
  view.setUint32(offset, value.length, true); offset += 4;
  out.set(value, offset); offset += value.length;
  view.setBigUint64(offset, expiresAt, true);
  return out;
}

function encodeVersionedBatch(operations) {
  const size = 1 + operations.reduce((sum, operation) => sum + operation.length, 0);
  const out = new Uint8Array(size);
  out[0] = 0x84;
  let offset = 1;
  for (const operation of operations) { out.set(operation, offset); offset += operation.length; }
  return out;
}

console.log('map_bridge_pagination');
(function testMapBridgePagination() {
  const bridge = makeMapBridge();
  for (const key of ['p/A', 'p/_', 'p/a']) bridge.kvPut(key, enc(key));
  const keys = [];
  let after = '';
  for (let page = 0; page < 3; page++) {
    const key = firstKvKey(bridge.kvListPage('p/', after, 1));
    if (key === null) break;
    keys.push(key);
    after = key;
  }
  check('binary sort agrees with the exclusive cursor across every page',
    keys.join(',') === 'p/A,p/_,p/a' && bridge.kvListPage('p/', after, 1).length === 0);
})();

console.log('map_bridge_mixed_batch_rollback');
(function testMapBridgeMixedBatchRollback() {
  const bridge = makeMapBridge({ failBatchMutation: 1 });
  const id = new Uint8Array(32).fill(0x5a);
  const batch = encodeVersionedBatch([
    encodeBatchOperation(2, id, enc('sealed bundle'), 5000n),
    encodeBatchOperation(1, enc('session/alice'), new Uint8Array([1, 2, 3])),
  ]);
  let failedAtSecond = false;
  try { bridge.kvBatch(batch); } catch (error) { failedAtSecond = /mutation 1/.test(String(error)); }
  check('second mutation failure surfaces', failedAtSecond);
  check('failed session write leaves no bundle custody or dedup state',
    !bridge.contains(id) && !bridge.seen(id) && bridge.kvGet('session/alice') === undefined);
})();

// Two real WasmNode instances (in-memory Map bridge, same backend scenario-check.mjs uses for its
// headless run) joined by one bearer link. Publishes both prekeys up front (every scenario does this
// via mesh.add()), same as the real sim.
function twoNodeLink(linkId = 1) {
  const a = new WasmNode(seed(), makeMapBridge());
  const b = new WasmNode(seed(), makeMapBridge());
  a.set_observe(true); b.set_observe(true);
  a.publish_prekey(); b.publish_prekey();
  a.connected(linkId, true);
  b.connected(linkId, false);
  return { a, b, aAddr: a.address, bAddr: b.address, linkId };
}

// Advance both clocks + pump bytes across the one link. Returns the new `now`.
function pumpFor(pair, startMs, steps, stepMs) {
  let now = startMs;
  for (let i = 0; i < steps; i++) {
    now += stepMs;
    pair.a.tick(now);
    pair.b.tick(now);
    for (const p of pair.a.drain()) if (p.link === pair.linkId) pair.b.receive(p.link, p.data);
    for (const p of pair.b.drain()) if (p.link === pair.linkId) pair.a.receive(p.link, p.data);
  }
  return now;
}

// Decode WasmNode.gradient()'s flat `[16-byte tag][u32 LE link][u8 hops]` records.
function gradientRecords(bytes) {
  const out = [];
  for (let i = 0; i + 21 <= bytes.length; i += 21) {
    const tag = bytes.slice(i, i + 16);
    const link = bytes[i + 16] | (bytes[i + 17] << 8) | (bytes[i + 18] << 16) | (bytes[i + 19] << 24);
    out.push({ tag, link, hops: bytes[i + 20] });
  }
  return out;
}

// ---- 1) set_default_lifetime_ms: a shortened sender TTL really prunes the sender's own held copy,
//         the exact behavior its own doc comment claims ("the store prunes on it"). ----
console.log('set_default_lifetime_ms');
(function testLifetime() {
  const pair = twoNodeLink();
  let now = pumpFor(pair, 0, 45, 100); // warmup: prekeys gossip, mirrors scenario-check's 45x100ms
  // Sever the link so the message we're about to send is never delivered -- it must survive purely on
  // the sender's own store until its (shortened) TTL prunes it.
  pair.a.disconnected(pair.linkId);
  pair.b.disconnected(pair.linkId);

  const SHORT_MS = 500;
  pair.a.set_default_lifetime_ms(SHORT_MS);
  const id = pair.a.send(pair.bAddr, enc('short-lived')); // prekey already known -> sealed immediately, not deferred

  check('sender holds its own copy right after send', containsId(pair.a.held_ids(), id));

  now += SHORT_MS + 1000; // well past the shortened lifetime
  pair.a.tick(now); // Node::tick -> store.prune(now_ms), keyed on the id's put-time expires_at
  check('shortened TTL prunes the sender copy on the next tick', !containsId(pair.a.held_ids(), id));
})();

// ---- 2) publish_recv_beacon: an EXPLICIT call (not Node::tick's own 30s auto-republish timer)
//         really emits a link-local unsigned prefix-only Wire::RecvBeacon that forms a real §39 P4 gradient on the neighbor. ----
console.log('publish_recv_beacon');
(function testRecvBeacon() {
  const pair = twoNodeLink(); // a = recipient, b = the neighbor that will learn a route toward a
  let now = pumpFor(pair, 0, 45, 100); // warmup only brings the link + prekeys up, no beacon yet

  check('no gradient toward the recipient exists before the explicit call',
    gradientRecords(pair.b.gradient()).length === 0);

  let threw = false;
  try { pair.a.publish_recv_beacon(); } catch (e) { threw = true; }
  check('callable without throwing', !threw);

  now = pumpFor(pair, now, 10, 100); // propagate the beacon record over the link
  // core/hop-core/src/node.rs RECV_BEACON_REFRESH_MS = 30_000ms: staying well under it means any
  // gradient we see below came from THIS explicit call, not Node::tick's own auto-republish.
  check('elapsed time stays well under the 30s auto-beacon timer', now < 30_000);

  const recipientTag = pair.a.mailbox_tag();
  const found = gradientRecords(pair.b.gradient()).some(r => addrEq(r.tag, recipientTag) && r.link === pair.linkId);
  check('neighbor now holds a gradient toward the recipient over the real link', found);
})();

// ---- 3) send_traced: the opt-in cleartext-address / directed-routing path really delivers, through
//         the real wasm binding (not the default private send() every scenario already exercises). ----
console.log('send_traced');
(function testSendTraced() {
  const pair = twoNodeLink();
  let now = pumpFor(pair, 0, 45, 100); // warmup: prekeys gossip

  let threw = false;
  try { pair.a.send_traced(pair.bAddr, enc('traced-hello')); } catch (e) { threw = true; }
  check('callable without throwing', !threw);

  now = pumpFor(pair, now, 20, 100);

  const inbox = pair.b.inbox();
  const got = inbox.find(m => dec(m.body) === 'traced-hello');
  check('the traced bundle really reaches the recipient inbox', !!got);
  check('the recipient sees the real (cleartext) sender address', !!got && addrEq(got.from, pair.aAddr));
})();

// ---- 4) inbox_debug: the debug string reports and explicitly accepts the durable inbox item. ----
console.log('inbox_debug');
(function testInboxDebug() {
  const pair = twoNodeLink();
  let now = pumpFor(pair, 0, 45, 100);

  pair.a.send(pair.bAddr, enc('debug-me'));
  now = pumpFor(pair, now, 20, 100);

  const report = pair.b.inbox_debug();
  check('reports the one delivered bundle', /n=1/.test(report));
  check('reports it read ok with content-type + length', /\[ok type=text\/plain len=\d+\]/.test(report));

  const report2 = pair.b.inbox_debug();
  check('a second call reports an empty inbox (the first call accepted it)', report2 === 'n=0');
})();

console.log(failed ? `\n${failed} wasm-glue check(s) FAILED` : '\nall wasm-glue checks pass (ok)');
process.exit(failed ? 1 : 0);
