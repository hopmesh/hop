#!/usr/bin/env bash
# Build libhop, then compile + run this ESP32-style full-client example against the C ABI on the host.
# Proves hop.h is consumable from plain embedded-style C. (Real ESP-IDF build: see README.md.)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
LIBDIR="$ROOT/target/debug"

cargo build -p hop-ffi --manifest-path "$ROOT/Cargo.toml"
"$ROOT/core/hop-ffi/regen-header.sh" >/dev/null

clang "$HERE/main.c" -I "$ROOT/sdk" -L "$LIBDIR" -lhop -Wl,-rpath,"$LIBDIR" -o "$HERE/hop-sensor"
"$HERE/hop-sensor"
