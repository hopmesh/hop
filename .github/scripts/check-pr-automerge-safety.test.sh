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

mkdir -p "$tmp/bin"
cat <<'SH' > "$tmp/bin/gh"
#!/usr/bin/env bash
if [ -n "${MOCK_GH_FAIL:-}" ]; then
  echo "gh: network timeout or API failure" >&2
  exit 1
fi
if [ -n "${MOCK_GH_EMPTY:-}" ]; then
  exit 0
fi
if [ -n "${MOCK_GH_INVALID_JSON:-}" ]; then
  echo "not json"
  exit 0
fi
if [ -n "${MOCK_GH_EMPTY_FILES:-}" ]; then
  echo '{"files":[],"reviews":[],"commits":[]}'
  exit 0
fi
if [ -n "${MOCK_GH_SENSITIVE_NO_REVIEW:-}" ]; then
  echo '{"files":[{"path":".github/workflows/release.yml"}],"reviews":[],"commits":[]}'
  exit 0
fi
if [ -n "${MOCK_GH_SENSITIVE_APPROVED:-}" ]; then
  echo '{"files":[{"path":".github/workflows/release.yml"}],"reviews":[{"state":"APPROVED"}],"commits":[]}'
  exit 0
fi
if [ -n "${MOCK_GH_CLEAN:-}" ]; then
  echo '{"files":[{"path":"core/hop/src/lib.rs"}],"reviews":[],"commits":[]}'
  exit 0
