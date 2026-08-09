# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- stop the native bundle tag check from blocking patch-drifted SDKs (9e2428c)
- pin the checksum of the first reproducible xcframework (6be047b)
- make the xcframework reproducible so its checksum can be pinned (82b1bf8)
- point the published manifest at the v0.0.2 asset it can verify (806a538)
- make the PLAT-001 tests actually run, and correct what the last commit claimed (15065c8)
- disabling a transport now actually stops it (PLAT-001) (7b84c71)
- `git add -A` committed the swapped Apple manifest, and add the guard for it (228a20d)
- guard fixed-32-byte C-ABI reads in all wrappers (ADV18-06) (c95c826)

### CI
- bump create-github-app-token to v3.2.0 across all mirrored components (efc9f6c)
- drop unused attestation read access (0137b19)
- per-repo release workflows (publish on a vX.Y.Z tag) (277cf32)

### Chore
- purge em-dashes and en-dashes from source (d222435)
- drop the root license, license per-component (FSL-1.1-ALv2) (#146) (be2a5a7)

### Documentation
- regenerate from conventional commits (fc4e725)
- regenerate from conventional commits (910695c)
- regenerate from conventional commits (7160289)
- regenerate from conventional commits (3b47a5f)
- regenerate from conventional commits (ffb2acb)
- regenerate from conventional commits (e19ed95)
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
- bind the relay pool in every C-ABI wrapper, and make the ABI guard cover all twelve declarations (PLAT-003, PLAT-004) (ab53d1a)
- let a host enable and disable individual bearers at runtime (c17b01a)
- wire the relay pool end to end, and stop the wire guard false-firing (35946e0)
- CLA gate on contributions (preserve commercial relicensing of core) (5a9aa7d)
- SECURITY.md per component + enable-security in the bootstrap script (a1492e9)
- copyright holder is Hop Mesh, LLC (7d8c514)
- fill the Apache-2.0 copyright placeholder (2026 Jason Waldrip) (2fb7d1c)
- CHANGE_REQUEST sync-back + document merge/conversation + confidentiality (9e1dec2)

### Refactor
- enforce purpose/platform/package (collapse sdk/wrappers, apps/web -> apps/web/site) (#116) (afd52df)

