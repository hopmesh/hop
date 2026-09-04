#!/usr/bin/env bash
# The local pre-push run of the CI jobs that can be reproduced on a workstation, in CI's order.
#
# HONESTY IS THE POINT OF THIS SCRIPT. It used to run the Rust job's steps and then print "ALL LOCAL
# GATES PASS", which reads as "CI will be green" while the Kotlin, Swift and Android suites had never
# been executed. On 2026-07-26 that gap hid 7 real test failures (the Kotlin SDK's JNA integration
# tests and the Android driver's Robolectric HNS suite) behind a 23/23 green run. A script that claims
# to mirror CI must never green-light work CI would reject, so it runs the platform suites too and,
# when it cannot, says exactly what it skipped instead of quietly narrowing its own scope.
#
# It still does NOT run every CI job, and the header used to claim otherwise ("the local mirror of what
# CI actually runs"). Seven gating jobs have no local counterpart at all and six more are only partly
# reproduced here, so a green run here is not a prediction that CI will be green. CI_COVERAGE below
# declares, per ci.yml job, exactly what this script does about it; the summary prints every job that
# is not fully covered, on every run, including a passing one.
# tools/local-ci-mirror-coverage.sh (self-tested, run in CI) fails when a job exists in ci.yml with no
# entry here, so this script cannot silently fall behind the thing it is measured against again. That
# guard also holds every `full` entry to its word: a task or cargo invocation in a full job's ci.yml
# steps that this script does not run reddens CI, which is how the android entry came to claim "full"
# while the five JaCoCo coverage-verification tasks CI gates on were never executed here.
#
# Three build artifacts are gitignored and therefore ABSENT in a fresh worktree. Each one makes a
# different suite fail in a way that looks like a defect, so they are built on demand rather than left
# as a trap: the wasm node package (sim wire vectors), the UniFFI Kotlin bindings (the Android driver
# will not even compile), and the host libhop cdylib (JNA/Robolectric tests need HOP_LIBDIR).
#
# THREE WAYS THIS SCRIPT USED TO DAMAGE THE TREE IT VERIFIES, all handled in one EXIT trap:
#   1. It wrote every step's output to a fixed /tmp/vstep.log, so two runs in sibling worktrees (the
#      normal way agents work here) overwrote each other's failure tail. During the 2026-07-29 audit
#      that misattributed a failure to the wrong branch. The log is now per-process (mktemp).
#   2. Building the Apple xcframeworks REWRITES drivers/apple/HopDriver/Frameworks/**, which is 178MB
#      of TRACKED build output. Following this script's own "run before every push" instruction left a
#      178MB dirty tree that is trivial to commit by accident. If this run dirtied it, the trap
#      restores it; anything it cannot restore is printed and makes the run FAIL rather than pass with
#      a dirty tree. A Frameworks/** that was already dirty before this run is left alone and named.
#   3. Its first step regenerates the tracked sim/pkg, whose wasm binary is not byte-reproducible, so a
#      fresh worktree comes out with sim/pkg modified. That one is NOT restored (after a real wire bump
#      it has to be committed), it is named, with the rule for deciding which case you are in.
#
#   SKIP_PLATFORMS=1   Rust + guards only, and the summary says so.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
fail=0
skipped=()

# PER-RUN scratch, never a fixed /tmp path. Several worktrees on one machine run this script at the
# same time (parallel agents), and the two fixed paths this used to use were shared mutable state
# across those runs:
#
#   /tmp/vstep.log            one run's step output overwrote another's WHILE the other was tailing
#                             it, so a FAIL tail printed a foreign run's output, and the tail | sed
#                             pipeline itself aborted ("Abort trap: 6") on the truncated file.
#   /tmp/hop-pkg-remote.bak   worse than confusing. Run A copies the PUBLISHED sdk/apple/Package.swift
#                             here, then swaps in Package.local.swift for the Swift suites. If run B
#                             reaches its own backup step while A is swapped, B copies A's SWAPPED
#                             manifest over the backup, and then BOTH runs "restore" the local
#                             manifest into their trees. The local manifest points at a machine-local
#                             path binaryTarget, so `package export smoke` fails, and a `git add -A`
#                             would commit the local manifest as the published one, which is the exact
#                             mistake this script's own comment below says has already happened once.
SCRATCH="$(mktemp -d)"
LOG="$SCRATCH/step.log"
# The tracked 178MB xcframework the Apple build rewrites, and whether it was dirty BEFORE this run.
FRAMEWORKS="drivers/apple/HopDriver/Frameworks"
frameworks_dirty_before="$(git -C "$ROOT" status --porcelain -- "$FRAMEWORKS" 2>/dev/null)"
# The other tracked build output a run rewrites: sim/build-wasm.sh regenerates sim/pkg, and the wasm
# binary is not byte-reproducible, so a fresh worktree ends up with a modified sim/pkg. This one is NOT
# auto-restored, because after a real BUNDLE_VERSION bump the rebuilt sim/pkg MUST be committed (the
# check-pkg-fresh guard reddens CI otherwise). So it is named instead, with which case is which.
WASM_PKG="sim/pkg"
wasm_pkg_dirty_before="$(git -C "$ROOT" status --porcelain -- "$WASM_PKG" 2>/dev/null)"
# Set while sdk/apple/Package.swift is swapped for the local-path manifest; empty means nothing to undo.
pkg_backup=""

