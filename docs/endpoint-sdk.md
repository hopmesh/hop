# Endpoint SDK: self-hostable, embeddable Hop endpoints

Status: design + working prototypes in Node (`sdk/node`, koffi over the C ABI), Elixir (`sdk/elixir`,
a Rustler NIF over the `hop` crate), and Python (`sdk/python`, ctypes over the C ABI, zero deps). This
locks the semantics before the surface grows to more languages.

## Why

Today a relay is a mandatory store-and-forward hop for offline delivery. That makes the paid relay
fleet a toll booth on all traffic and a central chokepoint, which is in tension with a mesh, censorship
resistant messenger, and it forces a "why do I pay to send a message" billing model. The endpoint SDK
federates the mailbox instead: a named, directly reachable endpoint holds its own mail, so senders can
deliver straight to it and skip the relay. The relay becomes an optional managed convenience, not a
required toll, which is both a healthier product boundary (open core: self-host free, managed hosting
paid) and better aligned with the mission (the network works without our infrastructure).

The load-bearing insight: this only pays off if self-hosting is trivial. "Operate a daemon" wins few
self-hosters. "`npm install` and set a key" wins most. So the endpoint must be an **embeddable library**
that a backend mounts the way it mounts an HTTP route, not a separate service to run.

## The model

An endpoint is a `hop-core` node in "host a mailbox + hand me inbound messages" mode. Two unifications
keep it small:

1. **Endpoint = a relay you run yourself.** Same node, same DESIGN.md 39 mailbox machinery (blind
   spool, mailbox tag, want beacon pull, relay vaccine, rate cap). "Relay" is the multi-tenant
   deployment; "endpoint" is the self-hosted one. Same code, different tenancy.
2. **A public endpoint is just another bearer.** Alongside BLE, LAN, and relay bearers, an Internet
   bearer lets any connected device form a link to a named endpoint. The existing routing and 39
   gradient handle delivery; the endpoint is a high-value, always-reachable sink. HNS is only the
   discovery layer.

Neither needs a new protocol.

## The ABI maps exactly (zero core changes)

The C ABI (`sdk/hop.h`) already exposes the whole surface:

| Endpoint concept          | libhop C ABI                                                  |
| ------------------------- | ------------------------------------------------------------- |
| register a receiver       | `hop_subscribe(node, "acme/orders")`                          |
| inbound handler           | `hop_poll_service_requests` -> `(from, request_id, service, method, args)` |
| `reply.send(status, body)`| `hop_send_service_response(node, from, request_id, status, body)` (status is `uint16`) |
| client `request(...)`     | `hop_send_service_request` + `hop_poll_service_responses`     |
| the Internet bearer       | `hop_link_up` + `hop_bytes_received` + `hop_drain_outgoing` (opaque bytes; core does Noise) |
| config = the key          | `hop_node_open(db, secret, ...)`                              |

The prototype proves the full `hops://` round trip (request in, `200`/`201` + body out) from Node over
this ABI, in process and over real TCP, with a real Noise handshake and forward-secret ratcheting.

## Delivery semantics (the one thing not to get wrong)

The developer experience is HTTP-shaped. The delivery is not. Design to these, not to synchronous
request/response:

- Inbound is a **durable, store-and-forward consume**, like a webhook receiver or a queue consumer,
  not a served request. It fires when a message arrives, which may be long after it was sent.
- A **reply is a new addressed message** back to the sender, sealed over the ratchet. It can be
  immediate or deferred, even across a process restart, because the sender address and ratchet state
  persist.
- Delivery should be **ack based**: the mailbox holds a message until the handler acks it, so a crash
  mid-handle redelivers. That yields at-least-once delivery and crash safety (strictly better than an
  HTTP webhook, which drops when your box is down) and natural backpressure.
- **Auth is cryptographic and free.** `req.from` is the ratchet-verified sender identity, not a
  spoofable header. There is no bearer-token or OAuth layer to add.

Faking synchronicity would throw away delay-tolerance, which is the entire reason to use Hop here.

## Config is the key

The only secret configuration is the node's identity key; everything else is derived (the address) or
environmental (IP, port, which HNS advertises). Two refinements:

