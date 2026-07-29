#!/usr/bin/env bash
# The local mirror of what CI actually runs, in order. Run this before EVERY push.
#
# HONESTY IS THE POINT OF THIS SCRIPT. It used to run the Rust job's steps and then print "ALL LOCAL
# GATES PASS", which reads as "CI will be green" while the Kotlin, Swift and Android suites had never
# been executed. On 2026-07-26 that gap hid 7 real test failures (the Kotlin SDK's JNA integration
# tests and the Android driver's Robolectric HNS suite) behind a 23/23 green run. A script named after
# mirroring CI must never green-light work CI would reject, so it now runs the platform suites too and,
# when it cannot, says exactly what it skipped instead of quietly narrowing its own scope.
#
# Three build artifacts are gitignored and therefore ABSENT in a fresh worktree. Each one makes a
# different suite fail in a way that looks like a defect, so they are built on demand rather than left
# as a trap: the wasm node package (sim wire vectors), the UniFFI Kotlin bindings (the Android driver
# will not even compile), and the host libhop cdylib (JNA/Robolectric tests need HOP_LIBDIR).
#
#   SKIP_PLATFORMS=1   Rust + guards only, and the summary says so.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
fail=0
skipped=()

step() { printf '%-46s' "$1"; shift; if "$@" >/tmp/vstep.log 2>&1; then echo "OK"; else echo "FAIL"; fail=1; tail -6 /tmp/vstep.log | sed 's/^/    /'; fi; }
skip() { printf '%-46s%s\n' "$1" "SKIP ($2)"; skipped+=("$1 ($2)"); }
have() { command -v "$1" >/dev/null 2>&1; }

# --- prerequisites: gitignored artifacts a fresh worktree lacks -----------------------------------
[ -f core/hop-wasm/pkg-node/hop_wasm.js ] || step "build wasm pkg-node (sim vectors)" bash sim/build-wasm.sh

# --- CI's rust job -------------------------------------------------------------------------------
step "cargo fmt --all --check"        cargo fmt --all --check
step "clippy -D warnings"             cargo clippy --workspace --all-targets -- -D warnings
step "cargo test --workspace"         cargo test --workspace
step "wire-version-guard self-test"   bash tools/wire-version-guard.test.sh
step "wire-version-guard"             env WIRE_BASE_REF=origin/main bash tools/wire-version-guard.sh
step "deterministic wire corpus"      cargo run -q -p hop-core --example wire-vectors --features wire-vectors
step "gateway (reqwest feature)"      cargo test -p hop-gateway --features reqwest
step "C ABI (sqlcipher feature)"      cargo test -p hop --no-default-features --features sqlcipher --locked
step "relayd (firestore feature)"     cargo test -p hop-relayd --features firestore
step "accountd (firestore feature)"   cargo test -p hop-accountd --features firestore
step "telemetryd (firestore feature)" cargo test -p hop-telemetryd --features firestore
step "billingd (live feature)"        cargo test -p hop-billingd --features live
step "store (sqlcipher feature)"      cargo test -p hop-store-sqlite --no-default-features --features sqlcipher
step "minimal embedded C-ABI build"   cargo build -p hop --no-default-features --features minimal

# The fuzz crate is OUTSIDE the cargo workspace, so `cargo test --workspace` never compiles it and a
# type change in core can break it invisibly. Wire v12 did exactly that: narrowing the mailbox prefix
# left a 2-byte literal in fuzz_targets/bundle_parse_verify.rs, which passed 32/32 here and reddened
# CI. Build-only (no fuzzing run) keeps it fast while still type-checking the targets against core.
# Call the SAME script CI calls (ci.yml runs `bash tools/fuzz-smoke.sh`) rather than invoking cargo
# fuzz directly: the targets need the pinned nightly toolchain, and reimplementing that here is how a
# mirror drifts from the thing it mirrors.
if cargo fuzz --version >/dev/null 2>&1; then
  step "fuzz smoke (outside workspace)" bash tools/fuzz-smoke.sh
else
  skip "fuzz smoke" "cargo-fuzz not installed"
fi

# --- guards --------------------------------------------------------------------------------------
step "docs-token-guard"               bash tools/docs-token-guard.sh
step "ble-backoff-parity self-test"   bash tools/ble-backoff-parity.test.sh
step "ble-backoff-parity"             bash tools/ble-backoff-parity.sh
step "abi-version guard"              bash tools/codegen/check-abi-version.sh
step "required-checks guard"          bash tools/check-required-checks.sh
step "repo-integrity guard"           bash tools/repo-integrity-guard.sh
# Catches a swapped-in Package.local.swift being committed by accident: it asserts the EXPORTED Apple
# manifest still carries the immutable v0.0.1 release URL rather than a local path binaryTarget. That
# is exactly the mistake `git add -A` made here while the Apple build had the manifest swapped.
step "package export smoke"           bash tools/package-export-smoke.test.sh
step "sim pkg freshness"              bash sim/check-pkg-fresh.sh
step "sim wire vectors"               node sim/wire-vector-check.mjs

