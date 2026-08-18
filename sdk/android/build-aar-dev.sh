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
#   ./sdk/android/build-aar-dev.sh --repository <path>    # publishes somewhere else
#
# Consume it with, and note includeGroup so this repository is never consulted for anything else:
#   repositories { maven { url = uri("<path>"); content { includeGroup "sh.hop" } } }
#   dependencies { implementation "sh.hop:hop:<version>" }
#
# PREREQUISITES, all of which this script checks before doing any work:
#   rustup targets: aarch64-linux-android x86_64-linux-android armv7-linux-androideabi i686-linux-android
#   cargo-ndk, an Android NDK, and a JDK.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

repository="$here/build/maven-repository"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository) repository="${2:?missing repository path}"; shift 2 ;;
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

command -v cargo >/dev/null || fail "cargo not found. Install rustup; this repo pins its version in rust-toolchain.toml."
command -v cargo-ndk >/dev/null || fail "cargo-ndk not found. Install it with: cargo install cargo-ndk"
command -v java >/dev/null || fail "no JDK on PATH. Toolchains here come from mise, not global installs, so try: mise exec -- $0"
command -v gradle >/dev/null || fail "gradle not found on PATH. Try: mise exec -- $0"

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

version="$(python3 -c 'import re,sys; print(re.search(r"^version = \"([^\"]+)\"$", open(sys.argv[1]).read(), re.M).group(1))' "$here/build.gradle.kts")"
echo "build-aar-dev: sh.hop:hop:$version (version comes from build.gradle.kts, which is the source of truth)"

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

echo "build-aar-dev: publishing to $repository"
( cd "$here" && gradle hopAar publishHopPublicationToHopRepository \
    -PhopNativeDir="$native" -PhopMavenRepository="$repository" --no-daemon -q )

aar="$repository/sh/hop/hop/$version/hop-$version.aar"
pom="$repository/sh/hop/hop/$version/hop-$version.pom"
test -f "$aar" || fail "publish reported success but $aar is absent"
test -f "$pom" || fail "publish reported success but $pom is absent"

# Verify the two things a consumer actually depends on, rather than trusting that gradle exited 0.
# 1. Every ABI is really inside the archive. An AAR missing a slice builds fine and then crashes on that
#    device class with an UnsatisfiedLinkError.
# 2. The POM still carries JNA. If a future change to the publication drops it, the consumer silently
#    loses the library that loads libhop.
python3 - "$aar" "$pom" <<'PY'
import re, sys, zipfile, pathlib
aar, pom = sys.argv[1], sys.argv[2]
names = set(zipfile.ZipFile(aar).namelist())
missing = [a for a in ("arm64-v8a", "armeabi-v7a", "x86", "x86_64") if f"jni/{a}/libhop.so" not in names]
if missing:
    sys.exit(f"build-aar-dev: AAR is missing native slices for: {', '.join(missing)}")
if "classes.jar" not in names:
    sys.exit("build-aar-dev: AAR has no classes.jar")
text = pathlib.Path(pom).read_text()
if "<artifactId>jna</artifactId>" not in text:
    sys.exit("build-aar-dev: the POM no longer declares JNA. A consumer would build green and then fail "
             "at runtime with a ClassNotFoundError on the first bridge call.")
if "<packaging>aar</packaging>" not in text:
    sys.exit("build-aar-dev: the POM does not declare aar packaging")
print(f"build-aar-dev: verified 4 ABIs, classes.jar, aar packaging, and the JNA dependency")
PY

cat <<EOF

build-aar-dev: published sh.hop:hop:$version (UNSIGNED, local only)
  repository: $repository
  aar:        $aar

Consume it from a gradle module with:

  repositories { maven { url = uri("$repository"); content { includeGroup "sh.hop" } } }
  dependencies { implementation "sh.hop:hop:$version" }

Or point @hop-mesh/react-native at it without editing files:

  export HOP_MAVEN_REPOSITORY="$repository"
EOF
