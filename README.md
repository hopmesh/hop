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
| Bearers | `bearers/` | One isolated package per transport (BLE, LAN, relay, multipeer). |
| Drivers | `drivers/` | The per-platform host layer. |
| Services | `services/` | The relay (`hop-relayd`), gateway, endpoint, and example origin. |
| Infra | `infra/` | OpenTofu for the cloud relay fleet. See `docs/runbooks/`. |
| Apps | `android/`, `apple/` | The demo apps. |
| Web / Sim | `web/`, `sim/` | The Astro marketing site and the browser swarm sim. |

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

Hop is licensed under FSL-1.1-ALv2. See `LICENSE.md`.
