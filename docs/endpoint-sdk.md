# Endpoint SDK: self-hostable, embeddable Hop endpoints

Status: design + working prototypes in Node (`sdk/node`, koffi over the C ABI), Elixir (`sdk/elixir`,
a Rustler NIF over the `hop` crate), Python (`sdk/python`, ctypes over the C ABI, zero deps), and Go
(`sdk/go`, cgo over the C ABI). This locks the semantics before the surface grows to more languages.

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
| `reply(status, body)`     | `hop_send_service_response(node, from, request_id, status, body)` (status is `uint16`) |
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
hop.on('acme/orders', (req, reply) => reply(201, { ok: true, order: req.json() }))
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

Python (`sdk/python`, ctypes, a `@hop.on(topic)` decorator) and Go (`sdk/go`, cgo, `server.On(topic,
fn)`) are built. Ruby (Fiddle) and others bind the C ABI and follow the same shape.

### Aligned surface

The four SDKs are kept as close as possible while staying idiomatic per language. Same verbs, same
argument order, same handler shape `(req, reply)`, a callable `reply(status, body)`, and a `request`
that defaults its timeout. Differences below are language convention, not divergence: casing (Go
exports `On`), Elixir's `.()` anonymous-call syntax, and Python's `req.from_addr` (because `from` is a
keyword).

| Concept   | Node                          | Python                         | Go                              | Elixir                              |
| --------- | ----------------------------- | ------------------------------ | ------------------------------- | ----------------------------------- |
| register  | `hop.on(svc, fn)`             | `@hop.on(svc)` / `hop.on(...)` | `ep.On(svc, fn)`                | `Endpoint.on(ep, svc, fn)`          |
| handler   | `(req, reply) =>`             | `def fn(req, reply)`           | `func(req, reply)`              | `fn req, reply ->`                  |
| reply     | `reply(status, body)`         | `reply(status, body)`          | `reply(status, body)`           | `reply.(status, body)`              |
| request   | `await hop.request(dst,s,m,a)`| `hop.request(dst,s,m,a)`       | `ep.Request(dst,s,m,a)`         | `Endpoint.request(ep,dst,s,m,a)`    |
| address   | `hop.address`                 | `hop.address`                  | `ep.Address()`                  | `Endpoint.address(ep)`              |
| sender id | `req.from`                    | `req.from_addr`                | `req.From`                      | `req.from`                          |
| listen    | `listen(hop, port)`           | `listen(hop, port)`            | `hop.Listen(ep, port)`          | `TcpBearer.listen(ep, port)`        |
| dial      | `dial(hop, host, port)`       | `dial(hop, host, port)`        | `hop.Dial(ep, host, port)`      | `TcpBearer.dial(ep, host, port)`    |

Return shapes stay idiomatic: Node resolves a `{status, body}` object (a Promise), Python returns a
`(status, body)` tuple, Go returns `(status, body, err)`, Elixir returns `{:ok, status, body}`.

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

Built and working (`sdk/node`): the handler/reply surface, client `request()`, in-process, TCP, and
**WSS** bearers, base58 addressing, ABI-version assertion, and **reachable-by-name discovery**
(`attach` + `dialByName` over HTTPS `/.well-known/hop` + a self-certifying reach record). Four passing
proofs. The reach record itself is a core primitive (`reach.rs` + the C ABI `hop_sign_reach_record` /
`hop_verify_reach_record`), so the other SDKs can adopt the same WSS + discovery surface.

Known follow-ups (each is additive, none is a core rewrite):

- DONE **Fan the WSS bearer + `attach`/`dial_by_name` out** to every server SDK (`node`, `python`, `go`,
  `ruby`, `crystal`, `elixir`), all with the aligned handler/reply/`channel` surface.
- DONE **CI**: each SDK has a job that builds libhop and runs its proofs; all are required checks.
- **Self-certifying discovery for the no-domain case** (resolve a bare `hops://<address>`). Specced in
  "Follow-up designs" 1 below.
- **Delegated endpoint keys** (receive-on-behalf-of, with rotation). Specced in design 2 below.
- **Multi-tenant hosting** (relay-for-others), which also buys the k-anonymity cover above. Specced in
  design 3 below.
- **The Internet bearer as a first-class, reconnecting, NAT-aware bearer** (the prototype uses a plain
  TCP framer; production wants keepalive, reconnect, and hole-punching or an outbound-kept presence for
  home hosting).
- **Ack-based redelivery** surfaced in the SDK (retain until the handler acks).

## Consequence to accept

Embedding the node in a customer's backend graduates the C ABI from "mobile demo contract" to
"production server contract." The soundness bar rises: a panic must never unwind across the FFI (apply
the `guard_core` catch-unwind pattern already used in `hop-relayd`), and the marshalling discipline from
the Kotlin JNA work (bool-as-byte, `uint8` at the surface) is non-negotiable, because a crash in a
customer's server is a worse failure than in a demo app.

## Follow-up designs

Two of the follow-ups above have landed: the WSS bearer + `attach`/`dial_by_name` surface is fanned out
to every server SDK (`node`, `python`, `go`, `ruby`, `crystal`, `elixir`), and each has its own CI job
that runs the proofs (a real `hops` round trip incl. the WSS + WebPKI discovery chain against an
in-process dev cert). The three remaining follow-ups are specced below. Each is additive; the split of
work between `hop-core`, `hop-relayd`, and the SDKs is called out so none is mistaken for "SDK only."

