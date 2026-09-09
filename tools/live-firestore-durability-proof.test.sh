#!/usr/bin/env bash
# tools/live-firestore-durability-proof.test.sh
# Self-test for tools/live-firestore-durability-proof.py.
# Runs in offline mock mode to prove:
# 1. Clean run verifies all 5 durability claims and exits 0.
# 2. Injected probe failure is detected and exits non-zero.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/live-firestore-durability-proof.py"

echo "=== Testing live-firestore-durability-proof.py (positive mock) ==="
python3 "$SCRIPT" --mock >/dev/null

echo "=== Testing live-firestore-durability-proof.py (injected failure) ==="
if python3 "$SCRIPT" --mock-fail >/dev/null 2>&1; then
  echo "FAIL: expected --mock-fail to exit non-zero" >&2
  exit 1
fi

echo "live-firestore-durability-proof.test.sh: OK"
