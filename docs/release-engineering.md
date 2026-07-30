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
   - `HOP_ABI_VERSION` (`sdk/hop.h`, currently `4`): the C-ABI contract every
     non-Rust client binds. Wrappers assert `hop_abi_version() == HOP_ABI_VERSION`
     at load, so a mismatch fails loudly at app launch.

Rule: a product-version bump does NOT imply a wire/ABI bump, and vice versa. State
both in the release notes.

### Keep the ABI version in sync (three copies)

`HOP_ABI_VERSION` is hand-duplicated in three places and they must agree:

- `core/hop/src/cabi.rs` (`pub const HOP_ABI_VERSION`), generated into `sdk/hop.h`.
- `sdk/apple/Sources/Hop/Hop.swift` (`expectedABIVersion`).
- `sdk/android/.../Hop.kt` (`HOP_ABI_VERSION`).

CI regenerates `sdk/hop.h` from `cabi.rs` and checks the Rust, header, Swift, and
Kotlin values together. An ABI bump updates `cabi.rs`, regenerates the header, and
updates both wrappers in the same commit.

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
   `all 15 publishing mirrors have every referenced secret seeded`), then re-run one mirror's failed
   `release` workflow to publish that component without creating a new tag.

Seeding the secrets is NOT sufficient on its own, and the three failure signatures at the mint step
say which piece is missing. Read the error rather than re-seeding:

| Mint step error | Meaning |
| --- | --- |
| `'client-id' ... must be set to a non-empty string` | the secrets do not resolve in this repo (unset, or scoped to the wrong repositories). Run the checker. |
| `Failed to create token for "hopmesh/monorepo": Not Found` (404, `get-a-repository-installation-for-the-authenticated-app`) | the App id and key are a valid pair, but the App is **not installed** on the org with `monorepo` selected. Install it; `gh api orgs/hopmesh/installations` should list it. |
| a 401, or `integration not found` | the id and the private key are not from the same App. |
| a permissions error naming actions/checks/contents | installed, but that permission was added after installation and the pending request was never approved. |

Prefer a tag-only mirror (`hop-bearers-apple`, `hop-driver-apple`, `hop-sdk-apple`, `hop-sdk-crystal`)
when testing the credential: those exercise mint, provenance, and artifact verification without pushing
to any registry, so a misconfiguration costs nothing irreversible. Do not test on `hop-sdk-python`,
whose 0.0.1 already exists on PyPI from the bootstrap publish and would fail on a duplicate version
even when everything else is correct.

The `release` environment on each mirror is an approval gate, so a release still waits for a human
even once the credential exists.

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

- Each workspace crate carries its OWN crate-local `LICENSE.md` (FSL-1.1-ALv2) and
  points at it via `license-file = "LICENSE.md"` in its `[package]` (FSL is not an
  SPDX id, so it is a `license-file`, not a `license` field). So a crate cut from
  the release tag with `cargo publish` ships its FSL terms with no extra step.

## License note (per-component)

There is no repo-wide root license. Each component carries its own `LICENSE.md` so its
terms travel with any package or split repository. Components under `core/` use
FSL-1.1-ALv2; SDKs, services, bearers, drivers, and apps use Apache-2.0. The
`tools/repo-integrity-guard.sh` check enforces the exact text for each tier and rejects
missing, truncated, or cross-tier copies. The Font Awesome asset license remains
separate from these code licenses.

## Pre-release checklist

1. CI green on the release SHA (tests, clippy, fmt, contract purity, header drift).
2. `cargo deny check` clean (advisories, licenses, bans, sources) per `deny.toml`.
3. All three `HOP_ABI_VERSION` copies agree.
4. `CHANGELOG.md` `[Unreleased]` promoted to the new version + date.
5. `Cargo.toml` version bumped and the git tag matches it.
6. For any wire/ABI change, the wire-stability test was updated deliberately and the
   release notes call out the break.
7. The canonical native workflow succeeded and its attached Sigstore bundle verifies
   the exact source SHA, run attempt, and complete release inventory.
