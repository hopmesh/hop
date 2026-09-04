#!/usr/bin/env bash
# tools/commit-message-guard.test.sh
# Self-test for tools/commit-message-guard.sh and tools/commit-message-guard-range.sh.
# Runs against synthetic git repositories and asserts:
#   1. Clean commits pass (exit 0).
#   2. One case per banned dash class fails (exit 1):
#      U+2014, U+2013, U+2015, U+2012, U+2212, and multiple encoded forms.
#   3. A merge commit with a banned dash in its title fails (exit 1).
#   4. A multi-commit range with the offender in the middle fails and names the right SHA.
#   5. A range where the offender is BEFORE the base is NOT flagged (proves history is not scanned).
#   6. Zero-SHA and unreachable base fallbacks to HEAD.
#   7. Bad ranges exit with code 2.
# No network, isolated temp dir.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/commit-message-guard.sh"
RANGE_SCRIPT="$HERE/commit-message-guard-range.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# Hex-constructed banned code points (keeps this test file ASCII-clean)
EMDASH=$(printf '\xe2\x80\x94')   # U+2014 em dash
ENDASH=$(printf '\xe2\x80\x93')   # U+2013 en dash
HBAR=$(printf '\xe2\x80\x95')     # U+2015 horizontal bar
FIGDASH=$(printf '\xe2\x80\x92')  # U+2012 figure dash
MINUS=$(printf '\xe2\x88\x92')    # U+2212 minus sign

ZERO_SHA="0000000000000000000000000000000000000000"
UNREACHABLE_SHA="ffffffffffffffffffffffffffffffffffffffff"

# Helper to create a fresh synthetic git repo
init_test_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git init -q "$dir"
  git -C "$dir" config user.name "Test Committer"
  git -C "$dir" config user.email "test@hopmesh.test"
  git -C "$dir" config commit.gpgsign false
}

# --- Test 1: Clean commit passes (exit 0) ---
REPO_CLEAN="$TMP/repo-clean"
init_test_repo "$REPO_CLEAN"
git -C "$REPO_CLEAN" commit --allow-empty -q -m "feat: clean commit with ascii - hyphen and normal text"
if (cd "$REPO_CLEAN" && bash "$GUARD" HEAD >/dev/null 2>&1); then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: expected clean commit to pass"
fi

