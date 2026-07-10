// Headless validation that every scenario in scenarios.js ACTUALLY COMPLETES — each scripted send
// delivers AND its ACK returns to the sender within the scenario's mini-loop budget (maxReal), under
// that scenario's infra. A homepage scenario that can't complete would be a fake demo.
//
// Replicates the app's model exactly (constants + rules mirrored from sim/index.html and
// sim-worker.js — keep in sync if those change):
//   cast (route people + anchored + extras), movement (routes.json polylines, bounce),
//   hasCell/apOf/apRadio/apNet with power/isp/sat components, linkInfo (RANGE + SOAK, relay star),
//   the worker's 45-tick relay warmup (prekey gossip), and the app's tick cadence
//   (one mesh.tick per ~100ms REAL → 0.1 × speed sim-seconds per tick).
//
// Run: node sim/scenario-check.mjs [scenarioId ...] [--appboot] [--jitter=SEED]
//   --appboot     fire every non-reply send on the FIRST tick (the app's clock races ahead during
//                 worker boot, so initial sends all land at once at worker-ready)
//   --jitter=N    seeded per-tick timing noise (±35%) + occasional hidden-tab stalls (6x gaps,
//                 sub-tick cap mirrored) — the browser's real cadence is never uniform
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { createRequire } from 'module';
import { makeMesh } from './mesh.js';
import { makeMapBridge } from './store-bridge.js';
import { SCENARIOS } from './scenarios.js';
// SINGLE source of truth for transport + geography constants and the pure helpers. sim-worker.js
// imports the SAME module, so the worker and this validator can no longer drift. index.html still
// inlines its own copies (one monolithic file); driftCheck() below greps them out and fails if they
// diverge from these values — so all three copies stay pinned.
import { RANGE, SOAK, RELAY_ID, SPEED, RKEYS, TOWERS, APS, djb, rnd01, areaSpot, hav } from './sim-constants.js';

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const { WasmNode } = require(join(here, '../core/hop-wasm/pkg-node/hop_wasm.js'));
const ROUTES_GEOM = JSON.parse(readFileSync(join(here, 'routes.json'), 'utf8'));

// ---- geometry ----
function buildLine(coords) {                        // cumulative-distance polyline for along-line lookup
  const cum = [0]; for (let i = 1; i < coords.length; i++) cum.push(cum[i - 1] + hav(coords[i - 1], coords[i]));
  return { coords, cum, lenKm: cum[cum.length - 1] / 1000 };
}
function along(line, km) {                          // point `km` along the line (clamped)
  const m = Math.max(0, Math.min(km * 1000, line.cum[line.cum.length - 1]));
  let i = 1; while (i < line.cum.length && line.cum[i] < m) i++;
  if (i >= line.coords.length) return line.coords[line.coords.length - 1].slice();
  const a = line.coords[i - 1], b = line.coords[i], seg = line.cum[i] - line.cum[i - 1];
  const f = seg > 0 ? (m - line.cum[i - 1]) / seg : 0;
  return [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f];
}
const LINES = Object.fromEntries(Object.entries(ROUTES_GEOM).map(([k, c]) => [k, buildLine(c)]));

// djb / rnd01 / areaSpot / hav are imported from sim-constants.js (shared with sim-worker.js).

