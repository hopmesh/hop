# sdk/node

The **server-side** Hop SDK: an embeddable endpoint (`HopEndpoint`) that lets a Node service receive
Hop messages with an Express/Fastify-shaped API, over the same `libhop` C ABI (`sdk/hop.h`) the mobile
SDKs bind. This is the "self-host is an import" layer, distinct in purpose from `sdk/apple`/`sdk/android`
(client SDKs that run a node on a device): this one hosts a mailbox in a backend.

```
lib/ffi.mjs         raw koffi bindings to libhop (one-to-one with hop_* symbols); resolves the lib
                    via HOP_LIBDIR or target/{debug,release}/libhop.<dylib|so>. incl. signReach/verifyReach
lib/endpoint.mjs    HopEndpoint: hop.on/reply/request + pump loop + bearer seam + attach()/dialByName()
lib/tcp-bearer.mjs  the raw-TCP Internet bearer: length-prefixed frames (core does the Noise)
lib/wss-bearer.mjs  the WSS Internet bearer: Noise over a WebSocket (ws dep); reachable on 443 under /_hop
lib/discovery.mjs   /.well-known/hop body (a signed reach record) + resolve() (fetch + verify)
examples/           raw-roundtrip, echo, tcp, server/client, discovery (HTTPS well-known + WSS by name)
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
  via `endpoint._deliver(id, buf)`. `connectInProcess`, `tcp-bearer` (length-prefixed frames), and
  `wss-bearer` (one WS message = one frame, no prefix) are the implementations; all move opaque bytes,
  core owns all crypto.
- **Reachable by name:** `attach(server, {publicUrl})` wires the WSS bearer (`/_hop`) AND the
  `/.well-known/hop` responder in one call. The well-known serves a self-certifying reach record;
  `dialByName(https://...)` fetches it (TLS = WebPKI domain proof), verifies the record (address
  self-certification), dials the WSS, and the Noise handshake confirms the address. No DNSSEC. The
  well-known route is served on the 'request' event only for a Hop-dedicated server; for an app router,
  mount `wellKnownHandler()` and pass `serveWellKnown:false` (a WS upgrade is a server-level hook, not
  an app route, which is why `attach` takes the server).
- **koffi sink callbacks** decode pointers that are valid ONLY during the call (see `bytes`/`addr` in
  ffi.mjs); copy anything you keep. `assertAbi()` fails loudly if `hop_abi_version()` drifts from 3.

## Verify

`cargo build -p hop` (or set `HOP_LIBDIR`), then `npm install && npm test` (four proofs incl. the
HTTPS + WSS discovery chain; needs `openssl` for the demo's self-signed cert). Prototype: not yet a
required CI job. Multi-tenant hosting, delegated
keys, and multi-tenant hosting are stubbed follow-ups, not core changes.
