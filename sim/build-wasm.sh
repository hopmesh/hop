#!/usr/bin/env bash
# Rebuild the sim's real-hop-core wasm packages from source (core/hop-wasm).
#
# Produces the two artifacts the sim consumes:
#   sim/pkg/                    (wasm-pack --target web)     — loaded by the browser sim-worker.js
#   core/hop-wasm/pkg-node/     (wasm-pack --target nodejs)  — loaded by sim/scenario-check.mjs (headless)
#
# Both are BUILD OUTPUTS of core/hop-wasm at HEAD, not hand-authored. sim/pkg is committed so the static
# site deploys without a wasm toolchain in the pages build; re-run this whenever core/hop-wasm or hop-core
# changes so the committed pkg keeps speaking the shipping protocol. `check-pkg-fresh.sh` fails if the
# committed sim/pkg has drifted from a fresh build.
#
# Requires: rustup wasm32-unknown-unknown target + wasm-pack.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
crate="$here/../core/hop-wasm"

command -v wasm-pack >/dev/null || { echo "error: wasm-pack not found (cargo install wasm-pack)"; exit 1; }

echo "==> building sim/pkg (target web)"
wasm-pack build "$crate" --target web --out-dir "$here/pkg"
# The committed pkg carries no package.json (it's not an npm package, just static assets the site copies).
rm -f "$here/pkg/package.json" "$here/pkg/.gitignore"

echo "==> building core/hop-wasm/pkg-node (target nodejs)"
wasm-pack build "$crate" --target nodejs --out-dir "$crate/pkg-node"

echo "==> done. sim/pkg and core/hop-wasm/pkg-node rebuilt from core/hop-wasm at HEAD."
