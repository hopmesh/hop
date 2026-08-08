# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- make the published bearer and driver packages actually resolvable (b3eaec2)
- per-mirror repository, and retryable release artifacts (bf04449)

### CI
- bump create-github-app-token to v3.2.0 across all mirrored components (efc9f6c)
- per-repo release workflows (publish on a vX.Y.Z tag) (277cf32)

### Chore
- purge em-dashes and en-dashes from source (d222435)
- drop the root license, license per-component (FSL-1.1-ALv2) (#146) (be2a5a7)
- finish the monorepo layout, kill platform stubs, unify the platform axis (O-1/O-3/O-4/O-5) (#115) (b56bb49)

### Documentation
- regenerate from conventional commits (910695c)
- regenerate from conventional commits (7160289)
- regenerate from conventional commits (3b47a5f)
- regenerate from conventional commits (ffb2acb)
- regenerate from conventional commits (e19ed95)
- regenerate from conventional commits (7a81fb6)
- regenerate from conventional commits (e6b97f2)
- regenerate from conventional commits (2741000)
- regenerate from conventional commits (b96e019)
- regenerate from conventional commits (330c8c6)
- regenerate from conventional commits (096180b)
- regenerate from conventional commits (102ae67)
- stop describing a routing algorithm the code no longer runs (5433b6e)
- regenerate from conventional commits (1572ae2)
- regenerate from conventional commits (a355901)
- branded, marketable READMEs for every sub-repo (9c2a477)
- stop mentioning DNSSEC (no longer part of the design) (179a278)

### Features
- add Meshtastic/LoRa bearer for iOS and Android (9335a6e)
- finish inbound (import), drop export_pr (41c095e)
- auto-generate monorepo + per-library changelogs (git-cliff) (8c64c37)

### Other
- let a host set the relay SOCKS proxy from driver config (51be0c1)
- extract Multipeer so EVERY bearer registers with the manager (f3949f7)
- per-transport switches, and show when the SENDER sent a message (7a923c0)
- wire the relay pool end to end, and stop the wire guard false-firing (35946e0)
- fix Apple's dial backoff and pin the schedule across platforms (54f6f02)
- CLA gate on contributions (preserve commercial relicensing of core) (5a9aa7d)
- SECURITY.md per component + enable-security in the bootstrap script (a1492e9)
- copyright holder is Hop Mesh, LLC (7d8c514)
- fill the Apache-2.0 copyright placeholder (2026 Jason Waldrip) (2fb7d1c)
- Apache-2.0 for everything except core/ (only the protocol stays FSL) (0fe9439)
- CHANGE_REQUEST sync-back + document merge/conversation + confidentiality (9e1dec2)
- make the TLS-served reach record the only name path (drop DNSSEC-over-DoH) (#139) (8998288)
- lift HopBearer+Hns.swift 59% -> 99% + add a per-file coverage floor (#83) (4bfb245)
- decompose the 1895-line HopBearer god-object into per-concern collaborators (B- → A) (#75) (4d86f9d)
- strip em-dashes from this session's Apple coverage test files (#67) (f11147f)
- split into HopContract (no libhop) + Hop (libhop node) — unblocks the app cutover (7f0eeb3)
- thin HopDriver composing the SDK + all four bearers (889fe62)

### Refactor
- enforce purpose/platform/package (collapse sdk/wrappers, apps/web -> apps/web/site) (#116) (afd52df)

### Testing
- make the per-transport toggle drivable from automation, so PLAT-001 can be proven on hardware (7c889a9)
- headless-node suite raises HopBearer.swift 12.8% -> 88.5% (F -> A) + CI coverage floor (#64) (75f4507)

