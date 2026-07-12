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

# Tracked files that must always carry content (paths relative to repo root). LICENSE.md is the repo
# license; most crates inherit [workspace.package] license-file = "LICENSE.md" (cargo reports it as
# ../../LICENSE.md against the crate dir), so the single root file is what ships in every published
# crate. The ONE exception is core/hop-wasm, which pins its OWN crate-local LICENSE.md (identical
# content) precisely so wasm-pack's license copy can't resolve the inherited ../../ path back onto the
# root LICENSE.md and truncate it (the 0-byte-LICENSE regression this guard exists for); that copy is
# what wasm-pack ships into the committed sim/pkg, so guard it too. The rest are load-bearing docs /
# the C ABI header.
#
# Each entry is "path|min_bytes|marker". `-s` (size > 0) alone is too weak: the regression this guard
# exists for could re-land as a 1-byte or wrong-content file and still pass a bare -s check. So we also
# require a per-file minimum length AND, where there's a stable signature line, that the file still
# contains it (an FSL license truncated to its title, or a header stripped of its ABI define, is just
# as broken as a 0-byte one). Keep floors comfortably below real sizes so honest edits don't trip them.
CRITICAL=(
  "LICENSE.md|1500|Functional Source License"
  "core/hop-wasm/LICENSE.md|1500|Functional Source License"
  "README.md|200|"
  "DESIGN.md|1000|"
  "MECHANISMS.md|1000|"
  "sdk/hop.h|2000|HOP_ABI_VERSION"
)

fail=0
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

# The two LICENSE files exist as separate copies ONLY to dodge wasm-pack's truncation; they must stay
# byte-identical. If they diverge, one of them is wrong (and the regression may be mid-flight).
if [ -f LICENSE.md ] && [ -f core/hop-wasm/LICENSE.md ] && ! cmp -s LICENSE.md core/hop-wasm/LICENSE.md; then
  echo "repo-integrity-guard: DRIFT LICENSE.md and core/hop-wasm/LICENSE.md differ (must be identical)" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "repo-integrity-guard: FAIL (a critical tracked file is missing, empty, truncated, or drifted)" >&2
  exit 1
fi
echo "repo-integrity-guard: OK (${#CRITICAL[@]} critical files present, above floor, signatures intact)"