fi
exec /opt/homebrew/bin/gh "$@" 2>/dev/null || exec gh "$@"
SH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

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
test_case_env() {
  label="$1"
  title="$2"
  body="$3"
  expected_arm="$4"
  shift 4

  output_file="$tmp/output"
  rm -f "$output_file"
  touch "$output_file"

  env GITHUB_OUTPUT="$output_file" TITLE="$title" BODY="$body" "$@" python3 "$script" >/dev/null 2>&1

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

# 17. Zero-width characters BETWEEN the marker's words (deleting them would fuse do+not+merge into
# one token and hide the word boundary; the checker must match the space-mapped form too).
test_case "zero_width_between_words" \
  "feat: do"$'\u200B'"not"$'\u200B'"merge yet" \
  "Landing later." \
  "false"

test_case "zero_width_joiner_inside_dnm" \
  "chore: d"$'\u2060'"n"$'\u2060'"m" \
  "Hold this." \
  "false"

# 18. A clean title with an unrelated zero-width character must still be allowed to auto-merge.
test_case "zero_width_in_clean_title" \
  "feat(core): tighten"$'\u200B'" bundle parsing" \
  "Adds the size ceiling." \
  "true"

# 19. Bidi override character in title (INFRA-018)
test_case "bidi_override_title" \
  "do"$'\u202E'"not merge" \
  "Clean description" \
  "false"

# 20. Bidi override character in body (INFRA-018)
test_case "bidi_override_body" \
  "feat(core): update timeout" \
  "do"$'\u202E'"not merge" \
  "false"

# 21. Cyrillic homoglyphs in title (INFRA-018)
test_case "cyrillic_homoglyph_wip" \
  "Fix issue [W"$'\u0456'"P]" \
  "Fixing bug" \
  "false"

test_case "cyrillic_homoglyph_do_not_merge" \
  "d"$'\u043E'" not merge" \
  "Experimental" \
  "false"

# 22. Review phrases: review required and awaiting review (INFRA-018)
test_case "review_required" \
  "docs: update API reference" \
  "review required before landing" \
  "false"

test_case "awaiting_review" \
  "feat: add capability" \
  "awaiting review from lead" \
  "false"

# 23. PR modifying workflow file without approved review (PROC-012)
test_case_env "workflow_file_no_review" \
  "feat: update release workflow" \
  "Routine update" \
  "false" \
  CHANGED_FILES=".github/workflows/release.yml"

# 24. PR modifying workflow file WITH approved review (PROC-012)
test_case_env "workflow_file_with_review" \
  "feat: update release workflow" \
  "Approved by lead" \
  "true" \
  CHANGED_FILES=".github/workflows/release.yml" \
  PR_REVIEWS='[{"state":"APPROVED"}]'

# 25. PR modifying export tooling without approved review (PROC-012)
test_case_env "export_tooling_no_review" \
  "fix(copybara): update export spec" \
  "Fixes export" \
  "false" \
  CHANGED_FILES="tools/copybara/copy.bara.sky"

# 26. PR modifying security-sensitive path without approved review (PROC-012)
test_case_env "workflow_secrets_no_review" \
  "chore: add secret" \
  "New secret" \
  "false" \
  CHANGED_FILES="tools/workflow-secrets.json"

# 27. Stale approval date in PR body (PROC-012)
test_case_env "stale_approval_date" \
  "fix(core): connection fix" \
  "Owner approval of 2026-09-04 covers this follow-up; auto-merge arms on the maintainer path" \
  "false" \
  CURRENT_DATE="2026-09-05"

# 28. Fresh approval date on non-sensitive PR
test_case_env "fresh_approval_date" \
  "fix(core): connection fix" \
  "Owner approval of 2026-09-05 covers this follow-up" \
  "true" \
  CURRENT_DATE="2026-09-05"

# 29. Blanket verbal approval claim in PR body (PROC-012)
test_case "blanket_approval_claim" \
  "fix: quick fix" \
  "move forward anyway, you have my approval" \
  "false"

# 30. Commit message with WIP or hold (PROC-012)
test_case_env "commit_message_wip" \
  "fix(core): clean title" \
  "Clean body" \
  "false" \
  COMMIT_MESSAGES="WIP: storage refactor"

test_case_env "commit_message_dnm" \
  "fix(core): clean title" \
  "Clean body" \
  "false" \
  COMMIT_MESSAGES="feat: experimental (do not merge)"

# 31. Clean commit messages allowed
test_case_env "clean_commit_messages" \
  "fix(core): clean title" \
  "Clean body" \
  "true" \
  COMMIT_MESSAGES="feat: real feature"$'\n'"fix: real fix"

# 32. Verify pr-automerge.yml configures 'edited' trigger and disarms auto-merge on failure (INFRA-018)
workflow="$root/.github/workflows/pr-automerge.yml"
if ! grep -q "edited" "$workflow"; then
  echo "FAIL: pr-automerge.yml does not configure 'edited' event trigger (INFRA-018)" >&2
  exit 1
fi
if ! grep -q "gh pr merge --disable-auto" "$workflow"; then
  echo "FAIL: pr-automerge.yml does not disarm auto-merge on safety check failure (INFRA-018)" >&2
  exit 1
fi

# 33. _fetch_pr_data fail-closed on gh CLI error (PROC-012)
test_case_env "fetch_pr_data_cli_error" \
  "fix: clean title" \
  "Clean body" \
  "false" \
  PR_NUMBER="999" \
  MOCK_GH_FAIL="1"

# 34. _fetch_pr_data fail-closed on gh empty stdout (PROC-012)
test_case_env "fetch_pr_data_empty_stdout" \
  "fix: clean title" \
  "Clean body" \
  "false" \
  PR_NUMBER="999" \
  MOCK_GH_EMPTY="1"

# 35. _fetch_pr_data fail-closed on gh invalid JSON (PROC-012)
test_case_env "fetch_pr_data_invalid_json" \
  "fix: clean title" \
  "Clean body" \
  "false" \
  PR_NUMBER="999" \
  MOCK_GH_INVALID_JSON="1"

# 36. _fetch_pr_data fail-closed on empty changed files list (PROC-012)
test_case_env "fetch_pr_data_empty_files" \
  "fix: clean title" \
  "Clean body" \
  "false" \
  PR_NUMBER="999" \
  MOCK_GH_EMPTY_FILES="1"

# 37. _fetch_pr_data sensitive file without approved review (PROC-012)
test_case_env "fetch_pr_data_sensitive_no_review" \
  "fix: clean title" \
  "Clean body" \
  "false" \
  PR_NUMBER="999" \
  MOCK_GH_SENSITIVE_NO_REVIEW="1"

# 38. _fetch_pr_data sensitive file WITH approved review (PROC-012)
test_case_env "fetch_pr_data_sensitive_approved" \
  "fix: clean title" \
  "Clean body" \
  "true" \
  PR_NUMBER="999" \
  MOCK_GH_SENSITIVE_APPROVED="1"

# 39. _fetch_pr_data clean files allowed (PROC-012)
test_case_env "fetch_pr_data_clean_allowed" \
  "fix: clean title" \
  "Clean body" \
  "true" \
  PR_NUMBER="999" \
  MOCK_GH_CLEAN="1"

# 40. Verify notice output on fail-closed CLI error
notice_out="$(env TITLE="clean" BODY="clean" PR_NUMBER="999" MOCK_GH_FAIL="1" python3 "$script" 2>&1 || true)"
if [[ "$notice_out" != *"::notice title=Auto-merge refused::"* ]]; then
  echo "FAIL: expected ::notice title=Auto-merge refused:: on gh CLI failure" >&2
  exit 1
fi
if [[ "$notice_out" != *"GitHub CLI metadata query failed or returned empty data"* ]]; then
  echo "FAIL: expected notice to mention GitHub CLI query failure" >&2
  exit 1
fi
echo "PR auto-merge safety tests passed"
