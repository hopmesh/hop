#!/usr/bin/env bash
# Fail when the DOCUMENTED mailbox routing-prefix width disagrees with the shipped constant.
#
# WHY THIS EXISTS (audit PROTO-004 / CLAIM-004, closure item 3). `crypto::MAILBOX_ROUTE_PREFIX_BYTES`
# is the single dial controlling the §39 recipient anonymity set. It narrowed 2 to 1 in wire v12, and
# the rustdoc sitting directly above it went on saying "Two bytes (16 bits) is the deliberate balance"
# and sizing the small-N threshold at ~2^16 for THREE consecutive wire versions (v12, v13, v14). It
# survived that long because `core/hop-core/src/crypto.rs` is listed in
# `core/hop-core/vectors/wire-source-manifest.txt`, so `tools/wire-version-guard.sh` hashes it whole and
# a comment edit costs a BUNDLE_VERSION bump plus a regenerated corpus plus a sim/pkg rebuild. Each bump
# deferred the edit to "the next real wire bump", which is the same prose-named trigger PROC-001
# indicted: a deferral nothing mechanical fires.
#
# The numbers were wrong in the CONSERVATIVE direction, which is why nobody noticed: they understated
# the delivered anonymity set (256 buckets, not 65_536) and overstated the do-not-trust-it threshold
# (~256 reachable addresses, not ~65k). An operator sizing a fleet against the documented figure was
# wrong by two orders of magnitude in both directions depending on which number it used for which
# purpose. Nothing in CI compared a documented constant against its symbol, and
# `core/hop-core/src/wire_vectors.rs` deliberately DERIVES its vector from the constant so it cannot
# pin the width either.
#
# WHAT IT CHECKS
#   1. Exactly one `pub const MAILBOX_ROUTE_PREFIX_BYTES: usize = <w>;` exists, and w is in 1..4.
#   2. A CANONICAL claim line, rendered here FROM w, appears verbatim in every normative surface that
#      is required to state it. Change w without rewriting those surfaces and this fails, because the
#      rendered line no longer matches what is committed.
#   3. No scanned file contains the canonical line rendered for a DIFFERENT w (a stale copy left
#      behind next to a corrected one, which is how the contradiction inside DESIGN.md §39 arose).
#   4. No line that talks about the mailbox routing prefix carries a width figure for a different w,
#      unless that line SCOPES itself. Three scopes are legitimate and are skipped:
#        * `w=<n>`  a named counterfactual, e.g. the w=1 vs w=2 table under the constant
#        * `v<n>`   a wire-version history entry, e.g. the `v3` line in bundle.rs's changelog, which
#                   says 2 bytes and is CORRECT as history (it really was 2 bytes at v3) and must
#                   never be renumbered
#        * `slot`   the C ABI's FIXED 2-byte metadata slot carrying a variable-width prefix, which is
#                   a genuine 2 whatever w is (sdk/hop.h, core/hop/src/cabi.rs)
#
# Usage: tools/mailbox-prefix-doc-guard.sh [ROOT]
# ROOT is injectable so the self-test can run it against a fixture tree.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
CONST_FILE="core/hop-core/src/crypto.rs"

fail=0
err() {
  echo "::error::mailbox prefix doc guard: $*" >&2
  fail=1
}

cd "$ROOT" || {
  echo "::error::mailbox prefix doc guard: no such root: $ROOT" >&2
  exit 1
}

if [ ! -f "$CONST_FILE" ]; then
  echo "::error::mailbox prefix doc guard: missing $CONST_FILE" >&2
  exit 1
fi

# ---- 1. the shipped width -----------------------------------------------------------------------
decls="$(grep -cE '^pub const MAILBOX_ROUTE_PREFIX_BYTES: usize = [0-9]+;$' "$CONST_FILE" || true)"
if [ "$decls" != "1" ]; then
  echo "::error::mailbox prefix doc guard: expected exactly one MAILBOX_ROUTE_PREFIX_BYTES declaration in $CONST_FILE, found $decls" >&2
  exit 1
