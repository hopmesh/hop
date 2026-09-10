# Public repo catalog

This monorepo is the source of truth. Copybara mirrors a component subtree to its own standalone repo
and brings external contributions back without forking (see `tools/copybara/`). Mirror export from this
repository is true again as of 2026-09-04; the mirrors' history up to that point carries monorepo
GitOrigin-RevId trailers (since `hopmesh/monorepo` continued running mirror exports until its workflows
were disabled on 2026-09-04), which is why the first hop export was dispatched with `last_rev`.

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

Every published package whose `repository` field still points at the private `hopmesh/monorepo` is
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

**Publishing from the monorepo.** The monorepo publishing path is restored via
`tools/crates-publish.py dry-run` / `publish-all` and `.github/workflows/crates-publish.yml`,
using `CRATE_RENAMES` in `tools/copybara/copy.bara.sky`. The dry run produces `.crate` archives
and metadata for `hop-mesh-core`, `hop-mesh-store-sqlite`, and `hop-mesh-store-firestore`,
resolving all workspace dependencies into concrete crates.io version dependencies without path
fallbacks, and publishing `hop-mesh-core` first before its dependents.
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
paragraph said making that repo public would fix the links. It is not being made public: it is private,
archiving it remains an owner action, and the canonical source is now `hopmesh/hop`. So those v0.0.2
links stay dead permanently, because a package's metadata is baked in at publish time and cannot be
rewritten in place.

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

## Repository authority and reconciliation roadmap

### 1. Division of authority across the repository estate

Four repositories partition the project estate:

1. **`hopmesh/hop` (public)**: The canonical open-source repository and the sole workflow and deploy authority. Contains the protocol core (`core/hop-core`), C ABI (`core/hop`), browser WASM builds, client SDKs (`sdk/*`), platform bearers (`bearers/*`), demo applications (`apps/*`), website and developer documentation, CI verification guards, and deployment workflows. Public runtime and bootstrap OpenTofu move into `hop`. It owns public package distribution and mirror exports via `sync-components.yml` to the three standalone SDK mirrors (`hop-sdk-go`, `hop-sdk-crystal`, `hop-sdk-apple`). It owns marketing site deployment to `hopme.sh` via `pages.yml`. All deployment and release authority originates here.
2. **`hopmesh/platform` (private)**: Private source storage for commercial code only (`services/hop-accountd`, `services/hop-billingd`, `apps/web/console`, and private billing configuration). The hop deploy workflow will pin one immutable platform commit in `hop` and check it out only on trusted `main`/`workflow_dispatch` runs. A platform change does not deploy until the pin changes in a hop PR.
3. **`hopmesh/monorepo` (archived, historical trust anchor)**: The pre-split private monorepo is archived. No deployment may ever run from it. It serves strictly as an immutable historical trust anchor for releases `v0.0.1` and `v0.0.2`, and as a git reference archive for historical commits and branches. Archived GitHub repositories remain readable via Git and the web interface (their URLs do not 404), but all actions, workflows, write operations, and deployments are permanently stopped. No current or future executable edge, build, package metadata, workflow dispatch, source checkout, or post-migration trust authority may use it. Enforced by `tools/archive-readiness-guard.py`.
4. **`hopmesh/internal` (private)**: The repository for confidential artifacts, holding adversarial audit reports, remediation ledgers, business and financial models, and private test mockups.

### 2. Source of truth per asset

- **Relay fleet and console deploy**: `hopmesh/hop` is the sole deploy authority. The deployment workflow in `hop` pins an immutable commit of `hopmesh/platform` for commercial backend crates and checks it out only during trusted deploy runs. `hopmesh/monorepo` is archived and has zero deployment authority.
- **Terraform roots**: Public runtime and bootstrap OpenTofu roots reside in `hopmesh/hop`. Private billing configuration remains in `hopmesh/platform`, but apply workflows originate in `hopmesh/hop`.
- **Commercial backend (`hop-accountd`, `hop-billingd`)**: `hopmesh/platform` is the private source storage. Deployed via `hopmesh/hop` pinning an immutable commit.
- **Stripe and Resend configuration**: Stored in `hopmesh/platform`, applied via workflow originating in `hopmesh/hop`.
- **Public mirrors (`hop-sdk-go`, `hop-sdk-crystal`, `hop-sdk-apple`, `hop-bearers-apple`)**: `hopmesh/hop` is the sole source of truth. Copybara export is strictly one-directional from `hopmesh/hop` to the mirror repositories via `.github/workflows/sync-components.yml`. `hopmesh/monorepo` is not upstream for anything.
### 3. Forensic finding: why commits still land in the old monorepo and what production actually serves