- **Delegate the key.** An endpoint on a VPS should run a delegated sub-identity authorized to
  receive on behalf of your address, so a compromised box does not burn your root identity. HNS maps
  `name -> current key`, so the endpoint key can rotate without changing the published name.
- The **receivers you register implicitly declare** which topics this process hosts. So the effective
  config is "the key plus your handlers."

## One ABI, many ergonomic surfaces

The same C ABI backs a thin, idiomatic wrapper per runtime (the `sdk/<target>` pattern). Node is built:

```js
const hop = new HopEndpoint({ dbPath: './hop.db' })
hop.on('acme/orders', (req, reply) => reply.send(201, { ok: true, order: req.json() }))
await listen(hop, 9944)
```

Elixir is built and is a natural fit (mailbox, supervision, and delay-tolerance line up). Note the
binding mechanism differs by runtime: C-FFI languages bind `sdk/hop.h`, while a Rust-hosting runtime
like the BEAM binds the `hop` crate directly through a Rustler NIF (no unsafe extern-C round trip):

```elixir
{:ok, ep} = Hop.Endpoint.start_link([])
Hop.Endpoint.on(ep, "acme/orders", fn req, reply -> reply.(201, Jason.encode!(%{ok: true})) end)
{:ok, _} = Hop.TcpBearer.listen(ep, 9944)
```

Python is built (`sdk/python`, via ctypes, a `@hop.on(topic)` decorator). Go (`hop.HandleFunc(topic,
fn)`), Ruby, and others bind the C ABI and follow the same shape.

## The privacy dial (never a silent default)

Publishing a reachable endpoint trades metadata privacy for reachability. That must be an explicit,
recipient-owned choice, not a silent erosion of the untraceable-by-default guarantee. There are three
distinct leaks, and only one is irreducible:

1. **Recipient identity at the endpoint**: already solved by the 39 mailbox tag. The endpoint holds
   bundles blind; only the recipient recognizes and pulls them.
2. **Who delivers**: let a mesh carrier do the final Internet hop, not the sender. Policy: a node does
   the final handoff only if it is not the origin (or the origin explicitly opts in). The endpoint
   sees the carrier's IP, not the sender's. Sender anonymity survives even though the endpoint is
   public.
3. **The endpoint is a fixed public point**: irreducible. Connecting to it reveals "someone talks to
   it." Bound it with k-anonymity: multi-tenant endpoints (traffic to Y is one of N), and endpoints
   that also carry pass-through traffic (cover for their own mailbox). A single-user published
   endpoint effectively deanonymizes that user, which is fine for a business or public service and
   is the conscious tradeoff for a privacy-seeker.

So the dial: max privacy (no published endpoint, mesh plus optional relay, recipient anonymous) is the
default; publish an endpoint to trade for reachability and lower cost. The recipient sets it.

## Prototype scope and follow-ups

Built and working (`sdk/node`): the handler/reply surface, client `request()`, in-process and TCP
bearers, base58 addressing, ABI-version assertion, three passing proofs.

Known follow-ups (each is additive, none is a core rewrite):

- **HNS publish and resolve** exposed through the ABI, so an endpoint advertises `name -> host/port/key`
  and callers resolve it. Without this, HNS becomes a metadata honeypot (lookups reveal the who-reaches-
  whom graph), so it needs the DoH/ODoH analog or mesh-gossiped records.
- **Delegated endpoint keys** (receive-on-behalf-of, with rotation).
- **Multi-tenant hosting** (relay-for-others), which also buys the k-anonymity cover above.
- **The Internet bearer as a first-class, reconnecting, NAT-aware bearer** (the prototype uses a plain
  TCP framer; production wants keepalive, reconnect, and hole-punching or an outbound-kept presence for
  home hosting).
- **Ack-based redelivery** surfaced in the SDK (retain until the handler acks).
- **CI**: build libhop, `npm test` the proofs, add as a required check.

## Consequence to accept

Embedding the node in a customer's backend graduates the C ABI from "mobile demo contract" to
"production server contract." The soundness bar rises: a panic must never unwind across the FFI (apply
the `guard_core` catch-unwind pattern already used in `hop-relayd`), and the marshalling discipline from
the Kotlin JNA work (bool-as-byte, `uint8` at the surface) is non-negotiable, because a crash in a
customer's server is a worse failure than in a demo app.
