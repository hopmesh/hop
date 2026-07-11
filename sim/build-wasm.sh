#!/usr/bin/env bash
# Rebuild the sim's real-hop-core wasm packages from source (core/hop-wasm).
#
# Produces the two artifacts the sim consumes:
#   sim/pkg/                    (wasm-pack --target web), loaded by the browser sim-worker.js
#   core/hop-wasm/pkg-node/     (wasm-pack --target nodejs), loaded by sim/scenario-check.mjs (headless)
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
root="$(cd "$here/.." && pwd)"

command -v wasm-pack >/dev/null || { echo "error: wasm-pack not found (cargo install wasm-pack)"; exit 1; }

# legal-01 backstop: wasm-pack copies the crate's license-file into --out-dir, joining the manifest's
# raw relative path onto the out-dir to pick the destination. If that path ever contains `../` (e.g. a
# crate inheriting the workspace `license-file = "LICENSE.md"`, which cargo reports as "../../LICENSE.md")
# the destination can resolve back onto the repo-root LICENSE.md and truncate it to 0 bytes. That exact
# 0-byte-LICENSE regression shipped before. core/hop-wasm/Cargo.toml now pins a crate-local license-file
# to prevent it; snapshot the root LICENSE.md here and hard-fail if a build ever empties or changes it.
license="$root/LICENSE.md"
license_before=""
[ -f "$license" ] && license_before="$(cksum < "$license")"

echo "==> building sim/pkg (target web)"
wasm-pack build "$crate" --target web --out-dir "$here/pkg"
# The committed pkg carries only the wasm-bindgen interface + wasm, not npm/license side files
# (it's not an npm package, just static assets the site copies). LICENSE.md is the crate license
# wasm-pack copies in; drop it so the committed pkg stays minimal and its tracked set doesn't drift.
rm -f "$here/pkg/package.json" "$here/pkg/.gitignore" "$here/pkg/LICENSE.md"

# sim-wasm-r2-02: stamp the wire version the committed pkg was built against. The wasm-bindgen
# interface (.d.ts/.js) does NOT change on a same-API BUNDLE_VERSION bump, so the interface diff alone
# can pass while the committed .wasm speaks an older wire. check-pkg-fresh.sh compares this stamp
# against the source BUNDLE_VERSION so any wire bump trips the freshness guard even with an identical API.
# sim-wasm-r3-02: take the number AFTER the `=`, not the first digit (which was the `8` in `u8`).
wire_version="$(grep -oE 'BUNDLE_VERSION: *u8 *= *[0-9]+' "$here/../core/hop-core/src/bundle.rs" | grep -oE '=[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)"
if [ -n "$wire_version" ]; then
  printf '%s\n' "$wire_version" > "$here/pkg/.wire-version"
  echo "==> stamped sim/pkg/.wire-version = $wire_version"
fi

echo "==> building core/hop-wasm/pkg-node (target nodejs)"
wasm-pack build "$crate" --target nodejs --out-dir "$crate/pkg-node"

# legal-01 backstop (see the snapshot above): the root LICENSE.md must be non-empty and byte-for-byte
# unchanged by this build. If it was truncated or altered, fail loudly instead of letting a 0-byte
# license slip into a commit.
if [ ! -s "$license" ]; then
  echo "error: $license is empty or missing after the wasm build (wasm-pack license-copy truncation?)." >&2
  echo "       Restore it with 'git checkout LICENSE.md' and check core/hop-wasm/Cargo.toml license-file." >&2
  exit 1
fi
if [ -n "$license_before" ] && [ "$license_before" != "$(cksum < "$license")" ]; then
  echo "error: $license was modified by the wasm build; it must be left untouched." >&2
  exit 1
fi

echo "==> done. sim/pkg and core/hop-wasm/pkg-node rebuilt from core/hop-wasm at HEAD."
