# Public repo catalog (swag)

A rough cut of the public repos we split out of this monorepo (source of truth stays here; each is
mirrored via Copybara, see `tools/copybara/`). Every one is intended to be public and carries its own
`LICENSE.md` in one of TWO tiers: the protocol core (`core/*`) is FSL-1.1-ALv2, everything else (SDKs,
bearers, drivers, services) is Apache-2.0. See the License section of `README.md`;
`tools/repo-integrity-guard.sh` fails CI on a cross-tier license, so this file is not a second source
of truth. Names are proposals; boundaries marked **(open)** are real decisions to make.

## Core (the protocol)

| Repo | From | What it is | Ships as | Audience |
| --- | --- | --- | --- | --- |
| `hop-core` | `core/hop-core` | The Hop protocol in pure Rust: bundles, wire format, Noise links, epidemic routing with delivery-vaccine reclamation routing, the §39 untraceable path, crypto. | crates.io | Rust embedders, auditors |
| `libhop` | `core/hop` | The C ABI (`hop.h`, cbindgen) over hop-core: the universal client + bearer contract every non-Rust SDK binds. | prebuilt binaries + crate | SDK authors, C/C++/embedded |
| `hop-wasm` | `core/hop-wasm` | hop-core compiled to WASM: a real Hop node in the browser. | npm | web / browser mesh |
| `hop-store-sqlite` | `core/stores/hop-store-sqlite` | SQLite + SQLCipher persistence behind the `Store` trait. | crates.io | Rust embedders |
| `hop-store-firestore` | `core/stores/hop-store-firestore` | Firestore persistence for the cloud relay/mailbox. | crates.io | operators |

**(decided)** the Rust crates depend on `hop-core` by path in the monorepo. Across repos they resolve by
**crates.io version**, so each stays its own repo. On export Copybara injects a self-contained
`[workspace]` preamble into every Rust mirror's `Cargo.toml` (see `tools/copybara/copy.bara.sky`),
rewriting the inter-crate path deps to those crates.io versions; cargo resolves the inheritance to
concrete values at publish time. `hop-core` is the leaf, so it publishes first, then the stores /
`hop-wasm`; `libhop` and the services also pull `hop-endpoint-core` (`core/hop-endpoint`), which is not
mirrored yet, so publish that crate before their first release.

The crates.io names `hop-core` and `hop` are already taken by an unrelated project, so the published
crates use the `hop-mesh-*` convention (matches the `@hop-mesh` npm scope): `hop-core` -> `hop-mesh-core`,
`hop` -> `libhop`, `hop-store-sqlite` -> `hop-mesh-store-sqlite`, `hop-store-firestore` ->
`hop-mesh-store-firestore`, `hop-endpoint-core` -> `hop-mesh-endpoint-core`. This is a publish-name-only
rename in the mirror transform: the monorepo keeps the bare names and consumer code keeps `use hop_core`
(the preamble deps alias via `package = "..."`). Mirror repo names are unchanged.

## Server SDKs (host an endpoint)

Same Express/Fastify-shaped surface over `libhop`, one per language.

| Repo | From | Package |
| --- | --- | --- |
| `hop-sdk-node` | `sdk/node` | npm `@hop-mesh/endpoint` (**mirror already live, private**) |
| `hop-sdk-python` | `sdk/python` | PyPI |
| `hop-sdk-go` | `sdk/go` | Go module |
| `hop-sdk-ruby` | `sdk/ruby` | RubyGems |
| `hop-sdk-crystal` | `sdk/crystal` | shards |
| `hop-sdk-elixir` | `sdk/elixir` | Hex |

## Client SDKs (run a node on a device)

| Repo | From | Ships as | Audience |
| --- | --- | --- | --- |
| `hop-sdk-apple` | `sdk/apple` | SwiftPM + xcframework | iOS/macOS apps |
| `hop-sdk-android` | `sdk/android` | Maven (AAR) | Android apps |
| `hop-embedded` | `sdk/embedded` | PlatformIO (`Hop`) | ESP32 / Arduino / MCU firmware |

## Bearers (per-platform transports)

| Repo | From | Ships as |
| --- | --- | --- |
| `hop-bearers-apple` | `bearers/apple/*` | SwiftPM (BLE / LAN / Relay) |
| `hop-bearers-android` | `bearers/android` | Maven (BLE / LAN / Relay) |

**(open)** the three Apple bearer packages could be one repo with three products, or three repos. One
repo is simpler.

## Drivers (app-facing client layer)

| Repo | From | Ships as |
| --- | --- | --- |
| `hop-driver-apple` | `drivers/apple/HopDriver` | SwiftPM |
| `hop-driver-android` | `drivers/android/hop-driver` | Maven |

## Services (operator daemons)

| Repo | From | What it is |
| --- | --- | --- |
| `hop-relayd` | `services/hop-relayd` | The relay: the most internet-exposed process; store-and-forward for offline peers. |
| `hop-endpoint` | `services/hop-endpoint` | The `hops://` origin endpoint (HTTP-over-mesh, bound to one domain). |
| `hop-gateway` | `services/hop-gateway` | The gateway. |

## Not extracted (stay in the monorepo)

`sim/` + `core/hop-sim` (the swarm simulator, also the site's scenario player), `apps/*` (the demo
apps), `assets/`, `learn/`, `mockups/`, `infra/`, `docs/`, `tools/`. These are the monorepo's own
subsystems, not standalone deliverables.

`sdk/react-native` also stays here for now. It is a real client SDK, but the cross-platform surface is
being reworked, so it is deliberately NOT mirrored or published yet: no `components.json` entry, no
Copybara workflows, and no release pipeline. It is verified by the monorepo's own `React Native SDK`
CI job. Re-register it here when the approach settles.

## Rough count

~18 public repos: 5 core, 6 server SDKs, 2 client SDKs, 2 bearer sets, 2 drivers, 3 services (minus any
collapsed by the **(open)** decisions above). Each gets the marketable README + brand mark; the
`hop-sdk-node` mirror is the first one live.
