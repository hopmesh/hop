# sdk/go

The Go server-side endpoint SDK: `hop.Endpoint`, an embeddable Hop endpoint with an net/http-shaped
surface, over the `libhop` C ABI via **cgo**. Sibling to `sdk/node` (koffi), `sdk/elixir` (Rustler),
and `sdk/python` (ctypes); all SERVER SDKs, same C-ABI contract.

```
hop.go            the cgo layer: C trampolines for the sink callbacks + Go wrappers over hop_*
endpoint.go       hop.Endpoint (pump GOROUTINE + handler dispatch) + Request + the Reply func type
tcp_bearer.go     the Internet bearer (length-prefixed frames over net.Conn) + ConnectInProcess
raw_test.go       proves the cgo layer (the cabi.rs round trip)
endpoint_test.go  in-process + TCP round trips
examples/tcp/     a runnable demo
```

## Non-obvious things (cgo footguns)

- **core's sink callbacks need C trampolines.** cgo can't hand a Go func to a C function pointer, so
  `hop.go`'s preamble has three tiny C trampolines (`drain_tramp`, ...) that call back into `//export`ed
  Go functions (`goDrainSink`, ...). The collector is passed through as a `uintptr`-encoded
  `runtime/cgo.Handle` in the `ctx` arg (encoded as `uintptr_t`, not `void*`, to keep cgo happy), and
  decoded via `cgo.Handle(ctx).Value()`. Each call makes + deletes its own handle.
- **`#cgo CFLAGS` include path is `${SRCDIR}/..`** (to reach `sdk/hop.h`), and `LDFLAGS` `-L` +
  `-Wl,-rpath` point at `${SRCDIR}/../../target/debug`. libhop's install name is absolute, so it also
  resolves without the rpath, but the rpath makes a relocated build dir work. Override with
  `CGO_LDFLAGS` if libhop lives elsewhere.
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