Commits continue to land daily in `hopmesh/monorepo` due to an un-decommissioned automated changelog loop:

1. At 08:17 UTC daily, `.github/workflows/changelog.yml` in `hopmesh/monorepo` runs on a cron schedule (`17 8 * * *`).
2. It generates a changelog commit on branch `chore/changelog-<run_id>` authored by `hop-sync <sync@hopme.sh>`.
3. It opens a pull request against `main` in `hopmesh/monorepo`.
4. `.github/workflows/pr-automerge.yml` triggers on `pull_request_target` and arms auto-merge.
5. Monorepo's `.github/workflows/ci.yml` runs on the PR and succeeds.
6. GitHub merges the PR to `main` as `Merge pull request #<N> from hopmesh/chore/changelog-...` authored by `Jason Waldrip`.
7. The push to `main` triggers monorepo's `ci.yml` on `main`.
8. When `ci.yml` completes on `main`, `.github/workflows/runtime-deploy.yml` triggers via `workflow_run: workflows: ["CI"], types: [completed]`.
9. `runtime-deploy.yml` builds Docker images and applies `infra/` to GCP `hop-mesh-tfstate/relay-fleet`.

Evidence: Run 34357179362 completed successfully on 2026-09-09T13:27:23Z with `Apply complete! Resources: 0 added, 3 changed, 0 destroyed.` at 13:36:04Z.

Deploy attribution is confirmed by direct observation on the live infrastructure: all three live Cloud Run services in `hop-mesh` (`hop-console`, `hop-accountd`, and `hop-example`) carry the label `hop-source-sha: b149f04a287344af3a571018fe290b78b6f98b87`, updated between 13:34Z and 13:35Z on 2026-09-09, exactly matching today's auto-merged commit in `hopmesh/monorepo`.

However, what is actually serving must be distinguished by service:
- The three deployed Cloud Run services are `hop-console`, `hop-accountd`, and `hop-example` (the relay fleet is currently disabled, `relays_enabled=false`).
- `hop-console` and `hop-accountd` do NOT exist in `hopmesh/hop` at all. In `hopmesh/hop`, `services/` holds only `hop-endpoint`, `hop-gateway`, `hop-relayd`, and `hop-telemetryd`, and the root `Cargo.toml` deliberately excludes `hop-accountd` and `hop-billingd` from the public export. For these two commercial services, `hopmesh/monorepo` is not a rogue duplicate; it is currently the only active deploying home they have.
- The one deployed service that does diverge from code maintained in `hopmesh/hop` is `hop-example` (built from `services/hop-endpoint`). In `hopmesh/monorepo`, `services/hop-endpoint` was last modified on 2026-08-12 (`5c12557b`) and its underlying protocol dependency `core/hop-core/src/node.rs` was last modified on 2026-08-06 (`40ae3907`). In `hopmesh/hop`, `core/hop-core/src/node.rs` was updated on 2026-09-09 at `9fe9c3a0`. This represents a month of protocol hardening and wire updates sitting in `hopmesh/hop` that `hop-example` in production does not receive.
- The primary operational risk is state collision and divergence. Both `hopmesh/monorepo` and `hopmesh/platform` declare the exact same OpenTofu backend bucket and prefix (`bucket = "hop-mesh-tfstate"`, `prefix = "relay-fleet"`). Whichever repository applies next wins the state, and the two trees disagree by more than a month of protocol and service commits.

### 4. Forensic finding: five consecutive Infrastructure drift failures in platform

In `hopmesh/platform`, the scheduled workflow `.github/workflows/infra-drift.yml` failed every day from 2026-09-05 through 2026-09-09 (runs 33969536771, 34037537854, 34142446473, 34241046901, and 34367309003).

