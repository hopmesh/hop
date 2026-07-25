#!/usr/bin/env bash
# Self-test for tools/ble-backoff-parity.sh. Drives the guard against synthetic Swift/Kotlin/vector
# fixtures and asserts it flags every drift shape it exists to catch. A guard that cannot fail is
# worse than no guard, because it reads as coverage.
#   run: bash tools/ble-backoff-parity.test.sh
# No network, no repo state.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/ble-backoff-parity.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# Canonical fixtures, regenerated per case so each test mutates exactly one thing.
write_vectors() {
  local out="$1" base="${2:-2000}" cap="${3:-30000}" qafter="${4:-6}" qms="${5:-120000}"
  python3 - "$out" "$base" "$cap" "$qafter" "$qms" <<'PY'
import json, sys
out, base, cap, qafter, qms = sys.argv[1], *[int(a) for a in sys.argv[2:6]]
rows = []
for n in range(1, 13):
    exp = base << min(max(n - 1, 0), 20)
    rows.append({"fail_count": n, "backoff_ms": min(exp, qms if n >= qafter else cap)})
json.dump({"base_ms": base, "max_ms": cap, "quarantine_after": qafter,
           "quarantine_ms": qms, "reset_on": "hello_complete", "vectors": rows},
          open(out, "w"), indent=2)
PY
}

write_kotlin() {
  local out="$1" base="${2:-2_000}" cap="${3:-30_000}" qafter="${4:-6}" qms="${5:-120_000}"
  cat > "$out" <<EOF
package sh.hopme.bearers.ble
internal const val BACKOFF_BASE_MS = ${base}L
internal const val BACKOFF_MAX_MS = ${cap}L
internal const val BACKOFF_QUARANTINE_AFTER = ${qafter}
internal const val BACKOFF_QUARANTINE_MS = ${qms}L
EOF
}

write_swift() {
  local out="$1" base="${2:-2.0}" cap="${3:-30.0}" qafter="${4:-6}" qms="${5:-120.0}"
  cat > "$out" <<EOF
import Foundation
let BACKOFF_BASE_S: Double = ${base}
let BACKOFF_MAX_S: Double = ${cap}
let BACKOFF_QUARANTINE_AFTER: Int = ${qafter}
let BACKOFF_QUARANTINE_S: Double = ${qms}
let MAX_FRAME = 1 << ${6:-20}
EOF
}

# The reset-point check derives two sibling paths from the ones we pass in, so the fixtures must
# provide them: CentralCore.swift beside B.swift, and BleBearer.kt beside D.kt.
write_reset_fixtures() {
  local opened_clears="${1:-no}" hello_clears="${2:-yes}" kotlin_hello="${3:-yes}"
  {
    echo 'final class CentralCore {'
    echo '    func channelOpened(_ id: UUID) -> [CentralEffect] {'
    [ "$opened_clears" = yes ] && echo '        failCount[key] = nil'
    echo '        return [.cancelDialTimeout(id)]'
    echo '    }'
    echo '    func dialerLinkUp(_ id: UUID) -> [CentralEffect] {'
    [ "$hello_clears" = yes ] && echo '        failCount[key] = nil'
    echo '        return []'
    echo '    }'
    echo '}'
  } > "$TMP/CentralCore.swift"
  {
    echo 'class BleBearer {'
    echo "internal const val MAX_FRAME_BYTES = 1 shl ${4:-20}"
    echo '    private fun dialerLinkUp(addr: String) {'
    [ "$kotlin_hello" = yes ] && echo '        synchronized(dial) { dialState.succeededForAddr(addr) }'
    echo '    }'
    echo '}'
  } > "$TMP/BleBearer.kt"
}

