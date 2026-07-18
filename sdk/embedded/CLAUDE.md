# Hop for Embedded (`sdk/embedded` / the `hop-embedded` repo)

The embedded SDK: a thin Arduino / ESP-IDF C++ library (`hop::Hop`) over the `libhop` C ABI, published
to the PlatformIO registry as `Hop`. It is the MCU sibling of the other SDKs (a node on a
microcontroller, not a server), and it mirrors to the public `hop-embedded` repo.

This file helps you develop this component whether you are in the Hop monorepo or in the standalone
`hop-embedded` repo (the two stay in sync; the monorepo is the source of truth).

```
library.json          the PlatformIO manifest (name "Hop", Apache-2.0, framework arduino/espidf,
                      platform espressif32) + how the prebuilt libhop archive is linked per arch
src/Hop.h, Hop.cpp     the C++ wrapper: begin / synchronized Unix clock gate / monotonic tick,
                      forward-secret sendMessage/onMessage, explicit service RPC, the bearer seam,
                      and address/secret persistence. It declares the extern "C" libhop functions it
                      uses and calls them; the core owns crypto
include/               release contract notes for exact-target hop.h + libhop.a archives
link-libhop.py         verifies the signed manifest and extracts only the board's exact target archive
examples/blink_send/   forward-secret messaging with explicit SNTP/RTC readiness gating
examples/service_rpc/ complete addressed request/response example, separate from user messaging
```

## Non-obvious things

- **It wraps the C ABI, it does not reimplement anything.** Every function in `Hop.cpp` maps to a
  `hop_*` call in the C ABI header. Do not add protocol logic here; if the wrapper needs something the C
  ABI does not expose, that is a change to the ABI (in `libhop` / `core/hop` upstream), not here.
- **Two clock domains.** `tick(monotonic_ms)` takes wrapping local cadence only. A trusted Unix
  epoch-millisecond provider or `synchronizeClock` gate supplies authenticated protocol time. Never
  pass uptime to `hop_node_tick`; clockless devices initialize and wait without publishing/sending.
- **Poll model.** The core never calls you asynchronously. Draining and delivery happen inside `tick`
  after the clock gate opens. Inbound message and RPC models copy C callback bytes before invoking the
  application handler; only `onOutgoing` retains the explicit borrowed-pointer contract.
- **Messaging versus RPC.** User content is `sendMessage` -> `hop_send_message` and is always Double
  Ratchet protected or deferred. Addressed service calls use the separate `sendServiceRequest` /
  `sendServiceResponse` surface and complete request/response polling.
- **No radio.** The library moves opaque bytes across a bearer seam (`linkUp`/`bytesReceived`/`linkDown`
  + the `onOutgoing` handler). BLE, LoRa, and Wi-Fi are the integrator's to wire; that is deliberate, an
  MCU has many possible radios.
- **The minimal build.** libhop for MCUs is `hop-core` compiled with its `minimal` feature (no UniFFI,
  no SQLite), so storage is in-memory; persist identity via `secret()` into NVS/flash and restore it
  with `begin(secret, 32)`.
- **ABI version pin.** `HOP_EMBEDDED_ABI_VERSION` must track the C ABI's `HOP_ABI_VERSION`; `begin()`
  asserts `hop_abi_version()` matches, so a wrapper paired with a stale prebuilt archive fails loudly.
- **Exact target archives.** The release build cross-compiles each supported Xtensa and RISC-V target
  separately. `link-libhop.py` rejects unsigned, missing, duplicate, unexpected, traversing,
  wrong-target, or wrong-digest assets before extraction.

## Verify / build

PlatformIO: `pio pkg pack` (packages the library), and build the example with
`pio run -d examples/blink_send`. A full on-device build needs the prebuilt `libhop.a`, which the
release workflow produces; without it, gate on the manifest + a compile of the wrapper against a stub.
Run `bash test/run-host-tests.sh` for the strict-warning mock-C host contract suite.
Publish is `pio pkg publish` on a `vX.Y.Z` tag (see `.github/workflows/release.yml`).
