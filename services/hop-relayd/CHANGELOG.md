# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- close F-18d, HpsRekey fails safe under a mid-arm panic (#104) (1d3e810)
- close two bypasses in the F-7 rate cap (F-18a unbounded map, F-18b pre-auth reset) (#96) (3da0781)
- close F-7 - per-node-identity rate cap on the driver's Ev::Data (#93) (0fba8f6)
- panic-isolate the driver loop (F-2, HIGH) - close an unauthenticated remote-DoS gap (#87) (de037f4)

### Chore
- drop the root license, license per-component (FSL-1.1-ALv2) (#146) (2e68a4b)

### Dependencies
- land the grouped rust-dependencies bump (sha2, ed25519/x25519-dalek, chacha20poly1305, snow, rusqlite, p256, uniffi, tungstenite) (#89) (f09a43f)

### Documentation
- regenerate from conventional commits (b85390e)
- regenerate from conventional commits (3dd7f37)
- regenerate from conventional commits (9e1fd4b)
- regenerate from conventional commits (1e7cf38)
- regenerate from conventional commits (3912d31)

### Other
- make the TLS-served reach record the only name path (drop DNSSEC-over-DoH) (#139) (549e4fc)
- remove Destination::InternetEgress (mesh-visible internet-bound leak) (e99eb3c)

### Testing
- raise hop-relayd line coverage 41.2% -> 81.1% (#62) (b3100ea)

