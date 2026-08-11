# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- use-after-free-safe teardown across go/python/node (+ elixir safety test) (#134) (f174422)

### Chore
- drop the root license, license per-component (FSL-1.1-ALv2) (#146) (2e68a4b)

### Documentation
- regenerate from conventional commits (3dd7f37)
- regenerate from conventional commits (9e1fd4b)
- regenerate from conventional commits (1e7cf38)
- regenerate from conventional commits (3912d31)

### Features
- expose the endpoint CP quorum setter in all six SDKs (#161) (132e97e)
- cluster bindings across all six SDKs (+ passphrase ABI entry) (#154) (4dfae0f)
- example parity + in-process dev certs across go/python/node/elixir (#133) (4cd101f)
- reachable-by-name over WSS + /.well-known/hop discovery (#128) (21a177c)
- self-certifying reachability records (core + ABI) for DNS-free endpoint discovery (#126) (e0bae40)
- Go endpoint SDK via cgo (net/http-shaped, proven) (#124) (f7d28c0)

### Other
- one consistent endpoint surface across node/python/go/elixir (#125) (f974dad)

