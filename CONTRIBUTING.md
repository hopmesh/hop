# Contributing to Hop

Hop is a metadata-privacy messaging mesh. This guide is the map from "clone" to a
merged change. For architecture, read `DESIGN.md` and `MECHANISMS.md`; for the
libhop C-ABI contract, `docs/libhop-architecture.md`.

## Repository layout

- `core/` - the Rust core: `hop-core` (protocol), `hop` (the C-ABI crate that
  generates `sdk/hop.h`), `hop-sim`, `hop-wasm`, and the store backends under
  `core/stores/`.
- `sdk/` - `hop.h` (the C ABI, the ONE contract every non-Rust client binds) and the
  Swift (`sdk/wrappers/apple`) and Kotlin (`sdk/wrappers/android`) wrappers.
- `bearers/` - per-transport packages (BLE, LAN, relay), one isolated
  package per bearer. Apple Multipeer (Wi-Fi P2P) is a live transport but stays in-driver, not a package.
- `drivers/` - the per-platform host layer.
- `services/` - the relay (`hop-relayd`), gateway, endpoint, and example origin.
- `infra/` - OpenTofu for the cloud relay fleet (see `docs/runbooks/`).
- `android/`, `apple/` - the demo apps.
- `web/`, `sim/` - the marketing site (Astro) and the browser swarm sim.

## Prerequisites

- Rust stable (rustup). Clippy and rustfmt components.
- For the header-drift check: `cargo install cbindgen --locked`.
- For the supply-chain check: `cargo install cargo-deny`.
- Kotlin/Android work: JDK + the Gradle wrapper (`./gradlew`).
- Apple work: Xcode.

## Build and test (Rust core)

The core is a Cargo workspace at the repo root:

```sh
cargo build
cargo test                 # the default suite
cargo clippy --all-targets # clippy; warnings are errors in CI
cargo fmt --all            # formatting
```

Store-backend features are mutually exclusive (`bundled` vs `sqlcipher`), so some
suites run per-feature (mirrors CI):

```sh
cargo test -p hop-store-sqlite --no-default-features --features sqlcipher
cargo test -p hop-relayd --features firestore
```

## The C-ABI contract (do not break it silently)

`sdk/hop.h` is generated from `core/hop/src/cabi.rs`. If you change the C ABI:

1. Regenerate the header: `bash core/hop/regen-header.sh` and commit the result. CI
   fails if the committed `sdk/hop.h` drifts from `cabi.rs`.
2. If you bump `HOP_ABI_VERSION`, update ALL THREE copies in the same commit:
   `cabi.rs`, the Swift `Hop.swift`, and the Kotlin `Hop.kt`. Only the
   `cabi.rs`->`hop.h` leg is CI-checked today.
3. Keep the contract PURE: no transport/bearer symbols leak into the SDK/contract.
   CI runs `tools/codegen/check-contract-purity.sh`.

For wire-format changes, update the wire-stability test deliberately; a change there
is a protocol break that must be called out (see `docs/release-engineering.md`).

## Style

- Match the surrounding code's style and comment density. The codebase is heavily
  commented with the "why"; keep that.
- Hard rule (repo-wide, including docs and comments): never use an em-dash or an
  en-dash. Use a plain hyphen, a comma, a colon, or two sentences.
- Content is always forward-secret. A send without a ratchet is a bug, never a
  static-seal fallback.

## Commit and PR

- Commit early and often on a feature branch; small, working increments.
- Open a PR against `main` with a real description of the problem and the fix.
- CI (`.github/workflows/ci.yml`) must be green: tests, clippy, format, contract
  purity, and header drift. Merge on green.
- Run `cargo deny check` for dependency changes (see `deny.toml`).

## Security

Do not file security or privacy issues in public. See `SECURITY.md` for the private
disclosure process.

## Where things are documented

- `DESIGN.md` - full protocol design and threat model.
- `MECHANISMS.md` - the mechanisms, briefly.
- `docs/libhop-architecture.md` - the libhop C-ABI architecture.
- `docs/runbooks/` - operating the relay fleet (enable/disable, incidents, 429s).
- `docs/release-engineering.md` - versioning, tagging, publishing.
- `CHANGELOG.md` - what changed, per release.
