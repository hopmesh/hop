#!/usr/bin/env bash
# Self-test for tools/codegen/verify-abi-signatures.py (ABI-016).
# Proves that:
# 1. An unsigned binding for hop_hps_rekey is rejected.
# 2. A void-returning service request sink is rejected.
# 3. A wrong-width integer is rejected.
# 4. Callback parameter count mismatch is rejected.
# 5. Callback argument pointer shape mismatch is rejected.
# 6. All 9 wrappers in the repository pass verification.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

# Run internal unit tests on mock wrappers
python3 "$HERE/verify-abi-signatures.py" --self-test "$ROOT/tools/codegen/abi-manifest.json"

# Run end-to-end verification on all 9 wrapper surfaces
SURFACES=(
  "sdk/apple/Sources"
  "sdk/android/src/main"
  "sdk/embedded/src"
  "sdk/go"
  "sdk/node/lib"
  "sdk/python/hop_endpoint"
  "sdk/ruby/lib"
  "sdk/crystal/src"
  "sdk/flutter/lib"
)

MANIFEST="$ROOT/tools/codegen/abi-manifest.json"

for surface in "${SURFACES[@]}"; do
  python3 "$HERE/verify-abi-signatures.py" "$MANIFEST" "$ROOT/$surface" >/dev/null
done

echo "verify-abi-signatures.test.sh: OK (all rejection cases and 9 wrapper surfaces pass)"
