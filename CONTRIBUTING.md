# Contributing to Hop

Hop is a metadata-privacy messaging mesh. This guide is the map from "clone" to a
merged change. For architecture, read `DESIGN.md` and `MECHANISMS.md`; for the
libhop C-ABI contract, `docs/libhop-architecture.md`.

## Repository layout

- `core/` - the Rust core: `hop-core` (protocol), `hop` (the C-ABI crate that
  generates `sdk/hop.h`), `hop-sim`, `hop-wasm`, and the store backends under
  `core/stores/`.
- `sdk/` - `hop.h` (the C ABI, the ONE contract every non-Rust client binds) and the
  Swift (`sdk/apple`) and Kotlin (`sdk/android`) wrappers.
- `bearers/` - per-transport packages (BLE, LAN, relay), one isolated
  package per bearer. Apple Multipeer (Wi-Fi P2P) is a live transport but stays in-driver, not a package.
- `drivers/` - the per-platform host layer.
- `services/` - the relay (`hop-relayd`), gateway, endpoint, and telemetry daemon. (Non-mesh services `hop-accountd` and `hop-billingd` live in `hopmesh/platform`; see `docs/repo-catalog.md`).
- `infra/` - OpenTofu for the cloud relay fleet lives in `hopmesh/platform/infra/` (see `docs/repo-catalog.md` and `docs/runbooks/`).
- `apps/` - every app: `apps/apple/HopDemo`, `apps/android/HopDemo`, `apps/web/site`, `apps/ble-lab`, `apps/esp32`.
- `sim/` - the browser swarm sim (real `hop-core` compiled to wasm) plus the scenario checks.

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
2. If you bump `HOP_ABI_VERSION`, update EVERY copy in the same commit: `cabi.rs`, both
   generated headers, and the pinned constant in each language wrapper under `sdk/`. If the
   bump adds `hop_*` calls, name them in the header's bump note AND bind them in every
   wrapper; the note is machine-checked against the wrappers. Also correct any doc that
   states the ABI level in prose. `tools/codegen/check-abi-version.sh` (CI, and in the local
   mirror) sweeps the tree for all of it and names every location it finds.
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

## Contributor License Agreement &amp; Developer Certificate of Origin

All external contributions to Hop require agreement to the Contributor License Agreement (CLA) or Developer Certificate of Origin (DCO sign-off):

- **Contributor License Agreement (CLA):** By submitting a pull request, you agree to the terms in `CLA.md` (present in each component directory). Hop is distributed under a dual-licensing model (Apache-2.0 for client libraries and core protocol, FSL-1.1-ALv2 for cloud services). The CLA grants Hop Mesh, LLC the necessary rights to distribute and relicense contributions under these terms while preserving your original authorship.
- **Developer Certificate of Origin (DCO):** Commits should include a `Signed-off-by: Author Name <email>` trailer (`git commit -s`), certifying that you wrote the code or have the right to contribute it under open-source and source-available licenses.
- **Automated Verification:** Pull requests are automatically verified for DCO sign-off and CLA compliance via GitHub Actions (`.github/workflows/dco.yml`).
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
