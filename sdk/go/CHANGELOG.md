# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- format main.go, and drop a rebar3 pin upstream can no longer resolve (137ad19)
- repoint the build identity and published metadata at hopmesh/hop (b2e6203)
- use-after-free-safe teardown across go/python/node (+ elixir safety test) (#134) (42020e3)

### Chore
- bind the v6 hps surface in the C ABI wrappers the guard enumerates (d33eb3e)
- ignore the hop-install build output (1b89726)
- drop the root license, license per-component (FSL-1.1-ALv2) (#146) (570c680)

### Documentation
- regenerate from conventional commits (ce99725)
- regenerate from conventional commits (0ba8f06)
- regenerate from conventional commits (288fb51)
- regenerate from conventional commits (f880b09)
- regenerate from conventional commits (adfd838)
- regenerate from conventional commits (9719166)
- regenerate from conventional commits (b185836)
- regenerate from conventional commits (0c6daf4)
- regenerate from conventional commits (8bd2185)
- regenerate from conventional commits (7c9cd96)
- regenerate from conventional commits (c563741)
- regenerate from conventional commits (9b0e086)
- regenerate from conventional commits (85aa20d)
- regenerate from conventional commits (f174097)
- regenerate from conventional commits (b49b07c)
- regenerate from conventional commits (0b7100d)
- regenerate from conventional commits (7eb4bed)

### Features
- run this repository's own CI, and repoint every canonical-repo gate at hopmesh/hop (d6f9618)
- expose the endpoint CP quorum setter in all six SDKs (#161) (3ce3c0c)
- cluster bindings across all six SDKs (+ passphrase ABI entry) (#154) (865a687)
- example parity + in-process dev certs across go/python/node/elixir (#133) (dae0895)
- reachable-by-name over WSS + /.well-known/hop discovery (#128) (f0a4d27)
- self-certifying reachability records (core + ABI) for DNS-free endpoint discovery (#126) (ef8accd)
- Go endpoint SDK via cgo (net/http-shaped, proven) (#124) (b8b7554)

### Other
- one consistent endpoint surface across node/python/go/elixir (#125) (b6f9884)

