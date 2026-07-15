# Hop for Embedded (`sdk/embedded` / the `hop-embedded` repo)

The embedded SDK: a thin Arduino / ESP-IDF C++ library (`hop::Hop`) over the `libhop` C ABI, published
to the PlatformIO registry as `Hop`. It is the MCU sibling of the other SDKs (a node on a
microcontroller, not a server), and it mirrors to the public `hop-embedded` repo.

This file helps you develop this component whether you are in the Hop monorepo or in the standalone
`hop-embedded` repo (the two stay in sync; the monorepo is the source of truth).

```
library.json          the PlatformIO manifest (name "Hop", Apache-2.0, framework arduino/espidf,
                      platform espressif32) + how the prebuilt libhop archive is linked per arch
src/Hop.h, Hop.cpp     the C++ wrapper: begin / tick / subscribe / send / onMessage / onOutgoing, the
                      bearer seam (linkUp/bytesReceived/linkDown), address/secret persistence. It
                      declares the extern "C" libhop functions it uses and calls them; the core owns crypto
include/               a note: hop.h (the C ABI) and prebuilt/<arch>/libhop.a are staged by the release build
link-libhop.py         the PlatformIO extra script that points the linker at the right prebuilt libhop.a
examples/blink_send/   a runnable PlatformIO/Arduino example (open a node, tick, send on a button, print rx)
```

## Non-obvious things

- **It wraps the C ABI, it does not reimplement anything.** Every function in `Hop.cpp` maps to a
  `hop_*` call in the C ABI header. Do not add protocol logic here; if the wrapper needs something the C
  ABI does not expose, that is a change to the ABI (in `libhop` / `core/hop` upstream), not here.
- **Poll model.** The core never calls you asynchronously; everything (drain outbound, deliver inbound,
  publish prekey, retransmit) happens inside `tick(now_ms)`. The `onOutgoing` / `onMessage` callbacks
  fire from inside `tick`. Pointers handed to a callback are borrowed for that call only; copy what you keep.
- **No radio.** The library moves opaque bytes across a bearer seam (`linkUp`/`bytesReceived`/`linkDown`
  + the `onOutgoing` handler). BLE, LoRa, and Wi-Fi are the integrator's to wire; that is deliberate, an
  MCU has many possible radios.
- **The minimal build.** libhop for MCUs is `hop-core` compiled with its `minimal` feature (no UniFFI,
  no SQLite), so storage is in-memory; persist identity via `secret()` into NVS/flash and restore it
  with `begin(secret, 32)`.
- **ABI version pin.** `HOP_EMBEDDED_ABI_VERSION` must track the C ABI's `HOP_ABI_VERSION`; `begin()`
  asserts `hop_abi_version()` matches, so a wrapper paired with a stale prebuilt archive fails loudly.
- **Two prebuilt arches.** The release build cross-compiles `libhop.a` for ESP32 xtensa (needs the
  esp-rs Rust fork) and riscv (stock Rust). `link-libhop.py` selects the archive for the board's arch.

## Verify / build

PlatformIO: `pio pkg pack` (packages the library), and build the example with
`pio run -d examples/blink_send`. A full on-device build needs the prebuilt `libhop.a`, which the
release workflow produces; without it, gate on the manifest + a compile of the wrapper against a stub.
Publish is `pio pkg publish` on a `vX.Y.Z` tag (see `.github/workflows/release.yml`).
