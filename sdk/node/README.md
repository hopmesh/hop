<p align="center">
  <img alt="Hop" src="https://hopme.sh/hop-mark.svg" width="200">
</p>

<h1 align="center">@hop-mesh/endpoint</h1>

<p align="center">
  <b>Receive Hop messages in your Node service.</b><br>
  An Express/Fastify-shaped endpoint on the <a href="https://hopme.sh">Hop</a> mesh, over the <code>libhop</code> C ABI.
</p>

<p align="center">
  <a href="https://www.npmjs.com/package/@hop-mesh/endpoint"><img src="https://img.shields.io/npm/v/@hop-mesh/endpoint?color=6ea8fe&label=npm" alt="npm"></a>
  <img src="https://img.shields.io/badge/license-Apache--2.0-3ddc84" alt="license">
  <img src="https://img.shields.io/badge/node-%E2%89%A518-6ea8fe" alt="node >=18">
</p>

---

Hop is a **delay-tolerant mesh**: end-to-end encrypted datagrams that hop device to device, over BLE,
Wi-Fi, and the internet, until they reach the person or service you meant. Held, never dropped.

`@hop-mesh/endpoint` is the **server side**: your Node service becomes a first-class address on the mesh, so
senders hand messages straight to it. Self-host is an import, not an ops project. No inbound port to
open to the world, no bearer tokens to rotate, no message queue to run: the sender identity is
authenticated by the ratchet, and delivery is durable and store-and-forward.

## Install

```sh
npm install @hop-mesh/endpoint
```

You also need `libhop` (the Rust core, via a prebuilt binary or a `cargo build -p hop`), pointed to
with `HOP_LIBDIR`. See [libhop](https://github.com/hopmesh/libhop).

## Quick start

```js
import { HopEndpoint } from '@hop-mesh/endpoint'
import { listen } from '@hop-mesh/endpoint/tcp'

const hop = new HopEndpoint({ dbPath: './hop.db' }) // the identity key is the only real config

hop.on('acme/orders', (req, reply) => {
  const order = req.json()                 // req.from is a VERIFIED identity, not a spoofable header
  reply(201, { ok: true, id: save(order) }) // uint16 status + JSON / Buffer / string body
})

await listen(hop, 9944)   // reachable by any device
console.log(hop.address)   // publish this (or its name); senders reach you by it
```

**The DX looks like HTTP; the semantics are better.** Inbound is a durable, store-and-forward consume;
a reply is a new addressed message that may arrive later, even after a restart. It works when the peer
is offline, and there is no auth layer to bolt on, the identity is cryptographic.

## Reachable by name (WSS + discovery)

Make your endpoint reachable at `myaddress.com` with no new port and no DNS records beyond a plain `A`.
Wire the WSS bearer and the discovery route into your existing HTTPS server in one call:

```js
const hop = new HopEndpoint({ dbPath: './hop.db' })
hop.attach(server, { publicUrl: 'wss://myaddress.com/_hop' }) // serves GET /.well-known/hop + wss /_hop
server.listen(443)
```

`attach` must run before `server.listen()`. It installs raw-socket admission and one absolute TLS plus
HTTP-header deadline before Node allocates or parses a Hop upgrade. Servers configured with an HTTP
header limit above Node's documented 16 KiB default are rejected instead of being silently weakened.

A client reaches it by name, verified end to end:

```js
const address = await client.dialByName('https://myaddress.com') // WebPKI + self-certifying reach record
const res = await client.request(address, 'acme/orders', 'create', order)
await persistResult(res)
res.accept() // remove the durable response only after local work succeeds
```

TLS proves the domain, a signed **reach record** proves the address, and the Noise handshake confirms
it. Spoof the `A` record or MITM the lookup and the attacker still cannot forge the cert or complete the
handshake as the address, and a request sealed to that address is unreadable to anyone else.

## How it maps to the core

The endpoint is a `hop-core` node in "host a mailbox" mode, over the same C ABI every Hop SDK binds,
with zero core changes:

| Endpoint          | libhop C ABI                                              |
| ----------------- | --------------------------------------------------------- |
| `hop.on(svc, fn)` | `hop_subscribe` + `hop_poll_service_requests`             |
| `reply(status,b)` | `hop_send_service_response`                               |
| `hop.request(…)`  | `hop_send_service_request` + durable response poll/accept |
| Internet bearer   | `hop_link_up` / `hop_bytes_received` / `hop_drain_outgoing`|

## Examples

```sh
npm test              # raw ABI round-trip + in-process + real-TCP, all must pass
node examples/echo.mjs        # the hop.on / reply DX in-process
node examples/tcp.mjs         # the same over a real TCP Internet bearer
node examples/discovery.mjs   # the full reachable-by-name chain (HTTPS + WSS)
```

## Status

The handler/reply surface, the client `request()`, the in-process/TCP/WSS bearers, base58 addressing,
and discovery are built and tested. HNS name publish/resolve, delegated endpoint keys, and multi-tenant
hosting are on the roadmap (each is an SDK-level follow-up, not a core change).

## The Hop family

`@hop-mesh/endpoint` is one of several SDKs over the same C ABI. Same surface, your language:
[node](https://github.com/hopmesh/hop-sdk-node) ·
[python](https://github.com/hopmesh/hop-sdk-python) ·
[go](https://github.com/hopmesh/hop-sdk-go) ·
[ruby](https://github.com/hopmesh/hop-sdk-ruby) ·
[crystal](https://github.com/hopmesh/hop-sdk-crystal) ·
[elixir](https://github.com/hopmesh/hop-sdk-elixir).
The protocol core is [libhop](https://github.com/hopmesh/libhop) / [hop-core](https://github.com/hopmesh/hop-core).

## License

[Apache-2.0](./LICENSE.md), embed it freely. Only the protocol core (`hop-core`) stays FSL-1.1-ALv2,
source-available and converting to Apache-2.0 after two years.
