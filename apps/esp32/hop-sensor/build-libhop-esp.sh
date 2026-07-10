#!/usr/bin/env bash
# Cross-compile the `minimal` libhop static library for an ESP32-class chip and stage it (plus the
# generated hop.h) into the local ESP-IDF `libhop` component (core-ffi-03). Run this ONCE before
# `idf.py build`, and again whenever cabi.rs / the wire format changes.
#
# The `minimal` feature drops UniFFI and the SQLite store, leaving a lean C-ABI archive that fits a
# constrained target. libhop still uses `std` (HashMap, Mutex, Vec), so it targets the ESP-IDF `std`
# tier (`*-esp-espidf`), where ESP-IDF supplies a newlib-backed std - NOT the bare `-none-elf` no_std
# tier. This is exactly the target the finding named (`riscv32imc-esp-espidf`). This script does the
# host-independent cross-compile; the only step it CANNOT do here is flash the image onto a board.
#
# Prerequisites (one-time): the esp-rs toolchain via `espup install` (adds the esp Rust channel + the
# targets below) and `cargo install ldproxy`. Xtensa chips REQUIRE the esp channel; RISC-V chips can
# use either the esp channel or a recent nightly with the espidf target added.
#
# Usage:
#   ./build-libhop-esp.sh [CHIP]     CHIP defaults to esp32c3.
set -euo pipefail

CHIP="${1:-esp32c3}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
COMP="$HERE/components/libhop"

case "$CHIP" in
  esp32c3)              TARGET="riscv32imc-esp-espidf" ;;
  esp32c6|esp32h2)      TARGET="riscv32imac-esp-espidf" ;;
  esp32|esp32s2|esp32s3) TARGET="xtensa-${CHIP}-espidf" ;; # requires the esp-rs (espup) toolchain
  *) echo "unknown chip '$CHIP' (try esp32c3, esp32c6, esp32, esp32s3, ...)" >&2; exit 2 ;;
esac

echo "==> regenerating hop.h from cabi.rs"
"$ROOT/core/hop/regen-header.sh" >/dev/null
mkdir -p "$COMP/include" "$COMP/lib"
cp -f "$ROOT/sdk/hop.h" "$COMP/include/hop.h"

echo "==> building minimal libhop for $CHIP ($TARGET)"
# The `minimal` feature excludes uniffi + sqlite. -Zbuild-std builds std for the espidf tier (the esp
# channel wires this up automatically). ESP_IDF_VERSION is honored by the esp-idf-sys sysroot if pulled.
cargo build \
  --manifest-path "$ROOT/Cargo.toml" \
  -p hop \
  --no-default-features \
  --features minimal \
  --target "$TARGET" \
  --release

ARCHIVE="$ROOT/target/$TARGET/release/libhop.a"
if [[ ! -f "$ARCHIVE" ]]; then
  echo "expected archive not found: $ARCHIVE" >&2
  exit 1
fi
cp -f "$ARCHIVE" "$COMP/lib/libhop.a"
echo "==> staged $COMP/lib/libhop.a  and  $COMP/include/hop.h"
echo "    now: idf.py set-target $CHIP && idf.py build"
