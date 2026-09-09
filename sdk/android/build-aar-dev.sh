#!/usr/bin/env bash
# Build and publish the Hop Android SDK AAR to a LOCAL Maven repository, from locally compiled native
# slices. This is the DEV path. It is not the release path and it must never be mistaken for one.
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
# the POM, and a group search for sh.hop returns nothing. So a consumer that declares
# `implementation "sh.hop:hop:<version>"` cannot resolve it from any remote, and @hop-mesh/react-native
# was unbuildable on Android for exactly that reason.
#
# This script closes that gap locally, without a signature and without a registry, so the Android half of
# the React Native SDK can be built and tested today.
#
# WHAT IT DELIBERATELY DOES NOT DO
# --------------------------------
# It does not sign anything, and it does not publish to a remote. The artifacts it produces are for local
# development and CI only. Publishing sh.hop:hop for real needs Sonatype credentials plus a signing key
# and is a release decision, not a build step.
#
# WHY A MAVEN REPOSITORY AND NOT A BARE .aar
# ------------------------------------------
# Because the POM is load-bearing. The publication appends net.java.dev.jna:jna as a runtime dependency,
# and the Kotlin wrapper loads libhop THROUGH JNA. A consumer that points at the .aar file directly, via
# `files(...)` or a flatDir repository, gets no POM and therefore no JNA, which does not fail the build.
# It fails at runtime on the first call into the bridge, as a ClassNotFoundError. A green build that
# proves nothing is the worse outcome, so this publishes a real repository layout with the POM intact.
#
# USAGE
#   ./sdk/android/build-aar-dev.sh                       # publishes to sdk/android/build/maven-repository
#   ./sdk/android/build-aar-dev.sh --repository <path>   # publishes somewhere else
#   ./sdk/android/build-aar-dev.sh --no-native           # stub native slices for compilation/metadata gating
#
# Consume them with, and note includeGroup so this repository is never consulted for anything else:
#   repositories {
#     maven {
#       url = uri("<path>")
#       content {
#         includeGroup "sh.hop"
#         includeGroup "sh.hop.bearers"
#       }
#     }
#   }
#   dependencies {
#     implementation "sh.hop:hop:<version>"
#     implementation "sh.hop.bearers:bearer-ble:<bearer-version>"
#     implementation "sh.hop.bearers:bearer-lan:<bearer-version>"
#   }
#
# PREREQUISITES, checked before doing any work:
#   JDK, Gradle, and Android SDK platforms.
#   When compiling native slices (default): rustup targets, cargo-ndk, and an Android NDK.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

repository="$here/build/maven-repository"
no_native=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository) repository="${2:?missing repository path}"; shift 2 ;;
    --no-native) no_native=true; shift ;;
    -h|--help) sed -n '1,50p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
mkdir -p "$(dirname "$repository")"
repository="$(cd "$(dirname "$repository")" && pwd)/$(basename "$repository")"

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

# cargo-ndk and NDK are required only when compiling real native slices.
if [[ "$no_native" = false ]]; then
  command -v cargo >/dev/null || fail "cargo not found. Install rustup; this repo pins its version in rust-toolchain.toml."
  command -v cargo-ndk >/dev/null || fail "cargo-ndk not found. Install it with: cargo install cargo-ndk --locked --version 4.1.2"
fi
command -v java >/dev/null || fail "no JDK on PATH. Toolchains here come from mise, not global installs, so try: mise exec -- $0"
command -v gradle >/dev/null || fail "gradle not found on PATH. Try: mise exec -- $0"

if [[ -z "${ANDROID_HOME:-}${ANDROID_SDK_ROOT:-}" ]]; then
  for candidate in /opt/homebrew/share/android-commandlinetools "$HOME/Library/Android/sdk" /usr/local/lib/android/sdk; do
    if [[ -d "$candidate/platforms" ]]; then
      export ANDROID_HOME="$candidate"
      break
    fi
  done
fi

if [[ "$no_native" = false && -z "${ANDROID_NDK_HOME:-}${ANDROID_NDK_ROOT:-}${NDK_HOME:-}" ]]; then
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

version="$(python3 -c 'import re,sys; print(re.search(r"^version = \"([^\"]+)\"$", open(sys.argv[1]).read(), re.M).group(1))' "$here/build.gradle.kts")"
bearer_version="$(python3 -c 'import re,sys; print(re.search(r"^version = \"([^\"]+)\"$", open(sys.argv[1]).read(), re.M).group(1))' "$root/bearers/android/build.gradle.kts")"
echo "build-aar-dev: sh.hop:hop:$version, sh.hop.bearers:$bearer_version"

# The four ABIs the AAR declares. Kept in the same order as build.gradle.kts's androidAbis so a mismatch
# is easy to spot by eye.
native="$here/build/native-android-dev"
rm -rf "$native"
mkdir -p "$native"
if [[ "$no_native" = true ]]; then
  echo "build-aar-dev: creating stub native slices (--no-native for compilation and metadata gating)"
  for abi in arm64-v8a armeabi-v7a x86 x86_64; do
    mkdir -p "$native/$abi"
    touch "$native/$abi/libhop.so"
  done
