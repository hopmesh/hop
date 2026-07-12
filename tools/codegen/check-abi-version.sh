#!/usr/bin/env bash
# core-ffi-08: guardrail that HOP_ABI_VERSION is identical across every place it is declared.
#
# A wrapper asserts `hop_abi_version() == HOP_ABI_VERSION` at load so a wrapper built against a newer
# header fails loudly instead of drifting silently (F-28). That safety net only works if the constant
# the wrapper compiles in actually matches the one the Rust library returns. If someone bumps the ABI
# in cabi.rs but forgets the Swift or Kotlin wrapper (or vice versa), the assertion checks the wrong
# number and the mismatch it was meant to catch slips through.
#
# This script greps the constant out of all five authoritative locations and fails (non-zero) if they
# disagree:
#   - core/hop/src/cabi.rs                                  (the source of truth: the Rust const)
#   - core/hop/include/hop.h                                (the hand-written header)
#   - sdk/hop.h                                             (the cbindgen-published header)
#   - sdk/wrappers/apple/Sources/Hop/Hop.swift               (the Swift wrapper's compiled-in expectation)
#   - sdk/wrappers/android/src/main/kotlin/sh/hop/Hop.kt    (the Kotlin wrapper's compiled-in expectation)
#
# The two headers under sdk/wrappers/apple/Frameworks/** are gitignored build artifacts (copied from
# core/hop/include/hop.h at xcframework-build time), so they are not authoritative and not checked here.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

fail=0
declare -a NAMES VALUES

# Extract the first run of digits following the given regex in a file. Emits empty if no match, which
# is itself a failure (the constant moved or got renamed and this guard would otherwise pass blindly).
extract() {
  local label="$1" file="$2" regex="$3"
  if [ ! -f "$file" ]; then
    echo "::error:: ABI guard: expected file not found: $file"
    fail=1
    return
  fi
  # Match the whole declaration, then take the LAST run of digits (the value after `=`), so a type
  # suffix like `u32` / `UInt32` in the matched text is never mistaken for the version.
  local v
  v="$(grep -Eo "$regex" "$file" | head -n1 | grep -Eo '[0-9]+' | tail -n1 || true)"
  if [ -z "$v" ]; then
    echo "::error:: ABI guard: could not find HOP_ABI_VERSION in $label ($file); the constant was renamed or removed"
    fail=1
    return
  fi
  NAMES+=("$label")
  VALUES+=("$v")
  printf '  %-22s %s = %s\n' "$label" "$file" "$v"
}

echo "Cross-checking HOP_ABI_VERSION across the Rust core and the language wrappers:"
extract "rust-cabi"    "$ROOT/core/hop/src/cabi.rs"                              'HOP_ABI_VERSION: *u32 *= *[0-9]+'
extract "header-src"   "$ROOT/core/hop/include/hop.h"                            '#define +HOP_ABI_VERSION +[0-9]+'
extract "header-sdk"   "$ROOT/sdk/hop.h"                                         '#define +HOP_ABI_VERSION +[0-9]+'
extract "swift"        "$ROOT/sdk/wrappers/apple/Sources/Hop/Hop.swift"           'expectedABIVersion: *UInt32 *= *[0-9]+'
extract "kotlin"       "$ROOT/sdk/wrappers/android/src/main/kotlin/sh/hop/Hop.kt" 'HOP_ABI_VERSION *= *[0-9]+'

if [ "$fail" -ne 0 ]; then
  echo "::error:: HOP_ABI_VERSION guard failed: one or more declarations are missing (see above)."
  exit 1
fi

# All present: assert they agree.
ref="${VALUES[0]}"
for i in "${!VALUES[@]}"; do
  if [ "${VALUES[$i]}" != "$ref" ]; then
    echo "::error:: HOP_ABI_VERSION mismatch: ${NAMES[$i]} declares ${VALUES[$i]} but ${NAMES[0]} declares $ref."
    echo "::error:: Bump every location together (cabi.rs, both hop.h, Hop.swift, Hop.kt) in the same change."
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "HOP_ABI_VERSION is consistent ($ref) across all ${#VALUES[@]} declarations."
