#!/usr/bin/env bash
# tools/integration-content-guard.sh
# Guard against commits or fixes lost during multi-agent integration.
#
# Rule:
# Given an integration branch and the lane branches it claims to integrate,
# every lane commit's CONTENT must be present in the integration result,
# not merely that the branch was merged or listed in a ledger.
#
# Why this exists:
# During round-3 integration, commit f6cfd1fa on fix/r3-legal (adding Firestore KV
# metadata TTL retention periods to privacy and DPA docs and tests) was superseded
# during the lane's second round and dropped during final integration. It was only
# discovered post-integration by inspecting abandoned branches. Standard git branch
# contains checks fail to detect dropped commits when lane branches are squashed,
# rebased, or partially merged.
#
# Mechanism:
# For each lane branch:
#   1. Resolve merge base between INTEGRATION_REF and LANE_REF.
#   2. Check whether LANE_REF has commits beyond merge base.
#   3. Perform an in-memory 3-way merge (via `git merge-tree --write-tree`) of
#      LANE_REF into INTEGRATION_REF.
#   4. If merge-tree fails with conflicts, the lane content is not cleanly integrated.
#   5. If merge-tree succeeds, verify that the diff between INTEGRATION_REF and the
#      merged tree is EMPTY.
#   6. If the diff is non-empty, report the unmerged commits (via `git cherry`) and
#      the exact unmerged file diffstat.
#
# Usage:
#   tools/integration-content-guard.sh <INTEGRATION_REF> <LANE_REF> [<LANE_REF>...]
#   tools/integration-content-guard.sh --integration <INTEGRATION_REF> <LANE_REF>...
#   tools/integration-content-guard.sh <LANE_REF>...  # defaults INTEGRATION_REF to HEAD
#
# Exit codes:
#   0: clean (all lane content is present in the integration ref)
#   1: content from one or more lanes is missing or conflicting
#   2: usage or git invocation error
set -euo pipefail

fail() {
  echo "error: integration-content-guard: $*" >&2
  exit 2
}

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "not inside a git repository"
cd "$ROOT"

INTEGRATION_REF=""
LANE_REFS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --integration)
      [ $# -ge 2 ] || fail "--integration requires a ref argument"
      INTEGRATION_REF="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [INTEGRATION_REF] <LANE_REF> [<LANE_REF>...]"
      echo "       $0 --integration <INTEGRATION_REF> <LANE_REF>..."
      exit 0
      ;;
    *)
      if [ -z "$INTEGRATION_REF" ] && [ $# -gt 1 ]; then
        # First positional argument is INTEGRATION_REF if multiple arguments remain
        INTEGRATION_REF="$1"
      else
        LANE_REFS+=("$1")
      fi
      shift
      ;;
  esac
done

if [ -z "$INTEGRATION_REF" ]; then
  INTEGRATION_REF="HEAD"
fi

[ "${#LANE_REFS[@]}" -gt 0 ] || fail "at least one LANE_REF must be specified"

# Verify INTEGRATION_REF exists
git cat-file -e "$INTEGRATION_REF^{commit}" 2>/dev/null || fail "integration ref unavailable: $INTEGRATION_REF"

failures=0
total_lanes="${#LANE_REFS[@]}"

for lane in "${LANE_REFS[@]}"; do
  # Verify lane ref exists
  if ! git cat-file -e "$lane^{commit}" 2>/dev/null; then
    echo "integration-content-guard: FAIL: lane ref unavailable: $lane" >&2
    failures=$((failures + 1))
    continue
  fi

  # Resolve common merge base
  merge_base="$(git merge-base "$INTEGRATION_REF" "$lane" 2>/dev/null || true)"
  if [ -z "$merge_base" ]; then
    echo "integration-content-guard: FAIL: lane '$lane' has no common history with '$INTEGRATION_REF'" >&2
    failures=$((failures + 1))
    continue
  fi

  # Check if lane has any commits beyond merge base
  lane_commits="$(git rev-list "$merge_base..$lane" 2>/dev/null || true)"
  if [ -z "$lane_commits" ]; then
    echo "integration-content-guard: OK: lane '$lane' has 0 commits beyond merge base with '$INTEGRATION_REF'"
    continue
  fi

  # Check if lane introduces any file diff against merge base
  lane_diff="$(git diff "$merge_base..$lane" 2>/dev/null || true)"
  if [ -z "$lane_diff" ]; then
    echo "integration-content-guard: OK: lane '$lane' introduces no file diff against merge base"
    continue
  fi

  # In-memory 3-way merge
  merge_status=0
  merge_output="$(git merge-tree --write-tree "$INTEGRATION_REF" "$lane" 2>&1)" || merge_status=$?

  if [ "$merge_status" -ne 0 ]; then
    echo "integration-content-guard: FAIL: lane '$lane' conflicts when merged into '$INTEGRATION_REF'" >&2
    echo "  Merge base: $merge_base" >&2
    unmerged_commits="$(git cherry "$INTEGRATION_REF" "$lane" 2>/dev/null | grep '^\+' | cut -d' ' -f2 || true)"
    if [ -n "$unmerged_commits" ]; then
      echo "  Unmerged commit(s) on lane '$lane':" >&2
      for c in $unmerged_commits; do
        subj="$(git log -1 --format='%h %s' "$c" 2>/dev/null || echo "$c")"
        echo "    $subj" >&2
      done
    fi
    failures=$((failures + 1))
    continue
  fi

  # Clean merge: check if merged tree introduces any changes relative to INTEGRATION_REF
  merged_tree="$(printf '%s\n' "$merge_output" | head -n 1)"
  residual_diff="$(git diff "$INTEGRATION_REF" "$merged_tree" 2>/dev/null || true)"

  if [ -n "$residual_diff" ]; then
    echo "integration-content-guard: FAIL: lane '$lane' has content missing from '$INTEGRATION_REF'" >&2
    echo "  Merge base: $merge_base" >&2
    unmerged_commits="$(git cherry "$INTEGRATION_REF" "$lane" 2>/dev/null | grep '^\+' | cut -d' ' -f2 || true)"
    if [ -n "$unmerged_commits" ]; then
      echo "  Unmerged commit(s) on lane '$lane':" >&2
      for c in $unmerged_commits; do
        subj="$(git log -1 --format='%h %s' "$c" 2>/dev/null || echo "$c")"
        echo "    $subj" >&2
      done
    fi
    echo "  Files with unmerged content:" >&2
    git diff --stat "$INTEGRATION_REF" "$merged_tree" 2>/dev/null | sed 's/^/    /' >&2
    failures=$((failures + 1))
  else
    echo "integration-content-guard: OK: lane '$lane' content is fully integrated into '$INTEGRATION_REF'"
  fi
done

if [ "$failures" -gt 0 ]; then
  echo "integration-content-guard: FAILED ($failures of $total_lanes lane(s) have missing or conflicting content in $INTEGRATION_REF)" >&2
  exit 1
fi

echo "integration-content-guard: OK: all $total_lanes lane(s) fully integrated into $INTEGRATION_REF"
exit 0
