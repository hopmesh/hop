# hop-sensor - an ESP32 full client

A complete Hop client for an ESP32-class chip, written in pure C against **only** `libhop`'s C ABI
(`sdk/hop.h`) with no UniFFI, SQLite, or Rust on the call site. This is why an ESP32 can be a
*first-class* Hop client, not just a bearer host.

Two things live here:

1. **A host demo** (`main.c` + `build.sh`) that runs the client loop on your dev machine, wiring a
   second in-process node over a loopback bearer so you can see a full `hops://` request/response
   without hardware.
2. **A real ESP-IDF project** (`CMakeLists.txt`, `main/`, `components/libhop/`,
   `build-libhop-esp.sh`) that cross-compiles the `minimal` libhop for the chip and links it into a
   flashable image. The bearer and trusted clock source remain platform integration points.

## Run the host demo (no hardware)

```sh
./build.sh
# -> PASS: [sensor] hops:// response status=202 body="stored ok"
```

## Build for a real ESP32 (ESP-IDF)

The chip build uses the **`minimal`** cargo feature of the `hop` crate, which drops UniFFI and the
SQLite store, leaving a lean C-ABI archive backed by an in-memory store. Confirm it builds on the host
first (no cross toolchain needed):

```sh
cargo build -p hop --no-default-features --features minimal   # host smoke-check: compiles clean
```

### Prerequisites (one-time)

- **ESP-IDF** >= 5.0, with `. $IDF_PATH/export.sh` sourced (gives you `idf.py`).
- **esp-rs toolchain**: `espup install` (adds the `esp` Rust channel and the `*-esp-espidf` targets),
  then `cargo install ldproxy`. RISC-V chips (esp32c3/c6/h2) can use a recent nightly with the espidf
  target added; Xtensa chips (esp32/s2/s3) REQUIRE the `esp` channel.

libhop still uses `std` (HashMap/Mutex/Vec), so it targets the ESP-IDF **std tier** (`*-esp-espidf`,
e.g. `riscv32imc-esp-espidf`) where ESP-IDF supplies a newlib-backed std - not the bare `-none-elf`
no_std tier.

### Build + flash

```sh
# 1. Cross-compile libhop for the chip and stage libhop.a + hop.h into components/libhop/.
./build-libhop-esp.sh esp32c3          # or esp32c6 / esp32 / esp32s3 ...

# 2. Point ESP-IDF at the same chip and build the image (links components/libhop/lib/libhop.a).
idf.py set-target esp32c3
idf.py build

# 3. The ONLY on-hardware step: flash + watch the logs.
idf.py -p /dev/ttyUSB0 flash monitor
# -> I (...) hop-sensor: libhop ABI version 7
# -> W (...) hop-sensor: protocol gated: implausible Unix time
# -> I (...) hop-sensor: trusted Unix clock synchronized; protocol ready
# -> I (...) hop-sensor: POST weather/report seq=1
```

## Clock synchronization is mandatory

`hop_node_tick` takes Unix epoch milliseconds, not time since boot. Advert expiry, prekey rotation,
mailbox epochs, receiver beacons, and bundles all authenticate that clock. Passing FreeRTOS ticks,
`esp_timer_get_time()`, or another uptime counter creates near-zero records that peers reject.

`main/hop_main.c` registers an ESP-IDF SNTP synchronization callback, then reads the wall clock through
`gettimeofday()` and applies a second validation gate:

- no protocol tick, prekey publication, link input, request, response poll, or outgoing drain occurs
  before the epoch is plausible;
- a regressing or stale wall clock closes the gate without passing the bad value to libhop;
- FreeRTOS ticks are used only for local report scheduling and stale-clock detection, with unsigned
  rollover-safe subtraction;
- after reboot, the gate starts closed even when the Hop identity is restored.

Initialize ESP-IDF SNTP after the network is up. Its callback explicitly confirms the first trusted
sample and SNTP updates the same wall clock returned by `gettimeofday()`. A trusted RTC, GNSS receiver,
or provisioned host calls `hop_sensor_mark_clock_synchronized()` only after setting and validating the
system wall clock. A clockless/offline device may initialize its radio and wait; it must not call the
Hop bearer seam or publish/send until the gate reports ready.

## What an integrator must supply: the bearer

`main/hop_main.c` runs the whole client loop; the ONE piece of hardware-specific code is a **bearer**:

- call `hop_link_up` / `hop_bytes_received` / `hop_link_down` as a radio (BLE and/or LoRa) forms,
  receives on, and loses links, and
- ship every packet handed to the `hop_drain_outgoing` callback out over that radio.

The bearer TX function in `hop_main.c` remains a stub so the project builds and links without choosing
a radio. Persist identity across reboots by saving `hop_node_secret()` to NVS and restoring it with
`hop_node_with_secret()`, then synchronize Unix time again before protocol work.

## Layout

```
CMakeLists.txt              top-level ESP-IDF project
main/
  hop_main.c                app_main: the on-chip client loop (calls the C ABI)
  CMakeLists.txt            registers the app component, REQUIRES libhop
  idf_component.yml         component manifest (idf >= 5.0)
components/libhop/
  CMakeLists.txt            imports the prebuilt libhop.a + exposes hop.h
  include/hop.h             (staged by build-libhop-esp.sh) the generated C ABI header
  lib/libhop.a              (staged by build-libhop-esp.sh) libhop cross-compiled for the chip
build-libhop-esp.sh         cross-compiles the `minimal` libhop and stages the two artifacts above
main.c, build.sh            the no-hardware host demo
```

The contract (`hop.h`) is generated from Rust by cbindgen and is identical to the one the Swift and
Kotlin SDKs bind - one source of truth across every language.
