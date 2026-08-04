# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- per-mirror repository, and retryable release artifacts (bf04449)
- declare the repository so npm provenance validates (c70e006)
- pass the PR ref as COPYBARA_SOURCEREF; drop the leaked probe (31cec8a)
- guard fixed-32-byte C-ABI reads in all wrappers (ADV18-06) (c95c826)
- pass-5 audit remediation - DNSSEC name-hijack (CRITICAL) + Node reply UAF (HIGH) (#138) (d207acc)
- use-after-free-safe teardown across go/python/node (+ elixir safety test) (#134) (42a4a2e)

### CI
- bump create-github-app-token to v3.2.0 across all mirrored components (efc9f6c)
- per-repo release workflows (publish on a vX.Y.Z tag) (277cf32)
- sdk/node CI as a canonical composite action (shared monorepo <-> standalone repo) (#149) (85d885b)

### Chore
- bump koffi in /sdk/node in the node-sdk-dependencies group (9e3f7c8)
- bump the node-sdk-dependencies group across 1 directory with 2 updates (#158) (1af6155)
- drop the root license, license per-component (FSL-1.1-ALv2) (#146) (be2a5a7)

### Documentation
- regenerate from conventional commits (e19ed95)
- regenerate from conventional commits (7a81fb6)
- regenerate from conventional commits (e6b97f2)
- regenerate from conventional commits (2741000)
- regenerate from conventional commits (b96e019)
- regenerate from conventional commits (330c8c6)
- regenerate from conventional commits (096180b)
- regenerate from conventional commits (102ae67)
- regenerate from conventional commits (1572ae2)
- regenerate from conventional commits (a355901)
- stop mentioning DNSSEC (no longer part of the design) (179a278)
- correct the license line (services are Apache now, only core is FSL) (f9681c9)
- marketable README template + brand mark + public-repo catalog (#148) (b585e9a)

### Features
- finish inbound (import), drop export_pr (41c095e)
- auto-generate monorepo + per-library changelogs (git-cliff) (8c64c37)
- expose the endpoint CP quorum setter in all six SDKs (#161) (1bc8eef)
- cluster bindings across all six SDKs (+ passphrase ABI entry) (#154) (afb1632)
- example parity + in-process dev certs across go/python/node/elixir (#133) (d58c460)
- reachable-by-name over WSS + /.well-known/hop discovery (consumes the reach record) (#127) (8d01c85)
- self-certifying reachability records (core + ABI) for DNS-free endpoint discovery (#126) (7c31123)
- embeddable Hop endpoint SDK prototype (receive Hop messages in a Node app) (#120) (87c1592)

### Other
- bump every published component to 0.0.2 (7b1ffab)
- wire the relay pool end to end, and stop the wire guard false-firing (35946e0)
- local first-publish + OIDC trusted publishing on npm/PyPI/RubyGems (beefc71)
- CLA gate on contributions (preserve commercial relicensing of core) (5a9aa7d)
- scope the packages under @hop-mesh (d53b7aa)
- SECURITY.md per component + enable-security in the bootstrap script (a1492e9)
- copyright holder is Hop Mesh, LLC (7d8c514)
- fill the Apache-2.0 copyright placeholder (2026 Jason Waldrip) (2fb7d1c)
- CHANGE_REQUEST sync-back + document merge/conversation + confidentiality (9e1dec2)
- one consistent endpoint surface across node/python/go/elixir (#125) (c46cd8d)

### Testing
- export_pr validation probe (sdk/node) (dddb024)

