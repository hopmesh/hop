# sdk/ruby

The Ruby server-side endpoint SDK: `Hop::Endpoint`, an embeddable Hop endpoint with a Sinatra/Rails-
shaped surface, over the `libhop` C ABI via **Fiddle** (Ruby's stdlib FFI, like ctypes). Sibling to
`sdk/python` (ctypes), `sdk/node` (koffi), and `sdk/elixir` (Rustler); all SERVER SDKs, same C-ABI
contract. **Zero gems** (Fiddle, OpenSSL, Socket, Net::HTTP, JSON are all stdlib).

```
lib/hop/ffi.rb          raw Fiddle bindings to libhop (one-to-one with hop_*, incl. sign/verify_reach);
                        resolves the lib via HOP_LIBDIR or target/{debug,release}
lib/hop/endpoint.rb     Hop::Endpoint (pump THREAD + handler dispatch) + Request + the reply callable
lib/hop/wss_bearer.rb   the WSS bearer + HTTPS server in PURE STDLIB (no gems): a minimal RFC 6455
                        WebSocket (handshake + binary framing) + a threaded server that also answers
                        GET /.well-known/hop on the same port
lib/hop/discovery.rb    well_known_body (signed reach record) + resolve (HTTPS fetch + verify)
lib/hop/tcp_bearer.rb   the Internet bearer: length-prefixed frames over a socket (core does Noise)
lib/hop.rb              top-level requires + connect_in_process
examples/ test/         raw_roundtrip (proves the ABI) + a minitest of in-process, reach, WSS discovery
```

## Non-obvious things (Fiddle footguns)

- **Bool-returning natives are declared `TYPE_CHAR`** (the C ABI returns a 1-byte `_Bool`), read as
  `!= 0`. Do not widen to a full int; the upper bits are not guaranteed zero on a `false`.
- **Pointer returns/args are `TYPE_VOIDP`.** The node handle is an opaque `void*`; Ruby strings passed
  as `TYPE_VOIDP` marshal to a pointer to their bytes, and hop-core reads exactly `len` bytes, so
  embedded NUL bytes in wire/Noise data are fine (the explicit length param bounds the read).
- **Sink callbacks run synchronously** during `hop_drain_outgoing` / `hop_poll_*` via
  `Fiddle::Closure::BlockCaller`. Pointers they receive are valid only for that call, so `read_bytes`
  copies immediately. `read_bytes` guards `len == 0` (never dereference a possibly-null 0-length ptr).
- **Teardown is use-after-free-safe.** core is poll-model, so `Hop::Endpoint` runs a pump thread AND the
  WSS/TCP bearers run their own accept/read threads, all holding the node. `close` therefore: (1) sets
  `@closed` under a reentrant `Monitor`, (2) runs registered closers to shut bearer sockets so those
  threads unblock, (3) joins the pump, (4) frees the node under the same lock. Every libhop call on the
  node goes through `with_node`, which no-ops once `@closed` is set, so a bearer thread firing
  `link_down` as its socket EOFs after teardown short-circuits instead of dereferencing a freed node.
  The `Monitor` is reentrant on purpose: a `reply` issued from inside `pump` re-enters cleanly.
- **Bearer seam:** a bearer calls `endpoint.register_link(link, role, send_fn)` and feeds inbound frames
  via `deliver`; a bearer with a socket registers a teardown hook via `register_closer`. `tcp_bearer`
  reassembles the 4-byte length prefix; `connect_in_process` wires two endpoints directly.

## Verify

`cargo build -p hop` (or set `HOP_LIBDIR`), then from `sdk/ruby`: `ruby -Ilib test/test_hop.rb` (in-
process, reach record, and the full WSS discovery round trip) and `ruby examples/raw_roundtrip.rb`.
Toolchain: Ruby 3.3+ (system 2.6 is too old for the endless-method syntax). Prototype: not yet a
required CI job.
