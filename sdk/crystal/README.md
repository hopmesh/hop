# hop-endpoint (Crystal endpoint SDK, prototype)

Receive Hop messages in Crystal with a Sinatra/Rails-shaped surface, over the `libhop` C ABI. Same idea
as `sdk/node`, `sdk/python`, `sdk/go`, `sdk/ruby`, `sdk/elixir`: your service becomes directly reachable
on the mesh, so senders hand messages straight to it without a relay. **Zero shards**: Crystal binds
libhop directly with `lib`, and the WSS bearer + discovery ride the stdlib.

```crystal
require "hop"

hop = Hop::Endpoint.new

hop.on("acme/orders") do |req, reply|
  # req.from is a cryptographically VERIFIED identity (base58), not a spoofable header
  order = JSON.parse(req.text)
  reply.call(201, {ok: true, order: order}.to_json) # uint16 status + bytes body
end

Hop::TcpBearer.listen(hop, 9944) # reachable by any device; in production HNS resolves name -> host/port/key
puts hop.address                 # publish this (or its HNS name)
```

## Two ways to receive: block or channel

The block handler above is the surface shared with every Hop SDK. Crystal (like Go) also has channels,
so you can consume verified requests on a `Channel` and reply from your own fiber, which reads naturally
for a long-running server (or a `select` across several services):

```crystal
orders = hop.channel("acme/orders")
spawn do
  loop do
    req, reply = orders.receive
    reply.call(201, req.text)
  end
end
```

Same delivery either way; `channel` is just `on` wired to a Channel.

## What it is (and isn't)

The endpoint is a `hop-core` node in service-host mode. The mapping onto the C ABI is exact:

| Endpoint concept          | libhop C ABI                                               |
| ------------------------- | ---------------------------------------------------------- |
| `hop.on(service) {...}`   | `hop_subscribe` + `hop_poll_service_requests`              |
| `reply.call(status, body)` | `hop_send_service_response` (status is a `uint16`)        |
| `hop.request(...)`        | `hop_send_service_request` + `hop_poll_service_responses`  |
| the Internet bearer       | `hop_link_up` / `hop_bytes_received` / `hop_drain_outgoing` |

**The DX is HTTP-shaped; the semantics are not.** Inbound is a durable store-and-forward consume; a
reply is a new addressed message that may arrive later, even after a restart. It is a queue consumer,
not a synchronous route, that is what makes it offline-tolerant. core is poll-model, so the endpoint
runs a background pump fiber (the node is thread-safe).

## Run the examples

Build `libhop` first (the `-L` in `src/hop/ffi.cr` defaults to the repo's `target/debug`, and libhop's
install name is absolute so the binary finds it at runtime with no env):

```sh
cargo build -p hop                          # from the repo root -> target/debug/libhop.<dylib|so>
cd sdk/crystal
crystal run examples/raw_roundtrip.cr       # raw C ABI round trip (proves the lib bindings)
crystal run examples/echo.cr                # the hop.on / reply DX in-process
crystal run examples/tcp.cr                 # the same round trip over a real TCP bearer
crystal run examples/discovery.cr           # WSS + WebPKI + reach-record discovery (in-process cert)
crystal spec                                # in-process, reach record, + WSS discovery, all pass
```

Two-process shape (a standalone server that uses the channel surface, plus a client):

```sh
crystal run examples/server.cr              # prints its address, listens on tcp://0.0.0.0:9944
crystal run examples/client.cr -- <address> localhost 9944
```

## Reachable by name (WSS + discovery)

Make an endpoint reachable at `myaddress.com` with **no new port and no DNSSEC**, on Crystal's stdlib
`HTTP::WebSocket` + `HTTP::Server` (zero shards):

```crystal
tls = OpenSSL::SSL::Context::Server.new
tls.certificate_chain = "cert.pem"
tls.private_key = "key.pem"
hop.attach(443, tls, "wss://myaddress.com/_hop") # WSS /_hop + /.well-known/hop in one call
```

```crystal
address = client.dial_by_name("https://myaddress.com")        # WebPKI + self-certifying
status, body = client.request(address, "acme/orders", "create", order)
```

Trust, no DNSSEC: `dial_by_name` fetches `/.well-known/hop` (TLS proves the domain), verifies the
self-certifying reach record (signed by the address), dials the WSS, and the Noise handshake confirms
the address. `spec/hop_spec.cr` proves the full chain against an in-process self-signed HTTPS server
(the cert is generated in-process by `Hop::DevTls`, no `openssl` CLI).

## Prototype scope

Built and working: `hop.on` (block) and `hop.channel` (Channel), `reply`, `request`, the pump fiber,
TCP + WSS bearers, base58 addressing, reach records + `attach`/`dial_by_name` discovery, ABI-version
assertion, and a use-after-free-safe `close` (a bearer fiber that fires after teardown short-circuits
instead of touching a freed node). Follow-ups (each additive, none a core change): the no-domain gossip
case, delegated keys, multi-tenant hosting. Not yet a required CI job.
Design: `docs/endpoint-sdk.md`.
