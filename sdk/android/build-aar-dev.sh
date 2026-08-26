#!/usr/bin/env bash
# Build the Hop Android core plus the BLE, LAN, and Relay bearer AARs into one LOCAL Maven repository,
# locally compiled native slices. This is the DEV path. It is not the release path and it must never be
# mistaken for one.
#
# WHY THIS EXISTS
# ---------------
# build-aar.sh, its sibling, is the sanctioned path: it takes --bundle and verifies
# native-artifacts.json against native-artifacts.json.sig before extracting one libhop.so per ABI. That
# path cannot run today, for two independent reasons:
#
#   1. The signing job that produces the bundle is red for want of NATIVE_ARTIFACT_SIGNING_KEY, which is
#      absent from hopmesh/hop's `release` environment. Secret values cannot be copied out of any repo,
#      so it has to be re-seeded by hand.
#   2. Even with the key, the only bundle ever published (hop-sdk-go v0.0.2) carries apple and linux
#      slices only. It contains no android targets at all, so there would be nothing to extract.
#
# Meanwhile sh.hop:hop is on no Maven repository anywhere: Central returns 404 for both the metadata and
# the POM, and a group search for sh.hop returns nothing. A consumer that declares
# `implementation "sh.hop:hop:<version>"` cannot resolve it from any remote, and @hop-mesh/react-native
# was unbuildable on Android for exactly that reason.
#
# This script closes that gap locally, without a signature and without a registry, so the Android half of
# the React Native SDK can build and test against the same core, BLE, LAN, and Relay artifacts it will consume.
#
# WHAT IT DELIBERATELY DOES NOT DO
# --------------------------------
# It does not sign anything, and it does not publish to a remote. The artifacts it produces are for local
# development and CI only. Publishing sh.hop:hop for real needs Sonatype credentials plus a signing key
# and is a release decision, not a build step.
#
# WHY A MAVEN REPOSITORY AND NOT BARE .aars
# ------------------------------------------
# The POMs are load-bearing. The core POM appends net.java.dev.jna:jna as a runtime dependency, and the
# Kotlin wrapper loads libhop THROUGH JNA. Each bearer POM derives exactly one runtime AAR dependency on
# sh.hop:hop, instead of exposing its in-tree :hop-sdk build shim. A consumer that points at AAR files
# directly, via `files(...)` or a flatDir repository, gets neither graph. That does not fail the build.
# It fails at runtime or resolution, so this publishes a real repository layout with the POMs intact.
#
# USAGE
#   ./sdk/android/build-aar-dev.sh                       # publishes to sdk/android/build/maven-repository
#   ./sdk/android/build-aar-dev.sh --repository <path>    # publishes somewhere else
#
# Consume it with, and note includeGroup so this repository is never consulted for anything else:
#   repositories { maven { url = uri("<path>"); content { includeGroup "sh.hop"; includeGroup "sh.hop.bearers" } } }
#   dependencies {
#     implementation "sh.hop:hop:<core-version>"
#     implementation "sh.hop.bearers:bearer-ble:<bearer-version>"
#     implementation "sh.hop.bearers:bearer-lan:<bearer-version>"
#     implementation "sh.hop.bearers:bearer-relay:<bearer-version>"
#   }
#
# PREREQUISITES, all of which this script checks before doing any work:
#   rustup targets: aarch64-linux-android x86_64-linux-android armv7-linux-androideabi i686-linux-android
#   cargo-ndk, an Android NDK, and a JDK.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
bearers="$root/bearers/android"
repository_helper="$bearers/local-maven-repository.py"

repository="$here/build/maven-repository"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository) repository="${2:?missing repository path}"; shift 2 ;;
    -h|--help) sed -n '1,50p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
repository_parent="$(dirname "$repository")"
mkdir -p "$repository_parent"
repository_parent="$(cd "$repository_parent" && pwd)"
repository="$repository_parent/$(basename "$repository")"

# rustup's cargo must win over Homebrew's. Homebrew rust carries no Android std, and the failure it
# produces is actively misleading: rustc says "can't find crate for `core`, the <target> target may not
# be installed" while `rustup target list` reports that exact target as installed, because the two are
# different toolchains. rust-toolchain.toml pins the version this repo builds with.
if [[ -d "$HOME/.cargo/bin" ]]; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi
if [[ -z "${JAVA_HOME:-}" && -x /opt/homebrew/opt/openjdk@17/bin/java ]]; then
  export JAVA_HOME=/opt/homebrew/opt/openjdk@17
  export PATH="$JAVA_HOME/bin:$PATH"
