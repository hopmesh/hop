# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- guard fixed-32-byte C-ABI reads in all wrappers (ADV18-06) (c95c826)
- pass-5 audit remediation - DNSSEC name-hijack (CRITICAL) + Node reply UAF (HIGH) (#138) (d207acc)
- use-after-free-safe teardown across go/python/node (+ elixir safety test) (#134) (42a4a2e)

### CI
- bump create-github-app-token to v3.2.0 across all mirrored components (efc9f6c)
- per-repo release workflows (publish on a vX.Y.Z tag) (277cf32)
- sdk/node CI as a canonical composite action (shared monorepo <-> standalone repo) (#149) (85d885b)

### Chore
- bump the node-sdk-dependencies group across 1 directory with 2 updates (#158) (1af6155)
- drop the root license, license per-component (FSL-1.1-ALv2) (#146) (be2a5a7)

### Documentation
- stop mentioning DNSSEC (no longer part of the design) (179a278)
- correct the license line (services are Apache now, only core is FSL) (f9681c9)
- marketable README template + brand mark + public-repo catalog (#148) (b585e9a)

### Features
- expose the endpoint CP quorum setter in all six SDKs (#161) (1bc8eef)
- cluster bindings across all six SDKs (+ passphrase ABI entry) (#154) (afb1632)
- example parity + in-process dev certs across go/python/node/elixir (#133) (d58c460)
- reachable-by-name over WSS + /.well-known/hop discovery (consumes the reach record) (#127) (8d01c85)
- self-certifying reachability records (core + ABI) for DNS-free endpoint discovery (#126) (7c31123)
- embeddable Hop endpoint SDK prototype (receive Hop messages in a Node app) (#120) (87c1592)

### Other
- local first-publish + OIDC trusted publishing on npm/PyPI/RubyGems (beefc71)
- CLA gate on contributions (preserve commercial relicensing of core) (5a9aa7d)
- scope the packages under @hop-mesh (d53b7aa)
- SECURITY.md per component + enable-security in the bootstrap script (a1492e9)
- copyright holder is Hop Mesh, LLC (7d8c514)
- fill the Apache-2.0 copyright placeholder (2026 Jason Waldrip) (2fb7d1c)
- CHANGE_REQUEST sync-back + document merge/conversation + confidentiality (9e1dec2)
- one consistent endpoint surface across node/python/go/elixir (#125) (c46cd8d)