// ---- cast, mirrored from cast() in index.html (stage-aware) ----
function buildCast(scen) {
  if (scen.stage && scen.stage.cast) {                 // staged scenario: its own cast on its own geography
    const st = scen.stage, C = [];
    for (const [name, spec] of Object.entries(st.routes || {}))
      if (!LINES[name]) LINES[name] = buildLine(ROUTES_GEOM[name] || spec);   // baked, or raw waypoint line (ski runs)
    st.cast.forEach((x, i) => { const plat = i % 2 ? 'ios' : 'android';
      const p = { id: x.id, platform: plat, bt: true, wifiP2P: (plat === 'ios'), cell: x.cell === true, wifiKeys: [] };
      if (x.ap != null) { const a = st.aps[x.ap]; const d = Math.min(a.r * 0.45, 20), th = x.ap * 1.9;
        p.anchored = true; p.pos = [a.pos[0] + (d * Math.sin(th)) / 87800, a.pos[1] + (d * Math.cos(th)) / 111000];
        if (!a.pub) p.wifiKeys = [a.key]; }
      else if (x.pos) { p.anchored = true; p.pos = x.pos.slice(); }
      else if (x.at) { p.anchored = true; p.area = x.at; p.pos = areaSpot(st.areas[x.at], p.id, 0); }
      else if (x.wander) { p.wander = x.wander; p.dwell = x.dwell || [30, 90]; p.mode = x.mode || 'walk'; p.visit = 0;
        p.area = x.wander[0]; p.pos = areaSpot(st.areas[p.area], p.id, 0); p.phase = 'dwell'; p.dwellUntil = 0; }
      else { p.route = x.route; const g = LINES[x.route]; p.len = g.lenKm;
        if (x.frac != null) { p.frac = x.frac; p.pos = along(g, x.frac * g.lenKm); }
        else { p.mode = x.mode || 'walk'; p.prog = (x.off || 0) * g.lenKm; p.dir = 1; p.pos = along(g, p.prog); if (x.seg) p.seg = x.seg; } }
      if (x.lora) p.lora = x.lora;
      C.push(p); });
    return C;
  }
  const C = [];
  RKEYS.forEach(rt => {
    C.push({ id: rt + 'A', route: rt, frac: 0.08 });
    C.push({ id: rt + 'B', route: rt, frac: 0.92 });
    C.push({ id: rt + 'bus', route: rt, mode: 'drive', off: 0.00 });
    C.push({ id: rt + 'car', route: rt, mode: 'drive', off: 0.50 });
  });
  C.forEach((p, i) => { p.platform = i % 2 ? 'ios' : 'android'; p.bt = true; p.wifiP2P = (p.platform === 'ios');
    p.cell = (i % 3 !== 0); p.wifiKeys = [['office', 'home1', 'home2'][i % 3]]; });
  APS.forEach((a, ai) => {
    const d = Math.min(a.r * 0.45, 20), th = ai * 1.9;
    const pos = [a.pos[0] + (d * Math.sin(th)) / 87800, a.pos[1] + (d * Math.cos(th)) / 111000];
    C.push({ id: 'at' + ai, anchored: true, pos, platform: ai % 2 ? 'ios' : 'android', bt: true,
      wifiP2P: (ai % 2 === 1), cell: false, wifiKeys: a.pub ? [] : [a.key] });
  });
  for (const x of (scen.extras || []))
    C.push({ id: x.id, route: x.route, mode: x.mode || 'walk', off: x.off || 0,
      platform: 'android', bt: true, wifiP2P: false, cell: false, wifiKeys: [] });
  // place on routes
  for (const p of C) { if (!p.route) continue; const g = LINES[p.route]; p.len = g.lenKm;
    if (p.frac != null) p.pos = along(g, p.frac * g.lenKm);
    else { p.prog = (p.off || 0) * g.lenKm; p.dir = 1; p.pos = along(g, p.prog); } }
  return C;
}