fi

fail() { echo "build-aar-dev: $*" >&2; exit 1; }

# The version below is a LITERAL on purpose. tools/executable-reference-guard.py requires every cargo
# install in this repo to name an exact version, and it caught this script for suggesting a bare
# `cargo install cargo-ndk`. It was right: an unpinned install instruction is an unpinned supply-chain
# reference even when it only ever appears in an error message a human copies.
#
# The guard DOES accept a variable, but only in the workflow-YAML shape (`NAME: "1.2.3"` on its own
# line, as ci.yml does for CARGO_FUZZ_VERSION and CBINDGEN_VERSION). A shell assignment with `=` does
# not match that, so a variable here would fail the guard for a reason unrelated to being unpinned. A
# literal is also the better error message: it is copy-pasteable with no indirection.
command -v cargo >/dev/null || fail "cargo not found. Install rustup; this repo pins its version in rust-toolchain.toml."
command -v cargo-ndk >/dev/null || fail "cargo-ndk not found. Install it with: cargo install cargo-ndk --locked --version 4.1.2"
command -v java >/dev/null || fail "no JDK on PATH. Toolchains here come from mise, not global installs, so try: mise exec -- $0"
command -v gradle >/dev/null || fail "gradle not found on PATH. Try: mise exec -- $0"

# AGP needs the Android SDK even though cargo-ndk only needs the NDK. A core-only publication did not
# expose this prerequisite, but compiling either bearer AAR does. Normalize ANDROID_SDK_ROOT to the
# variable AGP reads, or select the same conventional SDK locations used for the NDK.
if [[ -n "${ANDROID_HOME:-}" ]]; then
  android_sdk="$ANDROID_HOME"
elif [[ -n "${ANDROID_SDK_ROOT:-}" ]]; then
  android_sdk="$ANDROID_SDK_ROOT"
  export ANDROID_HOME="$android_sdk"
else
  android_sdk=""
  for candidate in /opt/homebrew/share/android-commandlinetools "$HOME/Library/Android/sdk"; do
    [[ -d "$candidate/platforms" && -d "$candidate/build-tools" ]] || continue
    android_sdk="$candidate"
    export ANDROID_HOME="$android_sdk"
    break
  done
fi
[[ -d "$android_sdk/platforms" && -d "$android_sdk/build-tools" ]] ||
  fail "no Android SDK found. Set ANDROID_HOME to an SDK containing platforms and build-tools."

# cargo-ndk finds the NDK through one of these. Checking here turns a deep, unreadable linker error into
# one line naming what to set.
if [[ -z "${ANDROID_NDK_HOME:-}${ANDROID_NDK_ROOT:-}${NDK_HOME:-}" ]]; then
  candidate=""
  for base in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" /opt/homebrew/share/android-commandlinetools "$HOME/Library/Android/sdk"; do
    [[ -n "$base" && -d "$base/ndk" ]] || continue
    candidate="$(find "$base/ndk" -maxdepth 1 -mindepth 1 -type d | sort -V | tail -n1)"
    [[ -n "$candidate" ]] && break
  done
  [[ -n "$candidate" ]] || fail "no Android NDK found. Set ANDROID_NDK_HOME, or install one via sdkmanager 'ndk;26.3.11579264'."
  export ANDROID_NDK_HOME="$candidate"
  echo "build-aar-dev: using NDK $ANDROID_NDK_HOME"
fi

test -f "$repository_helper" || fail "local Maven repository verifier is missing: $repository_helper"
versions="$(python3 "$repository_helper" versions --source-root "$root")" ||
  fail "could not derive the core and bearer versions from their publishing sources"
mapfile -t version_lines <<<"$versions"
[[ "${#version_lines[@]}" -eq 2 ]] ||
  fail "version derivation returned ${#version_lines[@]} values instead of the core and bearer versions"
core_version="${version_lines[0]}"
bearer_version="${version_lines[1]}"
echo "build-aar-dev: core sh.hop:hop:$core_version; bearers sh.hop.bearers:{bearer-ble,bearer-lan,bearer-relay}:$bearer_version"

# Build a fresh tree beside the destination. A failed publication never changes a previously verified
# local repository, and the final rename means the destination cannot retain stale modules.
staging="$(mktemp -d "$repository_parent/.$(basename "$repository").staging.XXXXXX")" ||
  fail "could not create a fresh Maven repository staging directory"
