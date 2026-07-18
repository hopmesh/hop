# include/

Two build inputs land in this library from the signed release bundle, not from source control history:

- **`hop.h`** , the generated libhop C ABI header. It is produced by cbindgen from the Hop core
  (`hop-core` / `libhop`) and is byte-identical across every Hop SDK, so it is not copied by hand into
  this repo (a hand copy would drift). The release workflow regenerates it and stages it here.
- **`native/artifacts/<target>.tar.gz`** , the protocol core and header, cross-compiled for one exact
  Rust target. `link-libhop.py` maps the board MCU to one target, verifies the signed manifest plus the
  archive/member SHA-256 and size, then extracts and links only that archive.

The C++ wrapper in `src/` does not `#include "hop.h"`: it declares the handful of `extern "C"`
functions it calls, so it compiles cleanly before the header is staged. You only need `hop.h` here if
you want to call the raw C ABI directly alongside the wrapper.

## Building locally without waiting for a release

Use the canonical native-artifact builder or reproduce its exact target commands:

```sh
# xtensa-esp32-espidf
# xtensa-esp32s2-espidf
# xtensa-esp32s3-espidf
# riscv32imc-esp-espidf
# riscv32imac-esp-espidf
```

Create one archive per target with `lib/libhop.a` and `include/hop.h`, then create and sign the shared
manifest with `native-artifacts.py`. Unsigned loose archives are intentionally unsupported.

libhop uses `std` (HashMap, Mutex, Vec), so it targets the ESP-IDF `*-esp-espidf` std tier where
ESP-IDF supplies a newlib-backed std, not the bare `-none-elf` no_std tier.
