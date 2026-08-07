# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- use-after-free-safe teardown across go/python/node (+ elixir safety test) (#134) (f174422)

### CI
- gate the six server SDKs (node/python/go/ruby/crystal/elixir) (#136) (ddfa09e)

### Chore
- drop the root license, license per-component (FSL-1.1-ALv2) (#146) (2e68a4b)

### Features
- expose the endpoint CP quorum setter in all six SDKs (#161) (132e97e)
- cluster bindings across all six SDKs (+ passphrase ABI entry) (#154) (4dfae0f)
- example parity + in-process dev certs across go/python/node/elixir (#133) (4cd101f)
- reachable-by-name over WSS + discovery (built-in :ssl, no WS deps) (#130) (100b2f8)
- Elixir endpoint SDK via a Rustler NIF (Phoenix/Plug-shaped, proven) (#122) (9f69061)

