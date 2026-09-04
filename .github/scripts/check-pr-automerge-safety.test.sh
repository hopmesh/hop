#!/usr/bin/env bash
# Self-test for PR auto-merge review-intent safety check (PROC-002).
# Asserts that PRs with review-intent, WIP, RFC, hold, or do-not-merge markers
# in title or body are refused from auto-merging, specifically reproducing
# the PR #71 incident.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="$root/.github/workflows/pr-automerge.yml"

step="$(python3 - "$workflow" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r"name: Inspect PR title and body for review-intent and hold markers\n.*?run: \|\n(.*?)(?=^\s+- |\Z)", text, re.S | re.M)
if not match:
    raise SystemExit("step not found")
print("\n".join(line[10:] for line in match.group(1).splitlines()))
PY
)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

test_case() {
  label="$1"
  title="$2"
  body="$3"
  expected_arm="$4"

  output_file="$tmp/output"
  rm -f "$output_file"
  touch "$output_file"

  GITHUB_OUTPUT="$output_file" TITLE="$title" BODY="$body" bash -c "$step" >/dev/null 2>&1

  actual_arm="$(grep '^arm_automerge=' "$output_file" | cut -d= -f2)"
  if [ "$actual_arm" != "$expected_arm" ]; then
    echo "FAIL [$label]: expected arm_automerge=$expected_arm, got $actual_arm" >&2
    exit 1
  fi
}

# 1. Historical PR #71 scenario: research doc with 'do not merge' in title
test_case "pr_71_reconstruction" \
  "docs: does Grit Chat LLC need its own Cloud Billing account (research, do not merge)" \
  "Investigation into billing account separation." \
  "false"

# 2. Routine non-draft PR: must be allowed
test_case "routine_pr" \
  "fix(core): update connection timeout" \
  "Fixes a flaky timeout during peer handshake." \
  "true"

# 3. WIP marker in title
test_case "wip_title" \
  "WIP: refactor storage layer" \
  "Still in progress." \
  "false"

# 4. RFC marker in title
test_case "rfc_title" \
  "[RFC] proposal for multi-transport routing" \
  "Needs team discussion." \
  "false"

# 5. Hold marker in body
test_case "hold_body" \
  "feat(cli): add new inspection flag" \
  "Please hold this until backend lands." \
  "false"

# 6. Do not merge in body
test_case "do_not_merge_body" \
  "chore: bump dependencies" \
  "Testing only, do not merge." \
  "false"

# 7. Review-only marker
test_case "review_only" \
  "docs: review-only draft guidelines" \
  "" \
  "false"

echo "PR auto-merge safety tests passed"