run_guard() {
  BLE_BACKOFF_VECTORS="$TMP/v.json" BLE_BACKOFF_KOTLIN="$TMP/D.kt" BLE_BACKOFF_SWIFT="$TMP/B.swift" \
  BLE_BACKOFF_SWIFT_CORE="$TMP/CentralCore.swift" BLE_BACKOFF_KOTLIN_BEARER="$TMP/BleBearer.kt" \
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

# --- baseline: the real schedule, in agreement -------------------------------
write_vectors "$TMP/v.json"; write_kotlin "$TMP/D.kt"; write_swift "$TMP/B.swift"
write_reset_fixtures
expect_pass "matching apple + android constants"

# --- the exact drift that shipped: Apple's base disagreeing -------------------
write_swift "$TMP/B.swift" "0.5"
expect_fail "swift base drifted (the delta-based 0.5s floor that actually shipped)"
write_swift "$TMP/B.swift"

# --- unit confusion: seconds vs milliseconds ---------------------------------
# Comparing raw numbers rather than scaling would let a schedule 1000x too fast pass.
write_swift "$TMP/B.swift" "2000.0"
expect_fail "swift constants left in milliseconds"
write_swift "$TMP/B.swift"

# --- each constant, independently -------------------------------------------
write_kotlin "$TMP/D.kt" "2_000" "45_000"
expect_fail "kotlin cap drifted"
write_kotlin "$TMP/D.kt"

write_kotlin "$TMP/D.kt" "2_000" "30_000" "3"
expect_fail "kotlin quarantine threshold drifted"
write_kotlin "$TMP/D.kt"

write_swift "$TMP/B.swift" "2.0" "30.0" "6" "60.0"
expect_fail "swift quarantine duration drifted"
write_swift "$TMP/B.swift"

# --- a missing constant must fail, never silently skip -----------------------
printf 'package sh.hopme.bearers.ble\n// backoff removed\n' > "$TMP/D.kt"
expect_fail "kotlin constant deleted entirely"
write_kotlin "$TMP/D.kt"

# --- the vector table must describe its own declared constants ---------------
python3 - "$TMP/v.json" <<'PY'
import json, sys
p = sys.argv[1]
doc = json.load(open(p))
doc["vectors"][0]["backoff_ms"] = 999   # a hand-edited table that no longer matches base_ms
json.dump(doc, open(p, "w"), indent=2)
PY
expect_fail "vector table internally inconsistent with its constants"
write_vectors "$TMP/v.json"

# --- both platforms drifting TOGETHER is a legitimate schedule change --------
# The guard pins agreement against the vectors, so a real change edits all three.
write_vectors "$TMP/v.json" "5000"; write_kotlin "$TMP/D.kt" "5_000"; write_swift "$TMP/B.swift" "5.0"
expect_pass "an intentional schedule change updated in all three places"

# --- reset point: the defect constants alone could never catch ------------------------------------
# Apple cleared the failure state at L2CAP-open while Android cleared it at HELLO-complete, so a peer
# that accepted a channel and never said HELLO had its count cleared every cycle and could never be
# quarantined. Every constant matched throughout, so only a structural check finds this.
write_vectors "$TMP/v.json"; write_kotlin "$TMP/D.kt"; write_swift "$TMP/B.swift"

write_reset_fixtures yes yes yes
expect_fail "swift clears the failure state at L2CAP-open (the regression that shipped)"

write_reset_fixtures no no yes
expect_fail "swift has no HELLO-complete reset at all"

write_reset_fixtures no yes no
expect_fail "kotlin dialerLinkUp stopped clearing the failure state"

write_reset_fixtures no yes yes
expect_pass "reset at HELLO-complete on both platforms"

# A guard that skips when a key is missing is a guard that reads as coverage and checks nothing.
python3 - "$TMP/v.json" <<'PY2'
import json, sys
p = sys.argv[1]; doc = json.load(open(p)); doc.pop("reset_on", None)
json.dump(doc, open(p, "w"), indent=2)
PY2
expect_fail "a MISSING reset_on must fail closed, not silently skip the check"
write_vectors "$TMP/v.json"

python3 - "$TMP/v.json" <<'PY2'
import json, sys
p = sys.argv[1]; doc = json.load(open(p)); doc["reset_on"] = "l2cap_open"
json.dump(doc, open(p, "w"), indent=2)
PY2
expect_fail "an UNKNOWN reset_on must fail rather than be assumed benign"
write_vectors "$TMP/v.json"

# --- frame cap: BLE drifted to 4x the protocol cap on the most exposed transport ----------------
write_swift "$TMP/B.swift" "2.0" "30.0" "6" "120.0" "22"
expect_fail "swift MAX_FRAME drifted above the protocol cap (the 4 MiB that shipped)"
write_swift "$TMP/B.swift"

write_reset_fixtures no yes yes 22
expect_fail "kotlin MAX_FRAME_BYTES drifted above the protocol cap"
write_reset_fixtures

echo "ble-backoff-parity.test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
