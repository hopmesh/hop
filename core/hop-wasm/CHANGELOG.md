# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- exercise publish_recv_beacon/send_traced/set_default_lifetime_ms/inbox_debug through real wasm (#92) (00c8534)
- dense contact chains everywhere, honest congestion, per-device bubble truth, real-street clockin (19b3580)
- per-device delivery truth — sender learns delivery only via ACK (5868328)
- prune old bundles (real OOM fix) + conversation view + compose close (e2f0592)
- only visualize the message's own bundle (kills persistent gossip lines) + ack double-check (0e8ce8e)

### CI
- bump create-github-app-token to v3.2.0 across all mirrored components (efc9f6c)
- per-repo release workflows (publish on a vX.Y.Z tag) (277cf32)

### Dependencies
- land the grouped rust-dependencies bump (sha2, ed25519/x25519-dalek, chacha20poly1305, snow, rusqlite, p256, uniffi, tungstenite) (#89) (2038ce9)

### Documentation
- branded, marketable READMEs for every sub-repo (9c2a477)
- decouple hop-core's vocabulary from the sim (comments only) (#119) (d153989)

### Features
- channels + mine scenario + curated homepage; fix two real protocol bugs the honest harness exposed (dc20947)
- real hop counts + LoRa net modeled + clockin & multi-hop everywhere + bubble timers (48b8e98)
- beacon ripple viz + average delivery/ack cards (5599e1b)
- visualize the §39 gradient routing tree + fix store indicator (692ccca)
- real hop-debug send status (Sent·N peers) + TTL cleanup + fix convo focus (42c5481)
- back each node with a real host Store (SQLite/OPFS) instead of wasm memory (9504585)
- flood driven by REAL held-copy state (not a timer) (13070a2)
- observe bundle-per-link transfers for the swarm viz (325a0ae)
- hop-wasm — run the real hop-core Node in the browser (8ff94bc)

### Other
- local first-publish + OIDC trusted publishing on npm/PyPI/RubyGems (beefc71)
- CLA gate on contributions (preserve commercial relicensing of core) (5a9aa7d)
- scope the packages under @hop-mesh (d53b7aa)
- SECURITY.md per component + enable-security in the bootstrap script (a1492e9)
- copyright holder is Hop Mesh, LLC (7d8c514)
- CHANGE_REQUEST sync-back + document merge/conversation + confidentiality (9e1dec2)
- root-cause the recurring 0-byte LICENSE bug; version floors; guard (all → A) (#73) (eee7beb)
- cargo fmt + clippy across the touched crates (c6216a1)

### Testing
- raise host-testable coverage to A (99%) by splitting off the wasm-only surface (#66) (ae6bb31)

