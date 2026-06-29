#!/usr/bin/env bash
# Build the Hop XCFramework + Swift bindings from hop-ffi, into the HopDriver package.
#
# Output (gitignored): apple/HopDriver/
#   - Frameworks/HopFFI.xcframework        (ios-arm64 device + ios-sim + macos universal)
#   - Sources/HopFFIBindings/hop.swift (the generated Swift API — a package target)
#
# Requires: Xcode, rustup. Run from anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."

CRATE=hop
LIB=libhop.a
PKG=apple/HopDriver
OUT=apple/HopDriver/.build-staging   # scratch for headers + generated swift
T=target

echo "▸ ensuring iOS + macOS Rust targets"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios \
                  aarch64-apple-darwin x86_64-apple-darwin >/dev/null

echo "▸ building host lib + generating Swift bindings"
cargo build -p "$CRATE"
rm -rf "$OUT"; mkdir -p "$OUT/Sources" "$OUT/Headers"
cargo run -p "$CRATE" --features cli --bin uniffi-bindgen -- \
  generate --library "$T/debug/$LIB" --language swift --out-dir "$OUT/Sources"
cp "$OUT/Sources/hopFFI.h" "$OUT/Headers/"
cp "$OUT/Sources/hopFFI.modulemap" "$OUT/Headers/module.modulemap"

# Place the generated Swift API as the HopFFIBindings target's source.
mkdir -p "$PKG/Sources/HopFFIBindings"
cp "$OUT/Sources/hop.swift" "$PKG/Sources/HopFFIBindings/hop.swift"

echo "▸ cross-compiling release staticlibs (iOS device + sim, macOS arm64 + x86_64)"
cargo build -p "$CRATE" --release --target aarch64-apple-ios
cargo build -p "$CRATE" --release --target aarch64-apple-ios-sim
cargo build -p "$CRATE" --release --target x86_64-apple-ios
cargo build -p "$CRATE" --release --target aarch64-apple-darwin
cargo build -p "$CRATE" --release --target x86_64-apple-darwin

# Fat simulator slice so the framework runs on Apple Silicon and Intel Macs.
SIM_FAT="$T/sim-universal"; mkdir -p "$SIM_FAT"
lipo -create \
  "$T/aarch64-apple-ios-sim/release/$LIB" \
  "$T/x86_64-apple-ios/release/$LIB" \
  -output "$SIM_FAT/$LIB"

# Universal macOS slice (Apple Silicon + Intel) so the package builds + hopmac runs on either Mac.
MAC_FAT="$T/mac-universal"; mkdir -p "$MAC_FAT"
lipo -create \
  "$T/aarch64-apple-darwin/release/$LIB" \
  "$T/x86_64-apple-darwin/release/$LIB" \
  -output "$MAC_FAT/$LIB"

echo "▸ packaging XCFramework"
DEST="$PKG/Frameworks/HopFFI.xcframework"
mkdir -p "$PKG/Frameworks"
rm -rf "$DEST"
xcodebuild -create-xcframework \
  -library "$T/aarch64-apple-ios/release/$LIB" -headers "$OUT/Headers" \
  -library "$SIM_FAT/$LIB"                     -headers "$OUT/Headers" \
  -library "$MAC_FAT/$LIB"                     -headers "$OUT/Headers" \
  -output "$DEST" >/dev/null

echo "✓ $DEST"
echo "✓ $PKG/Sources/HopFFIBindings/hop.swift"
