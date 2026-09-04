#!/usr/bin/env bash
# Test for tools/gen-changelogs.sh output scoping and staging (PROC-007).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/tools/gen-changelogs.sh"

# 1. Verify --list-outputs produces the expected known outputs
outputs="$("$SCRIPT" --list-outputs)"
if ! echo "$outputs" | grep -qx "CHANGELOG.md"; then
    echo "FAIL: expected CHANGELOG.md in outputs" >&2
    exit 1
fi

if ! echo "$outputs" | grep -qx "core/hop-endpoint/CHANGELOG.md"; then
    echo "FAIL: expected core/hop-endpoint/CHANGELOG.md in outputs" >&2
    exit 1
fi

# 2. Test scoped staging in a scratch git directory with a stray CHANGELOG.md
TMP_DIR="$(mktemp -d /tmp/changelog-test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

git -C "$TMP_DIR" init -q
mkdir -p "$TMP_DIR/stray-tool"
mkdir -p "$TMP_DIR/tools/copybara"
mkdir -p "$TMP_DIR/core/hop-endpoint"

# Copy components.json so --list-outputs works
cp "$ROOT/tools/copybara/components.json" "$TMP_DIR/tools/copybara/"

# Create legitimate changelog and stray changelog
echo "legit" > "$TMP_DIR/CHANGELOG.md"
echo "legit endpoint" > "$TMP_DIR/core/hop-endpoint/CHANGELOG.md"
echo "stray third-party changelog" > "$TMP_DIR/stray-tool/CHANGELOG.md"

# Run staging via --stage
(
    cd "$TMP_DIR"
    bash "$SCRIPT" --stage
)

staged="$(git -C "$TMP_DIR" diff --name-only --cached)"

if echo "$staged" | grep -q "stray-tool/CHANGELOG.md"; then
    echo "FAIL: stray-tool/CHANGELOG.md was staged by --stage" >&2
    exit 1
fi

if ! echo "$staged" | grep -qx "CHANGELOG.md"; then
    echo "FAIL: root CHANGELOG.md was not staged" >&2
    exit 1
fi

if ! echo "$staged" | grep -qx "core/hop-endpoint/CHANGELOG.md"; then
    echo "FAIL: core/hop-endpoint/CHANGELOG.md was not staged" >&2
    exit 1
fi

# 3. Assert git-cliff-2.13.1 is not tracked in the main repo
if [ -n "$(git -C "$ROOT" ls-files git-cliff-2.13.1/)" ]; then
    echo "FAIL: git-cliff-2.13.1/ is tracked in repo" >&2
    exit 1
fi

echo "gen-changelogs.test.sh: OK (stray changelog was not staged; outputs correctly scoped)"