// ---- one scenario run ----
function runScenario(id, scen) {
  const infra = scen.infra, powerUp = infra.power !== false, ispUp = infra.isp !== false,
    satUp = infra.sat !== false, cellOn = infra.cell === true;
  const stage = scen.stage;
  const towers = stage ? (stage.towers || []) : TOWERS;   // staged scenarios bring their own infrastructure
  const aps = stage ? (stage.aps || []) : APS;
  const people = buildCast(scen);
  const byId = Object.fromEntries(people.map(p => [p.id, p]));

  const apRadio = a => !!(a.on !== false && (powerUp || a.bat));
  const apNet = a => !!(a && apRadio(a) && ((a.sat && satUp) || ispUp));
  const hasCell = p => !!(p.cell && powerUp && cellOn && towers.some(t => hav(p.pos, t.pos) <= t.r));
  const apOf = p => { let best = null, bd = Infinity;
    for (const a of aps) { if (!apRadio(a)) continue; if (!a.pub && !(p.wifiKeys && p.wifiKeys.includes(a.key))) continue;
      const d = hav(p.pos, a.pos); if (d <= a.r && d < bd) { bd = d; best = a; } }
    return best; };

  const mesh = makeMesh(WasmNode, () => makeMapBridge());
  for (const p of people) mesh.add(p.id, seedFor(people.indexOf(p)));
  mesh.add(RELAY_ID, seedFor(900));
  const ids = people.map(p => p.id).concat([RELAY_ID]);

  if (scen.stage && scen.stage.channel) {   // group channel: key handshakes ride the warmup (worker-identical)
    const ch = scen.stage.channel; mesh.setupChannel(ch.host, ch.path, ch.members);
  }
  // worker-identical warmup: 45 ticks of instant relay links so prekeys gossip (pre-disaster contact;
  // under congestion everyone attached BEFORE the crowd peaked — the jam severs the relay below).
  const warmIn = (a, b) => (a === RELAY_ID || b === RELAY_ID) ? 0 : -1;
  let t = 0; for (let k = 0; k < 45; k++) { t += 100; mesh.tick(t, ids, warmIn); }

  // per-tick state, mirroring postTick + the worker's linkInfo
  let st = {};
  const computeState = () => { st = {}; for (const p of people) { const ap = apOf(p);
    st[p.id] = { c: hasCell(p) || apNet(ap), ap: ap ? (ap.net || ap.name) : null }; } };
  const congested = !!scen.congested;   // cell up but oversubscribed → the backbone is unusable
  const linkInfo = (a, b) => {
    if (a === RELAY_ID) return (!congested && st[b] && st[b].c) ? SOAK.relay : -1;
    if (b === RELAY_ID) return (!congested && st[a] && st[a].c) ? SOAK.relay : -1;
    const A = byId[a], B = byId[b]; if (!A || !B) return -1;
    const d = hav(A.pos, B.pos);
    if (A.bt && B.bt && d <= RANGE.ble) return SOAK.ble;
    if (A.wifiP2P && B.wifiP2P && A.platform === B.platform && d <= RANGE.wifi) return SOAK.wifi;
    if (st[a] && st[b] && st[a].ap && st[a].ap === st[b].ap) return SOAK.ap;
    if (A.lora && A.lora === B.lora) return SOAK.lora;   // Hop Bridges bonded by a sub-GHz net
    return -1;
  };

  // app cadence: one mesh.tick per ~100ms real → dt = 0.1 × speed sim-seconds
  const speed = scen.speed || 24, baseDt = 0.1 * speed, budgetSim = (scen.maxReal || 120) * speed;
  const rand = JITTER != null ? mulberry32(JITTER * 7919 + id.length) : null;
  // FULL script array (send + narr events) — `after: k` fires `at` sim-s after script event k's
  // send is DELIVERED (multi-turn replies), exactly like pumpScenario in the app.
  const script = (scen.script || []).map(e => ({ ...e }));
  const evSends = [];   // script index → send record
  const sends = [];     // {bundle, from, to, sentSim, deliveredSim, ackedSim}
  const acked = new Set();
  let simT = 0, chatterNext = 0, chatterN = 0;
  while (simT < budgetSim) {
    // browser cadence is never uniform: ±35% tick noise, and ~1.5% of ticks are hidden-tab stalls
    const dtSim = rand ? (rand() < 0.015 ? baseDt * 6 : baseDt * (0.65 + 0.7 * rand())) : baseDt;
    simT += dtSim;
    for (const p of people) if (p.wander) {   // SWARM: dwell at an area, then walk straight to the next
      if (p.phase === 'moving') {
        const dm = hav(p.pos, p.target), stepM = SPEED[p.mode] * dtSim;
        if (dm <= stepM) { p.pos = p.target.slice(); p.area = p.destArea; p.phase = 'dwell';
          p.dwellUntil = simT + p.dwell[0] + rnd01(djb(p.id), p.visit * 2 + 5) * (p.dwell[1] - p.dwell[0]); }
        else { const f = stepM / dm; p.pos = [p.pos[0] + (p.target[0] - p.pos[0]) * f, p.pos[1] + (p.target[1] - p.pos[1]) * f]; }
      } else if (simT >= p.dwellUntil) {
        p.visit++;
        const opts = p.wander.filter(a2 => a2 !== p.area);
        p.destArea = opts.length ? opts[Math.floor(rnd01(djb(p.id), p.visit * 2 + 3) * opts.length) % opts.length] : p.wander[0];
        p.target = areaSpot(scen.stage.areas[p.destArea], p.id, p.visit);
        p.phase = 'moving';
      }
    }
    for (const p of people) if (p.mode && p.route) {   // movement: patrol the SEGMENT + linger at ends
      if (p.pauseUntil && simT < p.pauseUntil) continue;
      const lo = (p.seg ? p.seg[0] : 0) * p.len, hi = (p.seg ? p.seg[1] : 1) * p.len;
      p.prog += p.dir * (SPEED[p.mode] / 1000) * dtSim;
      if (p.dwellSalt == null) { let hh = 5381; for (const c of p.id) hh = (hh * 33 + c.charCodeAt(0)) >>> 0; p.dwellSalt = hh % 97; }
      if (p.prog >= hi) { p.prog = hi; p.dir = -1; p.bounces = (p.bounces || 0) + 1; p.pauseUntil = simT + 4 + (((p.bounces * 2654435761 + p.dwellSalt * 131) >>> 0) % 23); }
      else if (p.prog <= lo) { p.prog = lo; p.dir = 1; p.bounces = (p.bounces || 0) + 1; p.pauseUntil = simT + 4 + (((p.bounces * 2654435761 + p.dwellSalt * 131) >>> 0) % 23); }
      p.pos = along(LINES[p.route], p.prog);
    }
    if (scen.chatter) {
      if (chatterNext === 0) chatterNext = simT + scen.chatter * 0.5;
      if (simT >= chatterNext) {
        chatterNext = simT + scen.chatter * (0.5 + rnd01(1337, ++chatterN));
        const pool = people;
        if (pool.length > 2) { const a2 = pool[Math.floor(rnd01(7331, chatterN * 2) * pool.length) % pool.length];
          const b2 = pool[Math.floor(rnd01(9973, chatterN * 2 + 1) * pool.length) % pool.length];
          if (b2 !== a2) { try { mesh.send(a2.id, b2.id, 'chatter ' + chatterN); } catch (_) {} } }
      }
    }
    script.forEach((ev, i) => {
      if (ev._fired) return;
      const due = ev.after != null
        ? (evSends[ev.after] && evSends[ev.after].deliveredSim != null && simT >= evSends[ev.after].deliveredSim + (ev.at || 0))
        : (APPBOOT || simT >= ev.at);
      if (!due) return;
      ev._fired = true;
      if (ev.publish) {   // ONE post, every member receives it (group fan-out)
        const p = ev.publish, members = ((scen.stage || {}).channel || {}).members || [];
        const rec = { kind: 'pub', bundle: mesh.publish(p.from, p.path, p.text), from: p.from, to: '#' + p.path,
          text: p.text, recips: members.filter(x => x !== p.from).length, gotSet: new Set(), sentSim: simT };
        sends.push(rec); evSends[i] = rec; return;
      }
      if (!ev.send) return;
      const s = ev.send;
      if (!byId[s.from] || !byId[s.to]) throw new Error(`${id}: unknown cast id ${s.from}→${s.to}`);
      const rec = { bundle: mesh.send(s.from, s.to, s.text), from: s.from, to: s.to, text: s.text, sentSim: simT };
      sends.push(rec); evSends[i] = rec;
    });
    computeState();
    // mirror the worker's SUB-TICK: slice big sim-time jumps into ≤2.5s steps so soak can mature
    { const target = Math.round(simT * 1000), from = Math.round((simT - dtSim) * 1000);
      const n = Math.min(8, Math.max(1, Math.ceil((target - from) / 2500)));
      for (let i = 1; i <= n; i++) mesh.tick(Math.round(from + (target - from) * i / n), ids, linkInfo); }
    // match deliveries like the APP does — by (from, to, text), not bundle id: a DEFERRED send
    // (recipient's prekey not yet gossiped, real hop-core behavior) is re-created with a different
    // wire id when it flushes, but the ack still comes home under the display id.
    for (const d of mesh.deliveries) {
      const rec = sends.find(x => x.deliveredSim == null && x.from === d.from && x.to === d.to && x.text === d.text);
      if (rec) { rec.deliveredSim = simT; rec.hops = d.hops; }   // real wire hops (env.hops), not path reconstruction
    }
    for (const h of mesh.hpsDeliveries.splice(0)) {   // channel fan-out receipts: complete when EVERY member has it
      const rec = sends.find(x => x.kind === 'pub' && x.text === h.text && '#' + h.path === x.to);
      if (rec && rec.deliveredSim == null) { rec.gotSet.add(h.to);
        if (rec.gotSet.size >= rec.recips) { rec.deliveredSim = simT; rec.ackedSim = simT; } }
    }
    for (const h of mesh.senderAcks.splice(0)) acked.add(h);
    for (const rec of sends) if (rec.ackedSim == null && acked.has(rec.bundle)) rec.ackedSim = simT;
    if (process.env.DBG2 && Math.round(simT) % 500 < dtSim) {
      const st2 = mesh.statusMap();
      for (const rec of sends) if (!rec.kind) console.log('  DBG2 t=' + Math.round(simT), rec.from + '→' + rec.to,
        'status:', JSON.stringify(st2[rec.bundle] || null), 'ackSeen:', acked.has(rec.bundle), 'allAcks:', acked.size);
    }
    if (script.every(e => e._fired) && sends.length && sends.every(x => x.ackedSim != null)) break;
  }
  // every scripted send must be a real RELAY chain (≥ minHops hops), not one carrier walking end to end
  const minHops = scen.minHops != null ? scen.minHops : 2;
  const hopsOk = sends.every(x => x.hops == null || x.hops >= minHops);
  if (process.env.DBG3) { const pairs = new Set();
    for (const lg of mesh.legs) if (sends.some(x => x.bundle === lg.bundle)) pairs.add(lg.from + '→' + lg.to);
    console.log('  DBG3 unique legs:', [...pairs].join(' '), '| total legs:', mesh.legs.length); }
  const ok = script.every(e => e._fired) && sends.length > 0 && sends.every(x => x.ackedSim != null) && hopsOk;
  return { ok, minHops, sends: sends.map(x => ({ from: x.from, to: x.to, hops: x.hops,
    deliveredReal: x.deliveredSim != null ? +((x.deliveredSim - x.sentSim) / speed).toFixed(1) : null,
    ackedReal: x.ackedSim != null ? +((x.ackedSim - x.sentSim) / speed).toFixed(1) : null })),
    usedReal: +(simT / speed).toFixed(1), budgetReal: scen.maxReal || 120 };
}
function seedFor(i) { const s = new Uint8Array(32); s[0] = (i + 1) & 0xff; s[1] = ((i + 1) >> 8) & 0xff; s[2] = 0xa5; s[3] = 0x5a; return s; }

