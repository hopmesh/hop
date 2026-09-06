# Hop monorepo

Hop is a delay-tolerant, untraceable-by-default mesh messenger. The protocol is Rust (`hop-core`),
compiled to a C ABI (`sdk/hop.h`) that every platform binds. This file is the map; each subtree has its
own `CLAUDE.md` with local detail (the nearest one to the files you are editing wins on specifics).

## Layout

```
core/       Rust: the protocol (hop-core), the C ABI crate (hop), the browser build (hop-wasm), stores
services/   Rust daemons: hop-relayd (the relay), hop-endpoint, hop-gateway, hop-telemetryd.
            (Non-mesh services hop-accountd and hop-billingd live in hopmesh/platform; see docs/repo-catalog.md)
sdk/        the C-ABI language wrappers (Kotlin via JNA, Swift) + the xcframework packaging
bearers/    per-platform transport packages (apple/, android/): BLE, LAN, relay
drivers/    per-platform app-facing client (apple/HopDriver, android/hop-driver): node + bearers + UI glue
apps/       every app: apps/apple/HopDemo, apps/android/HopDemo, apps/web/site, apps/ble-lab, apps/esp32
sim/        the WASM swarm sim + scenario checks (real hop-core compiled to wasm); its own subsystem
tools/      CI guards (each with a .test.sh) + build/link helpers + the platform SDK-artifact builders
            (build-xcframework.sh for Apple, build-aar.sh for Android, smoke-test.sh)
docs/       the developer docs site content; docs/audits/ holds the audit-report history
assets/     cross-platform design-asset SOURCE (Font Awesome SVGs), hand-derived into per-platform icons
learn/      standalone site pages, synced into apps/web/site/public/learn at build (like sim/)
```

The organizing axis is **purpose / platform / package-or-app** (the domain is always the root, never
the platform). Platform-specific purposes nest `apple`/`android`/`web`/`esp32` inside:
`bearers/apple/HopBearerBle`, `drivers/android/hop-driver`, `apps/web/site`, `sdk/apple`. There are NO
top-level platform trees. Two level-collapses are intentional and consistent: `sdk/<platform>` has
exactly one wrapper per platform so the platform dir *is* the package, and purposes that are inherently
cross-platform (`core/`, `services/`) carry no platform level at all. The one exception to the axis is
`apps/ble-lab` (a single cross-platform experiment; platform lives inside it), documented in
`apps/CLAUDE.md`.

The content dirs (`sim`, `assets`, `learn`) stay top-level ON PURPOSE: `sim` is a real
subsystem (the core compiled to wasm, 24 references), `assets` feeds all three platforms' icons (not
just web), and `learn` follows `sim`'s sync-into-the-site pattern. Folding them into `apps/web/site`
would break the icon pipeline and demote a subsystem, so they are documented here rather than moved.

## The verify loop (run before calling anything done)

