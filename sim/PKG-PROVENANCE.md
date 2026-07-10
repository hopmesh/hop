# `sim/pkg` provenance

`sim/pkg/` is **not hand-authored**. It is a committed build output of the `core/hop-wasm` crate,
which is a thin `wasm-bindgen` wrapper over a real `hop-core` `Node`. Every node in the browser
swarm is an actual `hop-core` instance running this wasm; that is what the homepage's "your browser
is running the real Hop protocol" claim rests on.

## What's in it

| file | what |
|------|------|
| `hop_wasm_bg.wasm` | the compiled `core/hop-wasm` crate (real hop-core + crypto) |
| `hop_wasm.js` | wasm-bindgen JS glue (loaded by `sim/sim-worker.js`) |
| `hop_wasm.d.ts`, `hop_wasm_bg.wasm.d.ts` | the TypeScript interface |

Built with `wasm-pack build core/hop-wasm --target web`. The sibling `core/hop-wasm/pkg-node/`
(`--target nodejs`) is the same crate for the headless validator `sim/scenario-check.mjs`.

## Why it's committed (and the risk)

The static site (`web/`, Astro) copies `sim/` into `public/sim/` at build time (`npm run sync-sim`)
and deploys it without a wasm toolchain in the pages build. Committing `sim/pkg` keeps that build
toolchain-free.

The risk this creates: a functional change to `hop-core` (e.g. a new wire-format `Destination`
variant) that is NOT followed by a rebuild ships a browser sim speaking an OLDER protocol than the
code beside it. To catch that, `sim/pkg` must be rebuilt whenever `core/hop-wasm` or `hop-core`
changes.

## Rebuild + drift check

- **Rebuild:** `sim/build-wasm.sh`, regenerates both `sim/pkg` (web) and
  `core/hop-wasm/pkg-node` (nodejs) from source. Commit the resulting `sim/pkg`.
- **Freshness check:** `sim/check-pkg-fresh.sh`, rebuilds into a temp dir and fails if the committed
  `sim/pkg` interface (`hop_wasm.d.ts` / `hop_wasm.js`) has drifted from a fresh build. Run it before
  committing a core change, and wire it into CI (the pages or ci workflow) so a stale `sim/pkg` fails
  the build. It compares the deterministic wasm-bindgen interface, not the optimized `.wasm` bytes
  (which vary run-to-run under `wasm-opt`), so it flags real API/protocol-surface drift without false
  positives from non-reproducible binary output.
- **Wire-version stamp (sim-wasm-r2-02):** the interface diff alone is blind to a *same-API* wire bump,
  a `BUNDLE_VERSION` change that keeps the same JS method surface produces an identical `.d.ts`/`.js`,
  so the committed `.wasm` could silently speak an older wire while the interface check passes. To close
  that hole, `build-wasm.sh` writes `sim/pkg/.wire-version` = the source `BUNDLE_VERSION` it built
  against, and `check-pkg-fresh.sh` fails if that stamp is missing or does not equal the current
  `core/hop-core/src/bundle.rs` `BUNDLE_VERSION`. So a wire bump trips the guard even with an unchanged
  API. (The public site is always safe regardless, CI rebuilds `sim/pkg` from source before deploy; the
  stamp protects a developer running `sim/` locally against the committed pkg.)
- **Guard teeth in CI (sim-wasm-r3-02):** two hardenings so the stamp check can actually fail on a
  *committed* drift. (1) `check-pkg-fresh.sh` reads the committed stamp via `git show HEAD:sim/pkg/.wire-version`
  rather than the working tree, so a `build-wasm.sh` re-stamp earlier in the same CI job cannot mask a
  drifted commit (it falls back to the working-tree file outside a git checkout). (2) a `--committed-only`
  mode skips the rebuild and cross-checks only the stamp, so it can run *before* `build-wasm.sh`. Also
  fixed the version extraction in both scripts: the old `grep -oE '[0-9]+' | head -1` matched the `8` in
  the `u8` type, not the version after `=`, so it stamped and compared `8 == 8` forever, silently masking
  every wire bump. Both now anchor on the `=` sign.

Both scripts require `rustup target add wasm32-unknown-unknown` and `wasm-pack`.
