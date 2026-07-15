# include/

Two build inputs land in this library from the release build, not from source control history:

- **`hop.h`** , the generated libhop C ABI header. It is produced by cbindgen from the Hop core
  (`hop-core` / `libhop`) and is byte-identical across every Hop SDK, so it is not copied by hand into
  this repo (a hand copy would drift). The release workflow regenerates it and stages it here.
- **`prebuilt/<arch>/libhop.a`** , the protocol core, cross-compiled to a static archive per ESP32
  architecture (`xtensa` and `riscv`). Same release workflow. `link-libhop.py` picks the archive that
  matches your board and links it, and adds this directory to the include path.

The C++ wrapper in `src/` does not `#include "hop.h"`: it declares the handful of `extern "C"`
functions it calls, so it compiles cleanly before the header is staged. You only need `hop.h` here if
you want to call the raw C ABI directly alongside the wrapper.

## Building locally without waiting for a release

Cross-compile the core yourself with the esp toolchain and drop the two artifacts in place:

```sh
# from a checkout of the Hop core (hopmesh/libhop):
#   riscv (stock Rust):  cargo build -p hop --no-default-features --features minimal \
#                          --target riscv32imc-esp-espidf --release
#   xtensa (esp-rs):     cargo build -p hop --no-default-features --features minimal \
#                          --target xtensa-esp32-espidf --release
# then copy target/<triple>/release/libhop.a to prebuilt/<arch>/libhop.a, and the generated
# hop.h to include/hop.h.
```

libhop uses `std` (HashMap, Mutex, Vec), so it targets the ESP-IDF `*-esp-espidf` std tier where
ESP-IDF supplies a newlib-backed std, not the bare `-none-elf` no_std tier.
