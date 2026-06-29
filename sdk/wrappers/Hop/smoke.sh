#!/usr/bin/env bash
# Build libhop, publish hop.h into the Swift package, then build+run the Swift smoke against the C ABI.
# Proves the Swift wrapper drives libhop (the same proof as crates/hop-ffi/examples/smoke.sh, one rung up).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
LIBDIR="$ROOT/target/debug"

cargo build -p hop-ffi --manifest-path "$ROOT/Cargo.toml"
"$ROOT/crates/hop-ffi/regen-header.sh" >/dev/null

cd "$HERE"
# NOTE: build flags MUST precede the product name; anything after it is the executable's argv.
LINK=(-Xlinker -L"$LIBDIR" -Xlinker -lhop -Xlinker -rpath -Xlinker "$LIBDIR")
swift run "${LINK[@]}" HopSmoke       # Swift wrapper -> C ABI -> protocol
swift run "${LINK[@]}" RuntimeSmoke   # HopRuntime + a Bearer -> node seam -> protocol
