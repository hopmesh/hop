# @hop/endpoint (prototype)

Receive Hop messages in your Node app, with an Express/Fastify-shaped surface, over the `libhop`
C ABI. This is the "self-host is an import, not an ops project" piece: your service becomes directly
reachable on the mesh, so senders can hand messages straight to it without routing through a relay.

```js
import { HopEndpoint } from '@hop/endpoint'
import { listen } from '@hop/endpoint/tcp'

const hop = new HopEndpoint({ dbPath: './hop.db' }) // the identity (key) is the only real config

hop.on('acme/orders', (req, reply) => {
  // req.from is a cryptographically VERIFIED identity, not a spoofable header
  const order = req.json()
  reply.send(201, { ok: true, id: save(order) }) // uint16 status + JSON/Buffer/string body
})

await listen(hop, 9944)     // reachable by any device; in production HNS resolves name -> host/port/key
console.log(hop.address)    // publish this (or its HNS name)
```

## What it is (and isn't)

The endpoint is a `hop-core` node in "host a mailbox + hand me inbound messages" mode. It maps onto
the existing C ABI with **zero core changes**:

| Endpoint concept        | libhop C ABI                                         |
| ----------------------- | ---------------------------------------------------- |
| `hop.on(service, fn)`   | `hop_subscribe` + `hop_poll_service_requests`        |
| `reply.send(status, b)` | `hop_send_service_response` (status is a `uint16`)   |
| `hop.request(...)`      | `hop_send_service_request` + `hop_poll_service_responses` |
| the Internet bearer     | `hop_link_up` / `hop_bytes_received` / `hop_drain_outgoing` |
| config = the key        | `hop_node_open(db, secret, ...)`                     |

**The DX looks like HTTP; the semantics are not.** Inbound is a durable, store-and-forward consume;
a reply is a new addressed message that may arrive later, even after a restart. It is closer to a
webhook receiver or a queue consumer than a synchronous HTTP route, and that is the point: it works
when the peer is offline, and the sender identity is authenticated by the ratchet, so there is no
bearer-token or OAuth layer to add.

## Run the proofs

Build `libhop` first (or set `HOP_LIBDIR` to a prebuilt one):

```sh
cargo build -p hop            # from the repo root -> target/debug/libhop.<dylib|so>
cd sdk/node && npm install
npm test                      # raw ABI round-trip + ergonomic in-process + real-TCP, all must PASS
```

- `examples/raw-roundtrip.mjs` drives the raw C ABI (proves the bindings).
- `examples/echo.mjs` shows the `hop.on` / `reply.send` DX in-process.
- `examples/tcp.mjs` runs the same round trip over a real TCP Internet bearer.

Two-process (the real deployment shape):

```sh
node examples/server.mjs                                   # prints its address
node examples/client.mjs <that-address> localhost 9944
```

## Prototype scope

Built and working: the handler/reply surface, the client `request()`, the in-process and TCP bearers,
base58 addressing, ABI-version assertion. **Stubbed / not yet wired** (each is a known follow-up, not a
core change): HNS publish + resolve (you pass host/port/address directly for now), delegated endpoint
keys (use your own identity today), and multi-tenant hosting (relay-for-others). Not yet in CI.

## Notes

- Persist the key (`dbPath`, or `hop_node_open` with a saved secret) so your address is stable, that
  stable address, or its HNS name, is what senders reach.
- One C ABI, many wrappers: the same surface is the basis for `sdk/elixir`, `sdk/go`, etc.
- License: FSL-1.1-ALv2 (matches the repo).
