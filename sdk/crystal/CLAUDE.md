# sdk/crystal

The Crystal server-side endpoint SDK: `Hop::Endpoint`, an embeddable Hop endpoint with a Sinatra/Rails-
shaped surface, over the `libhop` C ABI via Crystal's built-in `lib` bindings. Sibling to `sdk/ruby`
(Fiddle), `sdk/python` (ctypes), `sdk/node` (koffi), `sdk/go` (cgo), `sdk/elixir` (Rustler); all SERVER
SDKs, same C-ABI contract. **Zero shards** (Crystal binds C directly; the WSS bearer + discovery ride
the stdlib HTTP::WebSocket / HTTP::Server / HTTP::Client / OpenSSL / JSON).

```
src/hop/ffi.cr        the `lib LibHop` C bindings + thin Hop::FFI helpers (one-to-one with hop_*, incl.
                      sign/verify_reach); links libhop via -L in @[Link] (default target/debug)
src/hop/endpoint.cr   Hop::Endpoint (pump FIBER + handler dispatch) + Request + the Reply struct; the
                      `on` block surface AND the idiomatic `channel` surface (Channel({Request, Reply}))
src/hop/wss_bearer.cr the WSS bearer on stdlib HTTP::WebSocket (server + client) + HTTP::Server; also
                      answers GET /.well-known/hop on the same port
src/hop/discovery.cr  well_known_body (signed reach record) + resolve (HTTPS fetch + verify)
src/hop/tcp_bearer.cr the Internet bearer: length-prefixed frames over a socket (core does Noise)
src/hop/dev_tls.cr    DEV/TEST ONLY: in-process self-signed cert (reopens LibCrypto/LibSSL for keygen +
                      X509 sign, no openssl CLI); used by discovery.cr + the spec
src/hop.cr            top-level requires + connect_in_process
examples/ spec/       raw_roundtrip, echo, tcp, server (channel surface), client, discovery + a spec
```

## Non-obvious things (Crystal C-binding footguns)

- **C-callback procs must NOT be closures.** The sink procs passed to `hop_drain_outgoing` /
  `hop_poll_*` reference only their params, the `Box` type, and fully-qualified `Hop::FFI` methods, so
  they carry no captured `self` and convert to a C function pointer. Captured state travels through the
  `Void* ctx` via `Box.box` / `Box(...).unbox` (see `Hop::FFI.drain_outgoing`). Do not make them close
  over locals.
- **Pointers valid only during a call.** Sinks copy immediately: `read_bytes` does `Slice.new(ptr,
  len).dup` and guards `ptr.null? || len == 0`; `read_cstr` guards null.
- **`out` is a reserved word.** Local buffers are named `buf`, never `out`.
- **libhop is found via `-L#{__DIR__}/../../../../target/debug` in `@[Link]`** (`#{__DIR__}` resolves at
  compile time; `{{ }}` macros do NOT work in an annotation string). libhop's install_name is absolute,
  so the binary finds the dylib at runtime with no rpath/env. Point at a release build by adding its dir
  to `CRYSTAL_LIBRARY_PATH` (an extra `-L`).
- **Teardown is use-after-free-safe.** core is poll-model, so `Hop::Endpoint` runs a pump fiber AND the
  bearers run their own accept/read fibers, all holding the node. `close` sets `@closed` under a
  reentrant `Mutex`, runs registered closers to shut bearer sockets so those fibers exit, then frees the
  node under the same lock. Every libhop call goes through `with_node`, which no-ops once `@closed` is
  set, so a bearer fiber firing `link_down` as its socket closes after teardown short-circuits instead
  of dereferencing a freed node. The `Mutex` is reentrant so a `reply` issued from inside `pump` re-
  enters; the pump holds the lock only across the fast C calls, never across bearer IO or handlers.
- **`dev_tls.cr` reopens the stdlib `LibCrypto`/`LibSSL`** to add keygen + X509 sign funs (the stdlib
  binds X509 for parsing only). It reuses their pkg-config link + `Void*` type aliases and uses the
  classic OpenSSL 1.1 EC path (`EC_KEY_new_by_curve_name` + `EVP_PKEY_assign`), which also works on 3.x.

## Verify

`cargo build -p hop` (or set `HOP_LIBDIR`), then from `sdk/crystal`: `crystal spec` (in-process, reach
record, and the full WSS discovery round trip) and the six `examples/*.cr`. Toolchain: Crystal 1.15+.
Prototype: not yet a required CI job.
