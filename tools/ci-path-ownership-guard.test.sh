#!/usr/bin/env bash
# Self-test for tools/ci-path-ownership-guard.py (INFRA-012).
# Asserts that:
#   (a) a valid configuration with complete ownership passes,
#   (b) an unmatched tracked top-level tree fails,
#   (c) omitting apps/react-native/HopDemo/** from sdk_react_native fails,
#   (d) omitting apps/ble-lab/** from android fails,
#   (e) omitting fuzz/Cargo.toml from rust fails,
#   (f) omitting root DESIGN.md from docs fails.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/ci-path-ownership-guard.py"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

run_case() {
  local label="$1"
  local want_exit="$2"
  local ci_file="$3"
  local files_file="$4"

  set +e
  local output
  output="$(python3 "$GUARD" --ci "$ci_file" --files-list "$files_file" 2>&1)"
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

cat > "$TMP/files.txt" <<'EOF'
core/hop-core/src/lib.rs
services/hop-relayd/src/main.rs
apps/react-native/HopDemo/package.json
apps/react-native/HopDemo/App.tsx
apps/ble-lab/android/app/src/main/java/sh/hopme/blelab/MainActivity.kt
fuzz/Cargo.toml
fuzz/Cargo.lock
DESIGN.md
SECURITY.md
MECHANISMS.md
README.md
CLAUDE.md
CONTRIBUTING.md
.github/workflows/ci.yml
EOF

# 1. Valid configuration
cat > "$TMP/ci_valid.yml" <<'EOF'
name: CI
jobs:
  changes:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dorny/paths-filter@v3
        id: f
        with:
          filters: |
            full:
              - 'core/**'
              - '.github/**'
            rust:
              - 'services/**'
              - 'fuzz/**'
              - 'fuzz/Cargo.toml'
              - '**/*.rs'
            android:
              - 'apps/ble-lab/**'
            apple:
              - 'apps/ble-lab/**'
            sdk_react_native:
              - 'apps/react-native/HopDemo/**'
            docs:
              - 'DESIGN.md'
              - 'SECURITY.md'
              - 'MECHANISMS.md'
              - 'README.md'
              - 'CLAUDE.md'
              - 'CONTRIBUTING.md'
EOF

run_case "valid_full_ownership" 0 "$TMP/ci_valid.yml" "$TMP/files.txt"

# 2. Unmatched top-level tree
cat > "$TMP/files_with_unmatched.txt" <<'EOF'
core/hop-core/src/lib.rs
services/hop-relayd/src/main.rs
apps/react-native/HopDemo/package.json
apps/react-native/HopDemo/App.tsx
apps/ble-lab/android/app/src/main/java/sh/hopme/blelab/MainActivity.kt
fuzz/Cargo.toml
fuzz/Cargo.lock
DESIGN.md
SECURITY.md
MECHANISMS.md
README.md
CLAUDE.md
CONTRIBUTING.md
.github/workflows/ci.yml
unowned_dir/some_file.txt
EOF

run_case "unmatched_top_tree_fails" 1 "$TMP/ci_valid.yml" "$TMP/files_with_unmatched.txt"

# 3. Missing RN demo filter
cat > "$TMP/ci_missing_rn.yml" <<'EOF'
name: CI
jobs:
  changes:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dorny/paths-filter@v3
        id: f
        with:
          filters: |
            full:
              - 'core/**'
              - '.github/**'
            rust:
              - 'services/**'
              - 'fuzz/**'
              - 'fuzz/Cargo.toml'
              - '**/*.rs'
            android:
              - 'apps/ble-lab/**'
            apple:
              - 'apps/ble-lab/**'
            docs:
              - 'apps/**'
              - 'DESIGN.md'
              - 'SECURITY.md'
              - 'MECHANISMS.md'
              - 'README.md'
              - 'CLAUDE.md'
              - 'CONTRIBUTING.md'
EOF

run_case "missing_rn_demo_fails" 1 "$TMP/ci_missing_rn.yml" "$TMP/files.txt"

# 4. Missing ble-lab android filter
cat > "$TMP/ci_missing_ble_android.yml" <<'EOF'
name: CI
jobs:
  changes:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dorny/paths-filter@v3
        id: f
        with:
          filters: |
            full:
              - 'core/**'
              - '.github/**'
            rust:
              - 'services/**'
              - 'fuzz/**'
              - 'fuzz/Cargo.toml'
              - '**/*.rs'
            apple:
              - 'apps/ble-lab/**'
            sdk_react_native:
              - 'apps/react-native/HopDemo/**'
            docs:
              - 'DESIGN.md'
              - 'SECURITY.md'
              - 'MECHANISMS.md'
              - 'README.md'
              - 'CLAUDE.md'
              - 'CONTRIBUTING.md'
EOF

run_case "missing_ble_lab_android_fails" 1 "$TMP/ci_missing_ble_android.yml" "$TMP/files.txt"

# 5. Missing fuzz manifest filter
cat > "$TMP/ci_missing_fuzz.yml" <<'EOF'
name: CI
jobs:
  changes:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dorny/paths-filter@v3
        id: f
        with:
          filters: |
            full:
              - 'core/**'
              - '.github/**'
            rust:
              - 'services/**'
              - '**/*.rs'
            android:
              - 'apps/ble-lab/**'
            apple:
              - 'apps/ble-lab/**'
            sdk_react_native:
              - 'apps/react-native/HopDemo/**'
            docs:
              - 'DESIGN.md'
              - 'SECURITY.md'
              - 'MECHANISMS.md'
              - 'README.md'
              - 'CLAUDE.md'
              - 'CONTRIBUTING.md'
EOF

run_case "missing_fuzz_manifest_fails" 1 "$TMP/ci_missing_fuzz.yml" "$TMP/files.txt"

# 6. Missing root markdown filter
cat > "$TMP/ci_missing_docs.yml" <<'EOF'
name: CI
jobs:
  changes:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dorny/paths-filter@v3
        id: f
        with:
          filters: |
            full:
              - 'core/**'
              - '.github/**'
            rust:
              - 'services/**'
              - 'fuzz/**'
              - 'fuzz/Cargo.toml'
              - '**/*.rs'
            android:
              - 'apps/ble-lab/**'
            apple:
              - 'apps/ble-lab/**'
            sdk_react_native:
              - 'apps/react-native/HopDemo/**'
            docs:
              - 'README.md'
EOF

run_case "missing_root_markdown_fails" 1 "$TMP/ci_missing_docs.yml" "$TMP/files.txt"

echo
if [ "$fail" -eq 0 ]; then
  echo "ci-path-ownership-guard.test.sh: all $pass tests passed"
  exit 0
else
  echo "ci-path-ownership-guard.test.sh: $fail failed, $pass passed"
  exit 1
fi