Inspection of run 34367309003 shows the exact failure:
- Job: `Bootstrap IAM matches main`
- Step: `materialize bootstrap tfvars`
- Command: `test -n "$BOOTSTRAP_TFVARS" || { echo "BOOTSTRAP_TFVARS secret is empty" >&2; exit 1; }`
- Output: `BOOTSTRAP_TFVARS secret is empty` (exit code 1).

Root cause: `hopmesh/platform` has zero Actions secrets provisioned (`gh api repos/hopmesh/platform/actions/secrets` returns `[]`). While repository variables for WIF were created, the repository secrets `BOOTSTRAP_TFVARS`, `STRIPE_API_KEY`, and `RESEND_API_KEY` were never copied from `hopmesh/monorepo` to `hopmesh/platform`. Consequently, `Infrastructure drift` cannot authenticate to plan bootstrap IAM, and `Billing catalog` cannot run.

### 5. Monorepo workflow audit

Audit of every workflow in `hopmesh/monorepo`:

| Workflow | File | Trigger | Most recent success | Classification | Status and role |
| --- | --- | --- | --- | --- | --- |
| Runtime deploy | `.github/workflows/runtime-deploy.yml` | `workflow_run` (CI on main) | 2026-09-09T13:27:23Z | (b) Sole owner (active) | Sole active automated deployer to `hop-mesh-tfstate/relay-fleet`. Deploys monorepo commercial services and console daily. |
| Bootstrap root | `.github/workflows/bootstrap-apply.yml` | `pull_request`, `workflow_dispatch` | 2026-08-16T17:17:05Z | (b) Sole owner | Holds the last successful apply of bootstrap IAM and WIF. Platform has failed applies. |
| Billing catalog | `.github/workflows/billing-catalog.yml` | `pull_request`, `workflow_dispatch` | 2026-08-16T16:11:17Z | (b) Sole owner | Holds the last successful apply of the Stripe catalog and Resend domain. |
| Changelog | `.github/workflows/changelog.yml` | `schedule` (08:17 UTC daily) | 2026-09-09T12:58:56Z | (a) Redundant | Duplicated in hop. Harmful: drives the daily commit loop that triggers automated deploys. |
| PR auto-merge | `.github/workflows/pr-automerge.yml` | `pull_request_target` | 2026-09-09T13:02:30Z | (a) Redundant | Duplicated in hop. Harmful: automatically merges the daily changelog PRs. |
| CI | `.github/workflows/ci.yml` | `push: [main]`, `pull_request` | 2026-09-09T13:14:44Z | (a) Redundant | Duplicated in hop. In monorepo, its completion acts as the trigger for runtime deploy. |
| Native artifacts | `.github/workflows/native-artifacts.yml` | `push: [main]` | 2026-09-09T13:14:44Z | (a) Redundant | Duplicated in hop. In monorepo, artifacts are not consumed because release-tags is disabled. |
| Branch protection audit | `.github/workflows/branch-protection-audit.yml` | `schedule`, `workflow_dispatch` | 2026-09-07T18:15:22Z | (a) Redundant | Duplicated in hop. Audits monorepo branch protection only. |
| Deep fuzz | `.github/workflows/fuzz.yml` | `schedule`, `workflow_dispatch` | 2026-09-08T08:50:58Z | (a) Redundant | Duplicated in hop. Runs weekly fuzzing on stale monorepo code. |
| Workflow freshness | `.github/workflows/workflow-freshness.yml` | `schedule`, `workflow_dispatch` | 2026-09-08T14:51:39Z | (a) Redundant | Duplicated in hop. Runs daily freshness checks on monorepo workflows. |
| Tag Claude on failing dep PRs | `.github/workflows/dep-fix-tag.yml` | `workflow_run` (CI) | 2026-09-04T19:08:39Z | (a) Redundant | Duplicated in hop. |
| canary-selfhosted-docker | `.github/workflows/canary-selfhosted-docker.yml` | `push` (canary branch) | None (failed 2026-07-17) | (c) Dead | Deleted on main; only failed canary branch run in history. |
| Resend domain | `.github/workflows/resend-domain.yml` | `pull_request` | None (skipped 2026-07-24) | (c) Dead | Deleted on main; superseded by `billing-catalog.yml`. |
| Sync component | `.github/workflows/sync-components.yml` | `push`, `workflow_dispatch` | 2026-09-04T18:57:51Z | (a) Redundant / (c) Dead | Manually disabled on 2026-09-04. Duplicated and active in hop. |
| Deploy marketing site | `.github/workflows/pages.yml` | `push` | 2026-09-04T18:57:51Z | (a) Redundant / (c) Dead | Manually disabled on 2026-09-04. Duplicated and active in hop. |
| Release tags | `.github/workflows/release-tags.yml` | `workflow_run` | 2026-09-04T19:17:37Z | (a) Redundant / (c) Dead | Manually disabled on 2026-09-04. Duplicated and active in hop. |

