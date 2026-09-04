#!/usr/bin/env bash
# Self-test for dep-fix-tag authorization and resolution (INFRA-014).
# Asserts that fork branches, non-dependabot actors, ambiguous PRs,
# and already-tagged PRs do not trigger work requests, while authentic
# Dependabot failures produce exactly one comment.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
script="$root/.github/scripts/dep-fix-tag.py"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

calls_log="$tmp/calls.log"
export FAKE_CALLS_LOG="$calls_log"

cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env sh
echo "$*" >> "$FAKE_CALLS_LOG"
case "$*" in
  *"pr list"*)
    if [ -n "${FAKE_PR_LIST:-}" ]; then
      printf '%s\n' "$FAKE_PR_LIST"
    else
      echo "[]"
    fi
    ;;
  *"pr view"*)
    if [ -n "${FAKE_PR_COMMENTS:-}" ]; then
      printf '%s\n' "$FAKE_PR_COMMENTS"
    else
      echo '{"comments":[]}'
    fi
    ;;
  *"pr comment"*)
    echo "comment posted"
    ;;
  *)
    exit 1
    ;;
esac
SH
chmod +x "$tmp/bin/gh"

run_case() {
  label="$1"
  expected_exit="$2"
  expected_comment="$3"

  rm -f "$calls_log"
  touch "$calls_log"

  out=""
  actual_exit=0
  out="$(PATH="$tmp/bin:$PATH" \
  FAKE_CALLS_LOG="$calls_log" \
  FAKE_PR_LIST="${CASE_PR_LIST:-[]}" \
  FAKE_PR_COMMENTS="${CASE_PR_COMMENTS:-}" \
  HEAD_REPO="${CASE_HEAD_REPO:-hopmesh/hop}" \
  ACTOR="${CASE_ACTOR:-dependabot[bot]}" \
  BRANCH="${CASE_BRANCH:-dependabot/test}" \
  HEAD_SHA="${CASE_HEAD_SHA:-$sha1}" \
  REPO="${CASE_REPO:-hopmesh/hop}" \
  python3 "$script" 2>&1)" || actual_exit=$?
  if [ "$actual_exit" -ne "$expected_exit" ]; then
    echo "FAIL [$label]: expected exit $expected_exit, got $actual_exit" >&2
    echo "Output: $out" >&2
    exit 1
  fi

  has_comment=false
  if grep -q "pr comment" "$calls_log" 2>/dev/null; then
    has_comment=true
  fi

  if [ "$has_comment" != "$expected_comment" ]; then
    echo "FAIL [$label]: expected comment=$expected_comment, got $has_comment" >&2
    echo "Calls log:" >&2
    cat "$calls_log" >&2
    exit 1
  fi
}

sha1="1111111111111111111111111111111111111111"

# 1. Fork repository: must be rejected with no comment
CASE_HEAD_REPO="attacker/fork" CASE_ACTOR="dependabot[bot]" CASE_BRANCH="dependabot/npm_and_yarn/foo-1.0.0" CASE_HEAD_SHA="$sha1" \
  run_case "fork_rejected" 0 false

# 2. Non-dependabot actor: must be rejected with no comment
CASE_HEAD_REPO="hopmesh/hop" CASE_ACTOR="attacker" CASE_BRANCH="dependabot/npm_and_yarn/foo-1.0.0" CASE_HEAD_SHA="$sha1" \
  run_case "human_actor_rejected" 0 false

# 3. Non-dependabot branch: must be rejected with no comment
CASE_HEAD_REPO="hopmesh/hop" CASE_ACTOR="dependabot[bot]" CASE_BRANCH="feature/my-branch" CASE_HEAD_SHA="$sha1" \
  run_case "wrong_branch_rejected" 0 false

# 4. Authentic Dependabot PR: must post comment
CASE_PR_LIST='[{"number": 42, "headRefName": "dependabot/npm/foo-1.0.0", "headRefOid": "'"$sha1"'", "author": {"login": "dependabot[bot]"}, "headRepositoryOwner": {"login": "hopmesh"}}]' \
CASE_PR_COMMENTS='{"comments":[]}' \
CASE_HEAD_REPO="hopmesh/hop" CASE_ACTOR="dependabot[bot]" CASE_BRANCH="dependabot/npm/foo-1.0.0" CASE_HEAD_SHA="$sha1" \
  run_case "authentic_dependabot_success" 0 true

# 5. Already tagged for same head SHA: must not post duplicate comment
CASE_PR_LIST='[{"number": 42, "headRefName": "dependabot/npm/foo-1.0.0", "headRefOid": "'"$sha1"'", "author": {"login": "dependabot[bot]"}, "headRepositoryOwner": {"login": "hopmesh"}}]' \
CASE_PR_COMMENTS='{"comments":[{"body":"<!-- dep-fix-tag:sha='"$sha1"' --> already tagged"}]}' \
CASE_HEAD_REPO="hopmesh/hop" CASE_ACTOR="dependabot[bot]" CASE_BRANCH="dependabot/npm/foo-1.0.0" CASE_HEAD_SHA="$sha1" \
  run_case "already_tagged_skipped" 0 false

# 6. Ambiguous PRs: fails closed (exit 1)
CASE_PR_LIST='[{"number": 42, "headRefName": "dependabot/npm/foo-1.0.0", "headRefOid": "'"$sha1"'", "author": {"login": "dependabot[bot]"}, "headRepositoryOwner": {"login": "hopmesh"}}, {"number": 43, "headRefName": "dependabot/npm/foo-1.0.0", "headRefOid": "'"$sha1"'", "author": {"login": "dependabot[bot]"}, "headRepositoryOwner": {"login": "hopmesh"}}]' \
CASE_HEAD_REPO="hopmesh/hop" CASE_ACTOR="dependabot[bot]" CASE_BRANCH="dependabot/npm/foo-1.0.0" CASE_HEAD_SHA="$sha1" \
  run_case "ambiguous_prs_fail_closed" 1 false

echo "dep-fix-tag authorization tests passed"
