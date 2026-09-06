#!/usr/bin/env bash
# tools/check-worktree-checkpoints.test.sh
# Self-test for tools/check-worktree-checkpoints.sh (PROC-014).
# Asserts that:
#   (a) a clean repo with clean worktrees passes,
#   (b) a worktree with uncommitted modified files fails,
#   (c) a worktree with untracked files fails,
#   (d) a worktree with an unreachable detached commit fails,
#   (e) a worktree with a detached HEAD that is reachable from a branch passes,
#   (f) targeted verification via --worktree inspects only the target.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/check-worktree-checkpoints.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

run_case() {
  local label="$1"
  local want="$2"
  shift 2

  set +e
  local output
  output="$("$SCRIPT" "$@" 2>&1)"
  local rc=$?
  set -e

  case "$want" in
    pass)
      if [ "$rc" -eq 0 ]; then
        echo "  PASS $label (exit 0 as expected)"
        pass=$((pass + 1))
      else
        echo "  FAIL $label (expected exit 0, got $rc)"
        printf '    %s\n' "$output"
        fail=$((fail + 1))
      fi
      ;;
    fail)
      if [ "$rc" -ne 0 ]; then
        echo "  PASS $label (exit $rc as expected)"
        pass=$((pass + 1))
      else
        echo "  FAIL $label (expected non-zero exit, got 0)"
        printf '    %s\n' "$output"
        fail=$((fail + 1))
      fi
      ;;
  esac
}

# Setup a clean test git repository
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.name "Test Runner"
git -C "$REPO" config user.email "test@example.com"
echo "initial" > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -q -m "Initial commit"

# Create a clean secondary worktree on branch feature-1
WT1="$TMP/wt-clean"
git -C "$REPO" worktree add -q -b feature-1 "$WT1" main

# (a) Clean worktree on branch -> PASS
run_case "clean_worktrees_pass" pass --repo "$REPO"

# (b) Worktree with uncommitted modified file -> FAIL
echo "dirty change" >> "$WT1/file.txt"
run_case "uncommitted_modifications_fail" fail --repo "$REPO"
git -C "$WT1" checkout -q -- file.txt

# (c) Worktree with untracked file -> FAIL
echo "untracked" > "$WT1/untracked.txt"
run_case "untracked_files_fail" fail --repo "$REPO"
rm -f "$WT1/untracked.txt"

# (d) Worktree on detached HEAD with a commit not reachable from any branch -> FAIL
WT_DETACHED="$TMP/wt-detached"
git -C "$REPO" worktree add -q --detach "$WT_DETACHED" main
echo "detached commit" >> "$WT_DETACHED/file.txt"
git -C "$WT_DETACHED" commit -q -am "Detached commit"
run_case "unreachable_detached_commit_fails" fail --repo "$REPO"

# (e) Worktree on detached HEAD where the commit IS on a named branch -> PASS
# Create a branch that points to the detached commit
git -C "$REPO" branch saved-detached "$(git -C "$WT_DETACHED" rev-parse HEAD)"
run_case "reachable_detached_commit_passes" pass --repo "$REPO"

# (f) Targeted verification via --worktree
# Create a separate dirty worktree
WT_DIRTY="$TMP/wt-dirty"
git -C "$REPO" worktree add -q -b feature-dirty "$WT_DIRTY" main
echo "dirty" >> "$WT_DIRTY/file.txt"

# Checking clean worktree directly passes
run_case "targeted_clean_worktree_passes" pass --repo "$REPO" --worktree "$WT1"

# Checking dirty worktree directly fails
run_case "targeted_dirty_worktree_fails" fail --repo "$REPO" --worktree "$WT_DIRTY"

echo
if [ "$fail" -eq 0 ]; then
  echo "check-worktree-checkpoints.test.sh: all $pass tests passed"
  exit 0
else
  echo "check-worktree-checkpoints.test.sh: $fail failed, $pass passed" >&2
  exit 1
fi
