#!/usr/bin/env bash
# Self-test for tools/apple-pin-guard.py.
#
# The guard exists because a green tree published an unbuildable manifest, so the only thing worth
# testing is that it FAILS on each shape of that defect and passes on a consistent pair. Every case
# runs against fixtures with no network: the download path is exercised through --asset (a real zip
# built here) so the archive reader and the checksum verification are covered offline.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
guard="$root/tools/apple-pin-guard.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- fixture builders -----------------------------------------------------------------------------

# A minimal published manifest pinning one asset by url and checksum.
write_package() {
  local dir="$1" checksum="$2"
  mkdir -p "$dir"
  cat >"$dir/Package.swift" <<EOF
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Hop",
    targets: [
        .binaryTarget(
            name: "CHop",
            url: "https://example.invalid/releases/download/v9.9.9/libhop.xcframework.zip",
            checksum: "$checksum"
        ),
    ]
)
EOF
}

# Swift sources asserting an ABI and calling two C functions.
write_sources() {
  local dir="$1" abi="$2"
  mkdir -p "$dir/Sources/Hop"
  cat >"$dir/Sources/Hop/Hop.swift" <<EOF
public final class HopNode {
    public static let expectedABIVersion: UInt32 = $abi
    public func open() { hop_open(raw) }
    public func register() { hop_hps_register(raw, "topic") }
}
EOF
}

write_header() {
  local path="$1" abi="$2" include_hps="$3"
  mkdir -p "$(dirname "$path")"
  {
    echo "#define HOP_ABI_VERSION $abi"
    echo "bool hop_open(struct HopNode *node);"
    [ "$include_hps" = yes ] && echo "bool hop_hps_register(struct HopNode *node, const char *path);"
  } >"$path"
  return 0
}

# Package the header the way a real xcframework archive carries it.
zip_asset() {
  local header="$1" out="$2" stage
  stage="$(mktemp -d)"
  mkdir -p "$stage/libhop.xcframework/ios-arm64/Headers"
  cp "$header" "$stage/libhop.xcframework/ios-arm64/Headers/hop.h"
  (cd "$stage" && zip -q -r "$out" libhop.xcframework)
  rm -rf "$stage"
}

