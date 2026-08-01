# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- per-mirror repository, and retryable release artifacts (bf04449)

### CI
- bump create-github-app-token to v3.2.0 across all mirrored components (efc9f6c)
- per-repo release workflows (publish on a vX.Y.Z tag) (277cf32)

### Chore
- drop the root license, license per-component (FSL-1.1-ALv2) (#146) (be2a5a7)

### Documentation
- regenerate from conventional commits (2741000)
- regenerate from conventional commits (b96e019)
- regenerate from conventional commits (330c8c6)
- regenerate from conventional commits (096180b)
- regenerate from conventional commits (102ae67)
- regenerate from conventional commits (1572ae2)
- regenerate from conventional commits (a355901)
- branded, marketable READMEs for every sub-repo (9c2a477)
- stop mentioning DNSSEC (no longer part of the design) (179a278)

### Features
- finish inbound (import), drop export_pr (41c095e)
- auto-generate monorepo + per-library changelogs (git-cliff) (8c64c37)
- expose the endpoint CP quorum setter in all six SDKs (#161) (1bc8eef)
- cluster bindings across all six SDKs (+ passphrase ABI entry) (#154) (afb1632)
- Ruby endpoint SDK (Fiddle, zero gems) + use-after-free-safe teardown (#131) (dbc1997)

### Other
- bump every published component to 0.0.2 (7b1ffab)
- wire the relay pool end to end, and stop the wire guard false-firing (35946e0)
- RubyGems trusted-publishing release workflow (rake release + OIDC role) (5a2d6ee)
- local first-publish + OIDC trusted publishing on npm/PyPI/RubyGems (beefc71)
- CLA gate on contributions (preserve commercial relicensing of core) (5a9aa7d)
- SECURITY.md per component + enable-security in the bootstrap script (a1492e9)
- copyright holder is Hop Mesh, LLC (7d8c514)
- fill the Apache-2.0 copyright placeholder (2026 Jason Waldrip) (2fb7d1c)
- CHANGE_REQUEST sync-back + document merge/conversation + confidentiality (9e1dec2)

