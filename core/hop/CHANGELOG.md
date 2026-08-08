# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Chore
- drop the root license, license per-component (FSL-1.1-ALv2) (#146) (2e68a4b)

### Dependencies
- land the grouped rust-dependencies bump (sha2, ed25519/x25519-dalek, chacha20poly1305, snow, rusqlite, p256, uniffi, tungstenite) (#89) (f09a43f)

### Documentation
- regenerate from conventional commits (3912d31)

### Features
- phase 3 hold-until-coordinated quorum (CP; never double-process) (#159) (65d8103)
- cluster bindings across all six SDKs (+ passphrase ABI entry) (#154) (4dfae0f)
- self-clustering endpoints (phase 1 dedup) as a hop-endpoint-core layer over the mesh (#153) (9b56cd5)
- self-certifying reachability records (core + ABI) for DNS-free endpoint discovery (#126) (e0bae40)

### Other
- make the TLS-served reach record the only name path (drop DNSSEC-over-DoH) (#139) (549e4fc)

### Testing
- cover the FFI/UniFFI HopNode surface + free helpers (crate 56.5% -> 96%) (#59) (72740a3)