sha256() { python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

expect_pass() {
  local label="$1"; shift
  if ! "$@" >/dev/null 2>&1; then
    echo "FAIL: $label should have passed" >&2
    "$@" >&2 || true
    exit 1
  fi
}

expect_fail() {
  local label="$1" needle="$2"; shift 2
  local output
  if output="$("$@" 2>&1)"; then
    echo "FAIL: $label should have failed, but the guard passed" >&2
    echo "$output" >&2
    exit 1
  fi
  if ! printf '%s' "$output" | grep -q "$needle"; then
    echo "FAIL: $label failed for the wrong reason (expected to mention '$needle')" >&2
    echo "$output" >&2
    exit 1
  fi
}

# --- 1. a consistent pair passes ------------------------------------------------------------------
write_sources "$work/ok" 6
write_header "$work/ok/hop.h" 6 yes
write_package "$work/ok" "$(printf '%064d' 0)"
expect_pass "matched ABI and complete declarations" \
  python3 "$guard" --package "$work/ok/Package.swift" --sources "$work/ok/Sources/Hop" \
  --header "$work/ok/hop.h"

# --- 2. the measured defect: sources newer than the pinned asset ----------------------------------
# Needles avoid digits so a future level bump does not silently stop matching, and so this file never
# states a level other than the current one (tools/codegen/check-abi-version.sh sweeps for both).
write_header "$work/ok/stale.h" 5 no
expect_fail "stale pin (asset one level behind the sources)" "but the pinned asset provides" \
  python3 "$guard" --package "$work/ok/Package.swift" --sources "$work/ok/Sources/Hop" \
  --header "$work/ok/stale.h"

# --- 3. ABI constant in step, but a called function is absent -------------------------------------
# The constant is a coarse signal: a source can add a call without anyone bumping it. This is the
# case that catches the defect the constant would miss.
write_header "$work/ok/nohps.h" 6 no
expect_fail "missing declaration under a matching level" "are not declared in the pinned asset" \
  python3 "$guard" --package "$work/ok/Package.swift" --sources "$work/ok/Sources/Hop" \
  --header "$work/ok/nohps.h"

# --- 4. prose naming a symbol is not a call -------------------------------------------------------
# Guard against the opposite failure: a comment mentioning a removed function must not redden CI.
# The version is substituted rather than written literally, so this fixture is not itself a pinned
# copy of the ABI level.
mkdir -p "$work/comment/Sources/Hop"
printf 'public final class HopNode {\n    public static let expectedABIVersion: UInt32 = %s\n    // Superseded: hop_legacy_send(node) was removed, use hop_open instead.\n    /* hop_other_removed(node) is also gone. */\n    public func open() { hop_open(raw) }\n}\n' \
  6 >"$work/comment/Sources/Hop/Hop.swift"
write_package "$work/comment" "$(printf '%064d' 0)"
expect_pass "commented-out symbols ignored" \
  python3 "$guard" --package "$work/comment/Package.swift" --sources "$work/comment/Sources/Hop" \
  --header "$work/ok/hop.h"

# --- 5. the archive path, and checksum verification ------------------------------------------------
zip_asset "$work/ok/hop.h" "$work/asset.zip"
good_sum="$(sha256 "$work/asset.zip")"
write_package "$work/archive" "$good_sum"
write_sources "$work/archive" 6
expect_pass "asset archive with the pinned checksum" \
  python3 "$guard" --package "$work/archive/Package.swift" --sources "$work/archive/Sources/Hop" \
  --asset "$work/asset.zip"

write_package "$work/badsum" "$(printf 'a%063d' 0)"
write_sources "$work/badsum" 6
expect_fail "asset whose bytes do not match the pinned checksum" "checksum mismatch" \
  python3 "$guard" --package "$work/badsum/Package.swift" --sources "$work/badsum/Sources/Hop" \
  --asset "$work/asset.zip"

# A stale asset inside a well-formed archive still fails, so the zip path is not a way around case 2.
zip_asset "$work/ok/stale.h" "$work/stale-asset.zip"
write_package "$work/stalezip" "$(sha256 "$work/stale-asset.zip")"
write_sources "$work/stalezip" 6
expect_fail "stale header inside a checksum-clean archive" "but the pinned asset provides" \
  python3 "$guard" --package "$work/stalezip/Package.swift" --sources "$work/stalezip/Sources/Hop" \
  --asset "$work/stale-asset.zip"

# --- 6. every parse failure is an error, never a pass ---------------------------------------------
# A guard that cannot find what it compares must go red. Each of these once would have been a
# silently green "nothing to check" run.
printf 'let package = Package(name: "Hop")\n' >"$work/ok/NoPin.swift"
expect_fail "manifest with no binaryTarget" "no CHop binaryTarget" \
  python3 "$guard" --package "$work/ok/NoPin.swift" --sources "$work/ok/Sources/Hop" \
  --header "$work/ok/hop.h"

mkdir -p "$work/noabi/Sources/Hop"
printf 'public final class HopNode { public func open() { hop_open(raw) } }\n' \
  >"$work/noabi/Sources/Hop/Hop.swift"
write_package "$work/noabi" "$(printf '%064d' 0)"
expect_fail "sources with no expectedABIVersion" "no expectedABIVersion" \
  python3 "$guard" --package "$work/noabi/Package.swift" --sources "$work/noabi/Sources/Hop" \
  --header "$work/ok/hop.h"

mkdir -p "$work/nocalls/Sources/Hop"
printf 'public final class HopNode { public static let expectedABIVersion: UInt32 = %s }\n' \
  6 >"$work/nocalls/Sources/Hop/Hop.swift"
write_package "$work/nocalls" "$(printf '%064d' 0)"
expect_fail "sources with no hop_* calls at all" "no hop_\* C calls" \
  python3 "$guard" --package "$work/nocalls/Package.swift" --sources "$work/nocalls/Sources/Hop" \
  --header "$work/ok/hop.h"

printf 'bool hop_open(struct HopNode *node);\n' >"$work/noabi.h"
expect_fail "header with no HOP_ABI_VERSION" "no HOP_ABI_VERSION" \
  python3 "$guard" --package "$work/ok/Package.swift" --sources "$work/ok/Sources/Hop" \
  --header "$work/noabi.h"

expect_fail "empty source directory" "no Swift sources found" \
  python3 "$guard" --package "$work/ok/Package.swift" --sources "$work/empty-dir" \
  --header "$work/ok/hop.h"

# A well-formed archive whose checksum matches but which carries no header at all: the guard must say
# so rather than treat "nothing to read" as nothing to report.
mkdir -p "$work/emptyfx/libhop.xcframework/ios-arm64"
printf 'not a header\n' >"$work/emptyfx/libhop.xcframework/ios-arm64/libhop.a"
(cd "$work/emptyfx" && zip -q -r "$work/headerless.zip" libhop.xcframework)
write_package "$work/headerless" "$(sha256 "$work/headerless.zip")"
write_sources "$work/headerless" 6
expect_fail "archive with no bundled header" "no Headers/hop.h" \
  python3 "$guard" --package "$work/headerless/Package.swift" \
  --sources "$work/headerless/Sources/Hop" --asset "$work/headerless.zip"

echo "apple pin guard tests passed"
