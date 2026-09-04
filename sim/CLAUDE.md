# sim/

The WASM swarm sim: a clickable swarm where each dot is a REAL `hop-core` instance compiled to WASM
(via `core/hop-wasm`), bearer links forming and breaking as nodes move. It doubles as the homepage
scenario player. `apps/web/site` syncs this whole directory into its `public/sim` at build time.

## The committed pkg + the freshness guard

- `sim/pkg/` is a COMMITTED build output of `core/hop-wasm` (browser target), so the Astro site builds without a wasm toolchain. `sim/build-wasm.sh` regenerates it (browser `pkg/` + node `pkg-node/`).
- **Any wire bump (`BUNDLE_VERSION`) requires rebuilding + committing `sim/pkg`**, or `sim/check-pkg-fresh.sh` reddens CI. That guard diffs the COMMITTED pkg blob (via `git show HEAD:...`), not the working tree, so a CI rebuild cannot mask committed drift; a committed pkg file missing from HEAD is itself DRIFT. `--committed-only` mode checks just the wire stamp without a rebuild. `--working-tree` compares a fresh build and source stamp with the current generated files for local no-commit verification.

## Checks

- `node sim/scenario-check.mjs`: all real-world scenarios must deliver + ack (run this after any core change).
- `node sim/wasm-glue-check.mjs`: exercises the WasmNode methods the scenarios do not (the §39 receiver-beacon, traced send, custom TTL, inbox debug) against the real compiled pkg-node.
- `cargo build -p hop-wasm --target wasm32-unknown-unknown` must stay clean (watch for a dep pulling a getrandom major with no wasm backend; bridge it via the `wasm_js` feature).
- `bash sim/check-pkg-fresh.test.sh`: self-test for the freshness guard (verifies toolchain, build failure, and drift reporting).
