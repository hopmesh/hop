# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- guard fixed-32-byte C-ABI reads in all wrappers (ADV18-06) (c95c826)

### CI
- bump create-github-app-token to v3.2.0 across all mirrored components (efc9f6c)
- drop unused attestation read access (0137b19)
- per-repo release workflows (publish on a vX.Y.Z tag) (277cf32)

### Chore
- drop the root license, license per-component (FSL-1.1-ALv2) (#146) (be2a5a7)

### Documentation
- branded, marketable READMEs for every sub-repo (9c2a477)

### Features
- self-certifying reachability records (core + ABI) for DNS-free endpoint discovery (#126) (7c31123)

### Other
- CLA gate on contributions (preserve commercial relicensing of core) (5a9aa7d)
- SECURITY.md per component + enable-security in the bootstrap script (a1492e9)
- copyright holder is Hop Mesh, LLC (7d8c514)
- fill the Apache-2.0 copyright placeholder (2026 Jason Waldrip) (2fb7d1c)
- CHANGE_REQUEST sync-back + document merge/conversation + confidentiality (9e1dec2)

### Refactor
- enforce purpose/platform/package (collapse sdk/wrappers, apps/web -> apps/web/site) (#116) (afd52df)

