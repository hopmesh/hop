#!/usr/bin/env bash
# docs-token-guard.sh (docs-drift-02): fail the build when banned tokens appear in docs
# and site copy. Runs in CI so a doc/site edit that reintroduces one of these is caught
# pre-merge instead of shipping to the public site.
#
# What it bans (in the scoped paths only):
#   1. em-dash  U+2014 : the owner's hard no-em-dash rule.
#   2. en-dash  U+2013 : same rule (no en-dash substitution either).
#   3. "InternetEgress": a Destination wire variant that was removed. Docs must not teach
#      the dead API. Lines that explicitly document its REMOVAL are allowed (see below).
#   4. "Wi-Fi Direct"  : the Android P2P bearer was removed. Positioning must not claim it
#      as a live transport. Removal notes are allowed.
#   5. bare "Bluetooth": say "BLE" (passive, no-pairing) in user-facing copy. Real API
#      identifiers (CoreBluetooth, BluetoothAdapter, BluetoothLeScanner, WebBluetooth,
#      NSBluetooth*, bluetooth-central, ...) are NOT flagged: only the standalone word.
#
# Scope: user-facing docs + site copy only. Infra .tf comments, generated headers,
# vendored/build artifacts, and platform Info.plist permission strings are NOT scanned
# (a Bluetooth permission string is a legit iOS requirement, not marketing copy).
#
# Usage:  tools/docs-token-guard.sh            # scan the default doc/site paths
#         tools/docs-token-guard.sh PATH ...   # scan explicit paths (used by tests)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Default scan set: markdown docs at the repo root + docs/, the Astro site copy, and the
# sim/ + learn/ trees. web/package.json's `sync-sim`/`sync-learn` copy ../sim and ../learn
# into web/public and pages.yml deploys web/dist, so sim/*.html and learn/*.html ship to the
# live public site and must be guarded too (web-r3-01). Vendored/build artifacts under these
# (sim/pkg, sim/sqlite-wasm, *.wasm) are already dropped by the shared `excludes` below.
# Keep this list narrow so it does not false-positive on code/comments/build output.
if [ "$#" -gt 0 ]; then
  REQUESTED=("$@")
else
  REQUESTED=(
    "DESIGN.md" "MECHANISMS.md" "README.md"
    "docs" "web/src" "sim" "learn"
  )
fi

# Keep only paths that exist, so a not-yet-created doc (e.g. a root README) does not error
# the scan. A missing default path is fine; an explicitly-passed missing path is a caller bug.
TARGETS=()
for p in "${REQUESTED[@]}"; do
  if [ -e "$p" ]; then
    TARGETS+=("$p")
  fi
done
if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "docs-token-guard: no target paths to scan"
  exit 0
fi

# Resolve a real grep binary. The interactive shell aliases `grep` to a ugrep wrapper that
# honours .gitignore (which would hide tracked-but-ignored copy from the scan), so call the
# system grep directly. GNU grep (CI/Linux) and BSD grep (macOS) both accept these flags.
GREP="$(command -v grep)"

# The two dash code points, built from hex so this script file itself stays ASCII-clean and
# can never trip its own guard.
EMDASH=$(printf '\xe2\x80\x94')   # U+2014
ENDASH=$(printf '\xe2\x80\x93')   # U+2013

# Lines that explicitly record a removal are legitimate history, not a live claim. A doc that
# says "Wi-Fi Direct was REMOVED" or "InternetEgress ... removed" must pass; a doc that lists
# either as a current transport/API must fail.
REMOVAL_CONTEXT='REMOVED|[Rr]emoved|[Nn]o longer|[Dd]eleted|[Rr]emoval'

# Escape hatch for genuinely-legit uses the heuristics can't tell apart (e.g. a competitor
# comparison table that factually names another product's Wi-Fi Direct stack). Put the marker
# "docs-token-guard: allow" on that exact line and it is exempted. Use sparingly.
ALLOW_MARKER='docs-token-guard: allow'

# Common file exclusions shared by every scan.
excludes=(
  --binary-files=without-match
  --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=.astro
  --exclude-dir=pkg --exclude-dir=pkg-node --exclude-dir=sqlite-wasm
  --exclude='*.wasm' --exclude='*.lock' --exclude='package-lock.json'
  --exclude='*.svg' --exclude='*.png' --exclude='*.jpg'
)

fail=0

# report LABEL HITS: drop any explicitly-allowed line, then on any remaining hit print an error
# block and mark failure. Called in the parent shell (not a pipeline) so the fail flag survives.
report() {
  local label="$1" hits="$2"
  hits="$(printf '%s' "$hits" | "$GREP" -vF "$ALLOW_MARKER")"
  if [ -n "$hits" ]; then
    echo "::error::banned token found in docs/site copy: $label"
    echo "$hits"
    echo
    fail=1
  fi
}

# Fixed-string scan for the two dashes: any occurrence is a violation.
report "em-dash (U+2014): rewrite with a comma, colon, parens, or two sentences" \
  "$("$GREP" -rInF "${excludes[@]}" -e "$EMDASH" -- "${TARGETS[@]}" 2>/dev/null)"
report "en-dash (U+2013): do not substitute, rewrite the sentence" \
  "$("$GREP" -rInF "${excludes[@]}" -e "$ENDASH" -- "${TARGETS[@]}" 2>/dev/null)"

# InternetEgress + Wi-Fi Direct: fixed-string match, then drop lines that document the removal.
report "InternetEgress (removed Destination wire variant): use device-addressed hops://" \
  "$("$GREP" -rInF "${excludes[@]}" -e "InternetEgress" -- "${TARGETS[@]}" 2>/dev/null | "$GREP" -Ev "$REMOVAL_CONTEXT")"
report "Wi-Fi Direct (removed Android P2P bearer): Android-to-Android falls back to BLE" \
  "$("$GREP" -rInF "${excludes[@]}" -e "Wi-Fi Direct" -- "${TARGETS[@]}" 2>/dev/null | "$GREP" -Ev "$REMOVAL_CONTEXT")"

# Bluetooth: only the bare marketing word. Word-match, then drop real API identifiers where
# "Bluetooth" is glued to another alnum token (CoreBluetooth, BluetoothAdapter, WebBluetooth,
# bluetooth-central, NSBluetooth*, bluetoothd, ...). An alnum on either side means identifier.
report "bare Bluetooth (say BLE in user-facing copy)" \
  "$("$GREP" -rInw "${excludes[@]}" -e "Bluetooth" -- "${TARGETS[@]}" 2>/dev/null | "$GREP" -Ev '[[:alnum:]]Bluetooth|Bluetooth[[:alnum:]]|Bluetooth[Ll]e|bluetooth-|bluetoothd|NSBluetooth')"

if [ "$fail" -ne 0 ]; then
  echo "docs-token-guard: FAIL (see errors above)"
  exit 1
fi
echo "docs-token-guard: OK (no banned tokens in ${TARGETS[*]})"
