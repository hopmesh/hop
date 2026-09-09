#!/usr/bin/env bash
# tools/test-module-inline-guard.sh
# Guard against additive inline test modules colliding at end of file.
#
# Rule:
# When a Rust source file already contains an inline test module (e.g. `mod tests { ... }`),
# new test modules must NOT be appended inline to that file. Instead, new test modules
# must live in their own file (per-file convention):
#
#   #[cfg(test)]
#   #[path = "<file>_<lane>_tests.rs"]
#   mod <lane>_tests;
#
# In Rust, child modules declared with `#[path = "..."] mod ...;` retain full access
# to all private functions, types, and constants of the parent module via `super::*`.
#
# Why this exists:
# During multi-agent integration (such as round-4 integration of CAND-PROTO-A/B/C),
# multiple lanes each appending inline `#[cfg(test)] mod <lane>_tests` blocks to
# the end of a shared file (e.g. `core/hop-core/src/node.rs`) causes git 3-way merge
# conflicts at end-of-file. Because Rust test modules share common boilerplate
# (`use super::*;`, `#[test]`, closing `}`), git's merge engine can interleave their
# bodies across conflict blocks, risking corrupted or spliced module definitions.
#
# Usage:
#   tools/test-module-inline-guard.sh [REVISION_RANGE]
#   tools/test-module-inline-guard.sh --diff
#   tools/test-module-inline-guard.sh --file <path.rs>
#
# Exit codes:
#   0: clean (no additive inline test module collisions)
#   1: additive inline test module found in a file that already has one
#   2: usage or git invocation error
set -euo pipefail

fail() {
  echo "error: test-module-inline-guard: $*" >&2
  exit 2
}

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "not inside a git repository"
cd "$ROOT"

MODE="range"
RANGE=""
FILE_TARGET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --diff|--working-tree)
      MODE="diff"
      shift
      ;;
    --file)
      MODE="file"
      [ $# -ge 2 ] || fail "--file requires a file path argument"
      FILE_TARGET="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [REVISION_RANGE | --diff | --file <path.rs>]"
      exit 0
      ;;
    *)
      RANGE="$1"
      shift
      ;;
  esac
done

# Pattern matching inline mod <name>_tests or mod tests declarations (not ending with ;)
# Group 3 is the module name.
MOD_PATTERN='^[+]([[:space:]]*(pub([[:space:]]*\([a-z_]+\))?[[:space:]]+)?mod[[:space:]]+([a-zA-Z0-9_]*tests)\b)'
BASE_MOD_PATTERN='^[[:space:]]*(pub([[:space:]]*\([a-z_]+\))?[[:space:]]+)?mod[[:space:]]+[a-zA-Z0-9_]*tests\b'

failures=0

check_single_file() {
  local target="$1"
  [ -f "$target" ] || fail "file not found: $target"

  # Count inline test modules in the file directly (excluding out-of-line declarations ending with ;)
  local inline_count
  inline_count=$(grep -E "$BASE_MOD_PATTERN" "$target" 2>/dev/null | grep -v ';[[:space:]]*$' | wc -l | tr -d ' ' || echo 0)

  if [ "$inline_count" -gt 1 ]; then
    echo "test-module-inline-guard: FAIL: $target contains $inline_count inline test modules (maximum allowed: 1)" >&2
    echo "  Additive test modules must live in their own file (per-file convention):" >&2
    echo "    #[cfg(test)]" >&2
    echo "    #[path = \"<stem>_<lane>_tests.rs\"]" >&2
    echo "    mod <lane>_tests;" >&2
    return 1
  fi
  return 0
}

