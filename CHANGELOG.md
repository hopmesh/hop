# Changelog

All notable changes to Hop are recorded here. The format follows Keep a Changelog,
newest first. Hop is pre-1.0 and versioned per `[workspace.package] version` in the
root `Cargo.toml`; the wire (`BUNDLE_VERSION` in `core/hop-core/src/bundle.rs`) and
ABI (`HOP_ABI_VERSION`) versions are tracked separately (see
`docs/release-engineering.md`).

## [Unreleased]

### Added

- `SECURITY.md`: vulnerability-disclosure policy, supported-versions statement, and a
  threat-model summary with the current pre-production accepted risks.
- `CONTRIBUTING.md`: repository map and the build/test/PR path, including the C-ABI
  contract rules and the repo-wide no-em-dash rule.
- `deny.toml` and `.github/dependabot.yml`: supply-chain scanning. `deny.toml` is
  configured to gate advisories, licenses, bans, and sources (run locally with
  `cargo deny check`); the merge-blocking CI job is pending wiring (see `deny.toml`
  and `.github/workflows/ci.yml`). Dependabot watches Cargo, npm (web),
  Gradle (Kotlin SDK + Android modules), and GitHub Actions.
- `docs/runbooks/`: operational runbooks for the relay fleet: enable/disable (the
  `relays_enabled` flip and the Terraform destroy-time cycle gotcha), incident
  response, and quota/429 handling.
- `docs/release-engineering.md`: version scheme, git tag scheme, CHANGELOG process,
  and the signed-artifact publishing plan (xcframework/SPM, AAR/Maven, crates, and
  `sdk/hop.h` versioning).
- `docs/crash-reporting-design.md`: opt-in, scrubbed diagnostics design that will not
  leak content, contacts, identity, or device identifiers.
- `docs/identity-backup-restore-design.md`: hardware-held keys plus a passphrase-
  encrypted identity export and device-loss recovery design.

### Security

- Wire v9: preserve the already-shipped v8 carriage-stamp envelope while adding the
  authenticated HPS reach-ACK MAC layout and full publication signing context. The
  deterministic corpus now covers stamped and unstamped access plus canonical native
  C and WASM re-encoding.
- Audit remediation pass: closed the two critical findings (the Android db-key /
  quarantine-wipe divergence and the §39 private-path sender-spoofing), pinned the
  wire format against silent drift, and made the store open path fail safe. See the
  gap report and the per-area findings for the full set.
- Re-audit remediation round (wire `BUNDLE_VERSION` 3 -> 4, mixed-fleet-breaking):
  - **Prefix-only private header (core-protocol-r2-02):** the private header now
    carries only the 2-byte routing prefix (`crypto::MailboxRoute`), never the full
    16-byte mailbox-tag. A bundle-capturing address-knower can no longer recompute
    and uniquely re-link a recipient off the header; it learns at most the same
    anonymity-set membership the routing layer already exposes.
  - **Recipient-only CDH ACK proof (core-protocol-r2-04, the v3 -> v4 driver):** the
    private `Payload::Ack` gained a trailing `proof: Option<[u8;32]>`. The sender
    flips a send to Delivered only when
    `recognition_tag_from_shared(proof, for_bundle_id)` matches the original private
    tag, closing an ACK-forgery-by-address-knower hole. `None` on the traced ACK path.
  - **Delivery-vaccine hardening (core-protocol-r2-03 / security-privacy-r2-01):** a
    `Destination::Vaccine` is now subject to the same per-link ingest rate limit as a
    private bundle and is short-circuited on the `seen` set, so a re-flooded duplicate
    can no longer re-run the O(held) resolve scan (CPU-amplification DoS).
  - **Prefix-collision black-hole fix (core-protocol-r2-01):** a private bundle
    carrying a mailbox is now ALWAYS spooled, even when a live gradient exists, so a
    passive/offline recipient that merely collides on the 2-byte prefix with a live
    peer can still be reached via its later want-beacon pull.
  - **Android mirror sealing:** driver mirror payloads are sealed via `MirrorCrypto`.

[Unreleased]: https://github.com/hopmesh/hop/commits/main
