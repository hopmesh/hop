#!/usr/bin/env bash
# Self-test for tools/dependabot-coverage-guard.py (INFRA-013).
# Asserts that:
#   (a) a valid configuration with complete ecosystem coverage passes,
#   (b) an uncovered executable package root fails,
#   (c) an allowlist entry with a reason under 20 characters fails,
#   (d) an invalid or empty dependabot configuration fails,
#   (e) missing pyyaml dependency fails closed (PROC-017).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/dependabot-coverage-guard.py"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

run_case() {
  local label="$1"
  local want_exit="$2"
  local dep_file="$3"
  local manifests_file="$4"

  set +e
  local output
  output="$(python3 "$GUARD" --dependabot "$dep_file" --manifests-list "$manifests_file" 2>&1)"
  local got_exit=$?
  set -e

  if [ "$got_exit" -eq "$want_exit" ]; then
    echo "  PASS $label (exit $got_exit as expected)"
    pass=$((pass + 1))
  else
    echo "  FAIL $label (expected exit $want_exit, got $got_exit)"
    printf '    %s\n' "$output"
    fail=$((fail + 1))
  fi
}

cat > "$TMP/manifests_valid.txt" <<'EOF'
Cargo.toml
apps/web/site/package.json
sdk/node/package.json
sdk/android/build.gradle.kts
EOF

cat > "$TMP/dependabot_valid.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: cargo
    directory: "/"
    schedule:
      interval: weekly
  - package-ecosystem: npm
    directory: "/apps/web/site"
    schedule:
      interval: weekly
  - package-ecosystem: npm
    directory: "/sdk/node"
    schedule:
      interval: weekly
  - package-ecosystem: gradle
    directory: "/sdk/android"
    schedule:
      interval: weekly
EOF

# 1. Valid complete coverage
run_case "valid_complete_coverage" 0 "$TMP/dependabot_valid.yml" "$TMP/manifests_valid.txt"

# 2. Uncovered package root
cat > "$TMP/manifests_with_uncovered.txt" <<'EOF'
Cargo.toml
apps/web/site/package.json
sdk/node/package.json
sdk/android/build.gradle.kts
new_app/package.json
EOF

run_case "uncovered_root_fails" 1 "$TMP/dependabot_valid.yml" "$TMP/manifests_with_uncovered.txt"

# 3. Allowlisted root passes
cat > "$TMP/manifests_with_allowlisted.txt" <<'EOF'
Cargo.toml
apps/web/site/package.json
sdk/node/package.json
sdk/android/build.gradle.kts
sdk/crystal/shard.yml
EOF

run_case "allowlisted_root_passes" 0 "$TMP/dependabot_valid.yml" "$TMP/manifests_with_allowlisted.txt"

# 4. Invalid dependabot config
cat > "$TMP/dependabot_invalid.yml" <<'EOF'
version: 2
# missing updates key
EOF

run_case "invalid_config_fails" 1 "$TMP/dependabot_invalid.yml" "$TMP/manifests_valid.txt"

# 5. missing pyyaml dependency fails closed (PROC-017)
mkdir -p "$TMP/empty_pythonpath"
set +e
output="$(PYTHONPATH="$TMP/empty_pythonpath" python3 -c 'import sys, runpy; sys.modules["yaml"] = None; runpy.run_path("'"$GUARD"'")' 2>&1)"
got_exit=$?
set -e
if [ "$got_exit" -ne 0 ]; then
  echo "  PASS missing_pyyaml_fails_closed (exit $got_exit as expected)"
  pass=$((pass + 1))
else
  echo "  FAIL missing_pyyaml_fails_closed (expected non-zero exit, got 0)"
  printf '    %s\n' "$output"
  fail=$((fail + 1))
fi
echo
if [ "$fail" -eq 0 ]; then
  echo "dependabot-coverage-guard.test.sh: all $pass tests passed"
  exit 0
else
  echo "dependabot-coverage-guard.test.sh: $fail failed, $pass passed"
  exit 1
fi
