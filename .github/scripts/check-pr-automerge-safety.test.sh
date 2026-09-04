#!/usr/bin/env bash
# Self-test for PR auto-merge review-intent safety check (PROC-002).
# Asserts that PRs with review-intent, WIP, RFC, hold, or do-not-merge markers
# in title or body are refused from auto-merging, specifically reproducing
# the PR #71 incident and hostile bypass attempts.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
script="$root/.github/scripts/check-pr-automerge-safety.py"

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

  GITHUB_OUTPUT="$output_file" TITLE="$title" BODY="$body" python3 "$script" >/dev/null 2>&1

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

# 8. Hyphenated do-not-merge bypass attempt
test_case "hyphenated_do_not_merge" \
  "feat(core): experimental transport (do-not-merge)" \
  "Early draft." \
  "false"

# 9. Contraction dont-merge bypass attempt
test_case "dont_merge" \
  "docs(readme): draft proposal, please dont merge yet" \
  "Work in progress." \
  "false"

test_case "dont_merge_apostrophe" \
  "docs(readme): draft proposal, please don't merge yet" \
  "Work in progress." \
  "false"

# 10. Needs review marker
test_case "needs_review" \
  "feat(api): preliminary endpoint implementation" \
  "Ready for feedback, needs review." \
  "false"

# 11. Not ready marker
test_case "not_ready" \
  "test(sim): cluster stress test" \
  "WIP: not ready for main." \
  "false"

# 12. Blocked marker
test_case "blocked_marker" \
  "fix(deps): bump dependency version" \
  "Blocked on upstream security release." \
  "false"

# 13. Zero-width space obfuscation bypass attempt (w\u200bip)
test_case "zero_width_space_wip" \
  "w"$'\u200B'"ip: refactor link manager" \
  "Exploring alternative link management." \
  "false"

# 14. RFC with digits bypass attempt (RFC001, rfc123)
test_case "rfc_with_digits_title" \
  "[RFC001] mesh addressing specification" \
  "Initial draft." \
  "false"

test_case "rfc_with_digits_body" \
  "docs(mesh): addressing notes" \
  "Refers to rfc123 for details." \
  "false"

# 15. Please review / for review / under review
test_case "under_review" \
  "feat(crypto): add post-quantum hybrid prototype" \
  "This PR is under review by team." \
  "false"

test_case "for_review" \
  "docs: updated architecture diagrams" \
  "Submitted for review only." \
  "false"

# 16. Experiment marker
test_case "experiment_marker" \
  "experiment: alternate wire encoding" \
  "Testing benchmarks." \
  "false"

echo "PR auto-merge safety tests passed"
