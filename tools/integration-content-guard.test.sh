#!/usr/bin/env bash
# tools/integration-content-guard.test.sh
# Self-test for integration-content-guard.sh.
#
# Validates:
#   1. Historical reconstruction: catches dropped commit f6cfd1fa from fix/r3-legal
#      against audit/r3-integration.
#   2. Historical reconstruction: accepts fully integrated lanes (fix/r3-bearers, fix/r3-docs).
#   3. Synthetic fixture: accepts standard git merge commits.
#   4. Synthetic fixture: accepts cherry-picked commits (different SHA, identical content).
#   5. Synthetic fixture: accepts squash-merged commits (content present, different SHA).
#   6. Synthetic fixture: catches dropped/superseded commits on a lane branch.
#   7. Synthetic fixture: rejects lanes with merge conflicts.
#   8. Usage: rejects invalid or missing git refs.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GUARD="$HERE/integration-content-guard.sh"

pass=0
fail=0

record_pass() {
  pass=$((pass + 1))
  echo "  OK: $1"
}

record_fail() {
  fail=$((fail + 1))
  echo "  FAIL: $1" >&2
}

echo "=== Running integration-content-guard self-tests ==="

# 1. Historical reconstruction: fix/r3-legal dropped commit f6cfd1fa
echo "Test 1: Historical reconstruction: catches dropped commit f6cfd1fa on fix/r3-legal"
if git -C "$ROOT" cat-file -e "audit/r3-integration^{commit}" 2>/dev/null && \
   git -C "$ROOT" cat-file -e "fix/r3-legal^{commit}" 2>/dev/null; then
  output=$(bash "$GUARD" audit/r3-integration fix/r3-legal 2>&1 || true)
  if printf '%s\n' "$output" | grep -q "f6cfd1fa"; then
    record_pass "correctly caught dropped commit f6cfd1fa"
  else
    record_fail "failed to report f6cfd1fa in unmerged commits: $output"
  fi
else
  echo "  SKIP: historical refs audit/r3-integration or fix/r3-legal not found"
fi

# 2. Historical reconstruction: accepts fully integrated lanes
echo "Test 2: Historical reconstruction: accepts fully integrated lane fix/r3-bearers"
if git -C "$ROOT" cat-file -e "audit/r3-integration^{commit}" 2>/dev/null && \
   git -C "$ROOT" cat-file -e "fix/r3-bearers^{commit}" 2>/dev/null; then
  if bash "$GUARD" audit/r3-integration fix/r3-bearers >/dev/null 2>&1; then
    record_pass "correctly accepted fully integrated lane fix/r3-bearers"
  else
    record_fail "unexpectedly rejected fully integrated lane fix/r3-bearers"
  fi
else
  echo "  SKIP: historical refs audit/r3-integration or fix/r3-bearers not found"
fi

# Set up isolated fixture repository for synthetic tests
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FIXTURE="$TMP/repo"
mkdir -p "$FIXTURE"
git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.name "Test Runner"
git -C "$FIXTURE" config user.email "test@hopmesh.internal"
git -C "$FIXTURE" config commit.gpgsign false

echo "initial base" > "$FIXTURE/base.txt"
git -C "$FIXTURE" add base.txt
git -C "$FIXTURE" commit -q -m "chore: base commit"

# 3. Synthetic fixture: standard merge
echo "Test 3: Synthetic fixture: accepts standard git merge"
git -C "$FIXTURE" checkout -q -b lane-merge main
echo "lane merge content" > "$FIXTURE/feature-a.txt"
git -C "$FIXTURE" add feature-a.txt
git -C "$FIXTURE" commit -q -m "feat: lane feature a"

git -C "$FIXTURE" checkout -q -b integration-merge main
git -C "$FIXTURE" merge -q --no-ff lane-merge -m "merge: integrate lane-merge"

if (cd "$FIXTURE" && bash "$GUARD" integration-merge lane-merge) >/dev/null 2>&1; then
  record_pass "standard git merge correctly accepted"
else
  record_fail "standard git merge unexpectedly rejected"
fi

# 4. Synthetic fixture: cherry-picked commit (different SHA, identical content)
echo "Test 4: Synthetic fixture: accepts cherry-picked commit (content-based proof)"
git -C "$FIXTURE" checkout -q -b lane-cherry main
echo "cherry content" > "$FIXTURE/feature-b.txt"
git -C "$FIXTURE" add feature-b.txt
git -C "$FIXTURE" commit -q -m "feat: lane feature b"
git -C "$FIXTURE" checkout -q -b integration-cherry main
git -C "$FIXTURE" cherry-pick -x lane-cherry >/dev/null 2>&1

