#!/usr/bin/env bash
# tools/commit-message-guard-range.sh
# Compute the git revision range to scan for tools/commit-message-guard.sh
# based on GitHub Actions event context or CLI arguments.
#
# Event resolution:
#   pull_request:
#     ${BASE_SHA}..HEAD
#     Base SHA is extracted from $GITHUB_EVENT_PATH (.pull_request.base.sha),
#     $GITHUB_BASE_SHA, or $2.
#     If the base SHA is missing, the 40-zero SHA, or unreachable in the local
#     git object database, the range falls back to HEAD (scan HEAD only).
#
#     Note on pull_request checkout:
#     GitHub Actions checks out refs/pull/N/merge by default on pull_request
#     events. This is a synthetic merge commit with two parents (the target base
#     and the PR head) whose generated message is "Merge <sha> into <sha>".
#     The range base.sha..HEAD includes this synthetic merge commit. GitHub's
#     generated message never contains banned dashes, but any introduced merge
#     commit in the PR or the synthetic merge commit itself is checked.
#
#   push:
#     ${BEFORE_SHA}..HEAD unless before is the 40-zero SHA or unreachable,
#     in which case scan HEAD only.
#     Before SHA is extracted from $GITHUB_EVENT_PATH (.before),
#     $GITHUB_BEFORE_SHA, or $2.
#
#   workflow_dispatch / other:
#     HEAD (scan HEAD only).
#
# Output:
#   Prints the computed revision range string to stdout (exit 0).
set -euo pipefail

EVENT_NAME="${1:-${GITHUB_EVENT_NAME:-}}"
EVENT_ARG="${2:-}"

# Helper: check if a commit object is present in the local repository
is_reachable_commit() {
  local sha="$1"
  [ -n "$sha" ] || return 1
  git rev-parse --verify --quiet "$sha^{commit}" >/dev/null 2>&1
}

ZERO_SHA="0000000000000000000000000000000000000000"

case "$EVENT_NAME" in
  pull_request)
    base_sha=""
    if [ -n "$EVENT_ARG" ]; then
      base_sha="$EVENT_ARG"
    elif [ -n "${GITHUB_BASE_SHA:-}" ]; then
      base_sha="$GITHUB_BASE_SHA"
    elif [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "$GITHUB_EVENT_PATH" ]; then
      base_sha="$(python3 -c "import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        data = json.load(f)
    print(data.get('pull_request', {}).get('base', {}).get('sha', '') or '')
except Exception:
    pass" "$GITHUB_EVENT_PATH" 2>/dev/null || true)"
    fi

    if [ -n "$base_sha" ] && [ "$base_sha" != "$ZERO_SHA" ] && is_reachable_commit "$base_sha"; then
      echo "${base_sha}..HEAD"
    else
      echo "HEAD"
    fi
    ;;

  push)
    before_sha=""
    if [ -n "$EVENT_ARG" ]; then
      before_sha="$EVENT_ARG"
    elif [ -n "${GITHUB_BEFORE_SHA:-}" ]; then
      before_sha="$GITHUB_BEFORE_SHA"
    elif [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "$GITHUB_EVENT_PATH" ]; then
      before_sha="$(python3 -c "import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        data = json.load(f)
    print(data.get('before', '') or '')
except Exception:
    pass" "$GITHUB_EVENT_PATH" 2>/dev/null || true)"
    fi

    if [ -n "$before_sha" ] && [ "$before_sha" != "$ZERO_SHA" ] && is_reachable_commit "$before_sha"; then
      echo "${before_sha}..HEAD"
    else
      echo "HEAD"
    fi
    ;;

  workflow_dispatch|*)
    echo "HEAD"
    ;;
esac