check_file_diff() {
  local file="$1"
  local base_ref="$2"
  local diff_cmd="$3"

  # Extract added lines from diff
  local added_lines
  added_lines=$(eval "$diff_cmd" | grep -E "$MOD_PATTERN" || true)

  [ -n "$added_lines" ] || return 0

  # Filter out lines ending with semicolon (out-of-line per-file modules)
  local inline_additions
  inline_additions=$(printf '%s\n' "$added_lines" | grep -v ';[[:space:]]*$' || true)

  [ -n "$inline_additions" ] || return 0

  # Count pre-existing inline test modules in base version of file
  local pre_count=0
  if [ -n "$base_ref" ]; then
    local base_content
    base_content=$(git show "$base_ref:$file" 2>/dev/null || true)
    if [ -n "$base_content" ]; then
      pre_count=$(printf '%s\n' "$base_content" | grep -E "$BASE_MOD_PATTERN" | grep -v ';[[:space:]]*$' | wc -l | tr -d ' ' || echo 0)
    fi
  fi

  # Count how many inline test modules were added in this diff
  local add_count
  add_count=$(printf '%s\n' "$inline_additions" | wc -l | tr -d ' ')

  # Violation condition:
  # 1. Base file already had at least one test module (pre_count >= 1), AND diff adds >= 1 inline module.
  # 2. Base file had no test modules (pre_count == 0), BUT diff adds >= 2 inline modules.
  local is_violation=0
  if [ "$pre_count" -ge 1 ] && [ "$add_count" -ge 1 ]; then
    is_violation=1
  elif [ "$pre_count" -eq 0 ] && [ "$add_count" -ge 2 ]; then
    is_violation=1
  fi

  if [ "$is_violation" -eq 1 ]; then
    failures=$((failures + 1))
    local stem
    stem="$(basename "$file" .rs)"
    echo "test-module-inline-guard: FAIL: $file: added $add_count new inline test module(s)" >&2
    echo "  File pre-existing inline test module count: $pre_count" >&2
    printf '%s\n' "$inline_additions" | sed 's/^[+]//' | sed 's/^/  Offending declaration: /' >&2
    echo "  Additive test modules must live in their own file (per-file convention):" >&2
    echo "    #[cfg(test)]" >&2
    echo "    #[path = \"${stem}_<lane>_tests.rs\"]" >&2
    echo "    mod <lane>_tests;" >&2
    echo "  Appending inline 'mod *_tests' blocks to the same file causes 3-way merge" >&2
    echo "  collisions at end-of-file during multi-agent integration." >&2
  fi
}

case "$MODE" in
  file)
    if check_single_file "$FILE_TARGET"; then
      echo "test-module-inline-guard: OK ($FILE_TARGET has <= 1 inline test module)"
      exit 0
    else
      exit 1
    fi
    ;;

  diff)
    diff_files=$(git diff --name-only HEAD -- '*.rs' 2>/dev/null || true)
    scanned=0
    for f in $diff_files; do
      [ -f "$f" ] || continue
      scanned=$((scanned + 1))
      check_file_diff "$f" "HEAD" "git diff -U0 HEAD -- \"$f\""
    done
    if [ "$failures" -gt 0 ]; then
      echo "test-module-inline-guard: FAILED ($failures file(s) with additive inline test module violations)" >&2
      exit 1
    fi
    echo "test-module-inline-guard: OK ($scanned Rust file(s) scanned in working tree diff)"
    exit 0
    ;;

  range)
    if [ -z "$RANGE" ]; then
      if [ -n "${BASE_REF:-}" ]; then
        RANGE="${BASE_REF}..HEAD"
      elif git rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
        RANGE="origin/main..HEAD"
      else
        RANGE="HEAD"
      fi
    fi

    base_commit=""
    head_commit=""

    if [[ "$RANGE" == *".."* ]]; then
      base_commit="${RANGE%%..*}"
      head_commit="${RANGE##*..}"
      [ -n "$base_commit" ] || base_commit="origin/main"
      [ -n "$head_commit" ] || head_commit="HEAD"
    else
      # Single commit specified
      head_commit="$RANGE"
      base_commit="${RANGE}^"
    fi

    # Verify commits exist
    git cat-file -e "$head_commit^{commit}" 2>/dev/null || fail "head ref unavailable: $head_commit"
    git cat-file -e "$base_commit^{commit}" 2>/dev/null || fail "base ref unavailable: $base_commit"

    changed_files=$(git diff --name-only "$base_commit..$head_commit" -- '*.rs' 2>/dev/null || true)
    scanned=0

    for f in $changed_files; do
      scanned=$((scanned + 1))
      check_file_diff "$f" "$base_commit" "git diff -U0 \"$base_commit..$head_commit\" -- \"$f\""
    done

    if [ "$failures" -gt 0 ]; then
      echo "test-module-inline-guard: FAILED ($failures file(s) with additive inline test module violations in $RANGE)" >&2
      exit 1
    fi
    echo "test-module-inline-guard: OK ($scanned Rust file(s) scanned in $RANGE)"
    exit 0
    ;;
esac