- Rust: `cargo test --workspace`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo fmt --all --check`. Feature runs: relayd `--features firestore`, sqlite `--features sqlcipher`.
- Kotlin/Android: `gradle test` (SDK), the Android JVM unit tests (see `apps/android/CLAUDE.md`).
- Apple: `swift test` per package (bearers, driver, HopDemoKit); the app is build-only in CI.
- Web/sim: `sim/build-wasm.sh` then `sim/check-pkg-fresh.sh`; `node sim/scenario-check.mjs`.
- CI (`.github/workflows/ci.yml`) is the gate: 22 jobs. Most are path-filtered off `changes`, so a job that skips still has to report. The aggregate `CI gate` depends on the other 21 and is the ONE required context on `main` (branch-protected); `tools/check-required-checks.sh` keeps that list honest, and `tools/doc-path-guard.sh` fails CI when this sentence's counts drift from `ci.yml`. Adding a job means updating both the `changes` outputs and `gate.needs`.

## Repo-specific laws

- **Wire format is a contract.** `bundle.rs BUNDLE_VERSION` is the wire version. Any wire-layout change bumps it, and a bump MUST be followed by `sim/build-wasm.sh` + committing `sim/pkg` (a stamp guard reddens CI otherwise). Never change wire bytes as a side effect (a dep bump must produce identical bytes).
- **Deploy lives in hopmesh/platform.** Nothing in this repository deploys directly to cloud infrastructure. The runtime deploy workflow and OpenTofu infra live in the private hopmesh/platform repository (see docs/repo-catalog.md). The relay fleet is currently OFF (`relays_enabled=false`). The marketing site deploys from this repository's `pages.yml` to hopme.sh (Pages bound to hopmesh/hop since 2026-09-04). The merge itself is NOT a human gate, see the next law.
- **A PR opened by a maintainer merges itself.** `.github/workflows/pr-automerge.yml` fires on `pull_request_target: opened`, and arms merge-commit auto-merge with a PAT for any non-draft PR whose author is OWNER/MEMBER or `jwaldrip`/`dependabot[bot]`. `main` requires no approving review, so armed auto-merge plus a green `CI gate` IS the whole path into `main`, with nobody in the loop. **A PR you intend to be REVIEWED rather than merged MUST be opened `--draft`**: the gate's first term is `!draft`, and `ready_for_review` is a trigger, so marking it ready is the deliberate act that arms the merge. This is the repo's existing mechanism, not a new convention (see the `skipped` then `success` run pairs on that workflow). It has already bitten once: PR #71 carried a private business document and was self-merged into the public repo because nothing read the PR for intent. In response, `pr-automerge.yml` runs `.github/scripts/check-pr-automerge-safety.py`, which normalizes the PR title and body (NFKC, casefold, zero-width and punctuation stripping) and refuses to arm auto-merge when a review-intent or hold marker is present ('do not merge', 'dnm', 'wip', 'rfc', 'research', 'hold', 'review only', 'not ready', 'blocked', 'experiment' and their variants) (PROC-002). Furthermore, with `strict: true` branch protection enforced on `main`, auto-merge requires the PR branch to be fully updated with `main` before the `CI gate` passes and the merge lands (INFRA-011). Import PRs never auto-merge by design, see the comments in that file. Corollary: a PR **body and diff are served unauthenticated and permanently** (`refs/pull/N/head` survives close, branch deletion and merge, and the REST API serves both to anyone), so content that must not be published belongs in NEITHER, whatever you intend to do with the PR.
- **Device-to-device user content is always forward-secret** (Double Ratchet). A `PeerMessage` send without a session ratchet is a bug, never a static seal, and bare `PeerMessage` payloads are rejected symmetrically on both the traced and private receive paths (PROTO-007). This scopes to **user messaging content**: addressed RPC (`ServiceRequest`/`ServiceResponse`, `hops://`, `hop.identify`) and the other sealed-not-ratcheted classes (adverts, HNS answers, vaccines, egress) are statically sealed by design, see DESIGN.md §29.
- **No em-dashes or en-dashes anywhere** (code, comments, docs, commits, PRs). `tools/docs-token-guard.sh` enforces it in CI over docs/site copy and the source trees, and `tools/commit-message-guard.sh` enforces it over introduced commit messages, including encoded and lookalike forms. There are NO carve-outs left for hand-written code: the wire-manifest files (`core/hop-core/vectors/wire-source-manifest.txt`) used to be excluded, on a prose promise to clean them at the next wire bump that v12 and v13 both passed without honouring, and that exclusion was retired in the v13 to v14 bump (audit PROC-001). Most of what the source pass still skips is generated or captured output, listed in `src_excludes`, but TWO exclusions are hand-written and worth knowing: the guard and its own self-test (`--exclude='docs-token-guard.sh'`, `--exclude='docs-token-guard.test.sh'`), which have to spell every banned pattern in order to ban it, and `--exclude='*.svg'` in the shared list, which skips the 31 hand-authored icon and wordmark sources under `assets/`. Neither is generated, so neither is self-policing: the guard pair is held ASCII-clean by the `tools/CLAUDE.md` rule plus its own regression net, and an SVG's copy is on review alone.
- **Iteration mode:** pre-prod, single maintainer. Breaking changes are fine; iterate freely, but keep CI green.

## Working with agents

File-mutating work in parallel needs `isolation: "worktree"` on each agent, or they corrupt each other's HEAD in the shared checkout. Read-only fan-out is fine shared.
Worktree checkpoint rule: every file-mutating session in a worktree must commit its changes to a named branch before yielding. Never leave uncommitted changes or detached-HEAD commits without explicit checkpointing. Before tearing down or pruning a worktree, verify `git status --porcelain` is empty and all commits are reachable from a branch or PR (enforced by `tools/check-worktree-checkpoints.sh`).

Never enumerate environment values. For diagnostics, check fixed variable names and emit only `NAME=set` or `NAME=unset`; never print the value. The checked-in OpenCode policy blocks known environment dumps and clears recognized sensitive values before agent shell processes start.