### 1. No-domain discovery (resolve a bare `hops://<address>`)

The named case (`dial_by_name("https://acme.com")`) needs no new infra: a DNS A record plus the
TLS-served `/.well-known/hop`. The self-certifying reach record already exists as a core primitive
(`reach.rs`, `hop_sign_reach_record` / `hop_verify_reach_record`), so the missing piece is a way to fetch
a record for an address that has no domain fronting it.

**Mechanism A, relay-cache (preferred first cut).** Add two verbs to `hop-relayd`:

- `publish_reach(record)`: the relay stores the signed record keyed by its `address`, with a TTL taken
  from the record. The relay is UNTRUSTED for content: it verifies the signature before caching (so it
  cannot cache a forged location) but it learns nothing it could not already observe, because a record
  is public by construction.
- `resolve_reach(address) -> record?`: returns the freshest cached record. The client re-verifies it
  against the queried address (`hop_verify_reach_record`), so a malicious or stale relay can withhold or
  delay a record but can never substitute a wrong location.

Trust chain without a domain: instead of "TLS proves the domain, record self-certifies the address,"
it is "the address IS the name, the record self-certifies it." No WebPKI, no trusted relay.

**Mechanism B, gossip.** Reach records ride the existing prekey-advert gossip (adverts already propagate
on link-up), so a peer caches `address -> location` opportunistically from the mesh. Eventually
consistent, works offline-of-the-relay, but slower to converge and noisier. Ship A first, layer B for
the relay-free case.

**The metadata honeypot, and how to defang it.** `resolve_reach(address)` tells the relay "someone wants
to reach X." That is the lookup-privacy problem DNS has and DoH/ODoH answer. Options, cheapest first:
(a) query over the relay's own Noise channel so only the relay (not the network) sees it; (b) an
ODoH-style oblivious proxy so the relay sees the query but not the querier, and the proxy sees the
querier but not the query; (c) k-anonymity via multi-tenant hosting (design 3), where a lookup for a
host resolves N tenants at once. Start with (a); document (b)/(c) as the privacy roadmap.

**API (aligned across SDKs).** `endpoint.publish_reach(relay_url, ttl_secs)` and
`client.dial_by_address(address, via: relay_url)` (mirrors `dial_by_name`, keyed by address not URL).

**Work split.** Core: none (the record exists). Relay: the two verbs + a keyed, TTL'd store (reuse the
existing mailbox store adapter). SDK: two thin methods over the relay's request path. Wire: relay-scoped
framing, no `BUNDLE_VERSION` bump if it rides the existing relay channel; confirm with the round-trip
byte tests before merging.

### 2. Delegated endpoint keys (receive-on-behalf-of, with rotation)

An endpoint on a VPS should not hold the primary identity secret; a server compromise must not be an
identity compromise. Let the primary identity authorize a short-lived sub-key to receive for its address.

**Mechanism.** A delegation is a signed statement `sign(primary, {sub_pubkey, address, not_before,
not_after})`, a new self-verifying primitive shaped exactly like the reach record (its own `delegation.rs`
+ `hop_sign_delegation` / `hop_verify_delegation`). The endpoint runs with `sub_key` and presents the
delegation. A sender learns the authorized sub-key from discovery (the reach record gains an optional
`delegation` field, or the well-known serves it), verifies it chains to `address`, and completes the
Noise handshake to `sub_key` while treating the peer identity as `address`. Rotation is issue-and-expire:
mint a new delegation with a later `not_after`, let the old one lapse. Revocation is bounded by the TTL
(no CRL); keep TTLs short (hours to a day) for a hosted key.

**Work split.** Core: the signed primitive + verify + a receive path that accepts a session to `sub_key`
as delivery for `address` (a real addressing/session change, gated behind the delegation check, so this
is the one follow-up that touches the crypto core). SDK: `identity.delegate(sub_pubkey, ttl)` on the key
holder and `Endpoint.new(key: sub_key, delegation: cert)` on the host. Wire: the delegation is carried in
discovery, not in the message bundle, so no `BUNDLE_VERSION` bump; the session-bind change needs the
round-trip + `§39` verify tests re-run.

### 3. Multi-tenant hosting (relay-for-others, and the k-anonymity it buys)

One host process receives for many addresses, a hosting provider for endpoints, which also provides the
k-anonymity cover the privacy section calls for: traffic to any one tenant is one of N, so an observer of
the host cannot tell which tenant a bundle is for (the host is untrusted for content, which stays E2E to
the tenant's key).

**Mechanism.** Two shapes, in order of effort. (a) N nodes, one per tenant, behind a demux bearer: the
host runs one listening socket and routes each inbound frame to the tenant node whose address it targets
(the bearer already moves opaque bytes; the demux keys on the destination in the frame's routing header).
Pure SDK, no core change, ships first. (b) One node, many identities: a single `hop-core` node holds a
mailbox per tenant address, sharing one ratchet store and one pump. More efficient at scale but a core
change (a node today owns one identity), so it follows (a). Tenants onboard via design 2: each delegates
a receive-key to the host, so the host never holds a tenant's primary secret.

**Work split.** SDK: a `Host` registry (`host.mount(endpoint)` keyed by address) + the demux bearer for
shape (a). Core: only shape (b) (multi-identity node). Privacy: quantify and surface the anonymity set
(N) so callers know the cover they are getting; a host of one is no cover.