cleanup_staging() {
  [[ -n "${staging:-}" && -d "$staging" ]] && rm -rf "$staging"
}
trap cleanup_staging EXIT

# The four ABIs the AAR declares. Kept in the same order as build.gradle.kts's androidAbis so a mismatch
# is easy to spot by eye.
native="$here/build/native-android-dev"
rm -rf "$native"
mkdir -p "$native"
echo "build-aar-dev: compiling libhop for four ABIs (this is the slow part)"
( cd "$root" && cargo ndk \
    -t arm64-v8a -t armeabi-v7a -t x86 -t x86_64 \
    -o "$native" build --release -p hop )

for abi in arm64-v8a armeabi-v7a x86 x86_64; do
  test -f "$native/$abi/libhop.so" || fail "cargo-ndk did not produce $abi/libhop.so"
done

# Prefab metadata in the AAR ships the C ABI header, and the gradle task requires it at include/hop.h.
# sdk/hop.h is the canonical generated header (the drift guard in CI is what keeps it honest), so this
# copies rather than regenerates: regenerating here would need cbindgen and could disagree with the
# committed contract.
#
# Note for whoever fixes the signed path: build-aar.sh compares each extracted archive's header against
# $here/include/hop.h, and that file is NOT in the repository. So the signed path needs this staging step
# too, or an equivalent, quite apart from the missing signing key.
test -f "$root/sdk/hop.h" || fail "sdk/hop.h is missing; it is the canonical C ABI header the AAR ships"
mkdir -p "$here/include"
cp "$root/sdk/hop.h" "$here/include/hop.h"

echo "build-aar-dev: publishing core to a fresh staging repository"
( cd "$here" && gradle hopAar publishHopPublicationToHopRepository \
    -PhopNativeDir="$native" -PhopMavenRepository="$staging" --no-daemon -q )

# These tasks publish only the consumer-facing BLE, LAN, and Relay artifacts. `:hop-sdk` is an in-tree
# source shim, not a publication, and the root POM derivation rejects any other project dependency.
echo "build-aar-dev: publishing BLE, LAN, and Relay bearer artifacts"
( cd "$bearers" && gradle \
    :bearer-ble:publishBearerPublicationToHopRepository \
    :bearer-lan:publishBearerPublicationToHopRepository \
    :bearer-relay:publishBearerPublicationToHopRepository \
    -PhopMavenRepository="$staging" --no-daemon -q )

# The receipt is deterministic: it records every payload digest and the exact source-input tree, then
# the read-only pass checks the POM graph, sidecars, no Gradle module metadata, and no embedded core
# classes or libhop native slices in either bearer AAR.
python3 "$repository_helper" stamp --source-root "$root" --repository "$staging"
python3 "$repository_helper" verify --source-root "$root" --repository "$staging"

# Only a complete, verified replacement may change the requested destination. It is an explicit build
# output, so replacing an older local repository here is safe; failures before this point preserve it.
if [[ -e "$repository" || -L "$repository" ]]; then
  [[ ! -L "$repository" && -d "$repository" ]] ||
    fail "destination exists but is not a directory: $repository"
  rm -rf "$repository"
fi
mv "$staging" "$repository"
staging=""
trap - EXIT

cat <<EOF

build-aar-dev: published unsigned local artifacts
  repository: $repository
  core:       sh.hop:hop:$core_version
  BLE:        sh.hop.bearers:bearer-ble:$bearer_version
  LAN:        sh.hop.bearers:bearer-lan:$bearer_version
  Relay:      sh.hop.bearers:bearer-relay:$bearer_version
  receipt:    $repository/hop-android-dev-maven-provenance.json

Consume it from a Gradle module with:

  repositories { maven { url = uri("$repository"); content { includeGroup "sh.hop"; includeGroup "sh.hop.bearers" } } }
  dependencies {
    implementation "sh.hop.bearers:bearer-ble:$bearer_version"
    implementation "sh.hop.bearers:bearer-lan:$bearer_version"
    implementation "sh.hop.bearers:bearer-relay:$bearer_version"
  }

The bearer POMs resolve sh.hop:hop:$core_version transitively. Do not add a source sibling project.

Or point @hop-mesh/react-native at it without editing files:

  export HOP_MAVEN_REPOSITORY="$repository"
EOF
