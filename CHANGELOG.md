# Changelog

All notable changes to Hop are recorded here. The format follows Keep a Changelog,
newest first. Hop is pre-1.0 and versioned per `[workspace.package] version` in the
root `Cargo.toml`; the wire (`HOP_WIRE_VERSION`) and ABI (`HOP_ABI_VERSION`)
versions are tracked separately (see `docs/release-engineering.md`).

## [Unreleased]

### Added

- `SECURITY.md`: vulnerability-disclosure policy, supported-versions statement, and a
  threat-model summary with the current pre-production accepted risks.
- `CONTRIBUTING.md`: repository map and the build/test/PR path, including the C-ABI
  contract rules and the repo-wide no-em-dash rule.
- `deny.toml` and `.github/dependabot.yml`: supply-chain scanning. cargo-deny gates
  advisories, licenses, bans, and sources; Dependabot watches Cargo, npm (web),
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

- Audit remediation pass: closed the two critical findings (the Android db-key /
  quarantine-wipe divergence and the §39 private-path sender-spoofing), pinned the
  wire format against silent drift, and made the store open path fail safe. See the
  gap report and the per-area findings for the full set.

[Unreleased]: https://github.com/jwaldrip/hop/commits/main
