#!/usr/bin/env bash
# repo-integrity-guard.sh (legal-01): fail the build if a critical tracked file is empty or
# missing. A prior remediation shipped a 0-byte LICENSE.md TWICE (restored in one PR, silently
# re-emptied by the next squash-merge of an out-of-date branch) and all CI jobs stayed green,
# because none of them asserted that a tracked content file actually has content. This guard
# closes that gap: it walks a small allowlist of files that must never be empty and fails loudly
# if any is missing or zero-length. Runs in CI (docs-tokens job) and is runnable locally.
#
# Usage:  tools/repo-integrity-guard.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Tracked files that must always carry content (paths relative to repo root). There is no repo-wide
# root license: this is a monorepo, and each component carries its OWN FSL-1.1-ALv2 LICENSE.md (the
# per-component licenses are checked dynamically below). These are the load-bearing docs + the C ABI
# header.
#
# Each entry is "path|min_bytes|marker". `-s` (size > 0) alone is too weak: the regression this guard
# exists for could re-land as a 1-byte or wrong-content file and still pass a bare -s check. So we also
# require a per-file minimum length AND, where there's a stable signature line, that the file still
# contains it (an FSL license truncated to its title, or a header stripped of its ABI define, is just
# as broken as a 0-byte one). Keep floors comfortably below real sizes so honest edits don't trip them.
CRITICAL=(
  "README.md|200|"
  "DESIGN.md|1000|"
  "MECHANISMS.md|1000|"
  "sdk/hop.h|2000|HOP_ABI_VERSION"
)

fail=0

# Per-component FSL licenses (legal-01). Every component's LICENSE.md is the SAME FSL-1.1-ALv2 text; a
# single copy going 0-byte/truncated (the wasm-pack self-copy regression this guard exists for) or one
# drifting away from the rest is the failure mode. Find every first-party LICENSE.md (git-free, so the
# self-test can run in a throwaway tree; excludes vendored deps + build output), require each is above
# the floor and carries the FSL signature line, and require they are all byte-identical.
lic_canon=""
lic_count=0
while IFS= read -r lf; do
  lic_count=$((lic_count + 1))
  bytes="$(wc -c < "$lf" | tr -d ' ')"
  if [ "$bytes" -lt 1500 ]; then
    echo "repo-integrity-guard: TRUNCATED $lf ($bytes bytes < 1500 floor) - a gutted license" >&2
    fail=1
    continue
  fi
  if ! grep -qF -- "Functional Source License" "$lf"; then
    echo "repo-integrity-guard: CONTENT $lf lost its FSL signature line" >&2
    fail=1
    continue
  fi
  if [ -z "$lic_canon" ]; then
    lic_canon="$lf"
  elif ! cmp -s "$lf" "$lic_canon"; then
    echo "repo-integrity-guard: DRIFT $lf differs from $lic_canon (per-component licenses must be identical)" >&2
    fail=1
  fi
done < <(find . -name LICENSE.md \
  -not -path '*/node_modules/*' -not -path '*/target/*' -not -path '*/.git/*' \
  -not -path '*/.claude/*' -not -path '*/.build*' -not -path '*/vendor/*' 2>/dev/null | sort)
if [ "$lic_count" -eq 0 ]; then
  echo "repo-integrity-guard: MISSING no component LICENSE.md found at all" >&2
  fail=1
fi
for spec in "${CRITICAL[@]}"; do
  f="${spec%%|*}"
  rest="${spec#*|}"
  min="${rest%%|*}"
  marker="${rest#*|}"
  if [ ! -f "$f" ]; then
    echo "repo-integrity-guard: MISSING $f" >&2
    fail=1
    continue
  fi
  if [ ! -s "$f" ]; then
    echo "repo-integrity-guard: EMPTY $f (0 bytes) - a critical tracked file lost its content" >&2
    fail=1
    continue
  fi
  bytes="$(wc -c < "$f" | tr -d ' ')"
  if [ "$bytes" -lt "$min" ]; then
    echo "repo-integrity-guard: TRUNCATED $f ($bytes bytes < $min floor) - looks gutted, not edited" >&2
    fail=1
    continue
  fi
  if [ -n "$marker" ] && ! grep -qF -- "$marker" "$f"; then
    echo "repo-integrity-guard: CONTENT $f lost its signature line ('$marker' not found)" >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "repo-integrity-guard: FAIL (a critical tracked file is missing, empty, truncated, or drifted)" >&2
  exit 1
fi
echo "repo-integrity-guard: OK (${#CRITICAL[@]} critical docs + $lic_count component LICENSE.md present, above floor, signatures intact, identical)"
