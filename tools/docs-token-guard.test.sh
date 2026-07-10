#!/usr/bin/env bash
# Self-test for tools/docs-token-guard.sh. Runs the guard against synthetic fixtures and asserts
# it (a) flags real violations, (b) passes clean copy, and (c) does NOT false-positive on legit
# API identifiers or documented removal notes. No network, no repo state.
#   run: bash tools/docs-token-guard.sh.test.sh  (or tools/docs-token-guard.test.sh)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/docs-token-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# expect_pass FILE: the guard must exit 0 for this fixture.
expect_pass() {
  if "$GUARD" "$1" >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL: expected clean, guard flagged $1"
    "$GUARD" "$1" 2>&1 | sed 's/^/    /'
  fi
}

# expect_fail FILE: the guard must exit non-zero for this fixture.
expect_fail() {
  if "$GUARD" "$1" >/dev/null 2>&1; then
    fail=$((fail + 1)); echo "FAIL: expected a violation, guard passed $1"
  else
    pass=$((pass + 1))
  fi
}

# --- clean copy: must pass ---
printf 'Hop rides BLE and LAN. Address a payload to another device or hops://.\n' > "$TMP/clean.md"
expect_pass "$TMP/clean.md"

# --- legit API identifiers: must pass (not the bare marketing word) ---
printf 'Drives BLE via CoreBluetooth.\nUses BluetoothAdapter and BluetoothLeScanner.\nWebBluetooth is central-only.\nUIBackgroundModes: bluetooth-central.\n' > "$TMP/apis.md"
expect_pass "$TMP/apis.md"

# --- documented removal notes: must pass ---
printf 'Wi-Fi Direct was REMOVED (commit c059d69).\nInternetEgress is no longer a destination; egress is device-addressed.\n' > "$TMP/removed.md"
expect_pass "$TMP/removed.md"

# --- bare Bluetooth marketing word: must fail ---
printf 'Chat over Bluetooth with people nearby.\n' > "$TMP/bt.md"
expect_fail "$TMP/bt.md"

# --- present-tense removed API: must fail ---
printf 'Send to Destination::InternetEgress to reach the internet.\n' > "$TMP/egress.md"
expect_fail "$TMP/egress.md"

# --- Wi-Fi Direct claimed as a live transport: must fail ---
printf 'Android-to-Android uses Wi-Fi Direct for high-bandwidth transfer.\n' > "$TMP/wfd.md"
expect_fail "$TMP/wfd.md"

# --- explicitly-allowed legit use (competitor comparison): must pass ---
printf '| Bridgefy | messaging | BLE + Wi-Fi Direct mesh |  <!-- docs-token-guard: allow -->\n' > "$TMP/allow.md"
expect_pass "$TMP/allow.md"

# --- em-dash: must fail (built from bytes so this test file stays ASCII-clean) ---
printf 'Hop is fast%buntraceable by default.\n' "$(printf '\xe2\x80\x94')" > "$TMP/em.md"
expect_fail "$TMP/em.md"

# --- en-dash: must fail ---
printf 'See sections 5%b7 for the wire format.\n' "$(printf '\xe2\x80\x93')" > "$TMP/en.md"
expect_fail "$TMP/en.md"

echo "docs-token-guard.test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