cleanup() {
  local status=$?
  if [ -n "$pkg_backup" ]; then
    cp "$pkg_backup" "$ROOT/sdk/apple/Package.swift" 2>/dev/null
    rm -f "$pkg_backup"
  fi
  local after
  after="$(git -C "$ROOT" status --porcelain -- "$FRAMEWORKS" 2>/dev/null)"
  if [ -n "$after" ] && [ -z "$frameworks_dirty_before" ]; then
    git -C "$ROOT" checkout -- "$FRAMEWORKS" 2>/dev/null
    local remaining
    remaining="$(git -C "$ROOT" status --porcelain -- "$FRAMEWORKS" 2>/dev/null)"
    if [ -n "$remaining" ]; then
      echo
      # Reachable when the checkout itself fails (permissions, a lock). Untracked additions under
      # Frameworks cannot reach it: .gitignore covers that tree, so only the 10 tracked files there can
      # ever show up dirty, and those are exactly what the checkout above puts back.
      echo "ERROR: this run left $FRAMEWORKS dirty and it could not be restored:"
      printf '%s\n' "$remaining" | sed 's/^/    /'
      echo "  Fix it before committing: git checkout origin/main -- $FRAMEWORKS/"
      rm -rf "$SCRATCH"
      exit 1
    fi
    echo "(restored $FRAMEWORKS, which the Apple xcframework build rewrote)"
  elif [ -n "$after" ]; then
    echo
    echo "NOTE: $FRAMEWORKS was ALREADY dirty before this run, so it was left untouched."
    echo "  Never commit it: git checkout origin/main -- $FRAMEWORKS/"
  fi
  local wasm_after
  wasm_after="$(git -C "$ROOT" status --porcelain -- "$WASM_PKG" 2>/dev/null)"
  if [ -n "$wasm_after" ] && [ "$wasm_after" != "$wasm_pkg_dirty_before" ]; then
    echo
    echo "NOTE: this run rebuilt the tracked $WASM_PKG (the wasm binary is not byte-reproducible):"
    printf '%s\n' "$wasm_after" | sed 's/^/    /'
    echo "  Commit it ONLY as part of a wire-version bump; otherwise revert:"
    echo "  git checkout -- $WASM_PKG/"
  fi
  rm -rf "$SCRATCH"
  exit "$status"
}
trap cleanup EXIT

