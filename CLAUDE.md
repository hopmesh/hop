# Hop monorepo

Hop is a delay-tolerant, untraceable-by-default mesh messenger. The protocol is Rust (`hop-core`),
compiled to a C ABI (`sdk/hop.h`) that every platform binds. This file is the map; each subtree has its
own `CLAUDE.md` with local detail (the nearest one to the files you are editing wins on specifics).

## Layout

```
core/       Rust: the protocol (hop-core), the C ABI crate (hop), the browser build (hop-wasm), stores
services/   Rust daemons: hop-relayd (the relay), hop-endpoint, hop-gateway
sdk/        the C-ABI language wrappers (Kotlin via JNA, Swift) + the xcframework packaging
bearers/    per-platform transport packages (apple/, android/): BLE, LAN, relay
drivers/    per-platform app-facing client (apple/HopDriver, android/hop-driver): node + bearers + UI glue
apps/       every app: apps/apple/HopDemo, apps/android/HopDemo, apps/web/site, apps/ble-lab, apps/esp32
sim/        the WASM swarm sim + scenario checks (real hop-core compiled to wasm); its own subsystem
infra/      GitOps deploy (OpenTofu + Cloud Build); push to main = build + tofu apply
tools/      CI guards (each with a .test.sh) + build/link helpers + the platform SDK-artifact builders
            (build-xcframework.sh for Apple, build-aar.sh for Android, smoke-test.sh)
docs/       the developer docs site content; docs/audits/ holds the audit-report history
assets/     cross-platform design-asset SOURCE (Font Awesome SVGs), hand-derived into per-platform icons
learn/      standalone site pages, synced into apps/web/site/public/learn at build (like sim/)
mockups/    design prototypes + the swarm invariant test (run by the WASM sim CI job)
```

The organizing axis is **purpose / platform / package-or-app** (the domain is always the root, never
the platform). Platform-specific purposes nest `apple`/`android`/`web`/`esp32` inside:
`bearers/apple/HopBearerBle`, `drivers/android/hop-driver`, `apps/web/site`, `sdk/apple`. There are NO
top-level platform trees. Two level-collapses are intentional and consistent: `sdk/<platform>` has
exactly one wrapper per platform so the platform dir *is* the package, and purposes that are inherently
cross-platform (`core/`, `services/`) carry no platform level at all. The one exception to the axis is
`apps/ble-lab` (a single cross-platform experiment; platform lives inside it), documented in
`apps/CLAUDE.md`.

The content dirs (`sim`, `assets`, `learn`, `mockups`) stay top-level ON PURPOSE: `sim` is a real
subsystem (the core compiled to wasm, 24 references), `assets` feeds all three platforms' icons (not
just web), and `learn` follows `sim`'s sync-into-the-site pattern. Folding them into `apps/web/site`
would break the icon pipeline and demote a subsystem, so they are documented here rather than moved.

## The verify loop (run before calling anything done)

- Rust: `cargo test --workspace`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo fmt --all --check`. Feature runs: relayd `--features firestore`, sqlite `--features sqlcipher`.
- Kotlin/Android: `gradle test` (SDK), the Android JVM unit tests (see `apps/android/CLAUDE.md`).
- Apple: `swift test` per package (bearers, driver, HopDemoKit); the app is build-only in CI.
- Web/sim: `sim/build-wasm.sh` then `sim/check-pkg-fresh.sh`; `node sim/scenario-check.mjs`.
- CI (`.github/workflows/ci.yml`) is the gate: 9 named jobs, all must be green. `main` is branch-protected.

## Repo-specific laws

- **Wire format is a contract.** `bundle.rs BUNDLE_VERSION` is the wire version. Any wire-layout change bumps it, and a bump MUST be followed by `sim/build-wasm.sh` + committing `sim/pkg` (a stamp guard reddens CI otherwise). Never change wire bytes as a side effect (a dep bump must produce identical bytes).
- **Deploy = push to main.** The Cloud Build trigger builds images and runs `tofu apply` on every push to main, gated on this workflow being green for the commit. See `infra/CLAUDE.md`. The relay fleet is currently OFF (`relays_enabled=false`).
- **Device-to-device content is always forward-secret** (Double Ratchet). A send without a session ratchet is a bug, never a static seal.
- **No em-dashes or en-dashes anywhere** (code, comments, docs, commits, PRs). `tools/docs-token-guard.sh` enforces it on docs/site copy in CI, including encoded and lookalike forms.
- **Iteration mode:** pre-prod, single maintainer. Breaking changes are fine; iterate freely, but keep CI green.

## Working with agents

File-mutating work in parallel needs `isolation: "worktree"` on each agent, or they corrupt each other's HEAD in the shared checkout. Read-only fan-out is fine shared.
