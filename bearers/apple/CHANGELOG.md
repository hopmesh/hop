# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Chore
- drop the root license, license per-component (FSL-1.1-ALv2) (#146) (2e68a4b)
- finish the monorepo layout, kill platform stubs, unify the platform axis (O-1/O-3/O-4/O-5) (#115) (edaf8fc)

### Documentation
- regenerate from conventional commits (9e1fd4b)
- regenerate from conventional commits (1e7cf38)
- regenerate from conventional commits (3912d31)

### Other
- route dedup through the pure keep-rule cores; fix inverted Android dedup-ordering docs (#72) (d8174fd)
- strip em-dashes from this session's Apple coverage test files (#67) (f3a12f0)
- split into HopContract (no libhop) + Hop (libhop node) — unblocks the app cutover (68bf3ce)
- rename sdk/wrappers/swift -> sdk/wrappers/Hop (clean SwiftPM package id) (e376d96)
- re-home all four bearers as independent packages on the Hop SDK (1b59005)

### Refactor
- enforce purpose/platform/package (collapse sdk/wrappers, apps/web -> apps/web/site) (#116) (ffe08fe)

### Testing
- seam refactor takes BleBearer 7% → 97% (CB-free cores), replace shadow tests (#69) (41fe27a)
- real loopback integration tests for LAN + Relay bearers to >=80% coverage, CI gating, compile-bug root cause (#63) (917c617)

