# Hop

Hop is a metadata-privacy messaging mesh. Devices carry messages for each other over
whatever transports are around (BLE, LAN, and a scale-to-zero cloud relay, with more
bearers possible), so messages move even with no internet, and the network does not
learn who is talking to whom. Content is always end-to-end forward-secret.

This README is the entrypoint. For the full protocol and threat model, read
`DESIGN.md`; for a shorter mechanisms tour, `MECHANISMS.md`.

## What is here

| Area | Path | What it is |
|------|------|------------|
| Core | `core/` | The Rust protocol core (`hop-core`), the C-ABI crate (`hop`, generates `sdk/hop.h`), the routing sim (`hop-sim`), the wasm build (`hop-wasm`), and store backends (`core/stores/`). |
| SDK | `sdk/` | `hop.h` (the C ABI every non-Rust client binds) plus the Swift and Kotlin wrappers. |
| Bearers | `bearers/` | One isolated package per transport (BLE, LAN, relay). Apple Multipeer (Wi-Fi P2P) is a live transport but stays in-driver, not an extracted package. |
| Drivers | `drivers/` | The per-platform host layer. |
| Services | `services/` | The relay (`hop-relayd`), gateway, endpoint, and example origin. |
| Infra | `infra/` | OpenTofu for the cloud relay fleet. See `docs/runbooks/`. |
| Apps | `apps/` | Every app: `apps/apple/HopDemo`, `apps/android/HopDemo`, `apps/web/site`, `apps/ble-lab`, `apps/esp32`. |
| Sim | `sim/` | The browser swarm sim (real `hop-core` compiled to wasm) plus the scenario checks. |

## Quick start (Rust core)

The core is a Cargo workspace at the repo root:

```sh
cargo build
cargo test
cargo clippy --all-targets
```

To regenerate the C-ABI header after changing the ABI:

```sh
bash core/hop/regen-header.sh   # updates sdk/hop.h; CI fails if it drifts
```

See `CONTRIBUTING.md` for the full build/test/PR path, including the per-feature
store suites and the client wrappers.

## Documentation map

- `DESIGN.md` - full protocol design and threat model (large; the metadata-privacy
  sections, "§39", cover untraceable-by-default delivery).
- `MECHANISMS.md` - the mechanisms, briefly.
- `docs/libhop-architecture.md` - the libhop C-ABI architecture.
- `docs/runbooks/` - operating the relay fleet: enable/disable, incident response,
  quota/429 handling.
- `docs/release-engineering.md` - versioning, tagging, and publishing.
- `docs/crash-reporting-design.md`, `docs/identity-backup-restore-design.md` -
  privacy-safe diagnostics and identity recovery designs (pending app work).
- `CONTRIBUTING.md` - how to build, test, and contribute.
- `SECURITY.md` - how to report a vulnerability privately.
- `CHANGELOG.md` - what changed, per release.

## License

This monorepo has no single repo-wide license. Instead every component licenses itself, in two tiers:

- The protocol **core** (`core/*`: hop-core, libhop, hop-wasm, the stores) is **FSL-1.1-ALv2**
  (source-available, and converts to Apache-2.0 after two years). That is the differentiated work, the
  moat.
- **Everything else**, the SDKs, the bearers, the drivers, and the services, is **Apache-2.0**, so you
  can embed or self-host any of it with no strings attached. Adoption is the whole point of the layers
  people build on.

Each component carries its own `LICENSE.md`, so it stays licensed when it is split out into its own
repository. See any component's `LICENSE.md`.
