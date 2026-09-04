#!/usr/bin/env bash
# Self-test for tools/gen-third-party-notices.py.
#
# The CI gate for attribution is `--check`, and a check that cannot fail is worse than no check: it
# reports compliance while the notice silently drifts from what the binary actually links. So the
# thing this test pins is that --check FAILS on each way the committed notice can go stale, and that
# it does so via the EXIT CODE, which is the only part CI reads.
#
# What --check deliberately does NOT compare is the rendered file. Licence bodies are read from the
# local cargo registry, which only holds a crate's unpacked source once something has built it, so a
# workstation and a CI runner legitimately disagree about which bodies are present. Comparing whole
# files made the check host-dependent. The crate SET comes from the lockfile and is the same
# everywhere, so that is what is gated, and case (e) below pins that distinction on purpose: an edit
# that does not change the shipped crate set is NOT staleness and must stay green, or the gate would
# redden on unrelated prose edits and get disabled.
#
# Cases: (a) a freshly generated notice passes, (b) a crate dropped from the notice fails, (c) a
# crate in the notice that is no longer shipped fails, (d) a missing notice file fails, (e) prose
# appended without changing the crate set still passes. Uses a temp --out throughout, so the
# committed THIRD-PARTY-NOTICES.md is never touched.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GEN="$HERE/gen-third-party-notices.py"
cd "$ROOT" || exit 1
pass=0
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/NOTICES.md"

check() { python3 "$GEN" --root hop --out "$OUT" --check >/dev/null 2>&1; echo "$?"; }

expect() { # WANT LABEL
  local want="$1" label="$2" got
  got="$(check)"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); echo "ok   [$label]: exit $got as expected"
  else
    fail=$((fail + 1)); echo "FAIL [$label]: expected exit $want, got $got"
    python3 "$GEN" --root hop --out "$OUT" --check 2>&1 | sed 's/^/    /' | head -4
  fi
}

# (a) generate, then the check must agree with what it just wrote
python3 "$GEN" --root hop --out "$OUT" >/dev/null 2>&1 || {
  echo "FAIL: generator could not run (is cargo available?)"; exit 1; }
cp "$OUT" "$TMP/good.md"
expect 0 "freshly_generated_is_current"

# (b) a shipped crate dropped from the notice: the compliance-critical direction
victim="$(grep -m1 -E '^### ' "$TMP/good.md")"
[ -n "$victim" ] || { echo "FAIL: no '### name version' headings to work with"; exit 1; }
grep -v -F -- "$victim" "$TMP/good.md" > "$OUT"
expect 1 "crate_missing_from_notice"

# (c) a crate listed that is no longer shipped (over-attribution is drift too)
cp "$TMP/good.md" "$OUT"; printf '\n### ghost-crate 9.9.9\n' >> "$OUT"
expect 1 "crate_listed_but_not_shipped"

# (d) no notice at all
rm -f "$OUT"
expect 1 "notice_file_missing"

# (e) prose edit that does not change the crate set stays green, by design
cp "$TMP/good.md" "$OUT"; printf '\nAn editorial note that ships no crate.\n' >> "$OUT"
expect 0 "prose_edit_is_not_staleness"

# (f) minimal features generate matching subset of crates (ABI-011)
python3 "$GEN" --root hop --no-default-features --features minimal --out "$TMP/minimal.md" >/dev/null 2>&1 || {
  echo "FAIL: minimal feature generation failed"; exit 1; }
min_count="$(grep -c '^### ' "$TMP/minimal.md")"
good_count="$(grep -c '^### ' "$TMP/good.md")"
if [ "$min_count" -gt 0 ] && [ "$min_count" -lt "$good_count" ]; then
  pass=$((pass + 1)); echo "ok   [minimal_feature_subset]: $min_count < $good_count crates as expected"
else
  fail=$((fail + 1)); echo "FAIL [minimal_feature_subset]: expected fewer crates, got $min_count vs $good_count"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "gen-third-party-notices.test: all $pass cases passed"
else
  echo "gen-third-party-notices.test: $fail case(s) FAILED"
  exit 1
fi
