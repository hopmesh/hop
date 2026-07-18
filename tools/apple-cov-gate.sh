#!/usr/bin/env bash
# Run a Swift package's tests WITH coverage and gate LINE coverage at a floor. Used by the apple CI job so
# the bearer integration tests are not just computed on the side but actually GATE the build: the LAN/Relay
# bearers regressed to ~10% line coverage precisely because their tests never ran in CI and only re-modeled
# the logic. `swift test` also builds, so this doubles as the package build gate.
#
# Two modes:
#   Single file:  apple-cov-gate.sh <package-path> <source-file-suffix> <floor-percent>
#     e.g. apple-cov-gate.sh bearers/apple/HopBearerLan Sources/HopBearerLan/LanBearer.swift 80
#   Aggregate:    apple-cov-gate.sh <package-path> <label> <floor-percent> <exclude-regex>
#     Gates the aggregate line coverage across ALL of the package's Sources files whose path does NOT match
#     <exclude-regex>. Used by the BLE bearer, whose testable surface is spread over BleBearer.swift +
#     CentralCore.swift + PeripheralCore.swift while the CoreBluetooth glue (BleBearer+Radio.swift, which
#     cannot run headlessly) and the CoreLocation wake (BeaconWake.swift) are excluded from the denominator.
#     e.g. apple-cov-gate.sh bearers/apple/HopBearerBle "BLE cores" 80 'BleBearer\+Radio\.swift|BeaconWake\.swift'
set -euo pipefail

PKG="$1"; SRC="$2"; FLOOR="$3"; EXCLUDE="${4:-}"
cd "$PKG"

swift test --enable-code-coverage

BIN=$(swift build --show-bin-path)
XCTESTS=("$BIN"/*.xctest)
XCTEST="${XCTESTS[0]}"
[ -d "$XCTEST" ] || { echo "FAIL: no .xctest bundle found under $BIN"; exit 1; }
BINARY="$XCTEST/Contents/MacOS/$(basename "$XCTEST" .xctest)"
PROFDATA="$BIN/codecov/default.profdata"

PCT=$(xcrun llvm-cov export -summary-only -instr-profile "$PROFDATA" "$BINARY" \
  | python3 -c "
import json,sys,re,os
sub=sys.argv[1]; exclude=sys.argv[2]
d=json.load(sys.stdin)
files=d['data'][0]['files']
if exclude:
    # Aggregate line coverage across THIS package's own Sources files (scoped to \$PWD/Sources so a
    # dependency's Sources, e.g. HopContract, never dilutes the denominator) that do NOT match the
    # exclude regex.
    srcroot=os.path.join(os.getcwd(),'Sources')+os.sep
    rx=re.compile(exclude)
    cov=tot=0
    for f in files:
        fn=f['filename']
        if not fn.startswith(srcroot) or rx.search(fn): continue
        s=f['summary']['lines']; cov+=s['covered']; tot+=s['count']
    print(round(100.0*cov/tot,2) if tot else -1)
else:
    # Single-file line coverage.
    for f in files:
        if f['filename'].endswith(sub):
            print(f['summary']['lines']['percent']); break
    else:
        print('-1')
" "$SRC" "$EXCLUDE")

if [ -n "$EXCLUDE" ]; then
  echo "aggregate line coverage of [${SRC}] (excluding /${EXCLUDE}/) = ${PCT}% (floor ${FLOOR}%)"
else
  echo "line coverage of ${SRC} = ${PCT}% (floor ${FLOOR}%)"
fi
awk -v p="$PCT" -v f="$FLOOR" 'BEGIN { exit (p+0 >= f+0) ? 0 : 1 }' \
  || { echo "FAIL: ${SRC} line coverage ${PCT}% is below the ${FLOOR}% floor"; exit 1; }
echo "PASS: coverage gate satisfied for ${SRC}"
