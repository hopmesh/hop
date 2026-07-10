#!/usr/bin/env node
// Invariant tests for mockups/swarm.html's sim core (run: node mockups/swarm.test.js).
//
// The street-network rewrite exists so devices move like people and vehicles:
// along streets, never through buildings. These tests extract the DOM-free
// SWARM core out of the HTML and drive it for thousands of ticks across many
// regenerated worlds, asserting exactly that:
//   1. the street graph is fully connected (routing can never strand anyone)
//   2. buildings keep their setback from every street (per-street widths)
//   3. every Wi-Fi zone covers its four corner street nodes
//   4. at every tick, every device CENTER is on a street centerline (<=1px)
//   5. at every tick, no device center is inside any building
//   6. at every tick, the RENDERED position (sidewalk / lane offset applied)
//      also clears every building, and walkers actually sit off the asphalt
//   7. dwellers are pinned to their recorded street edge, and zone-goers
//      finish inside the zone they walked to
//   8. all of the above survive a mid-sim resize with NO rebuild (the exact
//      code path the browser's resize handler takes)
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const html = fs.readFileSync(path.join(__dirname, 'swarm.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const sandbox = { module: { exports: {} }, console };
vm.createContext(sandbox);
vm.runInContext(script, sandbox);
const S = sandbox.module.exports;

let checks = 0, failures = 0;
function assert(cond, msg) {
  checks++;
  if (!cond) { failures++; console.error('FAIL: ' + msg); }
}

function connected() {
  const seen = new Set([0]), q = [0];
  while (q.length) { const u = q.shift(); for (const v of S.world.adj[u]) if (!seen.has(v)) { seen.add(v); q.push(v); } }
  return seen.size === S.world.nodes.length;
}

// px distance from point p to the nearest street centerline segment
function distToStreets(p) {
  const { W, H } = S.view;
  const x0 = S.world.vs[0].pos * W, x1 = S.world.vs[S.world.vs.length - 1].pos * W;
  const y0 = S.world.hs[0].pos * H, y1 = S.world.hs[S.world.hs.length - 1].pos * H;
  let best = Infinity;
  for (const s of S.world.vs) {
    const dx = Math.abs(p.x - s.pos * W);
    const dy = p.y < y0 ? y0 - p.y : p.y > y1 ? p.y - y1 : 0;
    best = Math.min(best, Math.hypot(dx, dy));
  }
  for (const s of S.world.hs) {
    const dy = Math.abs(p.y - s.pos * H);
    const dx = p.x < x0 ? x0 - p.x : p.x > x1 ? p.x - x1 : 0;
    best = Math.min(best, Math.hypot(dx, dy));
  }
  return best;
}

function insideBuilding(p, shrinkPx) {
  const { W, H } = S.view;
  for (const b of S.world.buildings) {
    const x = b.x * W + shrinkPx, y = b.y * H + shrinkPx;
    const w = b.w * W - 2 * shrinkPx, h = b.h * H - 2 * shrinkPx;
    if (p.x > x && p.x < x + w && p.y > y && p.y < y + h) return b;
  }
  return null;
}

// buildings must clear every street by that street's half-width + sidewalk
function assertSetbacks(tag) {
  const { W, H } = S.view;
  for (const b of S.world.buildings) {
    const bx0 = b.x * W, bx1 = (b.x + b.w) * W, by0 = b.y * H, by1 = (b.y + b.h) * H;
    for (const s of S.world.vs) {
      const sx = s.pos * W, clearAt = s.w / 2 + S.SIDEWALK - 1;
      assert(bx1 < sx - clearAt || bx0 > sx + clearAt,
        `${tag}: building [${bx0.toFixed(0)}..${bx1.toFixed(0)}] under-setback at vertical street @${sx.toFixed(0)}`);
    }
    for (const s of S.world.hs) {
      const sy = s.pos * H, clearAt = s.w / 2 + S.SIDEWALK - 1;
      assert(by1 < sy - clearAt || by0 > sy + clearAt,
        `${tag}: building [${by0.toFixed(0)}..${by1.toFixed(0)}] under-setback at horizontal street @${sy.toFixed(0)}`);
    }
  }
}

const VIEWS = [[1124, 600], [1124, 600], [1124, 600], [1124, 600], [860, 480], [1400, 720]];
for (let w = 0; w < VIEWS.length; w++) {
  S.setView(VIEWS[w][0], VIEWS[w][1]);
  S.buildWorld();
  const tag = `world ${w} (${VIEWS[w][0]}x${VIEWS[w][1]})`;

  assert(connected(), `${tag}: street graph must be connected`);
  assert(S.world.buildings.length >= 14, `${tag}: expected a real city (got ${S.world.buildings.length} buildings)`);
  assert(S.world.zones.length === 3, `${tag}: expected 3 Wi-Fi zones`);
  assert(S.world.vs.some(s => s.w > 14) && S.world.hs.some(s => s.w > 14), `${tag}: expected an avenue each way`);
  assertSetbacks(tag);

  // each zone's AP coverage reaches its 4 corner street nodes (radius model)
  S.world.zones.forEach((z, zi) => {
    const corners = S.world.nodes.filter(n =>
      (n.i === z.bi || n.i === z.bi + 1) && (n.j === z.bj || n.j === z.bj + 1));
    assert(corners.length === 4, `${tag}: zone ${z.label} should touch 4 street nodes`);
    for (const c of corners) assert(S.zoneCovers(zi, S.P(c)), `${tag}: zone ${z.label} coverage must reach its corner nodes`);
  });

  // routing sanity: every node reachable with a finite street distance
  assert(S.dijkstra(0).dist.every(Number.isFinite), `${tag}: dijkstra must reach every node`);

  // spawn orientation: the FIRST paint must already have walkers displaced
  // laterally onto their sidewalk and cars aligned with their street (the
  // hardcoded-heading bug rendered half the swarm mid-road, cars broadside)
  for (const d of S.devices) {
    const A = S.P(S.world.nodes[d.at.a]), B = S.P(S.world.nodes[d.at.b]);
    const len = Math.hypot(B.x - A.x, B.y - A.y) || 1;
    const ex = (B.x - A.x) / len, ey = (B.y - A.y) / len;
    const c = S.P(d), rp = S.renderPos(d);
    const dx = rp.x - c.x, dy = rp.y - c.y;
    const along = Math.abs(dx * ex + dy * ey), lateral = Math.abs(dx * -ey + dy * ex);
    assert(along < 0.5, `${tag}: spawn ${d.id} (${d.kind}) offset runs ALONG its street (${along.toFixed(1)}px)`);
    const half = S.roadHalf(d.at.a, d.at.b);
    if (d.kind === 'walker') assert(lateral > half + 1.4, `${tag}: spawn walker ${d.id} on the asphalt (lat=${lateral.toFixed(1)} half=${half})`);
    else assert(lateral > half * 0.4, `${tag}: spawn vehicle ${d.id} not in a lane (lat=${lateral.toFixed(1)})`);
    assert(Math.abs(Math.hypot(d.hx, d.hy) - 1) < 1e-6, `${tag}: spawn ${d.id} heading not unit-length`);
  }

  // px distance from a point to a polyline (for the message-on-leg invariant)
  const distToPoly = (p, pts) => {
    let best = Infinity;
    for (let i = 1; i < pts.length; i++) {
      const ax = pts[i - 1].x, ay = pts[i - 1].y, bx = pts[i].x, by = pts[i].y;
      const dx = bx - ax, dy = by - ay, len2 = dx * dx + dy * dy;
      const t = len2 > 0 ? Math.max(0, Math.min(1, ((p.x - ax) * dx + (p.y - ay) * dy) / len2)) : 0;
      best = Math.min(best, Math.hypot(p.x - (ax + dx * t), p.y - (ay + dy * t)));
    }
    return best;
  };

  // movement invariants every tick; halfway through, the view RESIZES without
  // a rebuild (exactly what the browser's resize handler does)
  const prevRp = new Map();
  const msgTrack = new Map();
  const runTicks = (n, phase) => {
    prevRp.clear();
    for (let t = 0; t < n; t++) {
      S.update(1 / 60);
      // message invariants: a rider is pinned to its holder, a hop pulse is on
      // its leg's polyline, holders only advance to the planned next hop, and
      // soak means every carrying edge aged past its threshold
      for (const m of S.messages) {
        assert(['riding', 'hopping', 'done'].includes(m.state), `${tag} ${phase} t=${t}: msg ${m.id} bad state ${m.state}`);
        assert(m.trail.length <= 240, `${tag} ${phase} t=${t}: msg ${m.id} trail unbounded`);
        const tr = msgTrack.get(m.id);
        if (tr && m.holder !== tr.holder) {
          assert(tr.leg && m.holder === tr.leg.v, `${tag} ${phase} t=${t}: msg ${m.id} teleported holder ${tr.holder}->${m.holder}`);
          assert(m.hops === tr.hops + 1, `${tag} ${phase} t=${t}: msg ${m.id} hop count skipped`);
        }
        msgTrack.set(m.id, { holder: m.holder, leg: m.leg, hops: m.hops });
        if (m.state === 'riding') {
          const hp = S.renderPos(S.devices[m.holder]);
          assert(Math.hypot(m.pos.x - hp.x, m.pos.y - hp.y) < 1, `${tag} ${phase} t=${t}: rider ${m.id} not on its holder`);
        } else if (m.state === 'hopping') {
          assert(distToPoly(m.pos, S.msgLegPoints(m.leg)) < 1.5, `${tag} ${phase} t=${t}: msg ${m.id} pulse off its leg`);
        } else {
          assert(m.holder === m.to, `${tag} ${phase} t=${t}: msg ${m.id} done but not at recipient`);
        }
      }
      if (t % 30 === 0) {
        for (const e of S.edges) {
          const need = e.kind === 'ble' ? S.SOAK_BLE : S.SOAK_WIFI;
          assert(e.ready === (e.age >= need), `${tag} ${phase} t=${t}: edge ${e.i}-${e.j} soak flag wrong (age=${e.age.toFixed(2)})`);
          if (e.kind === 'ble') {
            const a = S.renderPos(S.devices[e.i]), b = S.renderPos(S.devices[e.j]);
            assert(Math.hypot(a.x - b.x, a.y - b.y) <= S.BLE_R + 0.5, `${tag} ${phase} t=${t}: BLE edge beyond best-case range`);
          }
        }
      }
      for (const d of S.devices) {
        const p = S.P(d);
        const street = distToStreets(p);
        if (street > 1) {
          assert(false, `${tag} ${phase} t=${t}: device ${d.id} (${d.kind}) center off-street by ${street.toFixed(1)}px`);
          break;
        }
        if (insideBuilding(p, 0.5)) {
          assert(false, `${tag} ${phase} t=${t}: device ${d.id} (${d.kind}) center INSIDE a building`);
          break;
        }
        // the RENDERED position (offset applied) must clear buildings too
        const rp = S.renderPos(d);
        if (insideBuilding(rp, -0.25)) {
          assert(false, `${tag} ${phase} t=${t}: device ${d.id} (${d.kind}) RENDERS inside a building`);
          break;
        }
        // renderPos continuity: no sidewalk-mirroring teleports; one frame may
        // move at most travel + easing (bounded well under 9px)
        const prev = prevRp.get(d.id);
        if (prev) {
          const jump = Math.hypot(rp.x - prev.x, rp.y - prev.y);
          assert(jump < 9, `${tag} ${phase} t=${t}: device ${d.id} (${d.kind}) rendered ${jump.toFixed(1)}px jump in one frame`);
        }
        prevRp.set(d.id, rp);
        // walkers' sidewalk target is genuinely off the asphalt of their street
        if (d.kind === 'walker') {
          const half = S.roadHalf(d.seg.a, d.seg.b);
          assert(Math.abs(d.offT) > half + 2, `${tag} ${phase} t=${t}: walker ${d.id} target on the asphalt (|offT|=${Math.abs(d.offT).toFixed(1)} vs half=${half})`);
        }
        // vehicles yield BEFORE the crossing, never inside the junction box
        if (d.kind === 'vehicle' && d.pause > 0 && d.path.length && d.path[0].node >= 0) {
          const node = S.P(S.world.nodes[d.path[0].node]);
          const dist = Math.hypot(node.x - p.x, node.y - p.y);
          assert(dist > 12, `${tag} ${phase} t=${t}: vehicle ${d.id} yielding INSIDE the intersection (${dist.toFixed(1)}px from node)`);
        }
        if (d.state === 'dwell') {
          const at = S.P(S.edgePoint(d.at.a, d.at.b, d.at.t));
          assert(Math.hypot(at.x - p.x, at.y - p.y) < 1, `${tag} ${phase} t=${t}: device ${d.id} not at its d.at edge point`);
          if (d.zoneTarget) assert(S.zoneOf(d) >= 0, `${tag} ${phase} t=${t}: zone-target device ${d.id} dwelling outside any zone`);
        }
      }
      // what is DRAWN is what was TESTED: every live BLE edge's rendered
      // segment must itself clear every building (sampled for cost)
      if (t % 15 === 0) {
        const E = S.computeEdges({ ble: true, wifi: false, net: false });
        for (const e of E) {
          const a = S.renderPos(S.devices[e.i]), b = S.renderPos(S.devices[e.j]);
          assert(S.bleClear(a, b), `${tag} ${phase} t=${t}: BLE link ${e.i}-${e.j} DRAWN through a building`);
        }
      }
      if (failures > 10) break;
    }
  };
  const TICKS = 60 * 60;
  runTicks(TICKS / 2, 'pre-resize');
  S.setView(VIEWS[w][0] * 0.62, VIEWS[w][1] * 0.9);    // shrink mid-sim, NO rebuild
  assertSetbacks(tag + ' post-resize');
  runTicks(TICKS / 2, 'post-resize');
  S.setView(VIEWS[w][0], VIEWS[w][1]);
  if (failures > 10) { console.error('aborting: too many failures'); break; }

  // link-layer smoke: a building blocks BLE line of sight; open street is clear
  {
    const { W, H } = S.view;
    const bld = S.world.buildings[0];
    const cy = (bld.y + bld.h / 2) * H;
    const a = { x: bld.x * W - 8, y: cy }, b = { x: (bld.x + bld.w) * W + 8, y: cy };
    assert(!S.bleClear(a, b), `${tag}: BLE must NOT pass through a building`);
    const y0 = S.world.hs[0].pos * H;
    assert(S.bleClear({ x: S.world.vs[0].pos * W + 20, y: y0 }, { x: S.world.vs[0].pos * W + 60, y: y0 }),
      `${tag}: BLE along an open street must be clear`);
  }
  // reach: BFS component includes the start; the UI shows size-1 as "others"
  {
    const adj = Array.from({ length: 3 }, () => []);
    adj[0].push(1); adj[1].push(0);
    const r = S.reachFrom(0, adj);
    assert(r.size === 2 && !r.has(2), `${tag}: reachFrom component math`);
  }

  const moving = S.devices.filter(d => d.state === 'move').length;
  assert(moving > 0 || S.devices.some(d => d.dwell > 0), `${tag}: swarm should be alive`);

  // the point of the demo: messages actually get delivered, multi-hop
  assert(S.msgStats.delivered >= 1, `${tag}: expected at least one delivery in 60s (got ${S.msgStats.delivered})`);
}

// every use-case scenario builds a valid world and the same physics hold:
// devices on streets and out of buildings (center + rendered), messages in
// valid states, and (except the sparse/degraded scenarios - the remote town and
// the disaster zone - where store-carry can legitimately take minutes and a fixed
// 45s window is not guaranteed) real deliveries happen
for (const key of Object.keys(S.SCENARIOS)) {
  S.setView(1124, 600);
  S.buildWorld(key);
  const sc = S.SCENARIOS[key];
  const tag = `scenario ${key}`;
  assert(S.scenario === sc, `${tag}: active scenario should switch`);
  assert(connected(), `${tag}: street graph connected`);
  assert(S.devices.length === sc.n, `${tag}: population ${S.devices.length} != ${sc.n}`);
  assert(S.world.zones.length <= sc.zones.length, `${tag}: too many zones`);
  assertSetbacks(tag);
  for (let t = 0; t < 60 * 45; t++) {
    S.update(1 / 60);
    if (t % 5) continue;                       // sample: full physics already proven above
    for (const d of S.devices) {
      if (distToStreets(S.P(d)) > 1) { assert(false, `${tag} t=${t}: device ${d.id} off-street`); break; }
      if (insideBuilding(S.P(d), 0.5)) { assert(false, `${tag} t=${t}: device ${d.id} in a building`); break; }
      if (insideBuilding(S.renderPos(d), -0.25)) { assert(false, `${tag} t=${t}: device ${d.id} renders in a building`); break; }
    }
    for (const m of S.messages) {
      assert(['riding', 'hopping', 'done'].includes(m.state), `${tag} t=${t}: msg ${m.id} bad state`);
      if (m.state === 'done') assert(m.holder === m.to, `${tag} t=${t}: msg ${m.id} done off-recipient`);
    }
    if (failures > 10) break;
  }
  // no-backbone scenarios must never bridge: with BLE+Wi-Fi off, nobody reaches anybody
  if (!sc.net) {
    const adj = S.adjacency(S.computeEdges({ ble: false, wifi: false, net: true }), { ble: false, wifi: false, net: true });
    assert(adj.every(a => a.length === 0), `${tag}: no-backbone scenario must have zero bridge links`);
  }
  // congested uplinks are present but useless: same zero-bridge property
  if (sc.zones.every(z => z.congested) && sc.zones.length) {
    const adj = S.adjacency(S.computeEdges({ ble: false, wifi: false, net: true }), { ble: false, wifi: false, net: true });
    assert(adj.every(a => a.length === 0), `${tag}: congested uplinks must not bridge`);
  }
  // The well-connected scenarios must deliver within the window; the sparse/degraded ones (remote,
  // disaster) are demos of store-carry over a broken mesh, where 0 deliveries in a fixed 45s is a
  // legitimate (marginal) outcome, so we do not gate on them.
  if (key !== 'remote' && key !== 'disaster') assert(S.msgStats.delivered >= 1, `${tag}: expected deliveries in 45s (got ${S.msgStats.delivered})`);
  if (failures > 10) break;
}

// phone-width canvas: buildWorld must terminate (no pickSpreadBlocks
// starvation) and still produce a connected, routable street grid
{
  S.setView(360, 600);
  S.buildWorld();
  assert(connected(), 'tiny view: street graph must be connected');
  assert(S.world.zones.length <= 3, 'tiny view: at most 3 zones');
  assert(S.devices.length > 0, 'tiny view: devices spawn');
  for (let t = 0; t < 240; t++) {
    S.update(1 / 60);
    for (const d of S.devices) {
      assert(distToStreets(S.P(d)) <= 1, `tiny view t=${t}: device ${d.id} off-street`);
      assert(!insideBuilding(S.P(d), 0.5), `tiny view t=${t}: device ${d.id} inside a building`);
    }
    if (failures > 10) break;
  }
}

console.log(`${checks} checks, ${failures} failures`);
process.exit(failures ? 1 : 0);
