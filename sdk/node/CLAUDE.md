# sdk/node

The **server-side** Hop SDK: an embeddable endpoint (`HopEndpoint`) that lets a Node service receive
Hop messages with an Express/Fastify-shaped API, over the same `libhop` C ABI (`sdk/hop.h`) the mobile
SDKs bind. This is the "self-host is an import" layer, distinct in purpose from `sdk/apple`/`sdk/android`
(client SDKs that run a node on a device): this one hosts a mailbox in a backend.

```
lib/ffi.mjs         raw koffi bindings to libhop (one-to-one with hop_* symbols); resolves the lib
                    via HOP_LIBDIR or target/{debug,release}/libhop.<dylib|so>
lib/endpoint.mjs    HopEndpoint: hop.on(service, handler) + reply.send(status, body) + request() + the
                    pump loop + the bearer seam. The ergonomics live here.
lib/tcp-bearer.mjs  the Internet bearer: length-prefixed frames over TCP (core does the Noise)
examples/           raw-roundtrip (proves the ABI), echo (in-process DX), tcp (real socket), server/client
```

## Non-obvious things

- **It's built on the SERVICE surface, not a new API.** `hop.on` == `hop_subscribe` +
  `hop_poll_service_requests`; `reply.send(status, body)` == `hop_send_service_response` (status is a
  `uint16`, HTTP-shaped). No core change was needed; the endpoint is a node in service-host mode.
- **The DX is HTTP-shaped; the semantics are not.** Inbound is a durable store-and-forward consume; a
  reply is a new addressed message that can arrive later. Do not "fix" it into synchronous request/
  response, that would throw away delay-tolerance, which is the point.
- **core is poll-model** ("core never pushes asynchronously", per hop.h). `HopEndpoint` runs a
  `setInterval` pump that ticks, drains outbound to the bearer, and polls requests/responses/inbox.
  The pump timer is intentionally NOT `unref`'d: a running endpoint keeps the process alive like a
  server. `close()` stops it and frees the node.
- **Bearer seam:** a bearer calls `endpoint._registerLink(id, role, sendFn)` and feeds inbound frames
  via `endpoint._deliver(id, buf)`. `connectInProcess` (in-process) and `tcp-bearer` (sockets) are the
  two implementations; both just move opaque bytes, core owns all crypto.
- **koffi sink callbacks** decode pointers that are valid ONLY during the call (see `bytes`/`addr` in
  ffi.mjs); copy anything you keep. `assertAbi()` fails loudly if `hop_abi_version()` drifts from 2.

## Verify

`cargo build -p hop` (or set `HOP_LIBDIR`), then `npm install && npm test` (runs all three proofs;
each exits non-zero on failure). Prototype: not yet a required CI job. HNS publish/resolve, delegated
keys, and multi-tenant hosting are stubbed follow-ups, not core changes.
