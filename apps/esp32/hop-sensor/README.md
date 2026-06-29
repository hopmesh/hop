# hop-sensor — an ESP32 full-client example

A complete Hop client in pure C: it makes a node and POSTs a sensor reading to a `hops://` service,
reading the response — binding **only** `libhop`'s C ABI (`sdk/hop.h`). This is why an ESP32 (or any
embedded/C target) can be a *first-class* client, not just a bearer host: it doesn't need UniFFI.

## Run the example on a dev host

```sh
./build.sh        # builds libhop, compiles main.c against hop.h, runs it
# -> PASS: [sensor] hops:// response status=202 body="stored ok"
```

For the example to run on one machine, the "cloud" weather service is a second in-process node wired
by a loopback bearer. The only difference from a real deployment is **where the bytes travel**.

## Deploying on a real ESP32 (ESP-IDF)

1. **Build `libhop` for the chip.** Add the Xtensa/RISC-V Rust target (`esp32` via `esp-rs`), build
   `hop-ffi` as a `staticlib` for it, and link `libhop.a` + `hop.h` into your ESP-IDF component.
2. **Plug in a real bearer.** Replace the loopback with a transport that:
   - calls `hop_link_up` / `hop_bytes_received` / `hop_link_down` as the radio (BLE and/or LoRa)
     forms/loses links and receives frames, and
   - ships every packet from `hop_drain_outgoing` over that radio.
   The bearer is the *only* hardware-specific code; everything above it is this file unchanged.
3. **Keep the loop.** `hop_node_tick` ~1 Hz; drain/feed the bearer; `hop_send_service_request` to
   POST readings; `hop_poll_service_responses` for acks. Persist identity with `hop_node_secret` /
   restore with `hop_node_open`.

The contract (`hop.h`) is generated from Rust by cbindgen and is identical to the one the Swift and
Kotlin SDKs bind — one source of truth across every language.