# ci.yml job id | full | partial | none | what this script does about it. Every job id in
# .github/workflows/ci.yml appears here exactly once. "partial" and "none" entries are printed in the
# summary of EVERY run, so the terminal verdict can never read broader than what was executed.
CI_COVERAGE=(
  "changes|none|dorny path-filter computation, no local analogue; it decides which jobs run, it gates nothing"
  "rust|full|fmt, clippy, the workspace tests, both wire guards, the deterministic corpus and every feature-matrix cargo invocation ci.yml runs, including the reqwest and sqlcipher clippy passes and the live and live+firestore telemetryd tests; the fuzz smoke needs cargo-fuzz and is named in NOT RUN without it"
  "deny|partial|cargo deny check runs locally when cargo-deny is installed (cargo install cargo-deny --locked --version 0.20.2); skipped if missing"
  "kotlin-sdk|full|gradle test + jacocoTestReport + jacocoTestCoverageVerification, the same tasks ci.yml runs, when mise java/android-sdk and gradle are present"
  "compose-sdk|none|the Compose Multiplatform desktopTest suite is not run here; it needs the Compose Multiplatform gradle toolchain, which the local mirror does not provision"
  "android|full|the bearers and HopDemo JVM unit suites AND all five per-module JaCoCo coverage-verification floors ci.yml gates on, when mise java/android-sdk and gradle are present"
  "apple|partial|swift test for all eight packages, when swift and xcodebuild are present; NOT the six apple-cov-gate floors, the HopDriver llvm-cov floor, or the build-only xcodebuild of the demo app"
  "wasm|none|the wasm32 browser-target build of hop-wasm is not run here; sim/build-wasm.sh builds the node target for the sim vectors, which is a different target"
  "web|partial|the sim pkg freshness and wire-vector checks run here; NOT the scenario check, the wasm-glue check, npm ci, the Astro build, or the internal link check"
  "contract|partial|the ABI version guard AND its self-test run here; NOT contract purity, the cbindgen header-drift diff, the C-ABI smoke, the wire vectors through the native C ABI, the embedded C++ host tests, or the ESP32 host example"
  "automation|partial|the docs token guard, the BLE backoff parity pair, the durable-store data map pair, the repo integrity guard, the package export smoke, the Apple published pin guard self-test and the required-checks guard run here; NOT the native attestation npm tests, the agent output guard, the executable reference guard, the Apple pod trunk publisher self-test, the sync/pages/release/artifact-publication/workflow-secrets guards, or the audit skill tests"
  "docs-tokens|partial|the docs token guard and the repo integrity guard run here; NOT the release provenance self-test, the full export generation, the coverage-floor gate self-test, or the version alignment guard"
  "node-sdk|none|the endpoint SDK suites are not run here"
  "python-sdk|none|the endpoint SDK suites are not run here"
  "go-sdk|none|the endpoint SDK suites are not run here"
  "ruby-sdk|none|the endpoint SDK suites are not run here"
  "crystal-sdk|none|the endpoint SDK suites are not run here, including the crystal tool format check that has broken CI repeatedly"
  "elixir-sdk|none|the endpoint SDK suites are not run here, including the mix format check that has broken CI repeatedly"
  "flutter-sdk|none|the endpoint SDK suites are not run here, including the dart analyze and dart format checks that need the Dart SDK"
  "react-native-sdk|none|the React Native SDK typecheck and JS bridge tests are not run here; unlike the other SDKs it has no mirror CI, so ci.yml is its only gate"
  "lowest-supported-bounds|none|the Python + Go lowest-supported-dependency-bounds run (go mod tidy -compat, uv lowest resolution) is not run here; it needs pinned Go 1.22 and Python 3.12 toolchains, and it is what INFRA-013 gates on"
  "gate|none|the aggregate that depends on the other 21; it exists only in CI and is the ONE required context on main"
)

step() { printf '%-46s' "$1"; shift; if "$@" >"$LOG" 2>&1; then echo "OK"; else echo "FAIL"; fail=1; tail -6 "$LOG" | sed 's/^/    /'; fi; }
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
# The feature matrix, in ci.yml's order and with ci.yml's exact flags. The CLIPPY passes matter as much
# as the tests: a feature-gated region that only ever gets `cargo test` still fails CI on a warning,
# and these three were the gap that made this script's rust entry read "partial".
step "gateway (reqwest feature)"      cargo test -p hop-gateway --features reqwest
step "clippy gateway (reqwest)"       cargo clippy -p hop-gateway --features reqwest --all-targets -- -D warnings
step "C ABI (sqlcipher feature)"      cargo test -p hop --no-default-features --features sqlcipher --locked
step "clippy C ABI (sqlcipher)"       cargo clippy -p hop --no-default-features --features sqlcipher --all-targets --locked -- -D warnings
step "relayd (firestore feature)"     cargo test -p hop-relayd --features firestore
# The accountd and billingd feature-matrix steps used to run here via --manifest-path (both crates sit
# outside the workspace). They moved to hopmesh/platform with the rest of the commercial backend, so
# their mirror steps went with them.
step "telemetryd (firestore feature)" cargo test -p hop-telemetryd --features firestore
step "telemetryd (live feature)"      cargo test -p hop-telemetryd --features live
step "telemetryd (live + firestore)"  cargo test -p hop-telemetryd --features live,firestore
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
if have cargo-deny; then
  step "cargo deny check" cargo deny check
else
  skip "cargo deny check" "cargo-deny not installed; cargo install cargo-deny --locked --version 0.20.2"
fi

