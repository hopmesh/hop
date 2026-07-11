#!/usr/bin/env bash
# Run a Swift package's tests WITH coverage and gate one source file's LINE coverage at a floor. Used by
# the apple CI job so the bearer integration tests are not just computed on the side but actually GATE the
# build: the LAN/Relay bearers regressed to ~10% line coverage precisely because their tests never ran in
# CI and only re-modeled the logic. `swift test` also builds, so this doubles as the package build gate.
#
# Usage: apple-cov-gate.sh <package-path> <source-file-suffix> <floor-percent>
#   e.g. apple-cov-gate.sh bearers/apple/HopBearerLan Sources/HopBearerLan/LanBearer.swift 80
set -euo pipefail

PKG="$1"; SRC="$2"; FLOOR="$3"
cd "$PKG"

swift test --enable-code-coverage

BIN=$(swift build --show-bin-path)
XCTEST=$(ls -d "$BIN"/*.xctest | head -1)
BINARY="$XCTEST/Contents/MacOS/$(basename "$XCTEST" .xctest)"
PROFDATA="$BIN/codecov/default.profdata"

PCT=$(xcrun llvm-cov export -summary-only -instr-profile "$PROFDATA" "$BINARY" \
  | python3 -c "
import json,sys
sub=sys.argv[1]
d=json.load(sys.stdin)
for f in d['data'][0]['files']:
    if f['filename'].endswith(sub):
        print(f['summary']['lines']['percent']); break
else:
    print('-1')
" "$SRC")

echo "line coverage of ${SRC} = ${PCT}% (floor ${FLOOR}%)"
awk -v p="$PCT" -v f="$FLOOR" 'BEGIN { exit (p+0 >= f+0) ? 0 : 1 }' \
  || { echo "FAIL: ${SRC} line coverage ${PCT}% is below the ${FLOOR}% floor"; exit 1; }
echo "PASS: coverage gate satisfied for ${SRC}"
