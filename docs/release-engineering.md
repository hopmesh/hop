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
   - `HOP_ABI_VERSION` (`sdk/hop.h`, currently `2`): the C-ABI contract every
     non-Rust client binds. Wrappers assert `hop_abi_version() == HOP_ABI_VERSION`
     at load, so a mismatch fails loudly at app launch.

Rule: a product-version bump does NOT imply a wire/ABI bump, and vice versa. State
both in the release notes.

### Keep the ABI version in sync (three copies)

`HOP_ABI_VERSION` is hand-duplicated in three places and they must agree:

- `core/hop/src/cabi.rs` (`pub const HOP_ABI_VERSION`), generated into `sdk/hop.h`.
- `sdk/wrappers/apple/Sources/Hop/Hop.swift` (`expectedABIVersion`).
- `sdk/wrappers/android/.../Hop.kt` (`HOP_ABI_VERSION`).

CI checks the `cabi.rs` -> `sdk/hop.h` leg (the header-drift job regenerates the
header with cbindgen and diffs it). The Swift/Kotlin copies are NOT yet
cross-checked in CI, so a `cabi.rs` bump without touching the wrappers ships green
and only fails on-device via the runtime assert. Until a CI cross-check exists,
bumping the ABI version is a THREE-FILE edit; do all three in the same commit.

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

### C ABI header (`sdk/hop.h`)

The universal contract. It is generated from `core/hop/src/cabi.rs` via cbindgen
(`core/hop/regen-header.sh`) and CI fails if the committed header drifts. On
release, tag the header state; downstream (ESP32, C++, ObjC) pins to a tag.
Any `HOP_ABI_VERSION` bump is a breaking release for all consumers.

### Apple: xcframework + SwiftPM

- Build the xcframework with `sdk/wrappers/apple/build-xcframework.sh` (device +
  simulator slices).
- Publish plan: attach the built `.xcframework` (zipped) to the GitHub release for
  the tag, and reference it from `Package.swift` as a `binaryTarget` with the
  release URL and its checksum (`swift package compute-checksum`). The checksum is
  the integrity gate; sign the release artifact and, for a notarized distribution,
  codesign + notarize the framework before zipping.
- The three per-bearer SwiftPM packages (`bearers/apple/HopBearer{Ble,Lan,Relay}`; Multipeer /
  Wi-Fi P2P is an in-driver transport, not an extracted package)
  and the SDK wrapper are pitched as independently publishable. Each needs a LICENSE
  file so the FSL-1.1-ALv2 terms travel with the package (see the license note
  below).

### Android: AAR + Maven

- Build the Kotlin SDK wrapper AAR from `sdk/wrappers/android` (Gradle). Bundle the
  `libhop` shared objects for the Android ABIs (`arm64-v8a`, `x86_64` for the
  emulator) into the AAR's `jniLibs`.
- Publish plan: publish to a Maven repository (GitHub Packages or Maven Central)
  under a stable group id, versioned to the release tag. Sign artifacts with the
  Gradle signing plugin (GPG) so consumers can verify. Use the Gradle WRAPPER for
  reproducible builds (the CI currently uses the runner's system gradle; switch to
  `./gradlew` before publishing).

### Rust crates

- The workspace crates are FSL-licensed (`LICENSE.md`), which is not an SPDX id, so
  they are not published to crates.io as-is. If/when a crate is published, it is
  cut from the release tag with `cargo publish` and the FSL terms stated in the
  crate metadata (`license-file`).

## License note (per-artifact)

Hop ships under FSL-1.1-ALv2 (`LICENSE.md`), which is NOT an SPDX identifier. The
workspace root covers the Rust crates via `license-file`. The independently
publishable Swift/Kotlin packages and the per-bearer packages currently carry no
LICENSE file, so a published or vendored artifact would ship with no license terms.
Before publishing any package, add a LICENSE file (copy `LICENSE.md`) to that
package root so the FSL obligations (and the Font Awesome Pro caveat for app assets)
travel with the artifact.

## Pre-release checklist

1. CI green on the release SHA (tests, clippy, fmt, contract purity, header drift).
2. `cargo deny check` clean (advisories, licenses, bans, sources) per `deny.toml`.
3. All three `HOP_ABI_VERSION` copies agree.
4. `CHANGELOG.md` `[Unreleased]` promoted to the new version + date.
5. `Cargo.toml` version bumped and the git tag matches it.
6. For any wire/ABI change, the wire-stability test was updated deliberately and the
   release notes call out the break.
