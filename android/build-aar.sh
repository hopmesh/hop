#!/usr/bin/env bash
# Build the Hop Android native libs (.so per ABI) + Kotlin bindings from hop-ffi.
#
# Output (gitignored): android/generated/
#   - jniLibs/<abi>/libhop_ffi.so      (drop into src/main/jniLibs/)
#   - kotlin/uniffi/hop_ffi/hop_ffi.kt (add to your Android library module)
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

CRATE=hop-ffi
OUT=android/HopDemo/generated   # gradle sourceSets read ../generated from :app
T=target

command -v cargo-ndk >/dev/null || { echo "missing: cargo install cargo-ndk"; exit 1; }
: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to your NDK path}"

rm -rf "$OUT"; mkdir -p "$OUT/kotlin"

echo "▸ building .so for each ABI"
cargo ndk -t arm64-v8a -t x86_64 -t armeabi-v7a -o "$OUT/jniLibs" \
  build -p "$CRATE" --release

echo "▸ generating Kotlin bindings"
cargo build -p "$CRATE"   # host lib for bindgen metadata
cargo run -p "$CRATE" --features cli --bin uniffi-bindgen -- \
  generate --library "$T/debug/libhop_ffi.dylib" --language kotlin --out-dir "$OUT/kotlin"

echo "✓ $OUT/jniLibs/<abi>/libhop_ffi.so"
echo "✓ $OUT/kotlin/uniffi/hop_ffi/hop_ffi.kt"
