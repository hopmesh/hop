#!/usr/bin/env bash
# tools/archive-readiness-guard.test.sh
# Self-test for tools/archive-readiness-guard.py.
#
# Asserts that the guard:
#   1. Rejects an invented current download URL pointing to hopmesh/monorepo.
#   2. Rejects a workflow source checkout of hopmesh/monorepo (file and text verified).
#   3. Rejects a mixed-case workflow source checkout (HopMesh/Monorepo).
#   4. Rejects hostile operational runbook commands in incident-response.md (file and text verified).
#   5. Rejects hostile operational runbook commands in relay-enable-disable.md (file and text verified).
#   6. Rejects executable clone appended to an allowlisted script (bootstrap-packages.sh).
#   7. Rejects reviewer subprocess list-form mutation with comment suffix in allowlisted test script.
#   8. Rejects shell command split over array syntax (cmd=("git" "clone" ...)).
#   9. Rejects split-quoted git clone command (git "clone" ...).
#  10. Rejects executable clone even when followed by a safety phrase on the same line.
#  11. Rejects a package manifest repository field pointing to hopmesh/monorepo.
#  12. Rejects a future-tag builder authorizing hopmesh/monorepo.
#  13. Accepts the legacy v0.0.1 trust anchor.
#  14. Accepts the legacy v0.0.2 trust anchor.
#  15. Rejects unallowlisted files referencing hopmesh/monorepo.
#  16. Passes on the clean repository tree.

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

# --- Helper to create synthetic case directory ---
make_case() {
  local name="$1"
  local dir="$tmp/$name"
  mkdir -p "$dir"
  echo "$dir"
}

# --- Test 1: Clean tree passes ---
if python3 "$guard" --root "$root" >/dev/null 2>&1; then
  record_pass "clean repository passes archive readiness guard"
else
  record_fail "clean repository" "guard failed unexpectedly on clean repository"
fi

# --- Test 2: Reject invented current download URL ---
case_dir="$(make_case download-url)"
mkdir -p "$case_dir/docs"
cat >"$case_dir/docs/repo-catalog.md" <<'EOF'
# Repository Catalog
Download current release assets here:
https://github.com/hopmesh/monorepo/releases/download/v0.0.3/hop-x86_64.tar.gz
EOF

out="$(python3 "$guard" --root "$case_dir" 2>&1 || true)"
if echo "$out" | grep -q "rejected current download URL pointing to archived hopmesh/monorepo"; then
  record_pass "rejects invented current download URL pointing to hopmesh/monorepo"
else
  record_fail "reject invented download URL" "guard failed to reject or report expected text: $out"
fi

# --- Test 3: Reject workflow source checkout (verified by file and text) ---
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

out="$(python3 "$guard" --root "$case_dir" 2>&1 || true)"
if echo "$out" | grep -q ".github/workflows/deploy.workflow.yml" && echo "$out" | grep -q "rejected workflow source checkout of archived hopmesh/monorepo"; then
  record_pass "rejects workflow source checkout of archived hopmesh/monorepo (file and text verified)"
else
  record_fail "reject workflow checkout" "expected failure matching file and text, got: $out"
fi

# --- Test 4: Reject mixed-case workflow source checkout (HopMesh/Monorepo) ---
case_dir="$(make_case mixed-case-checkout)"
mkdir -p "$case_dir/.github/workflows"
cat >"$case_dir/.github/workflows/deploy.workflow.yml" <<'EOF'
name: deploy
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          repository: HopMesh/Monorepo
EOF

out="$(python3 "$guard" --root "$case_dir" 2>&1 || true)"
if echo "$out" | grep -q ".github/workflows/deploy.workflow.yml" && echo "$out" | grep -q "rejected workflow source checkout of archived hopmesh/monorepo"; then
  record_pass "rejects mixed-case workflow source checkout (HopMesh/Monorepo)"
else
  record_fail "reject mixed-case workflow checkout" "expected failure matching mixed case, got: $out"
fi

# --- Test 5: Reject hostile operational runbook command in incident-response.md ---
case_dir="$(make_case hostile-incident-response)"
mkdir -p "$case_dir/docs/runbooks"
cat >"$case_dir/docs/runbooks/incident-response.md" <<'EOF'
# Runbook: incident response
1. Check repository variables:
   gh api /repos/hopmesh/monorepo/actions/variables/RELAYS_ENABLED --jq .value