# Verify SHAs are indeed different
LANE_SHA=$(git -C "$FIXTURE" rev-parse lane-cherry)
INT_SHA=$(git -C "$FIXTURE" rev-parse integration-cherry)
if [ "$LANE_SHA" = "$INT_SHA" ]; then
  record_fail "test setup error: SHAs should differ"
fi

if (cd "$FIXTURE" && bash "$GUARD" integration-cherry lane-cherry) >/dev/null 2>&1; then
  record_pass "cherry-picked commit correctly accepted (content matches)"
else
  record_fail "cherry-picked commit unexpectedly rejected"
fi

# 5. Synthetic fixture: squash-merged commit
echo "Test 5: Synthetic fixture: accepts squash-merged commit"
git -C "$FIXTURE" checkout -q -b lane-squash main
echo "squash 1" > "$FIXTURE/squash-1.txt"
git -C "$FIXTURE" add squash-1.txt
git -C "$FIXTURE" commit -q -m "feat: squash part 1"
echo "squash 2" > "$FIXTURE/squash-2.txt"
git -C "$FIXTURE" add squash-2.txt
git -C "$FIXTURE" commit -q -m "feat: squash part 2"

git -C "$FIXTURE" checkout -q -b integration-squash main
git -C "$FIXTURE" merge -q --squash lane-squash
git -C "$FIXTURE" commit -q -m "feat: integrate lane-squash (squashed)"

if (cd "$FIXTURE" && bash "$GUARD" integration-squash lane-squash) >/dev/null 2>&1; then
  record_pass "squash-merged commit correctly accepted"
else
  record_fail "squash-merged commit unexpectedly rejected"
fi

# 6. Synthetic fixture: dropped/superseded commit on lane branch
echo "Test 6: Synthetic fixture: catches dropped commit on lane branch"
git -C "$FIXTURE" checkout -q -b lane-dropped main
echo "commit 1" > "$FIXTURE/kept.txt"
git -C "$FIXTURE" add kept.txt
git -C "$FIXTURE" commit -q -m "feat: kept commit"
echo "commit 2" > "$FIXTURE/dropped.txt"
git -C "$FIXTURE" add dropped.txt
git -C "$FIXTURE" commit -q -m "feat: dropped commit"

# Integration takes only commit 1, drops commit 2
git -C "$FIXTURE" checkout -q -b integration-dropped main
git -C "$FIXTURE" cherry-pick lane-dropped~1 >/dev/null 2>&1

output=$( (cd "$FIXTURE" && bash "$GUARD" integration-dropped lane-dropped 2>&1) || true )
if printf '%s\n' "$output" | grep -q "dropped commit"; then
  record_pass "correctly caught dropped commit on lane-dropped"
else
  record_fail "failed to detect dropped commit on lane-dropped: $output"
fi

# 7. Synthetic fixture: conflicting lane branch
echo "Test 7: Synthetic fixture: catches conflicting lane branch"
git -C "$FIXTURE" checkout -q -b lane-conflict main
echo "lane conflict edit" > "$FIXTURE/base.txt"
git -C "$FIXTURE" add base.txt
git -C "$FIXTURE" commit -q -m "feat: lane edit base.txt"

git -C "$FIXTURE" checkout -q -b integration-conflict main
echo "integration conflicting edit" > "$FIXTURE/base.txt"
git -C "$FIXTURE" add base.txt
git -C "$FIXTURE" commit -q -m "feat: integration edit base.txt"

if (cd "$FIXTURE" && bash "$GUARD" integration-conflict lane-conflict) >/dev/null 2>&1; then
  record_fail "conflicting lane unexpectedly passed"
else
  record_pass "conflicting lane correctly rejected"
fi

# 8. Usage: invalid or missing git ref
echo "Test 8: Usage: rejects invalid git ref with code 2"
status=0
bash "$GUARD" "nonexistent-integration-ref" "main" >/dev/null 2>&1 || status=$?
if [ "$status" -eq 2 ]; then
  record_pass "invalid integration ref exits with code 2"
else
  record_fail "invalid integration ref returned code $status (expected 2)"
fi

echo ""
echo "=== Self-test results: $pass passed, $fail failed ==="
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
