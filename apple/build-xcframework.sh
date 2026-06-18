#!/usr/bin/env bash
# Build the Hop iOS XCFramework + Swift bindings from hop-ffi.
#
# Output (gitignored): apple/generated/
#   - HopFFI.xcframework   (ios-arm64 device + ios-arm64-simulator)
#   - Sources/hop_ffi.swift (the generated Swift API — add to your target)
#
# Requires: Xcode, rustup. Run from anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."

CRATE=hop-ffi
LIB=libhop_ffi.a
OUT=apple/generated
T=target

echo "▸ ensuring iOS Rust targets"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios >/dev/null

echo "▸ building host lib + generating Swift bindings"
cargo build -p "$CRATE"
rm -rf "$OUT"; mkdir -p "$OUT/Sources" "$OUT/Headers"
cargo run -p "$CRATE" --features cli --bin uniffi-bindgen -- \
  generate --library "$T/debug/$LIB" --language swift --out-dir "$OUT/Sources"
cp "$OUT/Sources/hop_ffiFFI.h" "$OUT/Headers/"
cp "$OUT/Sources/hop_ffiFFI.modulemap" "$OUT/Headers/module.modulemap"

echo "▸ cross-compiling release staticlibs (device + simulator: arm64 + x86_64)"
cargo build -p "$CRATE" --release --target aarch64-apple-ios
cargo build -p "$CRATE" --release --target aarch64-apple-ios-sim
cargo build -p "$CRATE" --release --target x86_64-apple-ios

# Fat simulator slice so the framework runs on Apple Silicon and Intel Macs.
SIM_FAT="$T/sim-universal"; mkdir -p "$SIM_FAT"
lipo -create \
  "$T/aarch64-apple-ios-sim/release/$LIB" \
  "$T/x86_64-apple-ios/release/$LIB" \
  -output "$SIM_FAT/$LIB"

echo "▸ packaging XCFramework"
rm -rf "$OUT/HopFFI.xcframework"
xcodebuild -create-xcframework \
  -library "$T/aarch64-apple-ios/release/$LIB" -headers "$OUT/Headers" \
  -library "$SIM_FAT/$LIB"                     -headers "$OUT/Headers" \
  -output "$OUT/HopFFI.xcframework" >/dev/null

echo "✓ $OUT/HopFFI.xcframework"
echo "✓ $OUT/Sources/hop_ffi.swift  (add this + the XCFramework to your Xcode target)"
