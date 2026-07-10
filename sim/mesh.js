// Real hop-core swarm over a JS bearer shim.
//
// Environment-agnostic: pass in the `WasmNode` class (browser: from ./pkg/hop_wasm.js;
// Node: from ../core/hop-wasm/pkg-node/hop_wasm.js). Each person is a real hop-core node.
// A link between two people shares ONE link id on both ends (the proven pipe pattern).
// The map/DOM layer just reads mesh.legs (colored by real bundle) and mesh.deliveries.

const _enc = s => new TextEncoder().encode(s);
const _dec = b => new TextDecoder().decode(b);
const _hex = u => { let s = ''; for (const b of u) s += b.toString(16).padStart(2, '0'); return s; };

export function makeMesh(WasmNode, bridgeFor) {
  return {
    nodes: new Map(),      // id -> { node, addr }
    addrToId: new Map(),   // addrHex -> id
    links: new Map(),      // linkId -> { a, b }
    pairLink: new Map(),   // "a|b" -> linkId
    soaking: new Map(),    // "a|b" -> sim-ms they came in range (link forms only after the transport's soak)
    linkSeq: 1,
    legs: [],              // { from, to, bundle, at }  (recent real bundle transfers, the live relay web)
    parent: new Map(),     // bundle hex -> Map(toId -> fromId): who handed each bundle to whom
    deliveries: [],        // { to, from, bundle, text, path, at }  (path = the legs it actually took)
    delivered: new Set(),  // bundle hexes that reached their destination
    msgBundles: new Set(), // bundle hexes that are actual user messages (from send), the only ones we visualize
    senderAcks: [],        // bundle hexes the SENDER just confirmed delivered (via a returning ACK)
    beaconEvents: [],      // node ids that emitted a §39 recv-beacon this frame (for the ripple viz)
    hpsDeliveries: [],     // channel posts received: { to, path, text, from, at }
    lastPrune: 0,

    add(id, seed) {
      const node = new WasmNode(seed, bridgeFor(id));   // per-node host store (SQLite/OPFS or Map)
      node.set_observe(true);

      node.publish_prekey();
      const addr = node.address;
      this.nodes.set(id, { node, addr });
      this.addrToId.set(_hex(addr), id);
    },
    addrOf(id) { return this.nodes.get(id).addr; },
    // Group channel (hps://, §32): `host` registers it, every member subscribes. Called before the
    // warmup so the key handshakes ride the warmup contact.
    setupChannel(hostId, path, memberIds) {
      this.nodes.get(hostId).node.register_channel(path);
      const hostAddr = this.addrOf(hostId);
      for (const mid of memberIds) if (mid !== hostId) this.nodes.get(mid).node.channel_subscribe(hostAddr, path);
    },
    // ONE post, every member receives it, the real fan-out.
    publish(fromId, path, text) {
      const bid = this.nodes.get(fromId).node.channel_publish(path, _enc(text));
      const hex = _hex(bid); this.msgBundles.add(hex);
      return hex;
    },
    send(fromId, toId, text) {
      const bid = this.nodes.get(fromId).node.send(this.addrOf(toId), _enc(text));
      const hex = _hex(bid); this.msgBundles.add(hex);
      if (this.msgBundles.size > 400) this.msgBundles.delete(this.msgBundles.values().next().value); // cap
      return hex;
    },

    // Advance one bearer frame. `ids` = node ids to consider; `inRange(a,b)` = can they link now.
    tick(now, ids, linkInfo) {
      // 1) form / drop links as people move in and out of range, with a per-transport SOAK: a pair must
      //    stay in range for `soak` ms before the link is usable (BLE/Wi-Fi take real seconds to connect),
      //    so a fast passer-by may never link. linkInfo(a,b) → soak ms if connectable, else -1.
      for (let i = 0; i < ids.length; i++) for (let j = i + 1; j < ids.length; j++) {
        const a = ids[i], b = ids[j], key = a < b ? a + '|' + b : b + '|' + a;
        const soak = linkInfo(a, b), have = this.pairLink.has(key);
        if (soak >= 0) {
          if (!have) {
            let since = this.soaking.get(key); if (since === undefined) { since = now; this.soaking.set(key, now); }
            if (now - since >= soak) {   // soaked long enough → the link comes up
              this.soaking.delete(key);
              const lid = this.linkSeq++;
              this.links.set(lid, { a, b }); this.pairLink.set(key, lid);
              this.nodes.get(a).node.connected(lid, true);
              this.nodes.get(b).node.connected(lid, false);
            }
          }
        } else {
          this.soaking.delete(key);   // out of range, reset the dwell timer
          if (have) {
            const lid = this.pairLink.get(key);
            this.nodes.get(a).node.disconnected(lid);
            this.nodes.get(b).node.disconnected(lid);
            this.links.delete(lid); this.pairLink.delete(key);
          }
        }
      }
      // 2) advance every node's clock, the core prunes its own store on tick, per each bundle's real TTL.
      //    (hop-core already auto-publishes §39 recv-beacons here via route_to_me, so gradients form and
      //    routing is directed, no explicit beacon needed.)
      for (const { node } of this.nodes.values()) node.tick(now);
      // 3) pump: bytes a node wants to send go to the peer on that link
      for (const [id, { node }] of this.nodes) {
        for (const p of node.drain()) {
          const lk = this.links.get(p.link); if (!lk) continue;
          const peer = lk.a === id ? lk.b : lk.a;
          this.nodes.get(peer).node.receive(p.link, p.data);
        }
      }
      // 4) real bundle transfers -> recent legs (live relay web) + a parent tree for path reconstruction
      for (const [id, { node }] of this.nodes) {
        for (const t of node.drain_transfers()) {
          const lk = this.links.get(t.link); if (!lk) continue;
          const peer = lk.a === id ? lk.b : lk.a, bundle = _hex(t.bundle);
          if (!this.msgBundles.has(bundle)) continue;   // skip ACK/gossip/control bundles, only visualize real messages
          this.legs.push({ from: id, to: peer, bundle, at: now });
          let pm = this.parent.get(bundle); if (!pm) { pm = new Map(); this.parent.set(bundle, pm); }
          if (!pm.has(peer)) pm.set(peer, id);   // 'peer' first received this bundle from 'id'
        }
      }
      if (this.legs.length > 2500) this.legs.splice(0, this.legs.length - 2500);   // bound the relay web
      if (this.parent.size > 500) { for (const k of [...this.parent.keys()]) { if (this.parent.size <= 400) break; if (!this.delivered.has(k)) this.parent.delete(k); } }
      if (this.delivered.size > 3000) this.delivered.clear();   // bound the delivered-dedup set
      // 5) deliveries -> reconstruct the exact path the delivered bundle took, then free its tree
      for (const [id, { node }] of this.nodes) {
        for (const d of node.inbox()) {
          const bundle = _hex(d.bundle), path = [], pm = this.parent.get(bundle);
          let cur = id, guard = 0;
          while (pm && pm.has(cur) && guard++ < 60) { const prev = pm.get(cur); path.unshift([prev, cur]); cur = prev; }
          this.delivered.add(bundle); this.parent.delete(bundle);
          this.deliveries.push({ to: id, from: this.addrToId.get(_hex(d.from)), bundle, text: _dec(d.body), path, hops: d.hops, at: now });
        }
      }
      // 6) sends WE (the sender) just confirmed delivered, via a returning ACK, the sender's ONLY
      //    signal of delivery (it never hears from the recipient directly).
      for (const [, { node }] of this.nodes) { const d = node.drain_delivered();
        for (let i = 0; i + 32 <= d.length; i += 32) { let h = ''; for (let j = i; j < i + 32; j++) h += d[j].toString(16).padStart(2, '0'); this.senderAcks.push(h); } }
      // 7) §39 recv-beacons emitted this frame, pulse those nodes in the viz (their reachability advert)
      for (const [id, { node }] of this.nodes) if (node.drain_beaconed()) this.beaconEvents.push(id);
      // 8) channel posts that arrived (group fan-out)
      for (const [id, { node }] of this.nodes)
        for (const cm of node.take_channel())
          this.hpsDeliveries.push({ to: id, path: cm.path, text: _dec(cm.body), from: this.addrToId.get(_hex(cm.sender)), at: now });
    },

    // Which nodes currently hold each message bundle, straight from the real stores. As the
    // delivery-ACK/vaccine reaches a relay it drops its copy and falls out of this map.
    holderMap() {
      const h = {};
      for (const [id, { node }] of this.nodes) {
        const bytes = node.held_ids();
        for (let i = 0; i + 32 <= bytes.length; i += 32) {
          let hex = ''; for (let j = i; j < i + 32; j++) hex += bytes[j].toString(16).padStart(2, '0');
          if (this.msgBundles.has(hex)) (h[hex] = h[hex] || []).push(id);
        }
      }
      return h;
    },

    // The §39 P4 routing tree toward one recipient: for every node that holds a gradient toward the
    // recipient's mailbox-tag, an arrow { from, to } along the link it would forward a private bundle
    // down (the next hop toward the recipient). Drawing these shows the distributed radix tree steer A→B.
    gradientTo(recipId) {
      const rn = this.nodes.get(recipId); if (!rn) return [];
      let tag = ''; { const t = rn.node.mailbox_tag(); for (let j = 0; j < 16; j++) tag += t[j].toString(16).padStart(2, '0'); }
      const arrows = [];
      for (const [id, { node }] of this.nodes) {
        if (id === recipId) continue;
        const g = node.gradient();
        for (let i = 0; i + 21 <= g.length; i += 21) {
          let t = ''; for (let j = i; j < i + 16; j++) t += g[j].toString(16).padStart(2, '0');
          if (t !== tag) continue;
          const link = g[i + 16] | (g[i + 17] << 8) | (g[i + 18] << 16) | (g[i + 19] << 24);
          const lk = this.links.get(link); if (!lk) continue;
          arrows.push({ from: id, to: lk.a === id ? lk.b : lk.a, hops: g[i + 20] });
        }
      }
      return arrows;
    },

    // Send status per originated message bundle: { hex: { peers, delivered } }, from each node's tx.
    statusMap() {
      const s = {};
      for (const { node } of this.nodes.values()) {
        const d = node.sends_status();
        for (let i = 0; i + 35 <= d.length; i += 35) {
          let hex = ''; for (let j = i; j < i + 32; j++) hex += d[j].toString(16).padStart(2, '0');
          s[hex] = { peers: d[i + 32] | (d[i + 33] << 8), delivered: !!d[i + 34] };
        }
      }
      return s;
    },
  };
}
