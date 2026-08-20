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

# ONE HEADER DIRECTORY, TWO MODULE FACES, because this xcframework is the only Hop core an Apple app
# links and two module names resolve against it.
#
# `hopFFI` is the UniFFI face that Sources/HopFFIBindings/hop.swift imports. `CHop` is the C ABI face
# that sdk/apple/Sources/Hop/Hop.swift imports, and it used to arrive from a SECOND xcframework, the
# libhop.xcframework release asset CHop.podspec fetched. Two xcframeworks cannot coexist in one app:
# both wrap a static library named libhop.a, CocoaPods puts each vendoring pod's slice directory on
# LIBRARY_SEARCH_PATHS and emits a single -l"hop", so that one flag silently resolves to whichever
# search path sorts first. Measured with nm on the ios-arm64 slice of each: they export the SAME 257
# symbols matching ^_(hop|uniffi|ffi), 160 of them uniffi_ scaffolding, so either archive satisfies
# both faces and the link succeeds either way. The difference is invisible at link time and decisive at
# runtime: `nm -a` finds 98 sqlcipher references in THIS artifact and 0 in the release asset, so picking
# the wrong one leaves hop.db in plaintext with no error at all.
#
# Carrying both headers here is what lets there be exactly one core. hop.h is the same tracked file
# sdk/apple/build-xcframework.sh copies (core/hop/include/hop.h), and the two headers share no
# declarations, so a consumer can import either module or both.
cp core/hop/include/hop.h "$OUT/Headers/hop.h"
cat "$OUT/Sources/hopFFI.modulemap" > "$OUT/Headers/module.modulemap"
cat >> "$OUT/Headers/module.modulemap" <<'EOF'

module CHop {
    header "hop.h"
    export *
}
EOF

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

echo "✓ $DEST"
echo "✓ $PKG/Sources/HopFFIBindings/hop.swift"
