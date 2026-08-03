# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- stop the native bundle tag check from blocking patch-drifted SDKs (9e2428c)
- make the PLAT-001 tests actually run, and correct what the last commit claimed (15065c8)
- disabling a transport now actually stops it (PLAT-001) (7b84c71)

### CI
- bump create-github-app-token to v3.2.0 across all mirrored components (efc9f6c)
- drop unused attestation read access (0137b19)

### Chore
- bump android + embedded to 0.0.4 so both can finally publish (9ceb2e6)
- bump android + embedded to 0.0.3 to release the two fixes (4e8924f)
- purge em-dashes and en-dashes from source (d222435)
- drop the root license, license per-component (FSL-1.1-ALv2) (#146) (be2a5a7)

### Dependencies
- AGP 9.3 + Gradle 9.6.1 + Kotlin 2.4.10 + core-ktx 1.19.0 (13 held bumps) (471edb7)

### Documentation
- regenerate from conventional commits (7a81fb6)
- regenerate from conventional commits (e6b97f2)
- regenerate from conventional commits (2741000)
- the deferred-teardown note was itself an overclaim (bc86421)
- regenerate from conventional commits (b96e019)
- regenerate from conventional commits (330c8c6)
- regenerate from conventional commits (096180b)
- regenerate from conventional commits (102ae67)
- regenerate from conventional commits (1572ae2)
- regenerate from conventional commits (a355901)
- branded, marketable READMEs for every sub-repo (9c2a477)

### Features
- finish inbound (import), drop export_pr (41c095e)
- auto-generate monorepo + per-library changelogs (git-cliff) (8c64c37)
- self-certifying reachability records (core + ABI) for DNS-free endpoint discovery (#126) (7c31123)

### Other
- bump android and embedded to 0.0.5 for a taggable commit (fb6966a)
- bump embedded and android to 0.0.2, and stop the tagger guessing their version (b655972)
- per-transport switches, and show when the SENDER sent a message (7a923c0)
- let a host enable and disable individual bearers at runtime (c17b01a)
- wire the relay pool end to end, and stop the wire guard false-firing (35946e0)
- CLA gate on contributions (preserve commercial relicensing of core) (5a9aa7d)
- SECURITY.md per component + enable-security in the bootstrap script (a1492e9)
- copyright holder is Hop Mesh, LLC (7d8c514)
- fill the Apache-2.0 copyright placeholder (2026 Jason Waldrip) (2fb7d1c)
- CHANGE_REQUEST sync-back + document merge/conversation + confidentiality (9e1dec2)

### Refactor
- enforce purpose/platform/package (collapse sdk/wrappers, apps/web -> apps/web/site) (#116) (afd52df)

