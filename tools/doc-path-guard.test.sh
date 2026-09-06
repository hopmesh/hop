#!/usr/bin/env bash
# tools/doc-path-guard.test.sh
# Self-test for tools/doc-path-guard.sh.
# Verifies that the guard:
# 1. Passes when all cited paths exist or are qualified with an external repo.
# 2. Fails when a doc cites a relative path that does not exist.
# 3. Passes when BUNDLE_VERSION in prose matches bundle.rs.
# 4. Fails when MECHANISMS.md or SECURITY.md cites a stale wire version or corpus.
# 5. Fails when a doc cites an unqualified PR number above max known PR (PROC-015).
# 6. Passes when a PR citation is qualified with a historical repository (PROC-015).
# 7. Passes when a PR citation is at or below the max known PR (PROC-015).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/doc-path-guard.sh"
pass=0
fail=0

expect() {
  local dir="$1"
  local want="$2"
  local label="$3"
  local code=0
  local out
  out="$(DOC_GUARD_ROOT="$dir" bash "$GUARD" 2>&1)" || code=$?

  if [ "$want" = "pass" ] && [ "$code" -eq 0 ]; then
    echo "  PASS $label (expected pass, got pass)"
    pass=$((pass + 1))
  elif [ "$want" = "fail" ] && [ "$code" -ne 0 ]; then
    echo "  PASS $label (expected failure, got failure: exit $code)"
    pass=$((pass + 1))
  else
    echo "  FAIL $label (wanted $want, got exit $code)"
    printf '    output:\n%s\n' "$out" | sed 's/^/      /'
    fail=$((fail + 1))
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Helper to lay down a minimal test fixture
lay_down() {
  local dir="$1"
  local bundle_ver="$2"
  local mech_ver="$3"
  local sec_corpus="$4"
  local extra_doc_content="$5"

  mkdir -p "$dir/core/hop-core/src" "$dir/docs"
  cat <<EOF > "$dir/core/hop-core/src/bundle.rs"
pub const BUNDLE_VERSION: u8 = $bundle_ver;
EOF

  cat <<EOF > "$dir/MECHANISMS.md"
Wire version is \`bundle.rs BUNDLE_VERSION\` (currently $mech_ver; append-only).
EOF

  cat <<EOF > "$dir/SECURITY.md"
The committed \`core/hop-core/vectors/$sec_corpus\` corpus locks complete encoded bytes.
EOF

  mkdir -p "$dir/core/hop-core/vectors"
  touch "$dir/core/hop-core/vectors/$sec_corpus"

  cat <<EOF > "$dir/CLAUDE.md"
# Test map
- \`core/hop-core/src/bundle.rs\` - protocol core
$extra_doc_content
EOF
}

# Test 1: All paths exist and versions match -> PASS
lay_down "$TMP/ok" "16" "16" "bundle-v16.json" ""
expect "$TMP/ok" pass "all_paths_and_versions_match"

# Test 2: Missing relative path cited in CLAUDE.md -> FAIL (CLAIM-010)
lay_down "$TMP/missing_path" "16" "16" "bundle-v16.json" "- \`infra/cloud_run.tf\` - non-existent"
expect "$TMP/missing_path" fail "missing_relative_path_fails"

# Test 3: External repository reference (hopmesh/platform) -> PASS (CLAIM-010 closure)
lay_down "$TMP/external_path" "16" "16" "bundle-v16.json" "- \`hopmesh/platform/infra/cloud_run.tf\` - external"
expect "$TMP/external_path" pass "external_repo_path_allowed"

# Test 4: Stale BUNDLE_VERSION in MECHANISMS.md -> FAIL (CLAIM-014)
lay_down "$TMP/stale_mech" "16" "15" "bundle-v16.json" ""
expect "$TMP/stale_mech" fail "stale_mechanisms_version_fails"

# Test 5: Stale corpus version in SECURITY.md -> FAIL (CLAIM-014)
lay_down "$TMP/stale_sec" "16" "16" "bundle-v9.json" ""
expect "$TMP/stale_sec" fail "stale_security_corpus_fails"

# Helper to write a mock ci.yml
lay_down_ci() {
  local dir="$1"
  local claude_job_text="$2"
  mkdir -p "$dir/.github/workflows"
  cat << 'EOF' > "$dir/.github/workflows/ci.yml"
name: CI
jobs:
  changes:
    runs-on: ubuntu-latest
  rust:
    runs-on: ubuntu-latest
  deny:
    runs-on: ubuntu-latest
  gate:
    runs-on: ubuntu-latest
    needs: [changes, rust, deny]
EOF
  cat << EOF >> "$dir/CLAUDE.md"
- CI (\`.github/workflows/ci.yml\`) $claude_job_text
EOF
}

# Test 6: Matching CI counts in CLAUDE.md -> PASS (CLAIM-015)
lay_down "$TMP/ci_ok" "16" "16" "bundle-v16.json" ""
lay_down_ci "$TMP/ci_ok" "is the gate: 4 jobs. The aggregate CI gate depends on the other 3 and is required."
expect "$TMP/ci_ok" pass "matching_ci_counts_pass"

# Test 7: Stale CI total jobs in CLAUDE.md -> FAIL (CLAIM-015)
lay_down "$TMP/ci_stale_total" "16" "16" "bundle-v16.json" ""
lay_down_ci "$TMP/ci_stale_total" "is the gate: 20 jobs. The aggregate CI gate depends on the other 3 and is required."
expect "$TMP/ci_stale_total" fail "stale_ci_total_jobs_fails"

# Test 8: Stale gate dependencies in CLAUDE.md -> FAIL (CLAIM-015)
lay_down "$TMP/ci_stale_deps" "16" "16" "bundle-v16.json" ""
lay_down_ci "$TMP/ci_stale_deps" "is the gate: 4 jobs. The aggregate CI gate depends on the other 19 and is required."
expect "$TMP/ci_stale_deps" fail "stale_ci_gate_deps_fails"

# Test 9: Unqualified PR citation above max PR -> FAIL (PROC-015)
lay_down "$TMP/pr_unqualified" "16" "16" "bundle-v16.json" "- Fixes issue in PR #138 without qualification"
expect "$TMP/pr_unqualified" fail "unqualified_pr_above_max_fails"

# Test 10: Qualified PR citation (hopmesh/monorepo#138) above max PR -> PASS (PROC-015)
lay_down "$TMP/pr_qualified" "16" "16" "bundle-v16.json" "- Fixes issue in hopmesh/monorepo#138 with qualification"
expect "$TMP/pr_qualified" pass "qualified_pr_above_max_passes"

# Test 11: Valid PR citation at or below max PR -> PASS (PROC-015)
lay_down "$TMP/pr_valid" "16" "16" "bundle-v16.json" "- Merged in PR #71 cleanly"
expect "$TMP/pr_valid" pass "pr_below_max_passes"

echo
if [ "$fail" -eq 0 ]; then
  echo "doc-path-guard.test.sh: all $pass tests passed"
  exit 0
else
  echo "doc-path-guard.test.sh: $fail failed, $pass passed" >&2
  exit 1
fi
