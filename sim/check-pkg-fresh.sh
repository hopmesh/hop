#!/usr/bin/env bash
# Freshness/drift check for the committed sim/pkg wasm build.
#
# sim/pkg/ is a committed BUILD OUTPUT of core/hop-wasm (see build-wasm.sh + PKG-PROVENANCE.md). If someone
# changes hop-core's wire format or the hop-wasm surface but forgets to rebuild, the committed sim would
# silently speak an OLDER protocol than the code beside it, and the homepage's "your browser is running
# the real Hop protocol" claim would quietly become false.
#
# This rebuilds core/hop-wasm --target web into a temp dir and compares the wasm-bindgen INTERFACE
# (hop_wasm.d.ts + the JS glue) against the committed copy. The interface is deterministic across builds
# (unlike the optimized .wasm binary, whose bytes vary run-to-run), so a diff here means the committed
# pkg is stale. Wire it into CI (pages or ci) so a drifted pkg fails the build, or run it locally before
# committing a core change. Exit 0 = fresh, 1 = drifted.
#
# sim-wasm-r2-02: the interface diff alone is BLIND to a same-API wire bump (a BUNDLE_VERSION change
# that keeps the same JS method surface produces an identical .d.ts/.js, so the committed .wasm could
# silently speak an older wire while this guard passes). To close that hole we also compare the wire
# version the committed pkg was stamped with (sim/pkg/.wire-version, written by build-wasm.sh) against
# the current source BUNDLE_VERSION, so a wire bump ALWAYS trips the guard even with an unchanged API.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
crate="$here/../core/hop-wasm"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

command -v wasm-pack >/dev/null || { echo "error: wasm-pack not found (cargo install wasm-pack)"; exit 1; }

wasm-pack build "$crate" --target web --out-dir "$tmp" >/dev/null 2>&1

drift=0
for f in hop_wasm.d.ts hop_wasm.js hop_wasm_bg.wasm.d.ts; do
  if ! diff -q "$tmp/$f" "$here/pkg/$f" >/dev/null 2>&1; then
    echo "DRIFT: sim/pkg/$f differs from a fresh core/hop-wasm build"
    drift=1
  fi
done

# Wire-version cross-check: the committed pkg must carry a .wire-version stamp that matches the source
# BUNDLE_VERSION. Catches a same-interface wire bump the .d.ts/.js diff cannot see.
src_wire="$(grep -oE 'BUNDLE_VERSION: *u8 *= *([0-9]+)' "$here/../core/hop-core/src/bundle.rs" | grep -oE '[0-9]+' | head -1)"
committed_wire="$(cat "$here/pkg/.wire-version" 2>/dev/null || echo "")"
if [ -z "$committed_wire" ]; then
  echo "DRIFT: sim/pkg/.wire-version is missing, rebuild the pkg so it stamps the wire version"
  drift=1
elif [ "$committed_wire" != "$src_wire" ]; then
  echo "DRIFT: sim/pkg/.wire-version=$committed_wire but source BUNDLE_VERSION=$src_wire (wire bump not rebuilt into the committed pkg)"
  drift=1
fi

if [ "$drift" -ne 0 ]; then
  echo
  echo "sim/pkg is STALE, rebuild it: sim/build-wasm.sh (then commit sim/pkg)"
  exit 1
fi
echo "sim/pkg interface matches a fresh core/hop-wasm build (fresh)"