# --- guards --------------------------------------------------------------------------------------
step "docs-token-guard"               bash tools/docs-token-guard.sh
step "ble-backoff-parity self-test"   bash tools/ble-backoff-parity.test.sh
step "ble-backoff-parity"             bash tools/ble-backoff-parity.sh
step "ble-threading self-test"        bash tools/ble-threading-guard.test.sh
step "ble-threading guard"            bash tools/ble-threading-guard.sh
step "mailbox-prefix-doc self-test"   bash tools/mailbox-prefix-doc-guard.test.sh
step "mailbox-prefix-doc guard"       bash tools/mailbox-prefix-doc-guard.sh
step "store-data-map self-test"       bash tools/store-data-map-guard.test.sh
step "store-data-map guard"           python3 tools/store-data-map-guard.py
step "abi-version guard self-test"    bash tools/codegen/check-abi-version.test.sh
step "abi-version guard"              bash tools/codegen/check-abi-version.sh
# Only the self-test: the live pin check downloads the pinned xcframework, and a pre-push script that
# reaches the network gets switched off. apple-pin-guard.yml runs the live half.
step "apple-pin guard self-test"      bash tools/apple-pin-guard.test.sh
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
    # The SAME task list ci.yml's android job runs. A bare `./gradlew test` used to stand in for it,
    # which meant the four per-module JaCoCo LINE floors CI GATES ON (lan, relay, ble, driver) were
    # never evaluated here while the coverage table still called this job "full". A coverage floor that
    # only exists in CI is a floor this script cannot see you break.
    step "bearers/android (+cov floors)" bash -c 'cd bearers/android && ./gradlew :bearer-ble:testDebugUnitTest test \
      :bearer-lan:jacocoLanReport :bearer-lan:jacocoLanCoverageVerification \
      :bearer-relay:jacocoRelayReport :bearer-relay:jacocoRelayCoverageVerification \
      :bearer-ble:jacocoBleReport :bearer-ble:jacocoBleCoverageVerification \
      :bearer-meshtastic:jacocoMeshtasticReport :bearer-meshtastic:jacocoMeshtasticCoverageVerification \
      :hop-driver:jacocoDriverReport :hop-driver:jacocoDriverCoverageVerification --stacktrace'
    step "HopDemo android (+cov floor)"  bash -c 'cd apps/android/HopDemo && ./gradlew :app:testDebugUnitTest \
      :app:jacocoDemoReport :app:jacocoDemoCoverageVerification --stacktrace'
  else
    skip "Kotlin SDK + Android suites" "no mise java/android-sdk or gradle"
  fi

  if have swift && have xcodebuild; then
    # Every in-tree Apple package resolves sdk/apple BY PATH, but the committed manifest is the
    # PUBLISHED one and points at a hop-sdk-apple release asset that does not exist, so resolution
    # 404s. CI does this same swap. The EXIT trap at the top of this script restores the manifest on
    # ANY exit (including a failure or a Ctrl-C) so a run never leaves the published manifest swapped.
    # tools/build-xcframework.sh below REWRITES the tracked 178MB drivers/apple/HopDriver/Frameworks;
    # the same trap restores that, and fails the run if it cannot.
    if [ ! -f sdk/apple/Frameworks/libhop.xcframework/Info.plist ]; then
      step "build apple xcframeworks" bash -c 'bash sdk/apple/build-xcframework.sh && bash tools/build-xcframework.sh'
    fi
        pkg_backup="$SCRATCH/Package.swift.published"
        cp sdk/apple/Package.swift "$pkg_backup"
    cp sdk/apple/Package.local.swift sdk/apple/Package.swift
    for p in sdk/apple drivers/apple/HopDriver apps/apple/HopDemoKit \
             bearers/apple/HopBearerBle bearers/apple/HopBearerLan bearers/apple/HopBearerRelay \
             bearers/apple/HopBearerMultipeer bearers/apple/HopBearerMeshtastic; do
      step "swift test $p" bash -c "cd '$p' && swift test"
    done
        cp "$pkg_backup" sdk/apple/Package.swift
        pkg_backup=""
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

# Every CI job this script does not fully cover, named, on every run. An empty `skipped` array means
# the local toolchain was complete, NOT that CI's scope was covered, and that difference is exactly
# what a bare pass line used to hide.
uncovered=()
for entry in "${CI_COVERAGE[@]}"; do
  job="${entry%%|*}"
  rest="${entry#*|}"
  level="${rest%%|*}"
  reason="${rest#*|}"
  [ "$level" = "full" ] || uncovered+=("$job [$level] $reason")
done
if [ "${#uncovered[@]}" -gt 0 ]; then
  echo "CI JOBS NOT FULLY COVERED HERE (${#uncovered[@]} of ${#CI_COVERAGE[@]}), a pass below says nothing about these:"
  for u in "${uncovered[@]}"; do echo "  - $u"; done
  echo
fi

if [ "$fail" -ne 0 ]; then
  echo "SOME GATES FAILED"
elif [ "${#skipped[@]}" -gt 0 ]; then
  echo "GATES RUN HERE PASS, but the lists above were NOT checked; CI still can redden."
else
  echo "ALL LOCAL GATES PASS (rust + guards + kotlin/android + apple); the CI jobs listed above were NOT checked here, so CI can still redden."
fi
exit "$fail"
