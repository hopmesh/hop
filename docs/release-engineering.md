# Release engineering

How Hop versions, tags, and publishes artifacts. Hop is pre-1.0 and ships from
`main`; this document defines the process we follow so a release is repeatable and
an operator can cut one without guessing.

## Version scheme

Two versions travel independently and MUST NOT be conflated:

1. Crate / product version: `[workspace.package] version` in the root `Cargo.toml`.
   Semantic-versioning-shaped, currently `0.0.x` (pre-1.0). Bumping this is a
   product release. All workspace crates inherit it via `version.workspace = true`.
2. Wire / ABI versions: the interop contract, versioned SEPARATELY from the product.
   - `BUNDLE_VERSION` (`core/hop-core/src/bundle.rs`): the on-the-wire bundle/frame
     format. A change here is a protocol break and needs the wire-stability test
     updated deliberately.
   - `HOP_ABI_VERSION` (`sdk/hop.h`, currently ABI 7): the C-ABI contract every
     non-Rust client binds. Wrappers assert `hop_abi_version() == HOP_ABI_VERSION`
     at load, so a mismatch fails loudly at app launch.

Rule: a product-version bump does NOT imply a wire/ABI bump, and vice versa. State
both in the release notes.

### Keep the ABI version in sync (thirteen copies, all guarded)
`HOP_ABI_VERSION` is hand-duplicated across the contract and every language wrapper,
and they must all agree:

- `core/hop/src/cabi.rs` (`pub const HOP_ABI_VERSION`), the source of truth, generated
  into `core/hop/include/hop.h` and `sdk/hop.h`.
- one compiled-in expectation per wrapper: `sdk/apple/Sources/Hop/Hop.swift`
  (`expectedABIVersion`), `sdk/android/.../Hop.kt`, `sdk/embedded/src/Hop.h`
  (`HOP_EMBEDDED_ABI_VERSION`), `sdk/go/hop.go` (`abiExpected`), `sdk/node/lib/ffi.mjs`,
  `sdk/python/hop_endpoint/_ffi.py`, `sdk/ruby/lib/hop/ffi.rb`,
  `sdk/crystal/src/hop/ffi.cr` (`ABI_EXPECTED`), `sdk/flutter/lib/src/ffi.dart`
  (`hopAbiVersion`).

`tools/codegen/check-abi-version.sh` does not work from that list. It SWEEPS the tree for
ABI-version literals, fails on any that disagrees with `cabi.rs`, fails on any it cannot
classify (so a fourteenth copy is caught the day it lands), fails when a listed site stops
declaring the constant, and fails when a wrapper pinned to the current level does not bind
the `hop_*` calls that level's bump note in `sdk/hop.h` names. It also holds prose that
states an ABI level ("asserts ABI 7") to the constant. It used to check six of twelve, and
that gap is how the v4 -> v5 bump shipped with a release validator still asserting the
retired level (PLAT-004).

An ABI bump therefore updates `cabi.rs`, regenerates the headers, updates every wrapper's
pinned constant, binds any new calls in every wrapper, and corrects the docs that state the
level, all in the same change. Run the guard locally; it names every location.

## Git tag scheme

- Tag each product release `vMAJOR.MINOR.PATCH` (e.g. `v0.0.2`), matching the root
  `Cargo.toml` version exactly.
- Annotated tags only (`git tag -a v0.0.2 -m "..."`), so the tag carries the
  release notes summary and the tagger identity.
- Tags are cut from `main` after CI is green. The tag SHA is the release SHA and is
  what every published artifact is built from.

## CHANGELOG process

- The project keeps a `CHANGELOG.md` at the repo root, newest entry first,
  Keep-a-Changelog-shaped (`Added` / `Changed` / `Fixed` / `Security` sections).
- Every user-visible or security-relevant change adds a line under an `[Unreleased]`
  heading as part of its PR.
- Cutting a release renames `[Unreleased]` to the new `vX.Y.Z` with the date, and
  opens a fresh empty `[Unreleased]`.
- Security fixes go under `Security` and, if they warrant it, a GitHub Security
  Advisory (see `SECURITY.md`).

## Signed-artifact publishing plan

Hop ships a Rust core plus per-platform wrappers and bearers. The publishing plan,
per surface:

### Canonical native provenance

