# Public repo catalog

This monorepo is the source of truth. Copybara mirrors a component subtree to its own standalone repo
and brings external contributions back without forking (see `tools/copybara/`).

As of the 2026-08 mirror retirement, three components mirrored; twenty were retired and their repos
deleted from the `hopmesh` org. One of the twenty, `hop-bearers-apple`, has been WIRED for return
(`components.json`, `copy.bara.sky`, and the subtree's `release.yml` and `sync-back.yml` all name it)
but its repository has NOT been created: `hopmesh/hop-bearers-apple` returns 404 and has never
existed, so nothing has ever been exported to it and no consumer can resolve it. Recreating it is a
human action per `tools/copybara/bootstrap-mirrors.sh`, followed by one seeded `init_history` export.
So **three** components mirror today, a fourth is configured and waiting on that repository, and
nineteen names remain retired. This file records both sets, because the difference is load bearing: a
name in the retired table is a repo that no longer exists, and any link to it 404s. The same is true
today of the wired-but-absent fourth.

Licensing has two tiers and `tools/repo-integrity-guard.sh` fails CI on a cross-tier license, so this
file is not a second source of truth. The services (`services/*`) are FSL-1.1-ALv2, which is
source-available; everything else, including the protocol core, is Apache-2.0. See the License section
of `README.md`.

## The three live mirrors, and one wired but absent

| Repo | From | Ships as | Audience | State |
| --- | --- | --- | --- | --- |
| `hop-sdk-go` | `sdk/go` | Go module | Go services hosting an endpoint | live |
| `hop-sdk-crystal` | `sdk/crystal` | shards | Crystal services hosting an endpoint | live |
| `hop-sdk-apple` | `sdk/apple` | SwiftPM + xcframework | iOS/macOS apps | live |
| `hop-bearers-apple` | `bearers/apple` | SwiftPM | iOS/macOS apps that need the radios (BLE, LAN, Multipeer, Relay, Meshtastic) without the monorepo | WIRED, repo does not exist |

All of them publish by pushing a git tag: the repo is the package. None needs a registry account, a
registry token, or a trusted-publisher configuration, which is why the three SDKs survived the
retirement and why `hop-bearers-apple` is the mirror worth restoring: its package manager resolves
from a repo root too. That restoration is not done. `tools/copybara/components.json` is the dispatch
allowlist and `tools/copybara/copy.bara.sky` holds the matching list; their CI self-test rejects any
drift between the two, which is why the config can be complete while the destination is missing.

## Retired mirrors (the repos are deleted)

Each component below still lives in the monorepo at the prefix shown. It is built and tested here, and
it is not separately published. Only the standalone mirror repo went away.

| Retired repo | Monorepo home |
| --- | --- |
| `hop-core` | `core/hop-core` |
| `libhop` | `core/hop` |
| `hop-wasm` | `core/hop-wasm` |
| `hop-store-sqlite` | `core/stores/hop-store-sqlite` |
| `hop-store-firestore` | `core/stores/hop-store-firestore` |
| `hop-sdk-node` | `sdk/node` |
| `hop-sdk-python` | `sdk/python` |
| `hop-sdk-ruby` | `sdk/ruby` |
| `hop-sdk-elixir` | `sdk/elixir` |
| `hop-sdk-android` | `sdk/android` |
| `hop-sdk-compose` | `sdk/compose` |
| `hop-sdk-flutter` | `sdk/flutter` |
| `hop-embedded` | `sdk/embedded` |
| `hop-bearers-android` | `bearers/android` |
| `hop-driver-apple` | `drivers/apple/HopDriver` |
| `hop-driver-android` | `drivers/android/hop-driver` |
| `hop-relayd` | `services/hop-relayd` |
| `hop-endpoint` | `services/hop-endpoint` |
| `hop-gateway` | `services/hop-gateway` |

Do not re-add one of these names to `components.json` expecting the repo to be there. Restoring a
mirror means creating the repo again and seeding it with a fresh `init_history` export.
`hop-bearers-apple` is the live demonstration of why those are two separate steps: it was re-added to
the config, which is why it sits in the table above, and the repository was never created, so nothing
has been exported to it.

## Not extracted (stay in this repo)

`sim/` + `core/hop-sim` (the swarm simulator, also the site's scenario player), `apps/*` except the
console (the demo apps), `assets/`, `learn/`, `docs/`, `tools/`. These are this repo's own subsystems,
not standalone deliverables.

Moved OUT, and no longer here at all, so do not look for them in this tree:

| tree | now lives in |
| --- | --- |
| `services/hop-accountd`, `services/hop-billingd` | `hopmesh/platform` (private) |
| `apps/web/console` | `hopmesh/platform` |
| `infra/` | `hopmesh/platform` |
| `mockups/` | `hopmesh/internal` (private) |
| `docs/audits/`, `business/` | `hopmesh/internal` |

`sdk/react-native` also stays here. It is a real client SDK, but the cross-platform surface is being
reworked, so it is deliberately not mirrored or published: no `components.json` entry, no Copybara
workflows, and no release pipeline. It is verified by this repo's own `React Native SDK` CI job.

## Registry fallout of the mirror retirement

Deleting a mirror does not unpublish anything that already shipped from it. This section is the durable
record of what is published, what is not, and which published artifact now carries a dead source link,
so it does not have to be rediscovered by hand. All of it was verified at retirement time.

Every published package whose `repository` field still points at the archived `hopmesh/monorepo` is
enumerated below, and the resolution is in "The published source links are permanently dead, and the
in-tree fix is already in" at the end of this section. Short version: those links cannot be repaired
retroactively, and the in-tree metadata already names `hopmesh/hop` for the next publish.

### Published, and affected

- **npm `@hop-mesh/endpoint` v0.0.2** is published. Its `repository` field points at
  `hopmesh/hop-sdk-node`, which is being deleted, so the source link on its
  [npm page](https://www.npmjs.com/package/@hop-mesh/endpoint) will 404.

### Published, and unaffected by mirror deletion

- **npm `@hop-mesh/wasm` v0.0.2**, whose `repository` field points at `hopmesh/monorepo` rather than
  at a mirror. See [its npm page](https://www.npmjs.com/package/@hop-mesh/wasm).
- **Three crates on crates.io**, all v0.0.2, all naming `hopmesh/monorepo` in `repository`. They
  publish under a RENAMED scheme because our natural names were already taken, so the crate you want
  is never the name the directory has:

| Monorepo crate | Published as | Page |
| --- | --- | --- |
| `core/hop-core` | `hop-mesh-core` | [crates.io/crates/hop-mesh-core](https://crates.io/crates/hop-mesh-core) |
| `core/stores/hop-store-sqlite` | `hop-mesh-store-sqlite` | [crates.io/crates/hop-mesh-store-sqlite](https://crates.io/crates/hop-mesh-store-sqlite) |
| `core/stores/hop-store-firestore` | `hop-mesh-store-firestore` | [crates.io/crates/hop-mesh-store-firestore](https://crates.io/crates/hop-mesh-store-firestore) |

**Keep that mapping.** It used to live in `CRATE_RENAMES` in `tools/copybara/copy.bara.sky`, which the
retirement emptied out because no Rust crate MIRROR survived. True about mirrors, but it deleted the
only in-tree record of the local-to-published naming for three crates that are still live. Someone
grepping crates.io for `hop-store-sqlite` lands on a 404 and concludes we never shipped it.

**Those three crates now have no publishing path, and that is a real gap rather than a tidy-up.** They
were published FROM the Rust mirrors: `tools/crates-publish.py` reached a mirror only through
`RUST_EXPORTS` in `tools/package-export-smoke.py`, which copies it to `.github/crates-publish.py`, and
that copy is gated on `component in RUST_MIRRORS`. With `RUST_MIRRORS` empty, nothing exports it, and no
monorepo workflow invokes `crates-publish.py publish` either (verified: zero hits across
`.github/workflows/`). So a new version of any of the three cannot currently be cut from anywhere.

Worse, the obvious repair is a trap. Publishing straight from the monorepo would use each crate's own
`[package] name`, which is `hop-core`, `hop-store-sqlite` and `hop-store-firestore`. `hop-core` on
crates.io belongs to an unrelated third party, so that publish would either fail or, for the two store
crates, silently claim NEW names and orphan the `hop-mesh-*` ones already depended on. Whoever wires
monorepo-side crate publishing has to carry the rename forward deliberately; it is a release contract,
not a naming preference.

Everything above is confirmed ours by scope or namespace AND by the `repository` field, which is the
standard to meet before calling any package ours. A URL returning 200 proves the name is taken, not
that we own it.

### Maven: no Central release, but the LOCAL publication path is live

Searched 2026-08: group ids `sh.hop` and `sh.hop.bearers` return ZERO artifacts on Maven Central, so
nothing of ours is published there and no released POM carries a stale URL.

That is NOT the same as the publication path being dead, and an earlier draft of this section wrongly
said it was. `sdk/android/build-aar.sh` runs `publishHopPublicationToHopRepository` into a local Maven
repository, and `tools/package-export-smoke.py` runs that script and asserts the resulting AAR. So a POM
IS generated and verified on every exercise of that path, which means the values inside it are live
inputs rather than decoration.

Because of that, the three POM blocks in `bearers/android/build.gradle.kts`,
`sdk/android/build.gradle.kts` and `sdk/compose/build.gradle.kts` were CHANGED rather than left alone:
each `url` now points at `https://hopme.sh`, and the `scm` block was removed outright. A POM `scm` is
optional, and there was no truthful public value left for it once the mirrors were deleted, since the
only remaining git home is the private monorepo. Pointing it at a private URL would have been worse
than omitting it.

### The endpoint SDKs ARE published, under `hop-endpoint`

Corrected after an initial sweep searched the wrong names (`hop-mesh`, `hop`) and wrongly concluded
these were unpublished. All three are ours, at v0.0.2, in lockstep with `sdk/python/pyproject.toml`:

| Registry | Package | Ownership evidence |
| --- | --- | --- |
| PyPI | [`hop-endpoint`](https://pypi.org/project/hop-endpoint/) | summary is verbatim our `sdk/python` description; v0.0.2 lockstep. No author or homepage field is set, which is worth fixing on the next publish. |
| RubyGems | [`hop-endpoint`](https://rubygems.org/gems/hop-endpoint) | authors `Jason Waldrip`, `homepage_uri` `https://hopme.sh` |
| Hex | [`hop_endpoint`](https://hex.pm/packages/hop_endpoint) | owners `["jwaldrip"]`, `meta.links.Homepage` `https://hopme.sh` |

**Known fallout that only a re-publish can fix:** Hex's own `meta.links.GitHub` for `hop_endpoint`
still points at `hopmesh/hop-sdk-elixir`, which is deleted. That value lives in the published release
metadata on hex.pm, not in this tree, so removing the dead `source_url` from `sdk/elixir/mix.exs` (done)
only stops the NEXT publish from repeating it. The live page keeps the dead link until a new version
ships.

The standard applied throughout this section: a package is ours only when its scope, maintainer, or
metadata ties it back to `hopmesh` or `hopme.sh`. A URL returning 200 proves the name is taken, nothing
more. That trap caught this catalog twice, on `hop-core` and again on the endpoint SDKs.

### Names that are NOT ours, and names that do not exist

Never link these, and never invent one:

- **`hop-core` and `hop` on crates.io belong to unrelated third parties.** `hop-core` is JROChub's
  crate (`JROChub/hop-corr`) and `hop` is `hopinc/rs`. Our equivalents are the `hop-mesh-*` names
  above. This is the exact trap that a liveness check walks into.
- **These `hop-mesh-*` names are confirmed 404 on crates.io**, so do not cite them as though they
  resolve: `hop-mesh-wasm`, `hop-mesh-sim`, `hop-mesh-ffi`, `libhop-sys`, `hop-mesh-relayd`,
  `hop-mesh-endpoint`, `hop-mesh-gateway`.
- **The bare `hop` names on PyPI, Hex and pub.dev belong to unrelated authors.** They are `balor/hop`,
  `seanmor5/hop` and `kevmoo/hop`. Our endpoint SDKs do NOT use that name, so a search for `hop` finds
  a stranger every time. Narrow warning, not a blanket one: see the endpoint packages below, which ARE
  ours.
- **pub.dev and PlatformIO genuinely have nothing of ours.** `hop_endpoint` on pub.dev is a confirmed
  404 and no `Hop` library exists on the PlatformIO registry, so the Flutter and embedded SDKs are the
  two that really are unpublished.

### The published source links are permanently dead, and the in-tree fix is already in

Worth stating plainly so the sequence is not misread, and this paragraph has been REWRITTEN because its
earlier conclusion is now obsolete.

All three crates and `@hop-mesh/wasm` at v0.0.2 point their `repository` field at `hopmesh/monorepo`.
That was already broken for the public before the mirror retirement, because the repo was private, so
the retirement did not cause it. What has changed is the resolution. The earlier version of this
paragraph said making that repo public would fix the links. It is not being made public: it is being
ARCHIVED, and the canonical source is now `hopmesh/hop`. So those v0.0.2 links stay dead permanently,
because a package's metadata is baked in at publish time and cannot be rewritten in place.

The in-tree fix is landed rather than pending. The workspace `repository` field, which every crate and
the wasm package inherit, now names `hopmesh/hop`, and `sdk/node/package.json` carries an explicit
`repository` with `directory: sdk/node` (it previously had none, and its published metadata came from
the deleted `hop-sdk-node` mirror). So the NEXT publish of each resolves. Nothing retroactively fixes
v0.0.2.

`@hop-mesh/endpoint` is the one the retirement genuinely broke on its own, because it pointed at a
mirror that was deleted rather than at a repo that was due to open.

### Release assets held by the retired repos

`hopmesh/libhop` held the only real release assets among the retired fleet: a single `v0.0.1` carrying
`hop.h`, `libhop-esp32-xtensa.a` and `libhop-esp32-riscv.a`. That release was already documented as
unsupported and superseded before the retirement. See the ESP32 section of
`docs/release-engineering.md`.

The other nineteen retired repos hold **zero** release assets.