### 6. The Archive Invariant and Cutover Architecture

The owner decided that `hopmesh/monorepo` must be archived and no deployment may ever run from it; every deployment action must originate in `hopmesh/hop`.

#### The archive invariant

`hopmesh/monorepo` is archived. It remains a historical trust anchor and git reference archive, but no current or future executable edge may use it:

1. **Historical trust anchor**: `v0.0.1` and `v0.0.2` release assets and Sigstore certificate provenance legitimately name `hopmesh/monorepo`. `sdk/go/cmd/hop-install/main.go` pins `legacyBuilder` and `legacyRepository` exclusively for those two tags. That anchor is immutable and must stay.
2. **Git reference archive**: GitHub archives retain all commits, branches, tags, and pull requests. Archived URLs remain readable via Git and web UI (they do not 404). This preserves the audit trail and reference history.
3. **Zero executable authority**: No current or future executable edge, workflow run, build, deployment, workflow dispatch, source checkout, package manifest repository field, or post-migration trust authority may reference `hopmesh/monorepo`. Any post-migration tag (`v0.0.3`+) naming the legacy builder or repository is strictly rejected.
4. **Automated enforcement**: Enforced in CI by `tools/archive-readiness-guard.py` (self-tested by `tools/archive-readiness-guard.test.sh`).

#### Reconciled monorepo branch inventory

The four unique monorepo branches reported by the reference audit have been reconciled by content against `hop` main:

- **`assets/email-logo` (commit `85d657b8`)**: Already present. The email-safe logo asset `apps/web/site/public/logo-email.png` in `hop` main is byte-identical (SHA-256 `e896127b6b864adaf391a2f28c9c9bf4eca0311dde87915799d1f6f559754b5c`).
- **`rnquickstart-docs` (commit `cf7bc9b5`)**: Superseded. The React Native quickstart documentation and SDK guides were merged into `hop` via commit `9a57b16f` and subsequently updated and refined across commits `bcb3796a`, `70378e00`, and `acabb035`.
- **Meshtastic bearer (commit `943f4db6`)**: Superseded. The Meshtastic SDK bearer implementation was merged into `hop` via PR #382 (commit `e0d0c298`), and subsequently hardened with audit PLAT-006 security fixes (`fa4bf985`, `2ed71390`, `8e5f47b6`, `c6545638`).
- **Tor relay spike (commit `a64fa6c1`)**: Superseded. The Tor onion relay spike from `feat/tor-onion-relay` was merged into `hop` via PR #342 (commit `e15a52ed`). Commit `a64fa6c1` was a later monorepo branch worktree merge of hop main into `feat/tor-onion-relay`.

Because the archived monorepo retains all git references, no cherry-picking was required and no unrelated feature code is landed in this cutover.

#### Transition architecture

1. **Workflow authority in `hop`**: `hopmesh/hop` becomes the sole deploy and workflow authority. Public runtime and bootstrap OpenTofu roots move into `hop`.
2. **Private source pinned in `platform`**: `hopmesh/platform` houses commercial code (`services/hop-accountd`, `services/hop-billingd`, `apps/web/console`, and private billing configuration). The `hop` deploy workflow pins an immutable commit of `platform` and checks it out only during trusted deployment runs. A platform change does not deploy until its pin changes in a `hop` PR.
3. **Monorepo permanently deactivated**: The daily changelog loop and automated deployments in `hopmesh/monorepo` are terminated, and the repository is archived.
