<p align="center">
  <img alt="Hop" src="https://hopme.sh/hop-mark.svg" width="200">
</p>

<h1 align="center">hop-endpoint</h1>

<p align="center">
  <b>Receive Hop messages in your Crystal service.</b><br>
  A Sinatra/Rails-shaped endpoint on the <a href="https://hopme.sh">Hop</a> mesh, over the <code>libhop</code> C ABI.
</p>

<p align="center">
  <a href="https://github.com/hopmesh/hop-sdk-crystal/tags"><img src="https://img.shields.io/github/v/tag/hopmesh/hop-sdk-crystal?color=333333&label=shard&sort=semver" alt="shard"></a>
  <img src="https://img.shields.io/badge/license-Apache--2.0-3ddc84" alt="license">
  <img src="https://img.shields.io/badge/crystal-%E2%89%A51.15-6ea8fe" alt="crystal >=1.15">
</p>

---

Hop is a **delay-tolerant mesh**: end-to-end encrypted datagrams that hop device to device, over BLE,
Wi-Fi, and the internet, until they reach the person or service you meant. Held, never dropped.

`hop-endpoint` is the **server side**: your Crystal service becomes a first-class address on the mesh, so
senders hand messages straight to it. Self-host is an import, not an ops project. No inbound port to open
to the world, no bearer tokens to rotate, no message queue to run: the sender identity is authenticated
by the ratchet, and delivery is durable and store-and-forward. **Zero shards**: Crystal binds libhop
directly with `lib`, and the WSS bearer plus discovery ride the stdlib.

## Install

Add it to `shard.yml`, then `shards install`:

```yaml
dependencies:
  hop-endpoint:
    github: hopmesh/hop-sdk-crystal
```

You also need `libhop`, the Rust protocol core, as a prebuilt binary or a local build. Crystal links it
at compile time; its default `-L` points at a local build, or add your `libhop` dir to
`CRYSTAL_LIBRARY_PATH` (or `HOP_LIBDIR`). See [libhop](https://github.com/hopmesh/libhop).

## Quick start

```crystal
require "hop"
require "json"

hop = Hop::Endpoint.new

hop.on("acme/orders") do |req, reply|
  # req.from is a VERIFIED identity (base58), not a spoofable header
  order = JSON.parse(req.text)
  reply.call(201, {ok: true, order: order}.to_json) # uint16 status + body
end

Hop::TcpBearer.listen(hop, 9944) # reachable by any device
puts hop.address                 # publish this (or its name); senders reach you by it
```

Crystal has channels, so besides the block handler you can consume verified requests on a `Channel` and
reply from your own fiber (natural for a long-running server, or a `select` across several services):

```crystal
orders = hop.channel("acme/orders")
spawn do
  loop do
    req, reply = orders.receive
    reply.call(201, req.text)
  end
end
```

Same delivery either way; `channel` is just `on` wired to a `Channel`.

**The DX looks like HTTP; the semantics are better.** Inbound is a durable, store-and-forward consume; a
reply is a new addressed message that may arrive later, even after a restart. It works when the peer is
offline, and there is no auth layer to bolt on, the identity is cryptographic. core is poll-model, so the
endpoint runs a background pump fiber (the node is thread-safe).

## Reachable by name

Make an endpoint reachable at `myaddress.com` with no new port, on Crystal's stdlib `HTTP::WebSocket` +
`HTTP::Server` (zero shards). `attach` wires the WSS bearer (`/_hop`) and the discovery route
(`/.well-known/hop`) in one call:

```crystal
tls = OpenSSL::SSL::Context::Server.new
tls.certificate_chain = "cert.pem"
tls.private_key = "key.pem"
hop.attach(443, tls, "wss://myaddress.com/_hop")
```

A client reaches it by name, verified end to end:

```crystal
address = client.dial_by_name("https://myaddress.com")
status, body = client.request(address, "acme/orders", "create", order)
```

TLS proves the domain, a signed **reach record** proves the address, and the Noise handshake confirms it.
Spoof the `A` record or MITM the lookup and the attacker still can't forge the cert or complete the
handshake as the address, and a request sealed to that address is unreadable to anyone else.

## How it maps to the core

The endpoint is a `hop-core` node in host-a-mailbox mode, over the same C ABI every Hop SDK binds (via
`lib`), with zero core changes:

| Endpoint                   | libhop C ABI                                               |
| -------------------------- | ---------------------------------------------------------- |
| `hop.on(svc) { }`          | `hop_subscribe` + `hop_poll_service_requests`              |
| `reply.call(status, body)` | `hop_send_service_response` (status is a `uint16`)         |
| `hop.request(...)`         | `hop_send_service_request` + `hop_poll_service_responses`  |
| the Internet bearer        | `hop_link_up` / `hop_bytes_received` / `hop_drain_outgoing`|

## Examples

Build or fetch `libhop`, then:

```sh
crystal spec                        # in-process + reach record + WSS discovery, all pass
crystal run examples/raw_roundtrip.cr # raw C ABI round trip (proves the lib bindings)
crystal run examples/echo.cr        # the hop.on / reply DX in-process
crystal run examples/tcp.cr         # the same round trip over a real TCP bearer
crystal run examples/discovery.cr   # the full reachable-by-name chain (HTTPS + WSS)
```

Two-process shape (a standalone server on the channel surface, plus a client):

```sh
crystal run examples/server.cr              # prints its address, listens on tcp://0.0.0.0:9944
crystal run examples/client.cr -- <address> localhost 9944
```

The discovery test generates its self-signed cert in-process (`Hop::DevTls`), no `openssl` CLI.

## Status

Prototype. Built and working: the `on` block handler and the `channel` surface, `reply`, the client
`request`, the in-process / TCP / WSS bearers, base58 addressing, reach-record `attach` / `dial_by_name`
discovery, sibling-replica clustering, the ABI-version assert, and a use-after-free-safe `close` (a
bearer fiber that fires after teardown short-circuits instead of touching a freed node). HNS name
publish/resolve and multi-tenant hosting are on the roadmap (each an SDK-level follow-up, not a core
change).

## The Hop family

`hop-endpoint` is one of several SDKs over the same C ABI. Same surface, your language:
[node](https://github.com/hopmesh/hop-sdk-node) ·
[python](https://github.com/hopmesh/hop-sdk-python) ·
[go](https://github.com/hopmesh/hop-sdk-go) ·
[ruby](https://github.com/hopmesh/hop-sdk-ruby) ·
[crystal](https://github.com/hopmesh/hop-sdk-crystal) ·
[elixir](https://github.com/hopmesh/hop-sdk-elixir).
The protocol core is [libhop](https://github.com/hopmesh/libhop) / [hop-core](https://github.com/hopmesh/hop-core).

## License

[Apache-2.0](./LICENSE.md), embed it freely. Only the protocol core (`hop-core`) is FSL-1.1-ALv2,
source-available and converting to Apache-2.0 after two years.
