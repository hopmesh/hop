# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Chore
- drop the root license, license per-component (FSL-1.1-ALv2) (#146) (2e68a4b)
- finish the monorepo layout, kill platform stubs, unify the platform axis (O-1/O-3/O-4/O-5) (#115) (edaf8fc)

### Documentation
- regenerate from conventional commits (1e7cf38)
- regenerate from conventional commits (3912d31)

### Other
- make the TLS-served reach record the only name path (drop DNSSEC-over-DoH) (#139) (549e4fc)
- lift HopBearer+Hns.swift 59% -> 99% + add a per-file coverage floor (#83) (a166f1d)
- decompose the 1895-line HopBearer god-object into per-concern collaborators (B- → A) (#75) (1a3f3d7)
- strip em-dashes from this session's Apple coverage test files (#67) (f3a12f0)
- split into HopContract (no libhop) + Hop (libhop node) — unblocks the app cutover (68bf3ce)
- thin HopDriver composing the SDK + all four bearers (5977496)

### Refactor
- enforce purpose/platform/package (collapse sdk/wrappers, apps/web -> apps/web/site) (#116) (ffe08fe)

### Testing
- headless-node suite raises HopBearer.swift 12.8% -> 88.5% (F -> A) + CI coverage floor (#64) (ee4c245)

