#!/usr/bin/env bash
# Guardrail: the contract (sdk/hop.h) and the SDK faces (Hop wrapper + bearer kit) must name NOTHING
# transport-specific — bearers are byte senders. The four bearer packages legitimately DO use these
# symbols, so they are excluded. Fails (non-zero) if a forbidden symbol leaks into the contract/SDK.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Files that form the contract + its language faces (NOT the bearer implementations).
TARGETS=(
  "$ROOT/sdk/hop.h"
  "$ROOT/core/hop-ffi/include/hop.h"
  "$ROOT/sdk/wrappers/Hop/Sources/Hop"
  "$ROOT/sdk/wrappers/kotlin/src/main/kotlin/sh/hop"
)

# Transport-specific symbols that must never appear in the contract/SDK.
FORBIDDEN='CBUUID|CBL2CAP|CBPeripheral|CBCentral|CBMutable|CLBeacon|CLLocation|CLRegion|BluetoothGatt|BluetoothSocket|NsdManager|NWConnection|NWListener|NWBrowser|MCSession|MCPeerID|MCNearby|URLSessionWebSocket|iBeacon|[^a-zA-Z_]PSM[^a-zA-Z_]|SERVICE_UUID|ENDPOINT_CHAR'

hits=0
for t in "${TARGETS[@]}"; do
  [ -e "$t" ] || continue
  if grep -rInE "$FORBIDDEN" "$t" 2>/dev/null; then
    hits=1
  fi
done

if [ "$hits" -ne 0 ]; then
  echo "FAIL: a transport-specific symbol leaked into the contract/SDK (see above)."
  exit 1
fi
echo "PASS: contract + SDK are transport-agnostic (no BLE/Wi-Fi/socket symbols)."
