# sdk/flutter

The Dart/Flutter endpoint SDK: `HopEndpoint`, an embeddable Hop endpoint with an Express/Flask-shaped
surface, over the `libhop` C ABI via **`dart:ffi`**. Sibling to `sdk/python` (ctypes), `sdk/ruby`
(Fiddle), `sdk/go` (cgo), `sdk/node` (koffi), and `sdk/crystal` (`lib`); all SERVER SDKs, same C-ABI
contract. It is a plain Dart package (no Flutter-framework import), so it runs under `dart test` AND
inside a Flutter app. The only dependency is `package:ffi` (the dart.dev allocator + UTF-8 helpers,
the FFI toolchain, not an app framework).

```
lib/hop_endpoint.dart    the public library: exports the surface below
lib/src/library.dart     resolves + opens libhop (HOP_LIBDIR or target/{debug,release}, else the
                         system/Flutter-bundled library) with an ABI-version assert at load
lib/src/ffi.dart         raw dart:ffi bindings to libhop (one-to-one with hop_*, incl. sign/verify_reach)
                         + thin typed wrappers; the sink callbacks use NativeCallable.isolateLocal
lib/src/endpoint.dart    HopEndpoint (pump via Timer.periodic on the event loop) + HopRequest +
                         HopResponse + the HopReply callable + connectInProcess
lib/src/tcp_bearer.dart  the Internet bearer: length-prefixed frames over a dart:io Socket (core does Noise)
lib/src/wss_bearer.dart  the WSS bearer on dart:io's built-in TLS + WebSocket (HttpServer.bindSecure +
                         WebSocketTransformer; no third-party WS lib) + the attach/dialByName surface
lib/src/discovery.dart   wellKnownBody (signed reach record) + resolve (HTTPS fetch + verify)
example/ test/           raw_roundtrip (proves the ABI), echo, tcp, discovery, server/client, and a
                         test of in-process + TCP + reach + the full WSS/WebPKI discovery round trip
```

## Non-obvious things (dart:ffi footguns)

- **The pump is single-threaded, so there is NO lock.** Unlike the thread-per-pump SDKs (Python/Ruby/Go
  run a pump thread + bearer threads that all touch the node under a mutex), a Dart isolate is one
  thread with an event loop. `HopEndpoint` pumps via `Timer.periodic`, and the `dart:io` bearers do
  their socket I/O async on the SAME loop, so the node is only ever touched from one thread. `close()`
  cancels the timer, runs the bearer closers, fails in-flight `request` completers, and frees the node,
  all inline. Every native-touching path guards on `_closed` so a socket callback firing after teardown
  short-circuits instead of dereferencing `nullptr`.
- **Handlers run AFTER the poll returns, never inside the FFI callback.** `hop_poll_service_requests`
  holds the node's Rust `Mutex` while it invokes the sink; a handler that called back into
  `hop_send_service_response` from inside the sink would re-lock that non-reentrant mutex and deadlock.
  So the sinks are pure COLLECTORS (copy the row into a Dart list), and the pump dispatches handlers /
  bearer sends / completer wakeups after the native call has returned and released the lock. Same shape
  as Python's collect-then-dispatch.
- **Sink callbacks are `NativeCallable.isolateLocal`, created per call and closed after.** They fire
  synchronously on this isolate during the drain/poll call, so the isolate-local (blocking) variant is
  correct (never `.listener`, which is async and would let the pointer die first). Every pointer is
  copied immediately (`Uint8List.fromList(ptr.asTypedList(len))`); the pointer is valid only for the
  callback. A bool-returning sink needs `exceptionalReturn: false`.
- **C `_Bool` is a single byte; use ffi `Bool`, not a widened int.** `Bool` reads exactly one byte, so a
  dirty-upper-bit `false` cannot misread as `true` (the JNA footgun the Kotlin SDK documents). Binary
  args pass an explicit length; hop-core reads exactly `len` bytes, so embedded NUL bytes are fine.
- **`calloc<Utf8>` does NOT compile** (`Utf8` is unsized). Allocate the out buffer as `calloc<Uint8>(n)`
  and pass `.cast<Utf8>()` where the C ABI wants a `char*` (see `toBase58`). In-strings use
  `String.toNativeUtf8()` and must be freed.
- **`request()` auto-accepts on delivery.** The `takeServiceResponses` sink returns false (leaves the
  durable row), then the pump calls `hop_accept_service_response` right as it completes the awaiting
  `request` future and pops `_pending`. So a redelivery of the same response finds no pending entry and
  is dropped; the row is not redelivered forever.

## Verify

`cargo build -p hop` (or set `HOP_LIBDIR`), then from `sdk/flutter`: `dart pub get`, `dart analyze`
(clean), `dart format --output=none --set-exit-if-changed .`, and `dart test` (raw ABI, in-process,
TCP, reach record, and the full WSS + WebPKI discovery round trip against an in-process dev cert). The
WSS discovery test self-skips if `openssl` is unavailable. Prototype: has its own CI job (`flutter-sdk`),
a required check via the aggregate `CI gate`.
