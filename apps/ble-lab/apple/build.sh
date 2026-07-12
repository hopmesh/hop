#!/usr/bin/env bash
# Build HopBleLab — the canonical dual-role BLE "proof of pipe" macOS CLI (ble-lab/SPEC.md §8).
# Pure CoreBluetooth: NO Rust / hop-ffi. Modeled on apple/hopmac/build.sh's swiftc invocation.
#
# Produces a runnable, self-describing binary `blepeer` with an embedded Info.plist
# (NSBluetoothAlwaysUsageDescription) so macOS TCC can grant Bluetooth on first run from Terminal.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/blepeer"

echo "▸ compiling HopBleLab (pure CoreBluetooth, no Rust)"
swiftc -O \
  -swift-version 5 \
  "$DIR/HopBleLab.swift" \
  "$DIR/main.swift" \
  -framework CoreBluetooth -framework Security \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$DIR/Info.plist" \
  -o "$OUT"

echo "✓ built $OUT"
echo "  run it from Terminal (grant Bluetooth on first launch):  $OUT"
echo "  grep the logs:  $OUT 2>&1 | grep -E 'HOPLAB|PROOF|LINK UP|LINK CLOSED|DEDUP|STATUS|counter gap'"