# --- Test 2: Banned classes fail (exit 1) and name class ---
test_banned_class() {
  local label="$1"
  local msg="$2"
  local expected_needle="$3"
  local repo_dir="$TMP/repo-$label"

  init_test_repo "$repo_dir"
  git -C "$repo_dir" commit --allow-empty -q -m "$msg"

  local out code=0
  out="$(cd "$repo_dir" && bash "$GUARD" HEAD 2>&1)" || code=$?

  if [ "$code" -ne 1 ]; then
    fail=$((fail + 1))
    echo "FAIL [$label]: expected exit code 1, got $code"
    return
  fi

  if printf '%s' "$out" | grep -F -q "::error::" && printf '%s' "$out" | grep -F -q "$expected_needle"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL [$label]: output missing expected needle '$expected_needle':"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

test_banned_class "emdash" "$(printf 'fix: text %b more text' "$EMDASH")" "em-dash (U+2014)"
test_banned_class "endash" "$(printf 'docs: sections 5 %b 7' "$ENDASH")" "en-dash (U+2013)"
test_banned_class "hbar" "$(printf 'refactor: hop is fast %b untraceable' "$HBAR")" "horizontal bar (U+2015)"
test_banned_class "figdash" "$(printf 'chore: figure 1 %b 2' "$FIGDASH")" "figure dash (U+2012)"
test_banned_class "minus" "$(printf 'perf: latency %b created_at' "$MINUS")" "minus sign (U+2212)"

# Encoded forms (multiple forms tested)
test_banned_class "ent-mdash" 'feat: signal grade &mdash; on by default' "encoded dash"
test_banned_class "ent-ndash" 'docs: see sections 1 &ndash; 3' "encoded dash"
test_banned_class "ent-dec" 'docs: fast &#8212; and quiet' "encoded dash"
test_banned_class "ent-dec-nosemi" 'docs: fast &#8212 and quiet' "encoded dash"
test_banned_class "ent-hex" 'docs: untraceable &#x2014; by default' "encoded dash"
test_banned_class "esc-u" 'fix: payload \u2014 delimiter' "encoded dash"
test_banned_class "esc-ubrace" 'fix: payload \u{2014} delimiter' "encoded dash"
test_banned_class "esc-css" 'style: add \2014 quote' "encoded dash"
test_banned_class "esc-minus" 'perf: delta \u2212 offset' "encoded dash"

# --- Test 3: Merge commit with banned dash in title fails (exit 1) ---
REPO_MERGE="$TMP/repo-merge"
init_test_repo "$REPO_MERGE"
git -C "$REPO_MERGE" commit --allow-empty -q -m "feat: root commit"
git -C "$REPO_MERGE" checkout -q -b feat-branch
git -C "$REPO_MERGE" commit --allow-empty -q -m "feat: branch commit"
git -C "$REPO_MERGE" checkout -q -
merge_title="$(printf 'Merge pull request #42 %b add feature' "$EMDASH")"
git -C "$REPO_MERGE" merge --no-ff -q -m "$merge_title" feat-branch

merge_out=""
merge_code=0
merge_out="$(cd "$REPO_MERGE" && bash "$GUARD" HEAD 2>&1)" || merge_code=$?
if [ "$merge_code" -eq 1 ] && printf '%s' "$merge_out" | grep -F -q "em-dash (U+2014)"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: expected merge commit with em-dash to fail (code: $merge_code)"
  printf '%s\n' "$merge_out" | sed 's/^/    /'
fi

# --- Test 4: Multi-commit range with offender in the middle fails and names SHA ---
REPO_MULTI="$TMP/repo-multi"
init_test_repo "$REPO_MULTI"
git -C "$REPO_MULTI" commit --allow-empty -q -m "feat: commit 1 base"
sha_base="$(git -C "$REPO_MULTI" rev-parse HEAD)"

offender_msg="$(printf 'fix: commit 2 with en dash %b here' "$ENDASH")"
git -C "$REPO_MULTI" commit --allow-empty -q -m "$offender_msg"
sha_offender="$(git -C "$REPO_MULTI" rev-parse HEAD)"

git -C "$REPO_MULTI" commit --allow-empty -q -m "feat: commit 3 clean"
git -C "$REPO_MULTI" commit --allow-empty -q -m "feat: commit 4 clean tip"
sha_tip="$(git -C "$REPO_MULTI" rev-parse HEAD)"

multi_out=""
multi_code=0
multi_out="$(cd "$REPO_MULTI" && bash "$GUARD" "$sha_base..$sha_tip" 2>&1)" || multi_code=$?
if [ "$multi_code" -eq 1 ] && printf '%s' "$multi_out" | grep -F -q "$sha_offender"; then
  # Must name offender SHA and not base or clean commits
  if ! printf '%s' "$multi_out" | grep -F -q "commit $sha_base contains" && \
     ! printf '%s' "$multi_out" | grep -F -q "commit $sha_tip contains"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: multi-commit scan falsely flagged clean commits in range"
  fi
else
  fail=$((fail + 1))
  echo "FAIL: multi-commit scan did not fail or did not name offending SHA $sha_offender"
  printf '%s\n' "$multi_out" | sed 's/^/    /'
fi

# --- Test 5: Offender BEFORE the base is NOT flagged (proves history is not scanned) ---
REPO_HIST="$TMP/repo-history"
init_test_repo "$REPO_HIST"
# Commit 0 in history contains a banned em-dash
hist_offender_msg="$(printf 'chore: old historical commit with %b dash' "$EMDASH")"
git -C "$REPO_HIST" commit --allow-empty -q -m "$hist_offender_msg"
sha_old_offender="$(git -C "$REPO_HIST" rev-parse HEAD)"

# Base commit (clean)
git -C "$REPO_HIST" commit --allow-empty -q -m "feat: clean base commit"
sha_hist_base="$(git -C "$REPO_HIST" rev-parse HEAD)"

# New introduced commits (all clean)
git -C "$REPO_HIST" commit --allow-empty -q -m "feat: new clean commit 1"
git -C "$REPO_HIST" commit --allow-empty -q -m "feat: new clean commit 2"
sha_hist_tip="$(git -C "$REPO_HIST" rev-parse HEAD)"

# Scanning only the introduced range sha_hist_base..sha_hist_tip must PASS (exit 0)
hist_out=""
hist_code=0
hist_out="$(cd "$REPO_HIST" && bash "$GUARD" "$sha_hist_base..$sha_hist_tip" 2>&1)" || hist_code=$?
if [ "$hist_code" -eq 0 ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: scan of introduced range flagged historical commit before base (code: $hist_code)"
  printf '%s\n' "$hist_out" | sed 's/^/    /'
fi

# --- Test 6: Zero-SHA and unreachable base handling in range computation ---
REPO_RANGE="$TMP/repo-range"
init_test_repo "$REPO_RANGE"
git -C "$REPO_RANGE" commit --allow-empty -q -m "feat: initial commit"
real_sha="$(git -C "$REPO_RANGE" rev-parse HEAD)"

assert_range_eq() {
  local label="$1"
  local expected="$2"
  shift 2
  local got
  got="$(cd "$REPO_RANGE" && "$@")"
  if [ "$got" = "$expected" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL [$label]: expected range '$expected', got '$got'"
  fi
}

# 6a. Push with zero-SHA before falls back to HEAD
assert_range_eq "push-zero-sha" "HEAD" \
  env GITHUB_EVENT_NAME=push GITHUB_BEFORE_SHA="$ZERO_SHA" bash "$RANGE_SCRIPT"

# 6b. Push with unreachable before falls back to HEAD
assert_range_eq "push-unreachable-sha" "HEAD" \
  env GITHUB_EVENT_NAME=push GITHUB_BEFORE_SHA="$UNREACHABLE_SHA" bash "$RANGE_SCRIPT"

# 6c. Push with reachable before produces before..HEAD
assert_range_eq "push-reachable-sha" "$real_sha..HEAD" \
  env GITHUB_EVENT_NAME=push GITHUB_BEFORE_SHA="$real_sha" bash "$RANGE_SCRIPT"

# 6d. Pull request with zero-SHA base falls back to HEAD
assert_range_eq "pr-zero-sha" "HEAD" \
  env GITHUB_EVENT_NAME=pull_request GITHUB_BASE_SHA="$ZERO_SHA" bash "$RANGE_SCRIPT"

# 6e. Pull request with unreachable base falls back to HEAD
assert_range_eq "pr-unreachable-base" "HEAD" \
  env GITHUB_EVENT_NAME=pull_request GITHUB_BASE_SHA="$UNREACHABLE_SHA" bash "$RANGE_SCRIPT"

# 6f. Pull request with reachable base produces base..HEAD
assert_range_eq "pr-reachable-base" "$real_sha..HEAD" \
  env GITHUB_EVENT_NAME=pull_request GITHUB_BASE_SHA="$real_sha" bash "$RANGE_SCRIPT"

# 6g. Workflow dispatch produces HEAD
assert_range_eq "workflow-dispatch" "HEAD" \
  env GITHUB_EVENT_NAME=workflow_dispatch bash "$RANGE_SCRIPT"

# 6h. Event payload JSON file parsing
EVENT_JSON="$TMP/event.json"
printf '{"pull_request": {"base": {"sha": "%s"}}}\n' "$real_sha" > "$EVENT_JSON"
assert_range_eq "pr-from-event-json" "$real_sha..HEAD" \
  env GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$EVENT_JSON" bash "$RANGE_SCRIPT"

printf '{"before": "%s"}\n' "$ZERO_SHA" > "$EVENT_JSON"
assert_range_eq "push-zero-from-event-json" "HEAD" \
  env GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH="$EVENT_JSON" bash "$RANGE_SCRIPT"

# 6i. commit-message-guard.sh --github-event integration with fallback
if (cd "$REPO_RANGE" && GITHUB_EVENT_NAME=push GITHUB_BEFORE_SHA="$ZERO_SHA" bash "$GUARD" --github-event >/dev/null 2>&1); then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: commit-message-guard --github-event failed on clean commit with zero-SHA fallback"
fi

# --- Test 7: Exit code assertions ---
# 7a. Bad range exits with code 2
bad_range_code=0
(cd "$REPO_CLEAN" && bash "$GUARD" "nonexistent..HEAD" >/dev/null 2>&1) || bad_range_code=$?
if [ "$bad_range_code" -eq 2 ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: bad range nonexistent..HEAD expected exit code 2, got $bad_range_code"
fi

bad_rev_code=0
(cd "$REPO_CLEAN" && bash "$GUARD" "not_a_real_sha_or_ref" >/dev/null 2>&1) || bad_rev_code=$?
if [ "$bad_rev_code" -eq 2 ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: bad ref expected exit code 2, got $bad_rev_code"
fi

# 7b. Empty range (e.g. HEAD..HEAD) exits with code 0
empty_range_code=0
(cd "$REPO_CLEAN" && bash "$GUARD" "HEAD..HEAD" >/dev/null 2>&1) || empty_range_code=$?
if [ "$empty_range_code" -eq 0 ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: empty range HEAD..HEAD expected exit code 0, got $empty_range_code"
fi

echo "commit-message-guard.test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
