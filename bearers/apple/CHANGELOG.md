# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- give the release the fleet chain of custody (7f1d882)

### Chore
- drop the root license, license per-component (FSL-1.1-ALv2) (#146) (570c680)
- finish the monorepo layout, kill platform stubs, unify the platform axis (O-1/O-3/O-4/O-5) (#115) (a0550d7)

### Documentation
- regenerate from conventional commits (9b0e086)

### Features
- guard the published Apple pin, allow a validated last_rev, and stop claiming the bearers mirror exists (122350d)
- publish bearers/apple as the hop-bearers-apple mirror (7f3f0d4)

### Other
- route dedup through the pure keep-rule cores; fix inverted Android dedup-ordering docs (#72) (37d1323)
- strip em-dashes from this session's Apple coverage test files (#67) (0e16bf0)
- split into HopContract (no libhop) + Hop (libhop node) — unblocks the app cutover (5853f35)
- rename sdk/wrappers/swift -> sdk/wrappers/Hop (clean SwiftPM package id) (4ccdaf7)
- re-home all four bearers as independent packages on the Hop SDK (48ade1f)

### Refactor
- enforce purpose/platform/package (collapse sdk/wrappers, apps/web -> apps/web/site) (#116) (48ec524)

### Testing
- seam refactor takes BleBearer 7% → 97% (CB-free cores), replace shadow tests (#69) (a20143b)
- real loopback integration tests for LAN + Relay bearers to >=80% coverage, CI gating, compile-bug root cause (#63) (dadfe5a)

