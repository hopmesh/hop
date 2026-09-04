#!/usr/bin/env bash
# Self-test for tools/codegen/check-contract-purity.sh (INFRA-017).
# Proves that the guard fails on:
# 1. Any missing contract target or header.
# 2. All missing targets.
# 3. An empty target file or directory.
# 4. An unclassified new SDK directory.
# 5. A transport-specific symbol leaked into a contract header.
# 6. A transport-specific symbol leaked into an SDK face.
# 7. Verifies clean sandboxes pass and report exact counts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$ROOT/tools/codegen/check-contract-purity.sh"

TMP_DIR="$(mktemp -d /tmp/purity-guard-test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

setup_clean_sandbox() {
    local target="$1"
    mkdir -p "$target/sdk"
    mkdir -p "$target/core/hop/include"
    echo "// hop.h" > "$target/sdk/hop.h"
    echo "// core hop.h" > "$target/core/hop/include/hop.h"
    local sdks=("android" "apple" "compose" "crystal" "elixir" "embedded" "flutter" "go" "node" "python" "react-native" "ruby")
    for s in "${sdks[@]}"; do
        mkdir -p "$target/sdk/$s"
        echo "// clean $s code" > "$target/sdk/$s/contract.txt"
    done
}

# 1. Test: clean sandbox passes and reports scanned targets and files
CLEAN_DIR="$TMP_DIR/clean"
setup_clean_sandbox "$CLEAN_DIR"
out="$(bash "$GUARD" --root "$CLEAN_DIR")"
if ! echo "$out" | grep -q "PASS: scanned 14 contract targets"; then
    echo "FAIL: clean sandbox did not report expected target count" >&2
    echo "$out" >&2
    exit 1
fi

# 2. Test: missing contract header fails
MISSING_HEADER="$TMP_DIR/missing_header"
setup_clean_sandbox "$MISSING_HEADER"
rm -f "$MISSING_HEADER/sdk/hop.h"
set +e
out="$(bash "$GUARD" --root "$MISSING_HEADER" 2>&1)"
code=$?
set -e
if [ "$code" -eq 0 ] || ! echo "$out" | grep -q "contract header missing"; then
    echo "FAIL: expected failure on missing contract header" >&2
    echo "$out" >&2
    exit 1
fi

# 3. Test: all targets missing fails
EMPTY_ROOT="$TMP_DIR/empty_root"
mkdir -p "$EMPTY_ROOT"
set +e
out="$(bash "$GUARD" --root "$EMPTY_ROOT" 2>&1)"
code=$?
set -e
if [ "$code" -eq 0 ]; then
    echo "FAIL: expected failure when SDK directory is missing" >&2
    echo "$out" >&2
    exit 1
fi

# 4. Test: empty contract header fails
EMPTY_HEADER="$TMP_DIR/empty_header"
setup_clean_sandbox "$EMPTY_HEADER"
: > "$EMPTY_HEADER/sdk/hop.h"
set +e
out="$(bash "$GUARD" --root "$EMPTY_HEADER" 2>&1)"
code=$?
set -e
if [ "$code" -eq 0 ] || ! echo "$out" | grep -q "contract header is empty"; then
    echo "FAIL: expected failure on empty contract header" >&2
    echo "$out" >&2
    exit 1
fi

# 5. Test: missing classified SDK directory fails
MISSING_SDK="$TMP_DIR/missing_sdk"
setup_clean_sandbox "$MISSING_SDK"
rm -rf "$MISSING_SDK/sdk/android"
set +e
out="$(bash "$GUARD" --root "$MISSING_SDK" 2>&1)"
code=$?
set -e
if [ "$code" -eq 0 ] || ! echo "$out" | grep -q "classified SDK directory missing"; then
    echo "FAIL: expected failure on missing classified SDK directory" >&2
    echo "$out" >&2
    exit 1
fi

# 6. Test: empty classified SDK directory fails
EMPTY_SDK="$TMP_DIR/empty_sdk"
setup_clean_sandbox "$EMPTY_SDK"
rm -f "$EMPTY_SDK/sdk/apple/contract.txt"
set +e
out="$(bash "$GUARD" --root "$EMPTY_SDK" 2>&1)"
code=$?
set -e
if [ "$code" -eq 0 ] || ! echo "$out" | grep -q "classified SDK directory is empty"; then
    echo "FAIL: expected failure on empty classified SDK directory" >&2
    echo "$out" >&2
    exit 1
fi

# 7. Test: unclassified new SDK directory fails
UNCLASSIFIED_SDK="$TMP_DIR/unclassified_sdk"
setup_clean_sandbox "$UNCLASSIFIED_SDK"
mkdir -p "$UNCLASSIFIED_SDK/sdk/csharp"
echo "// csharp" > "$UNCLASSIFIED_SDK/sdk/csharp/Hop.cs"
set +e
out="$(bash "$GUARD" --root "$UNCLASSIFIED_SDK" 2>&1)"
code=$?
set -e
if [ "$code" -eq 0 ] || ! echo "$out" | grep -q "unclassified SDK directory under sdk/: csharp"; then
    echo "FAIL: expected failure on unclassified SDK directory" >&2
    echo "$out" >&2
    exit 1
fi

# 8. Test: forbidden transport symbol in header fails
LEAKED_HEADER="$TMP_DIR/leaked_header"
setup_clean_sandbox "$LEAKED_HEADER"
echo "void connect(CBUUID *uuid);" >> "$LEAKED_HEADER/sdk/hop.h"
set +e
out="$(bash "$GUARD" --root "$LEAKED_HEADER" 2>&1)"
code=$?
set -e
if [ "$code" -eq 0 ] || ! echo "$out" | grep -q "transport-specific symbol leaked"; then
    echo "FAIL: expected failure on leaked symbol in header" >&2
    echo "$out" >&2
    exit 1
fi

# 9. Test: forbidden transport symbol in SDK face fails
LEAKED_SDK="$TMP_DIR/leaked_sdk"
setup_clean_sandbox "$LEAKED_SDK"
echo "import BluetoothGatt" >> "$LEAKED_SDK/sdk/android/contract.txt"
set +e
out="$(bash "$GUARD" --root "$LEAKED_SDK" 2>&1)"
code=$?
set -e
if [ "$code" -eq 0 ] || ! echo "$out" | grep -q "transport-specific symbol leaked"; then
    echo "FAIL: expected failure on leaked symbol in SDK face" >&2
    echo "$out" >&2
    exit 1
fi

# 10. Test: live repository passes cleanly
bash "$GUARD" >/dev/null

echo "check-contract-purity.test.sh: OK (all missing, empty, unclassified, leaked, and clean cases pass)"
