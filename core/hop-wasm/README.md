<p align="center">
  <img alt="Hop" src="https://hopme.sh/hop-mark.svg" width="200">
</p>

<h1 align="center">hop-wasm</h1>

<p align="center">
  <b>A real Hop node in the browser.</b><br>
  <a href="https://hopme.sh">Hop</a>'s Rust core compiled to WebAssembly, driven from JavaScript.
</p>

<p align="center">
  <a href="https://www.npmjs.com/package/hop-wasm"><img src="https://img.shields.io/npm/v/hop-wasm?color=654ff0&label=npm" alt="npm"></a>
  <img src="https://img.shields.io/badge/license-FSL--1.1--ALv2-3ddc84" alt="license">
  <img src="https://img.shields.io/badge/wasm-browser%20%2F%20node-654ff0" alt="wasm">
</p>

---

Hop is a **delay-tolerant mesh**: end-to-end encrypted datagrams that hop device to device, over BLE,
Wi-Fi, and the internet, until they reach the person you meant. Held, never dropped.

`@hop-mesh/wasm` is `hop-core` compiled to WebAssembly: a `WasmNode` is a **genuine** Hop node, the same
store-and-forward, crypto, and spray-and-wait routing that runs on a phone, now running in a tab. JS owns
the bearer (it decides who's in range, pumps bytes across links, reads the inbox) and owns the storage
(bundles live in a host store you provide, not in wasm memory, so a tab full of nodes doesn't OOM). It
powers the live browser swarm simulator, where every dot on the map is a real instance of the protocol.

## Install

```sh
npm install @hop-mesh/wasm
```

## Two nodes, one link

Give each node a 32-byte identity seed and a synchronous `StoreBridge` (a Map here; SQLite-on-OPFS in a
real Worker). JS pumps each node's drained packets into the other, and A sends B a message:

```js
import { WasmNode } from 'hop-wasm'

// A minimal in-memory host store. In a browser Worker this is SQLite over an OPFS sync-access handle.
const bridge = () => {
  const seen = new Map(), held = new Map(), kv = new Map()
  const hex = u => [...u].map(b => b.toString(16).padStart(2, '0')).join('')
  return {
    put(id, data, exp) { const h = hex(id); if (seen.has(h)) return false; seen.set(h, exp); held.set(h, data.slice()); return true },
    get: id => held.get(hex(id)), remove(id) { const h = hex(id), d = held.get(h); held.delete(h); return d },
    seen: id => seen.has(hex(id)), seenExpiry: id => seen.get(hex(id)), contains: id => held.has(hex(id)),
    have() { const o = new Uint8Array(held.size * 32); let i = 0; for (const h of held.keys()) { o.set(Uint8Array.from(h.match(/../g).map(x => parseInt(x, 16))), i); i += 32 } return o },
    prune(now) { for (const [h, e] of seen) if (e <= now) { seen.delete(h); held.delete(h) } },
    setData(id, d) { const h = hex(id); if (held.has(h)) held.set(h, d.slice()) },
    kvPut: (k, v) => kv.set(k, v.slice()), kvGet: k => kv.get(k), kvRemove: k => kv.delete(k),
    kvList() { return new Uint8Array() },
  }
}

const seed = () => crypto.getRandomValues(new Uint8Array(32))
const a = new WasmNode(seed(), bridge())
const b = new WasmNode(seed(), bridge())

let now = 1_700_000_000_000
for (const n of [a, b]) { n.tick(now); n.publish_prekey() }
a.connected(1, true)   // A dialed
b.connected(1, false)  // B accepted

a.send(b.address, new TextEncoder().encode('meet at the ridge'))

for (let i = 0; i < 400; i++) {
  for (const p of a.drain()) if (p.link === 1) b.receive(p.link, p.data)
  for (const p of b.drain()) if (p.link === 1) a.receive(p.link, p.data)
  for (const msg of b.inbox()) console.log(new TextDecoder().decode(msg.body))
  now += 100; a.tick(now); b.tick(now)
}
```

`send` is the untraceable path (§39); `send_traced` is the opt-in directed path. `drain_transfers`
surfaces each bundle crossing each link (so a visualizer can color the route), and the `hps://` channel
methods (`register_channel`, `channel_subscribe`, `channel_publish`, `take_channel`) carry group posts.

## The shape of it

- **Poll-model.** `tick(nowMs)` the clock, `drain()` outbound packets to the bearer, and poll `inbox()`.
  Inbox polling is non-destructive; call `accept_inbox(id)` after local persistence. Nothing pushes
  asynchronously.
- **Host-owned storage.** You implement `StoreBridge` (put/get/remove/seen/have/prune plus a small kv
  side store with atomic `kvBatch`). The core reads and writes it; bundles never live in wasm memory.
- **JS is the bearer.** `connected` / `receive` / `drain` / `disconnected` move opaque bytes over
  whatever transport you have (a mock link, WebRTC, a WebSocket). The core owns all crypto.
- **Deterministic identity.** A node built from the same 32-byte seed keeps its address across reloads.

## Status

Prototype. The full `WasmNode` surface is exercised end to end against this exact wasm build by the
browser swarm simulator (15 real-world scenarios, each delivered and ACKed). The published bundle is the
`nodejs`/`web` wasm-pack output (`hop_wasm.js` + `hop_wasm_bg.wasm` + types).

## The Hop family

`@hop-mesh/wasm` is the browser binding of the core, a peer of the C ABI. The protocol core is
[hop-core](https://github.com/hopmesh/hop-core); the C ABI is
[libhop](https://github.com/hopmesh/libhop). The language SDKs:
[node](https://github.com/hopmesh/hop-sdk-node) ·
[python](https://github.com/hopmesh/hop-sdk-python) ·
[go](https://github.com/hopmesh/hop-sdk-go) ·
[ruby](https://github.com/hopmesh/hop-sdk-ruby) ·
[crystal](https://github.com/hopmesh/hop-sdk-crystal) ·
[elixir](https://github.com/hopmesh/hop-sdk-elixir) ·
[apple](https://github.com/hopmesh/hop-sdk-apple) ·
[android](https://github.com/hopmesh/hop-sdk-android).

## License

[FSL-1.1-ALv2](./LICENSE.md): source-available, and converts to Apache-2.0 after two years. The SDKs
that bind this are Apache-2.0.
