#!/usr/bin/env bash
# Guardrail: the contract (sdk/hop.h) and the SDK faces (Hop wrapper + bearer kit) must name NOTHING
# transport-specific: bearers are byte senders. The four bearer packages legitimately DO use these
# symbols, so they are excluded. Fails (non-zero) if a forbidden symbol leaks into the contract/SDK.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ "${1:-}" = "--root" ]; then
    ROOT="$2"
    shift 2
fi

cd "$ROOT"

# Contract headers
CONTRACT_HEADERS=(
  "sdk/hop.h"
  "core/hop/include/hop.h"
)

# Classified SDK language faces (bidirectional completeness verified against sdk/* subdirectories)
CLASSIFIED_SDKS=(
  "android"
  "apple"
  "compose"
  "crystal"
  "elixir"
  "embedded"
  "flutter"
  "go"
  "node"
  "python"
  "react-native"
  "ruby"
)

# 1. Verify bidirectional SDK discovery: every directory under sdk/ must be classified,
# and every classified SDK must exist under sdk/.
SDK_DIR="sdk"
if [ ! -d "$SDK_DIR" ]; then
    echo "FAIL: SDK directory not found: $SDK_DIR" >&2
    exit 1
fi

discovered_sdks=()
while IFS= read -r d; do
    [ -n "$d" ] || continue
    name="$(basename "$d")"
    case "$name" in
        .*|build|Frameworks) continue ;;
        *) discovered_sdks+=("$name") ;;
    esac
done < <(find "$SDK_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

# Check for unclassified SDK directories
for d in "${discovered_sdks[@]}"; do
    classified=0
    for c in "${CLASSIFIED_SDKS[@]}"; do
        if [ "$d" = "$c" ]; then
            classified=1
            break
        fi
    done
    if [ "$classified" -eq 0 ]; then
        echo "FAIL: unclassified SDK directory under sdk/: $d (all SDK faces must be classified)" >&2
        exit 1
    fi
done

# Check that every classified SDK directory exists
for c in "${CLASSIFIED_SDKS[@]}"; do
    target_dir="$SDK_DIR/$c"
    if [ ! -d "$target_dir" ]; then
        echo "FAIL: classified SDK directory missing: $target_dir" >&2
        exit 1
    fi
    # Must be non-empty (contain at least one file)
    if [ -z "$(find "$target_dir" -type f 2>/dev/null | head -n 1)" ]; then
        echo "FAIL: classified SDK directory is empty: $target_dir" >&2
        exit 1
    fi
done

# 2. Check contract headers exist and are non-empty
for h in "${CONTRACT_HEADERS[@]}"; do
    if [ ! -f "$h" ]; then
        echo "FAIL: contract header missing: $h" >&2
        exit 1
    fi
    if [ ! -s "$h" ]; then
        echo "FAIL: contract header is empty: $h" >&2
        exit 1
    fi
done

# 3. Transport-specific symbols that must never appear in the contract/SDK.
FORBIDDEN='CBUUID|CBL2CAP|CBPeripheral|CBCentral|CBMutable|CLBeacon|CLLocation|CLRegion|BluetoothGatt|BluetoothSocket|NsdManager|NWConnection|NWListener|NWBrowser|MCSession|MCPeerID|MCNearby|URLSessionWebSocket|iBeacon|[^a-zA-Z_]PSM[^a-zA-Z_]|SERVICE_UUID|ENDPOINT_CHAR'

hits=0
scanned_files=0
scanned_targets=0

# Scan contract headers
for h in "${CONTRACT_HEADERS[@]}"; do
    scanned_targets=$((scanned_targets + 1))
    scanned_files=$((scanned_files + 1))
    if grep -rInE "$FORBIDDEN" "$h" 2>/dev/null; then
        hits=1
    fi
done

# Scan classified SDK directories (excluding build outputs, hidden dirs, node_modules)
for c in "${CLASSIFIED_SDKS[@]}"; do
    target_dir="$SDK_DIR/$c"
    scanned_targets=$((scanned_targets + 1))
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        scanned_files=$((scanned_files + 1))
        if grep -InE "$FORBIDDEN" "$f" 2>/dev/null; then
            hits=1
        fi
    done < <(find "$target_dir" -type f \
        -not -path '*/.*' \
        -not -path '*/build/*' \
        -not -path '*/target/*' \
        -not -path '*/node_modules/*' \
        -not -path '*/vendor/*' \
        -not -path '*/.build/*' \
        -not -name '*.png' \
        -not -name '*.wasm' \
        -not -name '*.lock' \
        -not -name '*.a' \
        2>/dev/null | sort)
done

if [ "$hits" -ne 0 ]; then
    echo "FAIL: a transport-specific symbol leaked into the contract/SDK (see above)." >&2
    exit 1
fi

echo "PASS: scanned $scanned_targets contract targets ($scanned_files files) across ${#CLASSIFIED_SDKS[@]} SDKs - transport-agnostic (no BLE/Wi-Fi/socket symbols)."
