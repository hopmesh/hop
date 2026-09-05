#!/usr/bin/env bash
# Build libhop.xcframework: the C ABI (hop.h + the static lib) for ios-arm64 + ios-sim(fat) +
# macOS(fat), so the Hop SwiftPM package (and everything that depends on it: the bearers, the
# driver, the app) builds for iOS devices, not just macOS. The package uses it as a binaryTarget
# named CHop (the module Hop.swift imports). Gitignored output; regenerate after editing cabi.rs.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"
CRATE=hop
LIB=libhop.a
T=target

# REL-004: Pin deployment targets matching sdk/apple/Package.swift platforms (.macOS(.v13), .iOS(.v16)).
# Exporting both variables ensures that rustc (linking libhop.dylib/staticlib) and cc-rs / openssl-src
# (compiling C objects for SQLCipher and vendored OpenSSL) target the exact same OS baseline.
# Without explicit deployment targets, cc-rs queries the Xcode SDK version (e.g. 18.2) while rustc
# defaults to iOS 10.0, producing object version mismatch warnings and undefined symbols
# (such as ___chkstk_darwin from compiler-rt).
DEPLOYMENT_TARGET_IOS="16.0"
DEPLOYMENT_TARGET_MACOS="13.0"
export IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET_IOS"
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET_MACOS"

# REL-009: the archive checksum committed in Package.swift is only maintainable if two builds of the
# same source produce the same bytes. With SQLCipher on, openssl-src compiles OpenSSL's cversion.c,
# whose `built on:` string is the build time unless SOURCE_DATE_EPOCH is set (util/mkbuildinf.pl);
# that one object made the v0.0.3 checksum differ between two CI builds of identical inputs.
# Pin the epoch (any fixed value; OpenSSL prints it in place of the clock) unless the caller set one.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"

if [ -d "$HOME/.cargo/bin" ]; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi

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

# F-25 / audit ABI-001: ship libhop with SQLCipher (encryption at rest) by DEFAULT, matching
# tools/build-xcframework.sh so HopNode.open_keyed actually encrypts the store.
# Set HOP_SQLCIPHER=0 to disable for plain-SQLite dev builds.
if [ "${HOP_SQLCIPHER:-1}" = "1" ]; then
  FEAT=(--no-default-features --features sqlcipher)
  echo "▸ SQLCipher at-rest ENABLED (set HOP_SQLCIPHER=0 to disable)"
else
  FEAT=()
  echo "▸ SQLCipher DISABLED, plain SQLite (no at-rest encryption)"
fi

echo "▸ cross-compiling libhop.a (release) for each slice"
for t in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-darwin x86_64-apple-darwin; do
  cargo build -p "$CRATE" --release --target "$t" ${FEAT[@]+"${FEAT[@]}"}
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
# xcodebuild emits AvailableLibraries in a NONDETERMINISTIC order, so two builds of identical sources
# produce a byte-different Info.plist, a byte-different zip, and a different SwiftPM checksum. That is
# not cosmetic: sdk/apple/Package.swift pins that checksum and the release job asserts it against a
# freshly built artifact, so the Apple, embedded, and Android releases could never pass except by luck,
# and the pinned value read as "stale" every time when it had never been stable at all. Measured: two
# main commits differing only by a doc, a test, and Package.swift itself produced different checksums,
# and extracting both showed every compiled library byte-identical with ONLY the plist's slice order
# changed. Applying this sort to both made the entire xcframework identical.
#
# Sort the slices by LibraryIdentifier so the plist is a pure function of its contents.
python3 - "$DEST/Info.plist" <<'PY'
import plistlib
import sys

path = sys.argv[1]
with open(path, "rb") as handle:
    plist = plistlib.load(handle)
libraries = plist.get("AvailableLibraries")
if libraries:
    plist["AvailableLibraries"] = sorted(libraries, key=lambda entry: entry["LibraryIdentifier"])
    # Each slice's architecture list is a set in meaning, not a sequence, so sort it too.
    for entry in plist["AvailableLibraries"]:
        if isinstance(entry.get("SupportedArchitectures"), list):
            entry["SupportedArchitectures"] = sorted(entry["SupportedArchitectures"])
    with open(path, "wb") as handle:
        plistlib.dump(plist, handle, sort_keys=True)
PY
cp "$ROOT/THIRD-PARTY-NOTICES.md" "$DEST/THIRD-PARTY-NOTICES.md"
cp "$ROOT/LICENSE.md" "$DEST/LICENSE.md"
python3 "$ROOT/tools/native-artifacts.py" apple-manifest \
  --xcframework "$DEST" --output "$DEST/architecture-manifest.json"
python3 "$ROOT/tools/native-artifacts.py" apple-verify \
  --xcframework "$DEST" --manifest "$DEST/architecture-manifest.json"
echo "✓ $DEST"
