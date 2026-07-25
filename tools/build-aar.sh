#!/usr/bin/env bash
# Build the Hop Android native libs (.so per ABI) + Kotlin bindings from hop-ffi.
#
# Output (gitignored): apps/android/HopDemo/generated/ (override with HOP_ANDROID_OUT)
#   - jniLibs/<abi>/libhop.so      (the C ABI / sh.hop SDK AND UniFFI, the crate is now `hop`)
#   - kotlin/uniffi/hop/hop.kt     (the UniFFI Kotlin bindings, namespace uniffi.hop)
#
# Prerequisites (one-time):
#   1. Android NDK. Either:
#        brew install --cask android-commandlinetools
#        sdkmanager "ndk;26.3.11579264"     # then: export ANDROID_NDK_HOME=...
#      or install via Android Studio's SDK Manager.
#   2. cargo install cargo-ndk
#   3. rustup target add aarch64-linux-android x86_64-linux-android \
#                        armv7-linux-androideabi i686-linux-android
#
# Runtime: the Android app must depend on JNA (uniffi-kotlin uses it):
#   implementation("net.java.dev.jna:jna:5.14.0@aar")
set -euo pipefail
cd "$(dirname "$0")/.."

CRATE=hop
OUT="${HOP_ANDROID_OUT:-apps/android/HopDemo/generated}" # gradle sourceSets read ../generated from :app
T=target

command -v cargo-ndk >/dev/null || { echo "missing: cargo-ndk"; exit 1; }
: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to your NDK path}"

rm -rf "$OUT"; mkdir -p "$OUT/kotlin"

# F-25: ship the app's libhop with SQLCipher (encryption at rest) by DEFAULT, the host passes a
# Keystore-derived key to HopNode.open_keyed and every db page is encrypted. Set HOP_SQLCIPHER=0 for
# a faster plain-SQLite dev build (skips the vendored-OpenSSL cross-compile, but no at-rest encryption).
if [ "${HOP_SQLCIPHER:-1}" = "1" ]; then
  FEAT=(--no-default-features --features sqlcipher)
  echo "▸ SQLCipher at-rest ENABLED (set HOP_SQLCIPHER=0 to disable)"
else
  FEAT=()
  echo "▸ SQLCipher DISABLED, plain SQLite (no at-rest encryption)"
fi

echo "▸ building libhop.so for each ABI"
cargo ndk -t arm64-v8a -t x86_64 -t x86 -t armeabi-v7a -o "$OUT/jniLibs" \
  build -p "$CRATE" --release --locked "${FEAT[@]}"
# ONE libhop.so per ABI now serves both the C ABI (sh.hop loads "hop") and UniFFI (component "hop").

echo "▸ generating Kotlin bindings"
cargo build -p "$CRATE" --locked   # host lib for bindgen metadata
case "$(uname -s)" in
  Darwin) HOST_LIB="$T/debug/libhop.dylib" ;;
  Linux) HOST_LIB="$T/debug/libhop.so" ;;
  *) echo "unsupported bindgen host: $(uname -s)" >&2; exit 1 ;;
esac
cargo run -p "$CRATE" --locked --features cli --bin uniffi-bindgen -- \
  generate --library "$HOST_LIB" --language kotlin --out-dir "$OUT/kotlin"

echo "✓ $OUT/jniLibs/<abi>/libhop.so"
echo "✓ $OUT/kotlin/uniffi/hop/hop.kt"