EOF

out="$(python3 "$guard" --root "$case_dir" 2>&1 || true)"
if echo "$out" | grep -q "docs/runbooks/incident-response.md" && echo "$out" | grep -q "gh api /repos/hopmesh/monorepo"; then
  record_pass "rejects hostile operational command in incident-response.md (file and text verified)"
else
  record_fail "reject hostile incident runbook command" "expected failure matching file and text, got: $out"
fi

# --- Test 6: Reject hostile operational runbook command in relay-enable-disable.md ---
case_dir="$(make_case hostile-relay-enable)"
mkdir -p "$case_dir/docs/runbooks"
cat >"$case_dir/docs/runbooks/relay-enable-disable.md" <<'EOF'
# Runbook: relay enable and disable
1. Immediate variable revert:
   In hopmesh/monorepo, set the repository variable RELAYS_ENABLED to false
EOF

out="$(python3 "$guard" --root "$case_dir" 2>&1 || true)"
if echo "$out" | grep -q "docs/runbooks/relay-enable-disable.md" && echo "$out" | grep -q "In hopmesh/monorepo, set the repository variable RELAYS_ENABLED"; then
  record_pass "rejects hostile operational command in relay-enable-disable.md (file and text verified)"
else
  record_fail "reject hostile relay runbook command" "expected failure matching file and text, got: $out"
fi

# --- Test 7: Reject executable clone in allowlisted script (bootstrap-packages.sh) ---
case_dir="$(make_case clone-in-allowlisted-script)"
mkdir -p "$case_dir/tools/copybara"
cat >"$case_dir/tools/copybara/bootstrap-packages.sh" <<'EOF'
#!/usr/bin/env bash
# Existing historical setup comment
gh repo clone hopmesh/monorepo
EOF

out="$(python3 "$guard" --root "$case_dir" 2>&1 || true)"
if echo "$out" | grep -q "tools/copybara/bootstrap-packages.sh" && echo "$out" | grep -q "rejected executable clone of archived hopmesh/monorepo"; then
  record_pass "rejects executable clone in allowlisted script (tools/copybara/bootstrap-packages.sh)"
else
  record_fail "reject clone in allowlisted script" "expected clone rejection in allowlisted script, got: $out"
fi

# --- Test 8: Reject reviewer exact subprocess list-form mutation with comment suffix ---
case_dir="$(make_case reviewer-subprocess-mutation)"
mkdir -p "$case_dir/tools"
cat >"$case_dir/tools/crates-publish.test.sh" <<'EOF'
#!/usr/bin/env bash
"repository": "https://github.com/hopmesh/monorepo",
subprocess.run(["git", "clone", "https://github.com/hopmesh/monorepo"]) # verify_repo_identity negative test
EOF

out="$(python3 "$guard" --root "$case_dir" 2>&1 || true)"
if echo "$out" | grep -q "tools/crates-publish.test.sh" && echo "$out" | grep -q "rejected executable clone of archived hopmesh/monorepo"; then
  record_pass "rejects reviewer subprocess list-form mutation with comment suffix"
else
  record_fail "reject reviewer subprocess mutation" "expected rejection of subprocess clone, got: $out"
fi

# --- Test 9: Reject shell command split over array syntax ---
case_dir="$(make_case shell-array-syntax)"
mkdir -p "$case_dir/tools/copybara"
cat >"$case_dir/tools/copybara/bootstrap-packages.sh" <<'EOF'
#!/usr/bin/env bash
# hopmesh/monorepo in their repository field.
cmd=("git" "clone" "https://github.com/hopmesh/monorepo")
"${cmd[@]}"
EOF

out="$(python3 "$guard" --root "$case_dir" 2>&1 || true)"
if echo "$out" | grep -q "tools/copybara/bootstrap-packages.sh" && echo "$out" | grep -q "rejected executable clone of archived hopmesh/monorepo"; then
  record_pass "rejects shell command split over array syntax (cmd=(\"git\" \"clone\" ...))"
else
  record_fail "reject shell array syntax" "expected rejection of array clone, got: $out"