fi
WIDTH="$(grep -E '^pub const MAILBOX_ROUTE_PREFIX_BYTES: usize = [0-9]+;$' "$CONST_FILE" | grep -oE '[0-9]+' | tail -n 1)"
case "$WIDTH" in
  1 | 2 | 3 | 4) ;;
  *)
    echo "::error::mailbox prefix doc guard: MAILBOX_ROUTE_PREFIX_BYTES = $WIDTH is outside the 1..4 range this guard renders claims for; widen the guard deliberately" >&2
    exit 1
    ;;
esac

# 256^w, computed rather than tabulated so widening the range above needs no second edit.
buckets_for() {
  local w="$1" b=1 i
  for ((i = 0; i < w; i++)); do b=$((b * 256)); done
  printf '%s\n' "$b"
}
BUCKETS="$(buckets_for "$WIDTH")"

# The one sentence every normative surface must state, derived from the constant.
canonical_for() {
  local w="$1" b
  b="$(buckets_for "$w")"
  printf 'MAILBOX_ROUTE_PREFIX_BYTES = %s => %s buckets, anonymity set ~N/%s, set of one below ~%s reachable addresses\n' \
    "$w" "$b" "$b" "$b"
}
CANONICAL="$(canonical_for "$WIDTH")"

# ---- the surfaces -------------------------------------------------------------------------------
# Files that MUST carry the canonical claim: the constant's own doc block, and the normative design
# section auditors and operators size the anonymity claim from.
REQUIRED=(
  "core/hop-core/src/crypto.rs"
  "DESIGN.md"
)
# Files whose mailbox-prefix lines are checked for a wrong-width figure. Every place a width claim has
# ever drifted, plus the published ABI surfaces, so a version of this guard that skipped the one file
# the drift actually lived in is not possible.
SCANNED=(
  "core/hop-core/src/crypto.rs"
  "core/hop-core/src/bundle.rs"
  "core/hop-core/src/node.rs"
  "core/hop-core/src/wire_emit.rs"
  "core/hop-core/src/wire_vectors.rs"
  "core/hop/src/cabi.rs"
  "services/hop-relayd/src/main.rs"
  "sdk/hop.h"
  "DESIGN.md"
  "MECHANISMS.md"
  "SECURITY.md"
)

for path in "${REQUIRED[@]}" "${SCANNED[@]}"; do
  [ -f "$path" ] || err "declared surface is missing: $path"
done
[ "$fail" -eq 0 ] || exit 1

# ---- 2. the canonical claim is present, once, in every required surface -------------------------
for path in "${REQUIRED[@]}"; do
  hits="$(grep -Fc -- "$CANONICAL" "$path" || true)"
  if [ "$hits" = "0" ]; then
    err "$path does not state the canonical claim for the SHIPPED width. Add this line verbatim:"
    printf '  %s\n' "$CANONICAL" >&2
    printf '  (MAILBOX_ROUTE_PREFIX_BYTES is %s in %s)\n' "$WIDTH" "$CONST_FILE" >&2
  elif [ "$hits" != "1" ]; then
    err "$path states the canonical claim $hits times; one place per surface, or the next edit corrects only one of them"
  fi
done

# ---- 3. no canonical claim rendered for a different width ---------------------------------------
for w in 1 2 3 4; do
  [ "$w" = "$WIDTH" ] && continue
  other="$(canonical_for "$w")"
  for path in "${SCANNED[@]}"; do
    if grep -Fq -- "$other" "$path"; then
      err "$path states the canonical claim for width $w while the shipped width is $WIDTH:"
      printf '  %s\n' "$other" >&2
    fi
  done
done

