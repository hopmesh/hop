#!/usr/bin/env bash
# Build libhop, then build+run the Kotlin/JVM smoke against it via JNA. Proves the Kotlin wrapper
# drives the C ABI (the same proof as the Swift/C smokes). Uses JDK17 + standalone gradle.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

cargo build -p hop-ffi --manifest-path "$ROOT/Cargo.toml"
"$ROOT/crates/hop-ffi/regen-header.sh" >/dev/null

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export HOP_LIBDIR="$ROOT/target/debug"
cd "$HERE"
gradle -q run --console=plain
