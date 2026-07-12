# apps/esp32

`hop-sensor` is a full Hop client for an ESP32-class chip, written in **pure C against only the C ABI**
(`sdk/hop.h`), no UniFFI, no SQLite, no Rust on the call site. It is the proof that an ESP32 is a
first-class Hop client, not just a bearer host.

## Build

- Host smoke (what CI runs, proves `hop.h` is consumable from embedded-style C): `apps/esp32/hop-sensor/build.sh`. It builds libhop (`cargo build -p hop`) and compiles `main.c` against the generated header, then runs it end to end (expects `PASS: [sensor] hops:// response status=202`).
- Real ESP-IDF firmware build: see the app's `README.md`. `build-libhop-esp.sh` cross-compiles libhop for the chip; the `minimal` cargo feature drops UniFFI + the SQLite store for the embedded target.
- The host smoke binary (`hop-sensor`) is a build artifact and gitignored.

Because this app talks only to `sdk/hop.h`, a change to the C ABI header (`HOP_ABI_VERSION`, a signature)
can break it silently; the contract-purity + header-drift CI job guards the header, and this smoke build
is the end-to-end check that the header is still usable from plain C.
