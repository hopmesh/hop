#!/usr/bin/env bash
# Build the Hop XCFramework + Swift bindings from hop-ffi, into the HopDriver package.
#
# Output (gitignored): drivers/apple/HopDriver/
#   - Frameworks/HopFFI.xcframework        (ios-arm64 device + ios-sim + macos universal)
#   - Sources/HopFFIBindings/hop.swift (the generated Swift API, a package target)
#
# Requires: Xcode, rustup. Run from anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."

CRATE=hop
LIB=libhop.a
PKG=drivers/apple/HopDriver
OUT=drivers/apple/HopDriver/.build-staging   # scratch for headers + generated swift
T=target

# REL-004: Pin deployment targets matching drivers/apple/HopDriver/Package.swift platforms (.iOS(.v16), .macOS(.v13)).
# Exporting both variables ensures that rustc (linking libhop.dylib/staticlib) and cc-rs / openssl-src
# (compiling C objects for SQLCipher and vendored OpenSSL) target the exact same OS baseline.
# Without explicit deployment targets, cc-rs queries the Xcode SDK version (e.g. 18.2) while rustc
# defaults to iOS 10.0, producing object version mismatch warnings and undefined symbols
# (such as ___chkstk_darwin from compiler-rt).
DEPLOYMENT_TARGET_IOS="16.0"
DEPLOYMENT_TARGET_MACOS="13.0"
export IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET_IOS"
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET_MACOS"

# REL-009: vendored OpenSSL stamps cversion.c with the build clock unless SOURCE_DATE_EPOCH is set
# (util/mkbuildinf.pl); pin it so identical inputs give byte-identical libraries and archives.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"

if [ -d "$HOME/.cargo/bin" ]; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi

echo "▸ ensuring iOS + macOS Rust targets"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios \
                  aarch64-apple-darwin x86_64-apple-darwin >/dev/null

echo "▸ building host lib + generating Swift bindings"
cargo build -p "$CRATE"
rm -rf "$OUT"; mkdir -p "$OUT/Sources" "$OUT/Headers"
cargo run -p "$CRATE" --features cli --bin uniffi-bindgen -- \
  generate --library "$T/debug/$LIB" --language swift --out-dir "$OUT/Sources"
# UniFFI emits trailing blanks in generated Swift and headers. Normalize them before these tracked
# artifacts are copied so regenerating the framework keeps `git diff --check` clean.
perl -pi -e 's/[[:blank:]]+$//' "$OUT/Sources/hop.swift" "$OUT/Sources/hopFFI.h"
cp "$OUT/Sources/hopFFI.h" "$OUT/Headers/"
cp "$OUT/Sources/hopFFI.modulemap" "$OUT/Headers/module.modulemap"

# Place the generated Swift API as the HopFFIBindings target's source.
mkdir -p "$PKG/Sources/HopFFIBindings"
cp "$OUT/Sources/hop.swift" "$PKG/Sources/HopFFIBindings/hop.swift"

# F-25: ship the app's libhop with SQLCipher (encryption at rest) by DEFAULT, the host passes a
# Keychain-derived key to HopNode.open_keyed and every db page is encrypted. Set HOP_SQLCIPHER=0 for
# a faster plain-SQLite dev build (no OpenSSL vendored compile, but no at-rest encryption either).
if [ "${HOP_SQLCIPHER:-1}" = "1" ]; then
  FEAT=(--no-default-features --features sqlcipher)
  echo "▸ SQLCipher at-rest ENABLED (set HOP_SQLCIPHER=0 to disable)"
else
  FEAT=()
  echo "▸ SQLCipher DISABLED, plain SQLite (no at-rest encryption)"
fi

echo "▸ cross-compiling release staticlibs (iOS device + sim, macOS arm64 + x86_64)"
cargo build -p "$CRATE" --release --target aarch64-apple-ios ${FEAT[@]+"${FEAT[@]}"}
cargo build -p "$CRATE" --release --target aarch64-apple-ios-sim ${FEAT[@]+"${FEAT[@]}"}
cargo build -p "$CRATE" --release --target x86_64-apple-ios ${FEAT[@]+"${FEAT[@]}"}
cargo build -p "$CRATE" --release --target aarch64-apple-darwin ${FEAT[@]+"${FEAT[@]}"}
cargo build -p "$CRATE" --release --target x86_64-apple-darwin ${FEAT[@]+"${FEAT[@]}"}

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
cp THIRD-PARTY-NOTICES.md "$DEST/THIRD-PARTY-NOTICES.md"
cp LICENSE.md "$DEST/LICENSE.md"

echo "✓ $DEST"
echo "✓ $PKG/Sources/HopFFIBindings/hop.swift"
