# sdk/python

The Python server-side endpoint SDK: `HopEndpoint`, an embeddable Hop endpoint with a Flask/FastAPI-
shaped surface, over the `libhop` C ABI via **ctypes** (stdlib, zero third-party deps). Sibling to
`sdk/node` (koffi) and `sdk/elixir` (Rustler); all SERVER SDKs, same C-ABI contract.

```
hop_endpoint/wss_bearer.py the WSS bearer + HTTPS server, in PURE STDLIB (no deps): a minimal RFC 6455
                           WebSocket (handshake + binary framing) + a threaded server that also answers
                           GET /.well-known/hop on the same port
hop_endpoint/discovery.py  well_known_body (signed reach record) + resolve (HTTPS fetch + verify)
hop_endpoint/_ffi.py       raw ctypes bindings to libhop (one-to-one with hop_*, incl. sign/verify_reach)
                           ; resolves the lib via
                           HOP_LIBDIR or target/{debug,release}
hop_endpoint/endpoint.py   HopEndpoint (pump THREAD + handler dispatch) + HopRequest + the reply callable
hop_endpoint/tcp_bearer.py the Internet bearer: length-prefixed frames over a socket (core does Noise)
hop_endpoint/__init__.py   exports + connect_in_process
examples/ tests/           raw_roundtrip (proves the ABI), echo, tcp, and a unittest of both round trips
```

## Non-obvious things (ctypes footguns)

- **`restype`/`argtypes` are set on every function.** Without `restype = c_void_p`, ctypes truncates a
  returned 64-bit pointer (node handle) to a 32-bit int, an instant crash. This is the classic ctypes
  bug; do not remove them.
- **Binary args go through `c_char_p` with an explicit length.** hop-core reads exactly `len` bytes, so
  embedded NUL bytes in wire/Noise data are fine (the length param, not NUL, bounds the read).
- **Sink callbacks run synchronously** during `hop_drain_outgoing` / `hop_poll_*`. The `@DRAIN_SINK`-
  decorated closures are kept alive for the duration of the call; pointers they receive are valid only
  then, so `ctypes.string_at(ptr, len)` copies immediately.
- **core is poll-model.** `HopEndpoint` runs a daemon pump THREAD (tick, drain to the bearer, take
  requests -> handlers, take responses -> resolve pending `request()` callers via a `threading.Event`).
  The node is thread-safe (interior Mutex), so the pump thread and a caller thread can both touch it.
  Handlers run inline in the pump; a slow handler stalls it (prototype simplification).
- **Bearer seam:** a bearer calls `endpoint._register_link(link, role, send_fn)` and feeds inbound
  frames via `_deliver`. `tcp_bearer` reassembles the 4-byte length prefix; `connect_in_process` wires
  two endpoints directly.

## Verify

`cargo build -p hop` (or set `HOP_LIBDIR`), then from `sdk/python`: `python3 -m unittest discover -s
tests` (both round trips) and the three `examples/*.py`. Prototype: not yet a required CI job.
