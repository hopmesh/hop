# sdk/go

The Go server-side endpoint SDK: `hop.Endpoint`, an embeddable Hop endpoint with an net/http-shaped
surface, over the `libhop` C ABI via **cgo**. Sibling to `sdk/node` (koffi), `sdk/elixir` (Rustler),
and `sdk/python` (ctypes); all SERVER SDKs, same C-ABI contract.

```
hop.go            the cgo layer: C trampolines for the sink callbacks (incl. reach) + Go wrappers over hop_*
endpoint.go       hop.Endpoint (pump GOROUTINE + handler dispatch) + Request + the Reply func type
tcp_bearer.go     the raw-TCP Internet bearer (length-prefixed frames over net.Conn) + ConnectInProcess
wss_bearer.go     the WSS Internet bearer (gorilla/websocket; one WS message = one frame, no prefix)
discovery.go      SignReach/VerifyReach + the /.well-known/hop responder + Resolve + Attach + DialByName
raw_test.go       proves the cgo layer (the cabi.rs round trip)
endpoint_test.go  in-process + TCP round trips
discovery_test.go reach record sign/verify + the full HTTPS well-known + WSS discovery round trip
examples/tcp/     a runnable demo
```

Reachable-by-name: create a `NewHTTPServer`, then `endpoint.Attach(server, publicURL)` before serving.
Attach wires `/_hop` (WSS) + `/.well-known/hop` and makes raw connection admission, TLS/header
deadlines, parser caps, and worker limits mandatory. `DialByName` fetches the well-known (TLS proves the domain), verifies the
self-certifying reach record, dials the WSS, and the Noise handshake confirms the address.
The reach cgo bindings reuse the trampoline + `runtime/cgo.Handle` pattern from the sink callbacks.

## Non-obvious things (cgo footguns)

- **core's sink callbacks need C trampolines.** cgo can't hand a Go func to a C function pointer, so
  `hop.go`'s preamble has three tiny C trampolines (`drain_tramp`, ...) that call back into `//export`ed
  Go functions (`goDrainSink`, ...). The collector is passed through as a `uintptr`-encoded
  `runtime/cgo.Handle` in the `ctx` arg (encoded as `uintptr_t`, not `void*`, to keep cgo happy), and
  decoded via `cgo.Handle(ctx).Value()`. Each call makes + deletes its own handle.
- **Copybara rewrites cgo paths for the public module.** In the monorepo, `hop.go` reaches the canonical
  `sdk/hop.h` and `target/debug`. The exact export keeps a root-level standalone `hop.h` in the module
  archive but rewrites cgo to `pkg-config: hop`. `go run github.com/hopmesh/hop-sdk-go/cmd/hop-install@VERSION`
  verifies and installs one signed target under a stable user prefix, then emits the exact
  `PKG_CONFIG_PATH` and loader environment. It never writes the Go module cache.
- **Binary in-params via `C.CBytes` (copy + `C.free`); out-params via `&slice[0]` + `runtime.KeepAlive`.**
  Do not pass a Go slice pointer into a call that may retain it; core copies synchronously so it is safe
  here, but keep the slice alive across the call.
- **core is poll-model.** `Endpoint` runs a pump GOROUTINE (ticker: tick, drain to bearer, take
  requests -> handlers, take responses -> resolve `Request` callers via a channel). The node is
  thread-safe (interior Mutex), so the pump, bearer, and caller goroutines can all touch it; the Go-side
  maps are guarded by `e.mu`. Handlers run inline in the pump; a slow handler stalls it (prototype).

## Verify

`cargo build -p hop`, then from `sdk/go`: `gofmt -l .` (clean), `go vet ./...`, `go test ./...` (raw +
in-process + TCP), `go run ./examples/tcp`. The first cgo build is slow (~1 min). Prototype: not yet a
required CI job.
