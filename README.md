<p align="center">
  <img alt="Hop" src="https://hopme.sh/hop-mark.svg" width="200">
</p>

<h1 align="center">Hop</h1>

<p align="center">
  <b>A metadata-privacy messaging mesh.</b><br>
  Devices carry messages for each other over whatever transports are around, so messages survive no internet and the network does not learn who is talking to whom.
</p>

<p align="center">
  <a href="https://hopme.sh">hopme.sh</a> &middot;
  <a href="DESIGN.md">Protocol &amp; threat model</a> &middot;
  <a href="MECHANISMS.md">Mechanisms tour</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/license-Apache--2.0-3ddc84" alt="license">
  <img src="https://img.shields.io/badge/services-FSL--1.1--ALv2-6ea8fe" alt="services FSL-1.1-ALv2">
  <img src="https://img.shields.io/badge/rust-1.97.0-dea584" alt="rust 1.97.0">
</p>

---

Devices carry messages for each other over BLE, LAN, and a scale-to-zero cloud relay, with more
bearers possible. Content is always end-to-end forward-secret, and the mesh is delay-tolerant: a
message survives the gap between one carrier and the next.

This README is the entrypoint. For the full protocol and threat model, read `DESIGN.md`; for a
shorter mechanisms tour, `MECHANISMS.md`.

## What is here

| Area | Path | What it is |
|------|------|------------|
| Core | `core/` | The Rust protocol core (`hop-core`), the C-ABI crate (`hop`, generates `sdk/hop.h`), the routing sim (`hop-sim`), the wasm build (`hop-wasm`), and store backends (`core/stores/`). |
| SDK | `sdk/` | `hop.h` (the C ABI every non-Rust client binds) plus the Swift and Kotlin wrappers. |
| Bearers | `bearers/` | One isolated package per transport (BLE, LAN, relay). Apple Multipeer (Wi-Fi P2P) is a live transport but stays in-driver, not an extracted package. |
| Drivers | `drivers/` | The per-platform host layer. |
| Services | `services/` | The relay (`hop-relayd`), gateway, endpoint, and example origin. |
| Infra | `hopmesh/platform/infra/` | OpenTofu for the cloud relay fleet. See `docs/runbooks/`. |
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
- `docs/tor.md` - reaching a relay over both the public internet and an onion
  service, what the mesh does and does not hide.
- `docs/release-engineering.md` - versioning, tagging, and publishing.
- `docs/crash-reporting-design.md`, `docs/identity-backup-restore-design.md` -
  privacy-safe diagnostics and identity recovery designs (pending app work).
- `CONTRIBUTING.md` - how to build, test, and contribute.
- `SECURITY.md` - how to report a vulnerability privately.
- `docs/audit-history.md` - what the `F-xx` / `SVC-xxx` / `PROC-xxx` identifiers cited in code
  mean, where the audit corpus lives, and why it is not published raw.
- `CHANGELOG.md` - what changed, per release.

## License

The root `LICENSE.md` is **Apache-2.0** and covers everything that does not carry its own. That
matters because 812 tracked files sit outside every component directory (apps, tools, sim, testkit,
infra, docs, assets) and would otherwise publish with no declared licence at all, which is not the
same as being permissive: no licence means no rights granted.

Components that carry their own `LICENSE.md` are licensed by it, in two tiers:

- The hosted **services** (`services/*`: relayd, endpoint, gateway, telemetryd, accountd, billingd) are
  **FSL-1.1-ALv2** (source-available, and converts to Apache-2.0 after two years). That is the layer
  worth defending.
- **Everything else**, the protocol core, the SDKs, the bearers, and the drivers, is **Apache-2.0**, so
  you can embed, self-host, or ship any of it with no strings attached. Each node someone else runs
  makes the mesh more valuable.

Each component carries its own `LICENSE.md`, so it stays licensed when it is split out into its own
repository. See any component's `LICENSE.md`.