# --- CI's Kotlin SDK + Android jobs --------------------------------------------------------------
android_env() {
  # The toolchain is mise-provided, never global: a bare shell reports "Unable to locate a Java
  # Runtime" while the JDK is in fact installed. Resolve it here so this script works non-interactively.
  local m="$HOME/.local/share/mise/installs"
  [ -d "$m/java" ] || return 1
  export JAVA_HOME="$(ls -d "$m"/java/* 2>/dev/null | head -1)"
  export PATH="$JAVA_HOME/bin:$PATH"
  export ANDROID_HOME="$(ls -d "$m"/android-sdk/* 2>/dev/null | head -1)"
  [ -n "$ANDROID_HOME" ] || return 1
  export ANDROID_SDK_ROOT="$ANDROID_HOME"
  export ANDROID_NDK_HOME="$(ls -d "$ANDROID_HOME"/ndk/* 2>/dev/null | head -1)"
  export HOP_LIBDIR="$ROOT/target/debug"     # JNA + Robolectric call the real libhop
  have gradle
}

if [ "${SKIP_PLATFORMS:-0}" = "1" ]; then
  skip "Kotlin SDK + Android suites" "SKIP_PLATFORMS=1"
  skip "Apple package suites" "SKIP_PLATFORMS=1"
else
  if android_env; then
    # REBUILD the host cdylib here, unconditionally, and never earlier. The feature-matrix steps above
    # end with `cargo build -p hop --no-default-features --features minimal`, which writes the SAME
    # target/debug/libhop.{dylib,so} with the SQLite store COMPILED OUT (minimal backs the node with
    # hop-core's in-memory store). JNA then loads that minimal library, `isPersistent()` answers false,
    # and two Kotlin persistence tests fail with what looks exactly like a product defect. CI never sees
    # this because its Kotlin job is a separate runner with its own target dir; running the whole matrix
    # in ONE tree is what creates the clobber, so the mirror has to undo it.
    step "rebuild host libhop (default feats)" cargo build -p hop --locked
    # The driver reads these generated bindings; without them it does not compile at all.
    if [ ! -f apps/android/HopDemo/generated/kotlin/uniffi/hop/hop.kt ]; then
      step "generate UniFFI Kotlin bindings" bash tools/build-aar.sh
    fi
    step "Kotlin SDK (+coverage gate)"  bash -c 'cd sdk/android && gradle test jacocoTestReport jacocoTestCoverageVerification'
    step "bearers/android (all modules)" bash -c 'cd bearers/android && ./gradlew test'
    step "HopDemo android (JVM units)"   bash -c 'cd apps/android/HopDemo && ./gradlew testDebugUnitTest'
  else
    skip "Kotlin SDK + Android suites" "no mise java/android-sdk or gradle"
  fi

  if have swift && have xcodebuild; then
    # Every in-tree Apple package resolves sdk/apple BY PATH, but the committed manifest is the
    # PUBLISHED one and points at a hop-sdk-apple release asset that does not exist, so resolution
    # 404s. CI does this same swap. Restore on any exit so a failed run never leaves the tree dirty.
    if [ ! -f sdk/apple/Frameworks/libhop.xcframework/Info.plist ]; then
      step "build apple xcframeworks" bash -c 'bash sdk/apple/build-xcframework.sh && bash tools/build-xcframework.sh'
    fi
    cp sdk/apple/Package.swift /tmp/hop-pkg-remote.bak
    trap 'cp /tmp/hop-pkg-remote.bak "$ROOT/sdk/apple/Package.swift" 2>/dev/null' EXIT
    cp sdk/apple/Package.local.swift sdk/apple/Package.swift
    for p in sdk/apple drivers/apple/HopDriver apps/apple/HopDemoKit \
             bearers/apple/HopBearerBle bearers/apple/HopBearerLan bearers/apple/HopBearerRelay; do
      step "swift test $p" bash -c "cd '$p' && swift test"
    done
    cp /tmp/hop-pkg-remote.bak sdk/apple/Package.swift
    trap - EXIT
  else
    skip "Apple package suites" "no swift/xcodebuild"
  fi
fi

# --- the summary, which must never overstate -----------------------------------------------------
echo
if [ "${#skipped[@]}" -gt 0 ]; then
  echo "NOT RUN (${#skipped[@]}):"
  for s in "${skipped[@]}"; do echo "  - $s"; done
fi
if [ "$fail" -ne 0 ]; then
  echo "SOME GATES FAILED"
elif [ "${#skipped[@]}" -gt 0 ]; then
  echo "GATES RUN HERE PASS, but the list above was NOT checked; CI still can redden."
else
  echo "ALL LOCAL GATES PASS (rust + guards + kotlin/android + apple)"
fi
exit "$fail"
