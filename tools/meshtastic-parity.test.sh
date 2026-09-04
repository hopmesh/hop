#!/usr/bin/env bash
# Self-test for tools/meshtastic-parity.sh. Drives the guard against synthetic Swift/Kotlin/vector
# fixtures and asserts it flags every drift shape it exists to catch. A guard that cannot fail reads as
# coverage while checking nothing.
#   run: bash tools/meshtastic-parity.test.sh
# No network, no repo state.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/meshtastic-parity.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

write_vectors() {
  local out="$1" port="${2:-260}" chunk="${3:-200}" ping="${4:-30000}" dead="${5:-180000}"
  python3 - "$out" "$port" "$chunk" "$ping" "$dead" <<'PY'
import json, sys
out, port, chunk, ping, dead = sys.argv[1], *[int(a) for a in sys.argv[2:6]]
lens = [0, 1, 200, 201, 400, 401, 1000]
vecs = [{"len": n, "frags": 1 if n == 0 else (n + chunk - 1) // chunk} for n in lens]
json.dump({
    "hop_portnum": port, "admin_portnum": 6, "routing_portnum": 5,
    "hop_channel_name": "Hop",
    "hop_channel_psk_hex": "686f702e6d6573682e70736b2e763121",
    "hop_channel_id": 1213157425,
    "hop_channel_role_secondary": 2,
    "hop_max_channels": 8,
    "max_chunk": chunk, "frag_header": 4, "max_frags": 255,
    "frames": {"hello": 1, "ping": 2, "pong": 3, "ack": 4, "data": 16},
    "ping_ms": ping, "dead_ms": dead,
    "spray_initial_ms": 2000, "spray_multiplier": 2, "spray_cap_ms": 60000,
    "spray_tick_ms": 1000, "spray_max_outstanding": 8,
    "fragment_vectors": vecs,
}, open(out, "w"), indent=2)
PY
}

write_swift() {
  local out="$1" port="${2:-260}" chunk="${3:-200}" data="${4:-0x10}" ping="${5:-30.0}" dead="${6:-180.0}"
  cat > "$out" <<EOF
import Foundation
let MESH_HOP_PORTNUM: UInt32 = ${port}
let MESH_ADMIN_PORTNUM: UInt32 = 6
let MESH_ROUTING_PORTNUM: UInt32 = 5
let MESH_HOP_CHANNEL_NAME = "Hop"
let MESH_HOP_CHANNEL_PSK_HEX = "686f702e6d6573682e70736b2e763121"
let MESH_HOP_CHANNEL_ID: UInt32 = 0x484F5031
let MESH_CHANNEL_ROLE_SECONDARY = 2
let MESH_MAX_CHANNELS = 8
let MESH_MAX_CHUNK = ${chunk}
let MESH_FRAG_HEADER = 4
let MESH_MAX_FRAGS = 255
let M_HELLO: UInt8 = 0x01
let M_PING: UInt8 = 0x02
let M_PONG: UInt8 = 0x03
let M_ACK: UInt8 = 0x04
let M_DATA: UInt8 = ${data}
let MESH_PING_S: Double = ${ping}
let MESH_DEAD_S: Double = ${dead}
let MESH_SPRAY_INITIAL_S: Double = 2.0
let MESH_SPRAY_MULTIPLIER = 2
let MESH_SPRAY_CAP_S: Double = 60.0
let MESH_SPRAY_TICK_S: Double = 1.0
let MESH_SPRAY_MAX_OUTSTANDING = 8
EOF
}

write_kotlin() {
  local out="$1" port="${2:-260}" chunk="${3:-200}" ping="${4:-30_000}" dead="${5:-180_000}"
  cat > "$out" <<EOF
package sh.hopme.bearers.meshtastic
internal const val MESH_HOP_PORTNUM = ${port}
internal const val MESH_ADMIN_PORTNUM = 6
internal const val MESH_ROUTING_PORTNUM = 5
internal const val MESH_HOP_CHANNEL_NAME = "Hop"
internal const val MESH_HOP_CHANNEL_PSK_HEX = "686f702e6d6573682e70736b2e763121"
internal const val MESH_HOP_CHANNEL_ID = 0x484F5031L
internal const val MESH_CHANNEL_ROLE_SECONDARY = 2
internal const val MESH_MAX_CHANNELS = 8
internal const val MESH_MAX_CHUNK = ${chunk}
internal const val MESH_FRAG_HEADER = 4
internal const val MESH_MAX_FRAGS = 255
internal const val M_HELLO = 0x01
internal const val M_PING = 0x02
internal const val M_PONG = 0x03
internal const val M_ACK = 0x04
internal const val M_DATA = 0x10
internal const val MESH_PING_MS = ${ping}L
internal const val MESH_DEAD_MS = ${dead}L
internal const val MESH_SPRAY_INITIAL_MS = 2_000L
internal const val MESH_SPRAY_MULTIPLIER = 2
internal const val MESH_SPRAY_CAP_MS = 60_000L
internal const val MESH_SPRAY_TICK_MS = 1_000L
internal const val MESH_SPRAY_MAX_OUTSTANDING = 8
EOF
}

run_guard() {
  MESH_VECTORS="$TMP/v.json" MESH_SWIFT="$TMP/W.swift" MESH_KOTLIN="$TMP/W.kt" \
    "$GUARD" >/dev/null 2>&1
}

expect_pass() {
  if run_guard; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: expected clean, guard flagged: $1"
  fi
}

expect_fail() {
  if run_guard; then
    fail=$((fail + 1)); echo "FAIL: expected a violation, guard passed: $1"
  else pass=$((pass + 1)); fi
}

# --- baseline: the real contract, in agreement -------------------------------
write_vectors "$TMP/v.json"; write_swift "$TMP/W.swift"; write_kotlin "$TMP/W.kt"
expect_pass "matching apple + android constants"

# --- each constant, independently -------------------------------------------
write_swift "$TMP/W.swift" "261"
expect_fail "swift hop_portnum drifted"
write_swift "$TMP/W.swift"

write_kotlin "$TMP/W.kt" "260" "199"
expect_fail "kotlin max_chunk drifted"
write_kotlin "$TMP/W.kt"

write_swift "$TMP/W.swift" "260" "200" "0x11"
expect_fail "swift DATA frame tag drifted"
write_swift "$TMP/W.swift"

# --- unit confusion: seconds vs milliseconds --------------------------------
write_swift "$TMP/W.swift" "260" "200" "0x10" "30000.0"
expect_fail "swift keepalive left in milliseconds"
write_swift "$TMP/W.swift"

write_kotlin "$TMP/W.kt" "260" "200" "45_000"
expect_fail "kotlin ping cadence drifted"
write_kotlin "$TMP/W.kt"

# --- a missing constant must fail, never silently skip -----------------------
printf 'package sh.hopme.bearers.meshtastic\n// wire removed\n' > "$TMP/W.kt"
expect_fail "kotlin constant deleted entirely"
write_kotlin "$TMP/W.kt"

# --- decision point: the port must stay in the PRIVATE_APP range -------------
# All three agree on a first-party port (< 256): the numbers match but the CHOICE is wrong.
write_vectors "$TMP/v.json" "100"; write_swift "$TMP/W.swift" "100"; write_kotlin "$TMP/W.kt" "100"
expect_fail "hop_portnum moved out of the PRIVATE_APP range even though all three agree"
write_vectors "$TMP/v.json"; write_swift "$TMP/W.swift"; write_kotlin "$TMP/W.kt"

# --- the fragment table must follow from max_chunk ---------------------------
python3 - "$TMP/v.json" <<'PY'
import json, sys
p = sys.argv[1]; doc = json.load(open(p))
doc["fragment_vectors"][3]["frags"] = 9   # len=201 with chunk=200 is 2, not 9
json.dump(doc, open(p, "w"), indent=2)
PY
expect_fail "fragment vector table inconsistent with max_chunk"
write_vectors "$TMP/v.json"

# --- both platforms changing TOGETHER is a legitimate contract change --------
# A real change edits all three, including recomputing the fragment vectors from the new chunk size.
write_vectors "$TMP/v.json" "260" "100"; write_swift "$TMP/W.swift" "260" "100"; write_kotlin "$TMP/W.kt" "260" "100"
expect_pass "an intentional max_chunk change updated in all three places"

echo "meshtastic-parity.test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
