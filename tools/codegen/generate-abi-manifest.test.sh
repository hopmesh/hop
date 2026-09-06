#!/usr/bin/env bash
# Self-test for tools/codegen/generate-abi-manifest.py (ABI-016).
# Proves that:
# 1. Generator self-test asserts uintptr_t signed:false and intptr_t signed:true.
# 2. Generator --check passes on the current tree.
# 3. Generator --check fails when header and manifest drift.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

# 1. Run internal self-test
python3 "$HERE/generate-abi-manifest.py" --self-test

# 2. Verify current tree
python3 "$HERE/generate-abi-manifest.py" --check

# 3. Drift test in a temporary sandbox
TMP_DIR="$(mktemp -d /tmp/abi-manifest-test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

python3 "$HERE/generate-abi-manifest.py" "$ROOT/sdk/hop.h" "$TMP_DIR/abi-manifest.json" >/dev/null

# Create drifted header by inserting a new function before the closing extern "C"
sed 's/}  \/\/ extern "C"/uintptr_t hop_drift_func(void);\n&/' "$ROOT/sdk/hop.h" > "$TMP_DIR/hop.h"

if python3 "$HERE/generate-abi-manifest.py" --check "$TMP_DIR/hop.h" "$TMP_DIR/abi-manifest.json" >/dev/null 2>&1; then
    echo "::error:: generate-abi-manifest --check should have failed on drifted header"
    exit 1
fi

echo "generate-abi-manifest.test.sh: OK (all self-test, sync, and drift cases pass)"