The canonical native workflow starts from each `main` push alongside CI and builds every platform
without release secrets. Only after the exact source commit has a successful canonical CI gate can a
separate release job load the native key, create the complete archive inventory, sign its manifest,
and create a GitHub OIDC SLSA v1 Sigstore bundle over the manifest, signature, and every native archive.
The local Sigstore bundle is part of the immutable release artifact and is verified against the exact
canonical workflow, source SHA, ref, run attempt, GitHub-hosted runner, certificate invocation, and
complete 14-target subject set before a mirror publishes. GitHub's attestation API is an additional
storage mirror when the repository plan supports it, not the sole copy of provenance.

#### The credential that makes provenance work (and why nothing published without it)

Verifying provenance means reading the CANONICAL repository from a PUBLIC mirror: every mirror's
`release.yml` mints a GitHub App token and `release-provenance.py` follows the `GitOrigin-RevId` label
on the mirror commit back to the monorepo SHA, then checks that SHA's CI. That needs two secrets to
resolve inside the mirror's `release` environment:

| Secret | Value |
| --- | --- |
| `HOP_SOURCE_APP_ID` | the App's id |
| `HOP_SOURCE_APP_PRIVATE_KEY` | the App's PEM private key |

**Neither was ever seeded, on any mirror, at any scope**, so no component had ever published: 15 of 15
mirrors had their registry token in place (npm, PyPI, crates, RubyGems, Hex, Maven, PlatformIO) and
failed one step earlier. GitHub resolves an unset secret to the EMPTY STRING instead of erroring, so
the only symptom was a third-party action complaining `The 'client-id' (or deprecated 'app-id') input
must be set to a non-empty string`, which names no secret and no repository. Run
`python3 tools/release/check-mirror-secrets.py` to see the real state; it compares what each
release workflow REFERENCES against what is seeded at repository, environment, and organization scope.

**Use a dedicated read-only App, never the sync App.** `hop-component-sync` holds
`contents: write` + `workflows: write` on all 21 repositories, and it lacks `actions`/`checks` read
anyway, so minting would fail. More importantly this key lives on PUBLIC repositories: if the sync
App's key leaked, someone could rewrite every mirror and inject workflows, whereas a read-only App
leaks as read-only. That separation is why the workflows name it `HOP_SOURCE_APP_*` and not
`HOP_SYNC_APP_*`.

To arm publishing:

1. Create a GitHub App (org `hopmesh`), e.g. `hop-source-read`, with repository permissions
   **`actions: read`, `checks: read`, `contents: read` and nothing else**. Install it on
   **`hopmesh/monorepo` only**: the mirrors hold the key to mint the token, they are not its target.
2. Seed both values ONCE as organization secrets scoped to the publishing mirrors, rather than
   fifteen times (the release workflows read them through the `release` environment):

   ```sh
   gh secret set HOP_SOURCE_APP_ID --org hopmesh --visibility selected \
     --repos "$(python3 tools/release/check-mirror-secrets.py --json \
                | python3 -c 'import json,sys; print(",".join(e["component"] for e in json.load(sys.stdin)))')"
   gh secret set HOP_SOURCE_APP_PRIVATE_KEY --org hopmesh --visibility selected \
     --repos "<same list>" < /path/to/app-private-key.pem
   ```

3. Confirm with `python3 tools/release/check-mirror-secrets.py` (expects
   `all 3 publishing mirrors have every referenced secret seeded`), then re-run one mirror's failed
   `release` workflow to publish that component without creating a new tag.

Seeding the secrets is NOT sufficient on its own, and the three failure signatures at the mint step
say which piece is missing. Read the error rather than re-seeding:

| Mint step error | Meaning |
| --- | --- |
| `'client-id' ... must be set to a non-empty string` | the secrets do not resolve in this repo (unset, or scoped to the wrong repositories). Run the checker. |
| `Failed to create token for "hopmesh/monorepo": Not Found` (404, `get-a-repository-installation-for-the-authenticated-app`) | the App id and key are a valid pair, but the App is **not installed** on the org with `monorepo` selected. Install it; `gh api orgs/hopmesh/installations` should list it. |
| a 401, or `integration not found` | the id and the private key are not from the same App. |
| a permissions error naming actions/checks/contents | installed, but that permission was added after installation and the pending request was never approved. |

The three live mirrors (`hop-sdk-go`, `hop-sdk-crystal`, `hop-sdk-apple`) are tag-only, so any of them
is safe to test the credential on: each exercises mint, provenance, and artifact verification without
pushing to a registry, so a misconfiguration costs nothing irreversible. The registry-pushing mirrors
that once made this a choice were retired in 2026-08. `hop-bearers-apple` is configured as a fourth
and cannot be used for this: its repository does not exist yet, so a token minted for it fails at the
installation lookup rather than telling you anything about the credential.

