#!/usr/bin/env bash
# Freshness/drift check for the committed sim/pkg wasm build.
#
# sim/pkg/ is a committed BUILD OUTPUT of core/hop-wasm (see build-wasm.sh + PKG-PROVENANCE.md). If someone
# changes hop-core's wire format or the hop-wasm surface but forgets to rebuild, the committed sim would
# silently speak an OLDER protocol than the code beside it — and the homepage's "your browser is running
# the real Hop protocol" claim would quietly become false.
#
# This rebuilds core/hop-wasm --target web into a temp dir and compares the wasm-bindgen INTERFACE
# (hop_wasm.d.ts + the JS glue) against the committed copy. The interface is deterministic across builds
# (unlike the optimized .wasm binary, whose bytes vary run-to-run), so a diff here means the committed
# pkg is stale. Wire it into CI (pages or ci) so a drifted pkg fails the build, or run it locally before
# committing a core change. Exit 0 = fresh, 1 = drifted.
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

if [ "$drift" -ne 0 ]; then
  echo
  echo "sim/pkg is STALE — rebuild it: sim/build-wasm.sh (then commit sim/pkg)"
  exit 1
fi
echo "sim/pkg interface matches a fresh core/hop-wasm build (fresh)"
