# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- well-known reach record was born expired (issued_at=0) (#141) (c2e7235)
- close F-18d, HpsRekey fails safe under a mid-arm panic (#104) (1d3e810)

### Chore
- drop the root license, license per-component (FSL-1.1-ALv2) (#146) (2e68a4b)

### Dependencies
- land the grouped rust-dependencies bump (sha2, ed25519/x25519-dalek, chacha20poly1305, snow, rusqlite, p256, uniffi, tungstenite) (#89) (f09a43f)

### Documentation
- regenerate from conventional commits (1e7cf38)
- regenerate from conventional commits (3912d31)

### Features
- phase 3 hold-until-coordinated quorum (CP; never double-process) (#159) (65d8103)
- self-clustering endpoints (phase 1 dedup) as a hop-endpoint-core layer over the mesh (#153) (9b56cd5)

### Other
- make the TLS-served reach record the only name path (drop DNSSEC-over-DoH) (#139) (549e4fc)
- close the two capping defects in Endpoint and the Kotlin SDK (#74) (847e565)

### Testing
- raise line coverage 39.4% -> 80.9% (#61) (2a7ad21)

