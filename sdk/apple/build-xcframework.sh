#!/usr/bin/env bash
# Build libhop.xcframework — the C ABI (hop.h + the static lib) for ios-arm64 + ios-sim(fat) +
# macOS(fat) — so the Hop SwiftPM package (and everything that depends on it: the bearers, the
# driver, the app) builds for iOS devices, not just macOS. The package uses it as a binaryTarget
# named CHop (the module Hop.swift imports). Gitignored output; regenerate after editing cabi.rs.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"
CRATE=hop
LIB=libhop.a
T=target

echo "▸ ensuring Apple Rust targets"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios \
                  aarch64-apple-darwin x86_64-apple-darwin >/dev/null

# Regenerate hop.h from cabi.rs when cbindgen is available (a dev machine). CI's apple job does not
# install cbindgen, and the committed hop.h is already guaranteed in sync by the `contract` job's
# header-drift check, so fall back to the committed header rather than aborting under `set -e`.
if command -v cbindgen >/dev/null 2>&1; then
  core/hop/regen-header.sh >/dev/null   # hop.h current
else
  echo "▸ cbindgen not installed; using the committed hop.h (kept in sync by the contract CI job)"
fi

echo "▸ cross-compiling libhop.a (release) for each slice"
for t in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-darwin x86_64-apple-darwin; do
  cargo build -p "$CRATE" --release --target "$t"
done

# The xcframework header dir: hop.h + a module map naming the module CHop (what Hop.swift imports).
HDR="$T/libhop-headers"; rm -rf "$HDR"; mkdir -p "$HDR"
cp core/hop/include/hop.h "$HDR/hop.h"
cat > "$HDR/module.modulemap" <<'EOF'
module CHop {
    header "hop.h"
    export *
}
EOF

SIM="$T/sim-universal-hop"; mkdir -p "$SIM"
lipo -create "$T/aarch64-apple-ios-sim/release/$LIB" "$T/x86_64-apple-ios/release/$LIB" -output "$SIM/$LIB"
MAC="$T/mac-universal-hop"; mkdir -p "$MAC"
lipo -create "$T/aarch64-apple-darwin/release/$LIB" "$T/x86_64-apple-darwin/release/$LIB" -output "$MAC/$LIB"

DEST="$HERE/Frameworks/libhop.xcframework"; mkdir -p "$HERE/Frameworks"; rm -rf "$DEST"
xcodebuild -create-xcframework \
  -library "$T/aarch64-apple-ios/release/$LIB" -headers "$HDR" \
  -library "$SIM/$LIB"                         -headers "$HDR" \
  -library "$MAC/$LIB"                         -headers "$HDR" \
  -output "$DEST" >/dev/null
python3 "$ROOT/tools/native-artifacts.py" apple-manifest \
  --xcframework "$DEST" --output "$DEST/architecture-manifest.json"
python3 "$ROOT/tools/native-artifacts.py" apple-verify \
  --xcframework "$DEST" --manifest "$DEST/architecture-manifest.json"
echo "✓ $DEST"
