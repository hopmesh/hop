<p align="center">
  <img alt="Hop" src="https://hopme.sh/hop-mark.svg" width="200">
</p>

<h1 align="center">hop-sdk-go</h1>

<p align="center">
  <b>Receive Hop messages in your Go service.</b><br>
  A net/http-shaped endpoint on the <a href="https://hopme.sh">Hop</a> mesh, over the <code>libhop</code> C ABI.
</p>

<p align="center">
  <a href="https://pkg.go.dev/github.com/hopmesh/hop-sdk-go"><img src="https://pkg.go.dev/badge/github.com/hopmesh/hop-sdk-go.svg" alt="Go Reference"></a>
  <img src="https://img.shields.io/badge/license-Apache--2.0-3ddc84" alt="license">
  <img src="https://img.shields.io/badge/go-%E2%89%A51.21-6ea8fe" alt="go >=1.21">
</p>

---

Hop is a **delay-tolerant mesh**: end-to-end encrypted datagrams that hop device to device, over BLE,
Wi-Fi, and the internet, until they reach the person or service you meant. Held, never dropped.

`hop-sdk-go` is the **server side**: your Go service becomes a first-class address on the mesh, so senders
hand messages straight to it. Self-host is an import, not an ops project. No inbound port to open to the
world, no bearer tokens to rotate, no message queue to run: the sender identity is authenticated by the
ratchet, and delivery is durable and store-and-forward.

## Install

Install the signed native core to a stable user prefix, export the emitted environment, then add the
same module version:

```sh
go run github.com/hopmesh/hop-sdk-go/cmd/hop-install@v0.0.1 --version v0.0.1

export HOP_PREFIX="$HOME/.local/hop/v0.0.1"
export PKG_CONFIG_PATH="$HOP_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

# macOS
export DYLD_LIBRARY_PATH="$HOP_PREFIX/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
# Linux
export LD_LIBRARY_PATH="$HOP_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

go get github.com/hopmesh/hop-sdk-go@v0.0.1
```

The versioned command runs directly from Go's read-only module cache but writes only to
`$HOME/.local/hop/v0.0.1` (override the base with `--prefix`). It verifies the detached signature over
the canonical native manifest, canonical builder identity, release tag, source SHA, exact host target,
archive inventory, size, and every SHA-256 before installation. The installed `hop.pc` supplies both
`hop.h` and `libhop`; cgo has no parent-checkout or writable-module-cache assumption. The release job
also verifies the attached GitHub OIDC SLSA provenance bundle before publishing these signed assets.

## Quick start

```go
package main

import (
	"fmt"

	hop "github.com/hopmesh/hop-sdk-go"
)

func main() {
	server, _ := hop.New()

	server.On("acme/orders", func(req *hop.Request, reply hop.Reply) {
		// req.From is a VERIFIED identity, not a spoofable header
		reply(201, req.Args) // uint16 status + bytes body
	})

	hop.Listen(server, 9944)      // reachable by any device
	fmt.Println(server.Address()) // publish this (or its name); senders reach you by it
}
```

**The DX looks like HTTP; the semantics are better.** Inbound is a durable, store-and-forward consume; a
reply is a new addressed message that may arrive later, even after a restart. It works when the peer is
offline, and there is no auth layer to bolt on, the identity is cryptographic. core is poll-model, so the
endpoint runs a pump goroutine (the node is thread-safe).

## Reachable by name

Make an endpoint reachable at `myaddress.com` with no new port. In Go a WS upgrade is a plain
`http.Handler`, so `Attach` wires the WSS bearer (`/_hop`) and the discovery route (`/.well-known/hop`)
into your mux in one call:

```go
httpsServer := hop.NewHTTPServer(":443", appHandler)
if err := server.Attach(httpsServer, "wss://myaddress.com/_hop"); err != nil {
    log.Fatal(err)
}
log.Fatal(httpsServer.ListenAndServeTLS(cert, key))
```

`(*Endpoint).Attach` is mandatory and must run before any serve method. The returned server path installs
raw `ConnState` admission before TLS, one absolute five-second TLS plus HTTP-head deadline, a 16 KiB
header cap, and bounded pending and WebSocket workers. Starting an unattached server or attaching after
start returns an error; these limits cannot be left as optional caller configuration.

A client reaches it by name, verified end to end:

```go
address, _ := client.DialByName("https://myaddress.com", false)
status, body, _ := client.Request(address, "acme/orders", "create", order)
```

TLS proves the domain, a signed **reach record** proves the address, and the Noise handshake confirms it.
Spoof the `A` record or MITM the lookup and the attacker still can't forge the cert or complete the
handshake as the address, and a request sealed to that address is unreadable to anyone else.

## How it maps to the core

The endpoint is a `hop-core` node in host-a-mailbox mode, over the same C ABI every Hop SDK binds (via
cgo), with zero core changes:

| Endpoint                | libhop C ABI                                               |
| ----------------------- | ---------------------------------------------------------- |
| `server.On(svc, h)`     | `hop_subscribe` + `hop_poll_service_requests`              |
| `reply(status, body)`   | `hop_send_service_response` (status is a `uint16`)         |
| `client.Request(...)`   | `hop_send_service_request` + `hop_poll_service_responses`  |
| the Internet bearer     | `hop_link_up` / `hop_bytes_received` / `hop_drain_outgoing`|

## Examples

Install `libhop` and export the `HOP_PREFIX` environment shown above, then:

```sh
go test ./...               # raw ABI + in-process + TCP + reach record + WSS discovery, all pass
go run ./examples/echo      # the On / reply DX in-process
go run ./examples/tcp       # the same round trip over a real TCP bearer
go run ./examples/discovery # the full reachable-by-name chain (HTTPS + WSS)
```

Two-process shape (a standalone server plus a client that dials it):

```sh
go run ./examples/server                       # prints its address, listens on tcp://0.0.0.0:9944
go run ./examples/client <address> localhost 9944
```

(The raw C ABI round trip lives in `TestRawRoundTrip`, since Go's FFI layer is unexported; `go test`
runs it.)

## Status

Prototype. Built and working: `On` and `reply`, the client `Request`, the in-process / TCP / WSS bearers,
base58 addressing, reach records (`SignReach` / `VerifyReach`) with `Attach` / `DialByName` discovery,
sibling-replica clustering, and the ABI-version assert. HNS name publish/resolve and multi-tenant hosting
are on the roadmap (each an SDK-level follow-up, not a core change).

## The Hop family

`hop-sdk-go` is one of several SDKs over the same C ABI. Same surface, your language:
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
