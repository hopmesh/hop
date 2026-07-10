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
# license; `cargo metadata` confirms every crate's license-file inherits [workspace.package]
# license-file = "LICENSE.md" resolved against the WORKSPACE ROOT (all crates point at ../../LICENSE.md
# or ../../../LICENSE.md), so the single root file is what ships in every published crate. The rest are
# load-bearing docs / the C ABI header.
CRITICAL=(
  "LICENSE.md"
  "README.md"
  "DESIGN.md"
  "MECHANISMS.md"
  "sdk/hop.h"
)

fail=0
for f in "${CRITICAL[@]}"; do
  if [ ! -f "$f" ]; then
    echo "repo-integrity-guard: MISSING $f" >&2
    fail=1
    continue
  fi
  if [ ! -s "$f" ]; then
    echo "repo-integrity-guard: EMPTY $f (0 bytes) - a critical tracked file lost its content" >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "repo-integrity-guard: FAIL (a critical tracked file is missing or empty)" >&2
  exit 1
fi
echo "repo-integrity-guard: OK (${#CRITICAL[@]} critical files present and non-empty)"