The `release` environment on each mirror is an approval gate, so a release still waits for a human
even once the credential exists.

### ESP32 prebuilt archives: the download path is RETIRED

`libhop-esp-release.yml` used to build two ESP32 `libhop.a` archives plus `sdk/hop.h` and publish them
as a GitHub Release on a standalone `libhop` repo. That workflow is deleted, and the embedded prebuilt
download is explicitly retired in this same change.

1. **The publishing workflow could not run.** Its publish job minted a token from `HOP_RELEASE_APP_ID`
   / `HOP_RELEASE_APP_PRIVATE_KEY`, and neither name was ever provisioned in the org, the repository,
   or the `release` environment. Creating that App is an org-owner action, so the workflow sat in the
   tree as a documented path that nothing could exercise.
2. **The consumer repo is gone too.** `sdk/embedded`'s `release.yml` used to consume the signed native
   bundle from a standalone `hop-embedded` repo, and `install-libhop.py` pointed at the same place.
   That repo is being deleted and it had ZERO releases, which is why the download is retired outright
   rather than repointed at something else.
3. **The build is unaffected.** `native-artifacts.yml` still builds the embedded targets in tree
   (`xtensa-esp32-espidf`, `xtensa-esp32s2-espidf`, `xtensa-esp32s3-espidf`, `riscv32imc-esp-espidf`,
   `riscv32imac-esp-espidf`) under a signed manifest with a Sigstore bundle. What is retired is the
   standalone repo that redistributed the output, not the ability to produce it.

For the record, because an earlier comment in that workflow claimed the opposite: the path DID publish
once. The retired `libhop` repo's release `v0.0.1` (2026-07-17) carried `hop.h`,
`libhop-esp32-xtensa.a` and `libhop-esp32-riscv.a`, produced by the pre-`4d5344a` version of the
workflow, which used the org `HOP_SYNC_TOKEN` rather than a libhop-only App. Those are the only real
release assets the retired fleet ever held, and they were already documented as unsupported and
superseded. See `docs/repo-catalog.md`.

Restoring an ESP32 download path means deciding where it publishes FIRST, then restoring the workflow
from history and provisioning the App. Do not restore the workflow on its own: with no destination it
recreates the same dead path.

### Secret inventory: what checks that a workflow's credentials exist

`tools/workflow-secrets.json` declares every `secrets.NAME` the workflows read and the ONE scope it is
provisioned in. Three checks hold it to reality, and they answer different questions:

| Check | Runs | Answers |
| --- | --- | --- |
| `python3 tools/workflow-secrets-guard.py` | CI, every push (the `automation` job) | do the workflows and the manifest agree, does every environment-scoped name get read only by a job declaring that environment, and is every declared name covered by a presence job |
| the `secret-presence*` jobs in `branch-protection-audit.yml` | weekly cron plus pushes to `main` | is each declared name ACTUALLY set, asked from inside a job in that scope, with no credential (each name is passed as an is-it-non-empty boolean, never a value) |
| `python3 tools/workflow-secrets-guard.py --verify-live` | by hand, never in a workflow | the same question through the API, across org, repository and environment inventories. It needs `admin:org` plus secrets read, which no provisioned token here has, so no workflow runs it |

The static pass cannot detect a DELETED secret, only a manifest that disagrees with the workflow files.
That is what the presence jobs are for: deleting `BRANCH_PROTECTION_TOKEN` makes them red.

`MIRROR_SECRET_AUDIT_TOKEN` is declared `provisioned: false`: the `mirror-secrets` job in
`branch-protection-audit.yml` FAILS until that PAT exists, because a check that cannot read the thing it
audits must not report success. Either add the PAT (`secrets: read` on the mirrors, plus `admin:org`),
or delete that job and run `python3 tools/release/check-mirror-secrets.py` by hand.

### C ABI header (`sdk/hop.h`)

The universal contract. It is generated from `core/hop/src/cabi.rs` via cbindgen
(`core/hop/regen-header.sh`) and CI fails if the committed header drifts. On
release, tag the header state; downstream (ESP32, C++, ObjC) pins to a tag.
Any `HOP_ABI_VERSION` bump is a breaking release for all consumers.

### Apple: xcframework + SwiftPM

- Build the xcframework with `sdk/apple/build-xcframework.sh` (device +
  simulator slices).
