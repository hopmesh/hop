#!/usr/bin/env bash
# Build HopMac — a headless macOS Hop node with a BLE-central bearer for cross-platform BLE testing.
# Links the real hop-core (hop-ffi) + the generated Swift bindings + a CoreBluetooth L2CAP bearer.
set -euo pipefail
cd "$(dirname "$0")/.."          # repo/apple
ROOT="$(cd .. && pwd)"           # repo root

echo "▸ building hop-ffi for macOS (host)"
( cd "$ROOT" && cargo build -p hop-ffi --release )

echo "▸ compiling HopMac"
swiftc -O \
  -I "$ROOT/apple/generated/Headers" \
  "$ROOT/apple/generated/Sources/hop_ffi.swift" \
  "$ROOT/apple/hopmac/main.swift" \
  -L "$ROOT/target/release" -lhop_ffi \
  -framework CoreBluetooth -framework Security -framework SystemConfiguration -framework CoreFoundation \
  -o "$ROOT/apple/hopmac/hopmac"

echo "✓ built apple/hopmac/hopmac — run it from Terminal (needs Bluetooth permission)"
