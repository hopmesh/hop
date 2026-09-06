#!/usr/bin/env bash
# tools/check-worktree-checkpoints.sh
# Verifies worktree checkpoint invariants for multi-agent isolation (PROC-014):
# 1. Every active worktree has a clean working tree (git status --porcelain is empty).
# 2. Every active worktree HEAD commit is reachable from at least one named branch.
#
# Usage:
#   tools/check-worktree-checkpoints.sh [--repo DIR] [--worktree DIR]
#
# Self-tested by tools/check-worktree-checkpoints.test.sh.

set -euo pipefail

REPO_DIR="${CHECK_WORKTREE_REPO:-}"
TARGET_WORKTREE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      REPO_DIR="$2"
      shift 2
      ;;
    --worktree)
      TARGET_WORKTREE="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--repo DIR] [--worktree DIR]"
      exit 0
      ;;
    *)
      echo "check-worktree-checkpoints: unrecognized argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$REPO_DIR" ]; then
  REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

if [ ! -d "$REPO_DIR/.git" ] && [ ! -f "$REPO_DIR/.git" ]; then
  echo "check-worktree-checkpoints: not a git repository: $REPO_DIR" >&2
  exit 2
fi

fail=0
checked=0

check_worktree() {
  local wt_path="$1"
  local wt_head="$2"
  local wt_branch="$3"

  if [ ! -d "$wt_path" ]; then
    echo "check-worktree-checkpoints: ERROR: worktree path does not exist: $wt_path" >&2
    fail=$((fail + 1))
    return
  fi

  checked=$((checked + 1))

  # 1. Check working tree cleanliness
  local status_output
  status_output="$(git -C "$wt_path" status --porcelain 2>/dev/null || true)"
  if [ -n "$status_output" ]; then
    echo "check-worktree-checkpoints: FAIL: uncommitted changes in worktree $wt_path" >&2
    printf '%s\n' "$status_output" | sed 's/^/    /' >&2
    fail=$((fail + 1))
  fi

  # 2. Check commit reachability from a named branch
  local containing_branches
  containing_branches="$(git -C "$REPO_DIR" branch -a --contains "$wt_head" 2>/dev/null | grep -v 'HEAD detached' || true)"
  if [ -z "$containing_branches" ]; then
    echo "check-worktree-checkpoints: FAIL: worktree $wt_path HEAD $wt_head is not reachable from any branch" >&2
    fail=$((fail + 1))
  fi
}

if [ -n "$TARGET_WORKTREE" ]; then
  abs_wt="$(cd "$TARGET_WORKTREE" 2>/dev/null && pwd || echo "$TARGET_WORKTREE")"
  wt_head="$(git -C "$abs_wt" rev-parse HEAD 2>/dev/null || echo "")"
  if [ -z "$wt_head" ]; then
    echo "check-worktree-checkpoints: cannot resolve HEAD for worktree: $abs_wt" >&2
    exit 1
  fi
  wt_branch="$(git -C "$abs_wt" symbolic-ref --short HEAD 2>/dev/null || echo "detached")"
  check_worktree "$abs_wt" "$wt_head" "$wt_branch"
else
  # Parse git worktree list --porcelain output
  current_wt=""
  current_head=""
  current_branch=""

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      worktree\ *)
        current_wt="${line#worktree }"
        current_head=""
        current_branch=""
        ;;
      HEAD\ *)
        current_head="${line#HEAD }"
        ;;
      branch\ *)
        current_branch="${line#branch }"
        ;;
      detached)
        current_branch="detached"
        ;;
      "")
        if [ -n "$current_wt" ] && [ -n "$current_head" ]; then
          check_worktree "$current_wt" "$current_head" "$current_branch"
        fi
        current_wt=""
        current_head=""
        current_branch=""
        ;;
    esac
  done < <(git -C "$REPO_DIR" worktree list --porcelain 2>/dev/null || true)

  # Handle final entry if file did not end with a blank line
  if [ -n "$current_wt" ] && [ -n "$current_head" ]; then
    check_worktree "$current_wt" "$current_head" "$current_branch"
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "check-worktree-checkpoints: FAILED ($fail issue(s) detected across $checked worktree(s))" >&2
  exit 1
fi

echo "check-worktree-checkpoints: OK ($checked worktree(s) clean and reachable)"