- Publish plan: attach the built `.xcframework` (zipped) to the GitHub release for
  the tag, and reference it from `Package.swift` as a `binaryTarget` with the
  release URL and its checksum (`swift package compute-checksum`). The checksum is
  the integrity gate; sign the release artifact and, for a notarized distribution,
  codesign + notarize the framework before zipping.
- The three per-bearer SwiftPM packages (`bearers/apple/HopBearer{Ble,Lan,Relay}`; Multipeer /
  Wi-Fi P2P is an in-driver transport, not an extracted package)
  and the SDK wrapper are pitched as independently publishable. Each already carries its own
  `LICENSE.md` so the Apache-2.0 terms travel with the package (see the license note below).

### CocoaPods podspecs: the mirrors do not publish them (open gap)

`sdk/apple` ships three podspecs (`CHop`, `HopContract`, `HopSDK`) so the React Native SDK can depend on
the Apple SDK the ordinary CocoaPods way. Two facts make them unusable from outside the monorepo today,
and both are verified rather than assumed:

1. **No mirror carries them.** `hopmesh/hop-sdk-apple` has tags `v0.0.1` and `v0.0.2` and a `main`
   branch, and its tree contains ZERO `.podspec` files at any of those refs. An earlier
   `sdk/react-native/README.md` pointed consumers at those tags; every URL 404s.
2. **A raw-URL `:podspec` fetch cannot evaluate them even where the file exists.** Each podspec
   `File.read`s `Package.swift` from its own directory while CocoaPods evaluates it, and `CHop` reads
   `LICENSE.md` as well. A `:podspec =>` URL fetches one file into a temp directory with neither beside
   it, so evaluation dies on the first read (`CHop.podspec` line 19, `Errno::ENOENT`). Pointing at
   `raw.githubusercontent.com/hopmesh/hop/main/sdk/apple/*.podspec` therefore fails at `pod install`
   despite returning 200.

Consumers today must vendor five files side by side from a monorepo checkout (the three podspecs,
`Package.swift`, `LICENSE.md`), which is what `sdk/react-native/README.md` now documents. The real fix
is release engineering, not documentation: the `hop-sdk-apple` mirror's release workflow must publish
the three podspecs **alongside `Package.swift` and `LICENSE.md`** so an external `Podfile` can resolve
them without vendoring. Publishing the podspecs alone would recreate failure 2. Until that lands, do
not "fix" the README back to URLs on the strength of a 200 response.

### Android: AAR + Maven

- Build the Kotlin SDK wrapper AAR from `sdk/android` (Gradle). Bundle the
  `libhop` shared objects for `arm64-v8a`, `armeabi-v7a`, `x86`, and `x86_64`
  into the AAR's `jniLibs`.
- Publish plan: publish to a Maven repository (GitHub Packages or Maven Central)
  under a stable group id, versioned to the release tag. Sign artifacts with the
  Gradle signing plugin (GPG) so consumers can verify. Use the Gradle WRAPPER for
  reproducible builds (the CI currently uses the runner's system gradle; switch to
  `./gradlew` before publishing).

### Rust crates

- Each workspace crate carries its OWN crate-local `LICENSE.md`. Crates under
  `services/` use FSL-1.1-ALv2 (and point at it via `license-file = "LICENSE.md"`
  in their `[package]`, since FSL is not an SPDX id). Crates under `core/` use
  Apache-2.0. So a crate cut from the release tag with `cargo publish` ships
  its matching terms with no extra step.

## License note (per-component)

There is no repo-wide root license. Each component carries its own `LICENSE.md` so its
terms travel with any package or split repository. Components under `services/` use
FSL-1.1-ALv2; `core/`, SDKs, bearers, drivers, and apps use Apache-2.0. The
`tools/repo-integrity-guard.sh` check enforces the exact text for each tier and rejects
missing, truncated, or cross-tier copies. The Font Awesome asset license remains
separate from these code licenses.

## Pre-release checklist

1. CI green on the release SHA (tests, clippy, fmt, contract purity, header drift).
2. `cargo deny check` clean (advisories, licenses, bans, sources) per `deny.toml`.
3. `tools/codegen/check-abi-version.sh` passes (every `HOP_ABI_VERSION` copy, every
   wrapper's bound surface, and every doc claim agree with `cabi.rs`).
4. `CHANGELOG.md` `[Unreleased]` promoted to the new version + date.
5. `Cargo.toml` version bumped and the git tag matches it.
6. For any wire/ABI change, the wire-stability test was updated deliberately and the
   release notes call out the break.
7. The canonical native workflow succeeded and its attached Sigstore bundle verifies
   the exact source SHA, run attempt, and complete release inventory.
