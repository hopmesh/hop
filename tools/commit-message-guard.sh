#!/usr/bin/env bash
# tools/commit-message-guard.sh (PROC-009)
# Scan commit messages introduced by a change for banned em/en/lookalike dashes.
#
# Usage:
#   tools/commit-message-guard.sh [REVISION_RANGE]
#   tools/commit-message-guard.sh --github-event
#
# Arguments:
#   REVISION_RANGE: Git revision or range to inspect (default: HEAD).
#                   Single revisions (e.g. HEAD) scan that single commit only.
#                   Ranges (e.g. base..HEAD) scan all commits in the range.
#   --github-event: Resolves the revision range from GitHub Actions event context
#                   via tools/commit-message-guard-range.sh (pull_request: base..HEAD,
#                   push: before..HEAD with fallback to HEAD, etc.).
#
# Iterates `git log --format='%H%x00%B%x00' RANGE`.
# Note: Merge commits are deliberately scanned (not skipped with --no-merges):
# merge commits carry PR titles and must satisfy the dash law too.
#
# What it bans (reusing the exact banned list and conventions from tools/docs-token-guard.sh):
#   1. em-dash       U+2014
#   2. en-dash       U+2013
#   3. horizontal bar U+2015 (em-dash lookalike)
#   4. figure dash   U+2012 (en-dash lookalike)
#   5. minus sign    U+2212 (en-dash lookalike; use an ASCII hyphen)
#   6. encoded dashes: HTML entities (&mdash;, &ndash;, &#8212;, &#x2014;, etc.),
#      \u escapes (\u2014, \u{2014}, etc.), and CSS \NNNN escapes (\2014, etc.)
#      including lookalike code points U+2015, U+2012, U+2212.
#
# Note: Keep the banned-pattern code points and regex in lockstep with
# tools/docs-token-guard.sh (lines 125-130, 260).
#
# Zero allowlist: every commit introduced by a change must be clean.
# History is not scanned; only the commits a change introduces are checked.
#
# Exit codes:
#   0: clean (no banned dashes in any scanned commit)
#   1: banned dash found in commit message(s)
#   2: bad revision range or git invocation error
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# Resolve system grep binary
GREP="$(command -v grep)"

# The banned dash code points, built from hex so this script file itself stays ASCII-clean.
# These must match tools/docs-token-guard.sh exactly.
EMDASH=$(printf '\xe2\x80\x94')   # U+2014 em dash
ENDASH=$(printf '\xe2\x80\x93')   # U+2013 en dash
HBAR=$(printf '\xe2\x80\x95')     # U+2015 horizontal bar (em-dash lookalike)
FIGDASH=$(printf '\xe2\x80\x92')  # U+2012 figure dash (en-dash lookalike)
MINUS=$(printf '\xe2\x88\x92')    # U+2212 minus sign (en-dash lookalike); use an ASCII hyphen

# Encoded dash regex matching HTML entities, \u escapes, and CSS escapes.
# Matches tools/docs-token-guard.sh line 260. Single-quoted so backslashes are preserved.
ENCODED_DASH_REGEX='&mdash;|&ndash;|&#0*(821[0123]|8722);?|&#x0*(201[2345]|2212);?|\\u\{?0*(201[2345]|2212)\}?|\\0*(201[2345]|2212)'

RANGE=""
if [ "${1:-}" = "--github-event" ]; then
  if [ -f "$HERE/commit-message-guard-range.sh" ]; then
    RANGE="$(bash "$HERE/commit-message-guard-range.sh")"
  else
    echo "::error::commit-message-guard: missing $HERE/commit-message-guard-range.sh" >&2
    exit 2
  fi
elif [ "$#" -gt 0 ]; then
  RANGE="$1"
else
  RANGE="HEAD"
fi

if [ -z "$RANGE" ]; then
  RANGE="HEAD"
fi

# Verify the range or revision is valid in git
if ! git rev-parse "$RANGE" >/dev/null 2>&1; then
  echo "::error::commit-message-guard: invalid revision or range: $RANGE" >&2
  exit 2
fi

git_args=()
if [[ "$RANGE" =~ \.\. ]]; then
  # Revision range A..B or A...B
  git_args=("$RANGE")
elif [[ "$RANGE" =~ ^- ]]; then
  # Flag passed directly, e.g. -n 1
  git_args=("$RANGE")
else
  # Single revision: inspect only that single commit
  git_args=(-1 "$RANGE")
fi

fail=0
scanned=0

while IFS= read -r -d '' commit && IFS= read -r -d '' body; do
  commit="$(printf '%s' "$commit" | tr -d '[:space:]')"
  [ -n "$commit" ] || continue

  scanned=$((scanned + 1))
  commit_fail=0
  classes=()

  if printf '%s' "$body" | "$GREP" -F -q -e "$EMDASH"; then
    classes+=("em-dash (U+2014)")
    commit_fail=1
  fi
  if printf '%s' "$body" | "$GREP" -F -q -e "$ENDASH"; then
    classes+=("en-dash (U+2013)")
    commit_fail=1
  fi
  if printf '%s' "$body" | "$GREP" -F -q -e "$HBAR"; then
    classes+=("horizontal bar (U+2015)")
    commit_fail=1
  fi
  if printf '%s' "$body" | "$GREP" -F -q -e "$FIGDASH"; then
    classes+=("figure dash (U+2012)")
    commit_fail=1
  fi
  if printf '%s' "$body" | "$GREP" -F -q -e "$MINUS"; then
    classes+=("minus sign (U+2212)")
    commit_fail=1
  fi
  if printf '%s' "$body" | "$GREP" -iE -q -e "$ENCODED_DASH_REGEX"; then
    classes+=("encoded dash")
    commit_fail=1
  fi

  if [ "$commit_fail" -ne 0 ]; then
    fail=1
    subject="$(printf '%s' "$body" | head -n 1)"
    for cls in "${classes[@]}"; do
      echo "::error::commit $commit contains banned dash class: $cls"
    done
    echo "  Commit:  $commit"
    echo "  Subject: $subject"
    echo
  fi
done < <(git log --format='%H%x00%B%x00' "${git_args[@]}")

if [ "$fail" -ne 0 ]; then
  echo "commit-message-guard: FAIL ($scanned commit(s) scanned in range $RANGE, banned dashes found)"
  exit 1
fi

echo "commit-message-guard: OK ($scanned commit(s) scanned in range $RANGE, no banned dashes)"
exit 0