fi

# --- Test 10: Reject split-quoted git clone command ---
case_dir="$(make_case split-quoted-clone)"
mkdir -p "$case_dir/docs/runbooks"
cat >"$case_dir/docs/runbooks/incident-response.md" <<'EOF'
# Runbook: incident response
git "clone" "https://github.com/hopmesh/monorepo"
EOF

out="$(python3 "$guard" --root "$case_dir" 2>&1 || true)"
if echo "$out" | grep -q "docs/runbooks/incident-response.md" && echo "$out" | grep -q "rejected executable clone of archived hopmesh/monorepo"; then
  record_pass "rejects split-quoted git clone command (git \"clone\" ...)"
else
  record_fail "reject split-quoted clone" "expected rejection of split-quoted clone, got: $out"
fi

# --- Test 11: Reject executable clone followed by safety phrase on the same line ---
case_dir="$(make_case clone-same-line-safety)"
mkdir -p "$case_dir/docs/runbooks"
cat >"$case_dir/docs/runbooks/incident-response.md" <<'EOF'
# Runbook: incident response
git clone https://github.com/hopmesh/monorepo # no operational action may target the repo
EOF

out="$(python3 "$guard" --root "$case_dir" 2>&1 || true)"
if echo "$out" | grep -q "docs/runbooks/incident-response.md" && echo "$out" | grep -q "rejected executable clone of archived hopmesh/monorepo"; then
  record_pass "rejects executable clone even when followed by safety phrase on the same line"
else
  record_fail "reject clone with safety phrase" "expected priority rejection of clone command, got: $out"
fi

# --- Test 12: Reject package repository field in package.json ---
case_dir="$(make_case package-repo)"
cat >"$case_dir/package.json" <<'EOF'
{
  "name": "@hop-mesh/sdk",
  "version": "0.0.3",
  "repository": "https://github.com/hopmesh/monorepo"
}
EOF

out="$(python3 "$guard" --root "$case_dir" 2>&1 || true)"
if echo "$out" | grep -q "package.json" && echo "$out" | grep -q "rejected package manifest repository field"; then
  record_pass "rejects package manifest repository field pointing to archived hopmesh/monorepo"
else
  record_fail "reject package repository field" "expected failure on package.json, got: $out"
fi

# Also test Cargo.toml package repository field rejection
case_dir="$(make_case cargo-repo)"
cat >"$case_dir/Cargo.toml" <<'EOF'
[package]
name = "hop-core"
version = "0.0.3"
repository = "https://github.com/hopmesh/monorepo"
EOF

out="$(python3 "$guard" --root "$case_dir" 2>&1 || true)"
if echo "$out" | grep -q "Cargo.toml" && echo "$out" | grep -q "rejected package manifest repository field"; then
  record_pass "rejects Cargo.toml repository field pointing to archived hopmesh/monorepo"
else
  record_fail "reject Cargo.toml repository field" "expected failure on Cargo.toml, got: $out"
fi

# --- Test 13: Reject future-tag builder ---
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

out="$(python3 "$guard" --root "$case_dir" 2>&1 || true)"
if echo "$out" | grep -q "rejected future-tag builder"; then
  record_pass "rejects future-tag builder authorizing archived hopmesh/monorepo"
else
  record_fail "reject future builder" "expected failure on future builder, got: $out"
fi

# --- Test 14: Accept legacy v0.0.1 trust anchor ---
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

# --- Test 15: Accept legacy v0.0.2 trust anchor ---
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

# --- Test 16: Reject unallowlisted file containing reference ---
case_dir="$(make_case unallowlisted-ref)"
cat >"$case_dir/random_file.txt" <<'EOF'
This file mentions hopmesh/monorepo unexpectedly.
EOF

out="$(python3 "$guard" --root "$case_dir" 2>&1 || true)"
if echo "$out" | grep -q "unallowlisted reference to archived repository hopmesh/monorepo"; then
  record_pass "rejects unallowlisted file referencing hopmesh/monorepo"
else
  record_fail "reject unallowlisted reference" "expected unallowlisted failure, got: $out"
fi

echo "archive-readiness-guard.test.sh: all $pass tests passed ($fail failed)"
[ "$fail" -eq 0 ]