else
  echo "build-aar-dev: compiling libhop for four ABIs (this is the slow part)"
  ( cd "$root" && cargo ndk \
      -t arm64-v8a -t armeabi-v7a -t x86 -t x86_64 \
      -o "$native" build --release -p hop )
  for abi in arm64-v8a armeabi-v7a x86 x86_64; do
    test -f "$native/$abi/libhop.so" || fail "cargo-ndk did not produce $abi/libhop.so"
  done
fi

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

echo "build-aar-dev: publishing sh.hop:hop to $repository"
( cd "$here" && gradle hopAar publishHopPublicationToHopRepository \
    -PhopNativeDir="$native" -PhopMavenRepository="$repository" --no-daemon -q )

aar="$repository/sh/hop/hop/$version/hop-$version.aar"
pom="$repository/sh/hop/hop/$version/hop-$version.pom"
test -f "$aar" || fail "publish reported success but $aar is absent"
test -f "$pom" || fail "publish reported success but $pom is absent"

echo "build-aar-dev: publishing bearer AARs to $repository"
( cd "$root/bearers/android" && gradle :bearer-ble:publishBearerPublicationToHopRepository :bearer-lan:publishBearerPublicationToHopRepository \
    -PhopMavenRepository="$repository" --no-daemon -q )

ble_aar="$repository/sh/hop/bearers/bearer-ble/$bearer_version/bearer-ble-$bearer_version.aar"
ble_pom="$repository/sh/hop/bearers/bearer-ble/$bearer_version/bearer-ble-$bearer_version.pom"
lan_aar="$repository/sh/hop/bearers/bearer-lan/$bearer_version/bearer-lan-$bearer_version.aar"
lan_pom="$repository/sh/hop/bearers/bearer-lan/$bearer_version/bearer-lan-$bearer_version.pom"
test -f "$ble_aar" || fail "publish reported success but $ble_aar is absent"
test -f "$ble_pom" || fail "publish reported success but $ble_pom is absent"
test -f "$lan_aar" || fail "publish reported success but $lan_aar is absent"
test -f "$lan_pom" || fail "publish reported success but $lan_pom is absent"

python3 - "$aar" "$pom" "$ble_aar" "$ble_pom" "$lan_aar" "$lan_pom" "$no_native" <<'PY'
import pathlib, sys, zipfile

hop_aar, hop_pom, ble_aar, ble_pom, lan_aar, lan_pom, no_native_str = sys.argv[1:8]
no_native = (no_native_str == "true")

hop_names = set(zipfile.ZipFile(hop_aar).namelist())
if not no_native:
    missing = [a for a in ("arm64-v8a", "armeabi-v7a", "x86", "x86_64") if f"jni/{a}/libhop.so" not in hop_names]
    if missing:
        sys.exit(f"build-aar-dev: AAR is missing native slices for: {', '.join(missing)}")
if "classes.jar" not in hop_names:
    sys.exit("build-aar-dev: hop AAR has no classes.jar")
hop_pom_text = pathlib.Path(hop_pom).read_text()
if "<artifactId>jna</artifactId>" not in hop_pom_text:
    sys.exit("build-aar-dev: the hop POM no longer declares JNA. A consumer would build green and then fail "
             "at runtime with a ClassNotFoundError on the first bridge call.")
if "<packaging>aar</packaging>" not in hop_pom_text:
    sys.exit("build-aar-dev: the hop POM does not declare aar packaging")

for b_name, b_aar, b_pom in [("bearer-ble", ble_aar, ble_pom), ("bearer-lan", lan_aar, lan_pom)]:
    b_names = set(zipfile.ZipFile(b_aar).namelist())
    if "classes.jar" not in b_names:
        sys.exit(f"build-aar-dev: {b_name} AAR has no classes.jar")
    b_pom_text = pathlib.Path(b_pom).read_text()
    if "<artifactId>hop</artifactId>" not in b_pom_text:
        sys.exit(f"build-aar-dev: {b_name} POM does not declare sh.hop:hop dependency")
    if "<packaging>aar</packaging>" not in b_pom_text:
        sys.exit(f"build-aar-dev: {b_name} POM does not declare aar packaging")

print("build-aar-dev: verified all 3 required artifacts (sh.hop:hop, bearer-ble, bearer-lan)")
PY

cat <<EOF

build-aar-dev: published 3 artifacts (UNSIGNED, local only)
  repository: $repository
  sh.hop:hop:$version:
    aar: $aar
  sh.hop.bearers:bearer-ble:$bearer_version:
    aar: $ble_aar
  sh.hop.bearers:bearer-lan:$bearer_version:
    aar: $lan_aar

Consume them from a gradle module with:

  repositories {
    maven {
      url = uri("$repository")
      content {
        includeGroup "sh.hop"
        includeGroup "sh.hop.bearers"
      }
    }
  }
  dependencies {
    implementation "sh.hop:hop:$version"
    implementation "sh.hop.bearers:bearer-ble:$bearer_version"
    implementation "sh.hop.bearers:bearer-lan:$bearer_version"
  }

Or point @hop-mesh/react-native at it without editing files:

  export HOP_MAVEN_REPOSITORY="$repository"
EOF