// ---- main ----
const argv = process.argv.slice(2);
const APPBOOT = argv.includes('--appboot');
const JITTER = (() => { const a = argv.find(x => x.startsWith('--jitter=')); return a ? parseInt(a.split('=')[1], 10) : null; })();
function mulberry32(seed) { let a = seed >>> 0; return () => { a |= 0; a = (a + 0x6D2B79F5) | 0;
  let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }
// ---- drift check: index.html inlines its own copies of these constants/helpers (one monolithic file
// that can't easily import ES modules mid-render). Assert those inlined copies still MATCH the shared
// sim-constants.js this validator runs against — otherwise the checker could pass while the deployed
// site uses different ranges/soaks/geometry (exactly the silent divergence this checker exists to catch).
function driftCheck() {
  const html = readFileSync(join(here, 'index.html'), 'utf8');
  const norm = s => s.replace(/\s+/g, '');   // whitespace-insensitive literal match
  const H = norm(html);
  const problems = [];
  const need = (label, snippet) => { if (!H.includes(norm(snippet))) problems.push(label); };

  // SPEED object (m/s of sim time)
  need('SPEED', `const SPEED={walk:${SPEED.walk},drive:${SPEED.drive},bike:${SPEED.bike}};`);
  // RKEYS is derived from ROUTES in index.html; assert the route set matches ours.
  for (const k of RKEYS) need(`ROUTE:${k}`, `${k}:[[`);
  // TOWERS: count + a representative first/last coordinate + radius.
  need('TOWERS.count', `r:${TOWERS[TOWERS.length - 1].r}}`);
  need('TOWERS.first', `pos:[${TOWERS[0].pos[0]},${TOWERS[0].pos[1]}],r:${TOWERS[0].r}`);
  // APS: names + the pub/key flags that the link model keys off.
  for (const a of APS) {
    need(`AP:${a.name}`, `name:'${a.name}'`);
    if (a.key) need(`AP.key:${a.name}`, `key:'${a.key}'`);
  }
  // pure helpers — the exact expressions the harness re-uses.
  need('djb', `let h=5381; for(const c of id) h=(h*33+c.charCodeAt(0))>>>0;`);
  need('rnd01', `((((salt+n*2654435761)^(salt<<7))>>>0)%10000)/10000`);
  need('areaSpot', `rad=4+rnd01(salt,visit*2+2)*11`);

  // sim-worker.js must now IMPORT the transport constants (not redefine them), so its copy can't drift.
  const worker = readFileSync(join(here, 'sim-worker.js'), 'utf8');
  if (!/from ['"]\.\/sim-constants\.js['"]/.test(worker)) problems.push('worker: not importing sim-constants.js');
  if (/const\s+RANGE\s*=/.test(worker) || /const\s+SOAK\s*=/.test(worker)) problems.push('worker: still defines its own RANGE/SOAK');

  return problems;
}
const drift = driftCheck();
if (drift.length) {
  console.log(`❌ DRIFT: sim/index.html (or sim-worker.js) no longer matches sim/sim-constants.js — ${drift.join(', ')}`);
  console.log('   Update the inlined copies in index.html (or re-import in sim-worker.js) to match sim-constants.js.');
  process.exit(1);
}

const only = argv.filter(x => !x.startsWith('--'));
// comingSoon stages verify too — their scripts only exercise what IS real (e.g. lora's local BLE hop).
const entries = Object.entries(SCENARIOS).filter(([k]) => !only.length || only.includes(k));
let fail = 0;
for (const [id, scen] of entries) {
  const t0 = Date.now();
  let r;
  try { r = runScenario(id, scen); } catch (e) { r = { ok: false, error: e.message }; }
  const cpu = ((Date.now() - t0) / 1000).toFixed(1);
  if (r.ok) {
    const det = r.sends.map(s => `${s.from}→${s.to} ${s.hops!=null?s.hops+'h ':''}deliver ${s.deliveredReal}s ack ${s.ackedReal}s`).join(' · ');
    console.log(`✅ ${id.padEnd(11)} completes in ${String(r.usedReal).padStart(5)}s real (budget ${r.budgetReal}s) — ${det}  [cpu ${cpu}s]`);
  } else {
    fail++;
    const det = r.error || r.sends.map(s => `${s.from}→${s.to} ${s.hops!=null?s.hops+'h ':''}deliver ${s.deliveredReal ?? '—'} ack ${s.ackedReal ?? '—'}`).join(' · ');
    console.log(`❌ ${id.padEnd(11)} DID NOT complete within ${r.budgetReal ?? '?'}s real — ${det}  [cpu ${cpu}s]`);
  }
}
console.log(fail ? `\n${fail}/${entries.length} scenarios FAILED` : `\nall ${entries.length} scenarios complete ✓`);
process.exit(fail ? 1 : 0);
