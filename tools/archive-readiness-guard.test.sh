#!/usr/bin/env bash
# tools/archive-readiness-guard.test.sh
# Self-test for tools/archive-readiness-guard.py.
#
# Asserts that the guard:
#   1. Rejects an invented current download URL pointing to hopmesh/monorepo.
#   2. Rejects a workflow source checkout of hopmesh/monorepo.
#   3. Rejects a package manifest repository field pointing to hopmesh/monorepo.
#   4. Rejects a future-tag builder authorizing hopmesh/monorepo.
#   5. Accepts the legacy v0.0.1 trust anchor.
#   6. Accepts the legacy v0.0.2 trust anchor.
#   7. Passes on the clean repository tree.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
guard="$root/tools/archive-readiness-guard.py"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

record_pass() {
  echo "ok   [$1]"
  pass=$((pass + 1))
}

record_fail() {
  echo "FAIL [$1]: $2" >&2
  fail=$((fail + 1))
}

# --- Test 1: Clean tree passes ---
if python3 "$guard" --root "$root" >/dev/null 2>&1; then
  record_pass "clean repository passes archive readiness guard"
else
  record_fail "clean repository" "guard failed unexpectedly on clean repository"
fi

# --- Helper to create synthetic case directory ---
make_case() {
  local name="$1"
  local dir="$tmp/$name"
  mkdir -p "$dir"
  echo "$dir"
}

# --- Test 2: Reject invented current download URL ---
case_dir="$(make_case download-url)"
mkdir -p "$case_dir/docs"
cat >"$case_dir/docs/repo-catalog.md" <<'EOF'
Download current release assets here:
https://github.com/hopmesh/monorepo/releases/download/v0.0.3/hop-x86_64.tar.gz
EOF

if python3 "$guard" --root "$case_dir" >/dev/null 2>&1; then
  record_fail "reject invented download URL" "guard accepted current download URL pointing to hopmesh/monorepo"
else
  record_pass "rejects invented current download URL pointing to hopmesh/monorepo"
fi

# --- Test 3: Reject workflow source checkout ---
case_dir="$(make_case workflow-checkout)"
mkdir -p "$case_dir/.github/workflows"
cat >"$case_dir/.github/workflows/deploy.workflow.yml" <<'EOF'
name: deploy
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          repository: hopmesh/monorepo
EOF

if python3 "$guard" --root "$case_dir" >/dev/null 2>&1; then
  record_fail "reject workflow checkout" "guard accepted workflow checkout of hopmesh/monorepo"
else
  record_pass "rejects workflow source checkout of archived hopmesh/monorepo"
fi

# --- Test 4: Reject package repository field in package.json ---
case_dir="$(make_case package-repo)"
cat >"$case_dir/package.json" <<'EOF'
{
  "name": "@hop-mesh/sdk",
  "version": "0.0.3",
  "repository": "https://github.com/hopmesh/monorepo"
}
EOF

if python3 "$guard" --root "$case_dir" >/dev/null 2>&1; then
  record_fail "reject package repository field" "guard accepted package manifest pointing to hopmesh/monorepo"
else
  record_pass "rejects package manifest repository field pointing to archived hopmesh/monorepo"
fi

# Also test Cargo.toml package repository field rejection
case_dir="$(make_case cargo-repo)"
cat >"$case_dir/Cargo.toml" <<'EOF'
[package]
name = "hop-core"
version = "0.0.3"
repository = "https://github.com/hopmesh/monorepo"
EOF

if python3 "$guard" --root "$case_dir" >/dev/null 2>&1; then
  record_fail "reject Cargo.toml repository field" "guard accepted Cargo.toml repository pointing to hopmesh/monorepo"
else
  record_pass "rejects Cargo.toml repository field pointing to archived hopmesh/monorepo"
fi

# --- Test 5: Reject future-tag builder ---
case_dir="$(make_case future-builder)"
mkdir -p "$case_dir/sdk/go/cmd/hop-install"
cat >"$case_dir/sdk/go/cmd/hop-install/main.go" <<'EOF'
package main

const (
	legacyRepository = "https://github.com/hopmesh/monorepo"
	legacyBuilder    = "hopmesh/monorepo"
)

func builderFor(tag string) (string, string) {
	switch tag {
	case "v0.0.1", "v0.0.2", "v0.0.3":
		return legacyRepository, legacyBuilder
	}
	return "https://github.com/hopmesh/hop", "hopmesh/hop"
}
EOF

if python3 "$guard" --root "$case_dir" >/dev/null 2>&1; then
  record_fail "reject future builder" "guard accepted post-v0.0.2 tag mapping to legacy builder"
else
  record_pass "rejects future-tag builder authorizing archived hopmesh/monorepo"
fi

# --- Test 6: Accept legacy v0.0.1 trust anchor ---
case_dir="$(make_case legacy-v001)"
mkdir -p "$case_dir/sdk/go/cmd/hop-install"
cat >"$case_dir/sdk/go/cmd/hop-install/main.go" <<'EOF'
package main

const (
	legacyRepository = "https://github.com/hopmesh/monorepo"
	legacyBuilder    = "hopmesh/monorepo"
)

func builderFor(tag string) (string, string) {
	switch tag {
	case "v0.0.1":
		return legacyRepository, legacyBuilder
	}
	return "https://github.com/hopmesh/hop", "hopmesh/hop"
}
EOF

if python3 "$guard" --root "$case_dir" >/dev/null 2>&1; then
  record_pass "accepts legacy v0.0.1 trust anchor"
else
  record_fail "accept legacy v0.0.1" "guard rejected legacy v0.0.1 trust anchor"
fi

# --- Test 7: Accept legacy v0.0.2 trust anchor ---
case_dir="$(make_case legacy-v002)"
mkdir -p "$case_dir/sdk/go/cmd/hop-install"
cat >"$case_dir/sdk/go/cmd/hop-install/main.go" <<'EOF'
package main

const (
	legacyRepository = "https://github.com/hopmesh/monorepo"
	legacyBuilder    = "hopmesh/monorepo"
)

func builderFor(tag string) (string, string) {
	switch tag {
	case "v0.0.1", "v0.0.2":
		return legacyRepository, legacyBuilder
	}
	return "https://github.com/hopmesh/hop", "hopmesh/hop"
}
EOF

if python3 "$guard" --root "$case_dir" >/dev/null 2>&1; then
  record_pass "accepts legacy v0.0.2 trust anchor"
else
  record_fail "accept legacy v0.0.2" "guard rejected legacy v0.0.2 trust anchor"
fi

# --- Test 8: Reject unallowlisted file containing reference ---
case_dir="$(make_case unallowlisted-ref)"
cat >"$case_dir/random_file.txt" <<'EOF'
This file mentions hopmesh/monorepo unexpectedly.
EOF

if python3 "$guard" --root "$case_dir" >/dev/null 2>&1; then
  record_fail "reject unallowlisted reference" "guard accepted unallowlisted file referencing hopmesh/monorepo"
else
  record_pass "rejects unallowlisted file referencing hopmesh/monorepo"
fi

echo "archive-readiness-guard.test.sh: all $pass tests passed ($fail failed)"
[ "$fail" -eq 0 ]