# ---- 4. no stale width figure on a mailbox-prefix line ------------------------------------------
# A line is IN SCOPE when it talks about the mailbox routing prefix at all.
IN_SCOPE='mailbox|MAILBOX_ROUTE_PREFIX_BYTES|route prefix|routing prefix|prefix bucket|route bucket'
# ... and EXEMPT when it names the width it is talking about (a counterfactual, a version history
# entry, or the fixed ABI slot). Case-insensitive so "Slot" and "V12" also scope.
#
# The version form is DELIBERATELY narrow. A bare `\bv[0-9]+\b` would have exempted any line that
# happens to carry a version-shaped token for an unrelated reason, and one of the very lines this guard
# has to police is `mailbox_tag`'s, which contains the domain separator `H("v2" ...)`. That is a KDF
# label, not a claim about when the prefix was 2 bytes, and it must not buy the line an exemption.
# So the version has to appear as a phrase that scopes a claim in time: "wire v12", "pre-v12",
# "since v13", "as of v3", "in v12", or a "v13 -> v14" changelog arrow.
SELF_SCOPED='w=[0-9]|w = [0-9]|(wire |pre-|since |as of |in )v[0-9]+|v[0-9]+ ->|slot'

# Width figures, per candidate width. Byte counts use "<n>-byte"; bit counts use "<n> bits"/"<n>-bit"
# so a "16-byte mailbox tag" (a real, width-independent figure) is never mistaken for a 16-BIT claim.
figures_for() {
  local w="$1" bits=$((w * 8)) b
  b="$(buckets_for "$w")"
  printf '%s-byte\n' "$w"
  printf '%s bits\n' "$bits"
  printf '%s-bit\n' "$bits"
  printf '2^%s\n' "$bits"
  printf '%s\n' "$b"
  # The underscored Rust literal form, e.g. 65_536. Only meaningful above 999. Grouped here rather
  # than with a sed label loop, which is not portable between GNU and BSD sed and silently produced
  # an "unused label" error on macOS instead of a figure.
  if [ "$b" -gt 999 ]; then
    local out="" i len=${#b}
    for ((i = 0; i < len; i++)); do
      if [ "$i" -gt 0 ] && [ $(((len - i) % 3)) -eq 0 ]; then out="${out}_"; fi
      out="${out}${b:i:1}"
    done
    printf '%s\n' "$out"
  fi
}

# The figures that belong to the shipped width are allowed everywhere; everything else on an in-scope,
# unscoped line is a stale claim.
allowed="$(figures_for "$WIDTH")"
forbidden=()
for w in 1 2 3 4; do
  [ "$w" = "$WIDTH" ] && continue
  while IFS= read -r figure; do
    [ -n "$figure" ] || continue
    printf '%s\n' "$allowed" | grep -Fxq -- "$figure" && continue
    forbidden+=("$figure")
  done <<EOF
$(figures_for "$w")
EOF
done

for path in "${SCANNED[@]}"; do
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    number="${hit%%:*}"
    text="${hit#*:}"
    printf '%s' "$text" | grep -Eqi -- "$SELF_SCOPED" && continue
    for figure in "${forbidden[@]}"; do
      if printf '%s' "$text" | grep -Fq -- "$figure"; then
        err "$path:$number states a mailbox-prefix width figure '$figure' while MAILBOX_ROUTE_PREFIX_BYTES is $WIDTH ($BUCKETS buckets). Correct it, or scope the line (w=<n> for a counterfactual, v<n> for a version-history entry, 'slot' for the fixed ABI slot):"
        printf '  %s\n' "$text" >&2
        break
      fi
    done
  done <<EOF
$(grep -nEi -- "$IN_SCOPE" "$path" || true)
EOF
done

if [ "$fail" -ne 0 ]; then
  echo "::error::mailbox prefix doc guard FAILED (shipped width $WIDTH, $BUCKETS buckets)" >&2
  exit 1
fi
echo "mailbox prefix doc guard passed: MAILBOX_ROUTE_PREFIX_BYTES = $WIDTH, $BUCKETS buckets, ${#SCANNED[@]} surfaces scanned, ${#REQUIRED[@]} carrying the canonical claim"
