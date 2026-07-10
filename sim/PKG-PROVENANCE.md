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

- **Rebuild:** `sim/build-wasm.sh` — regenerates both `sim/pkg` (web) and
  `core/hop-wasm/pkg-node` (nodejs) from source. Commit the resulting `sim/pkg`.
- **Freshness check:** `sim/check-pkg-fresh.sh` — rebuilds into a temp dir and fails if the committed
  `sim/pkg` interface (`hop_wasm.d.ts` / `hop_wasm.js`) has drifted from a fresh build. Run it before
  committing a core change, and wire it into CI (the pages or ci workflow) so a stale `sim/pkg` fails
  the build. It compares the deterministic wasm-bindgen interface, not the optimized `.wasm` bytes
  (which vary run-to-run under `wasm-opt`), so it flags real API/protocol-surface drift without false
  positives from non-reproducible binary output.

Both scripts require `rustup target add wasm32-unknown-unknown` and `wasm-pack`.
