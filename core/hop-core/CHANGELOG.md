# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- re-ingest mailbox pulls via LOCAL_LINK so a >cap backlog isn't dropped-after-delete (#143) (81a9c56)
- pass-5 audit remediation - DNSSEC name-hijack (CRITICAL) + Node reply UAF (HIGH) (#138) (74fd6ca)
- close F-18d, HpsRekey fails safe under a mid-arm panic (#104) (1d3e810)
- make hexd byte-safe so a hostile DS-digest can't panic the resolver (2nd-pass audit finding) (#78) (20375b0)

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
- decouple hop-core's vocabulary from the sim (comments only) (#119) (48243e4)

### Features
- self-clustering endpoints (phase 1 dedup) as a hop-endpoint-core layer over the mesh (#153) (9b56cd5)
- self-certifying reachability records (core + ABI) for DNS-free endpoint discovery (#126) (e0bae40)

### Other
- make the TLS-served reach record the only name path (drop DNSSEC-over-DoH) (#139) (549e4fc)
- verify_publish uses verify_strict, matching the crate-wide ed25519 convention (#95) (c4fc5be)
- canonicalize the delivery-vaccine shape at verify (r15-01) — close the is_ack twin on the vaccine id (#56) (e86d44d)
- bind the entire private inner into the wire id (r14-01) — close the flags.request_ack twin residual (#55) (52363ab)
- bind the §39 recognition header into the private wire id (r13-01) — close the 7th chimera vector at its root (#52) (7c136b4)
- cargo fmt the r12 chimera test (rustfmt line-wrap) (#51) (0ad7f07)
- close the §39 recognition-header chimera (r12-01) — the 6th vector (#50) (a322559)
- authorize the response-cleanup purges (r11-01) - close the last purge vector (#47) (fb42a97)
- enforce the §39 private-bundle invariant at the gate (r10-01 root fix) (#46) (2c8f3b5)
- close the traced-ACK forgery on the DEFAULT private send path (r9-01) (#45) (f460972)
- close the private-chimera bypass of the traced-ACK authorization (r8-01) (#44) (de9c5a8)
- remove Destination::InternetEgress (mesh-visible internet-bound leak) (e99eb3c)

### Testing
- close store.rs and hps.rs coverage gaps to 100 percent (#81) (8087fa5)

