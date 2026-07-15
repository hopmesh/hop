# hop (Go endpoint SDK, prototype)

Receive Hop messages in Go with an net/http-shaped surface, over the `libhop` C ABI via cgo. Same idea
as `sdk/node`, `sdk/elixir`, and `sdk/python`: your service becomes directly reachable on the mesh, so
senders hand messages straight to it without a relay.

```go
server, _ := hop.New()

server.On("acme/orders", func(req *hop.Request, reply hop.Reply) {
    // req.From is a cryptographically VERIFIED identity, not a spoofable header
    reply(201, req.Args) // uint16 status + bytes body
})

hop.Listen(server, 9944)     // reachable by any device; in production HNS resolves name -> host/port/key
fmt.Println(server.Address()) // publish this (or its HNS name)
```

## What it is (and isn't)

The endpoint is a `hop-core` node in service-host mode. The mapping onto the C ABI is exact:

| Endpoint concept        | libhop C ABI                                              |
| ----------------------- | --------------------------------------------------------- |
| `server.On(service, h)` | `hop_subscribe` + `hop_poll_service_requests`             |
| `reply(status, body)`   | `hop_send_service_response` (status is a `uint16`)        |
| `client.Request(...)`   | `hop_send_service_request` + `hop_poll_service_responses` |
| the Internet bearer     | `hop_link_up` / `hop_bytes_received` / `hop_drain_outgoing` |

**The DX is HTTP-shaped; the semantics are not.** Inbound is a durable store-and-forward consume; a
reply is a new addressed message that may arrive later. It is a queue consumer, not a synchronous
handler, that is what makes it offline-tolerant. core is poll-model, so the endpoint runs a pump
goroutine (the node is thread-safe).

## Build + run

cgo compiles against `sdk/hop.h` and links `libhop`. Build `libhop` first (or set the loader path):

```sh
cargo build -p hop          # from the repo root -> target/debug/libhop.<dylib|so>
cd sdk/go
go test ./...               # raw ABI + in-process + real TCP + reach record + WSS discovery, all pass
go run ./examples/echo      # the On / reply DX in-process
go run ./examples/tcp       # the same round trip over a real TCP bearer
go run ./examples/discovery # WSS + WebPKI + reach-record discovery (in-process cert)
```

Two-process shape (a standalone server + a client that dials it):

```sh
go run ./examples/server                       # prints its address, listens on tcp://0.0.0.0:9944
go run ./examples/client <address> localhost 9944
```

(The raw C ABI round trip lives in `TestRawRoundTrip` rather than an example, since Go's FFI layer is
unexported; `go test` runs it.)

The cgo `LDFLAGS` point `-L`/`-rpath` at `../../target/debug`. Set `CGO_LDFLAGS` if your `libhop` lives
elsewhere.

## Reachable by name (WSS + discovery)

Make an endpoint reachable at `myaddress.com` with **no new port**. In Go a WS upgrade is
a normal `http.Handler`, so `Attach` wires the WSS bearer and the discovery route into your mux in one
call:

```go
mux := http.NewServeMux()
hop.Attach(mux, "wss://myaddress.com/_hop")   // /_hop (WSS) + /.well-known/hop
http.ListenAndServeTLS(":443", cert, key, mux)
```

```go
address, _ := client.DialByName("https://myaddress.com", false) // WebPKI + self-certifying
status, body, _ := client.Request(address, "acme/orders", "create", order)
```

Trust: `dialByName` fetches `/.well-known/hop` (TLS proves the domain), verifies the
self-certifying reach record (signed by the address), then the Noise handshake over the WSS confirms
the address. `discovery_test.go` proves the full chain against an in-process self-signed HTTPS server.

## Prototype scope

Built and working: `On`, `reply`, `Request`, the pump goroutine, TCP + WSS bearers, base58 addressing,
reach records (`SignReach`/`VerifyReach`), `Attach`/`DialByName` discovery, ABI-version assertion.
Follow-ups (each additive, none a core change): the no-domain gossip case,
delegated keys, multi-tenant hosting. Not yet a required CI job. Design: `docs/endpoint-sdk.md`.
