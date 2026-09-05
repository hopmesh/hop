# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- stop the ledger retry-buffer tests racing and unclassify the Apple pin comment (REL-010) (82b5bfe)
- make the native libraries reproducible by pinning SOURCE_DATE_EPOCH (REL-009) (18800a7)
- pin CHop to the v0.0.3 bundle built and attested at cd1289256f23354042ba2b1107cb26c5ad53cbaa (ABI-008) (36540e9)
- pin a consistent deployment target for the SQLCipher/OpenSSL native slices (REL-004) (b2935b9)
- wire authentication feedback and enforce preauth deadline across bearers (PLAT-005) (c51d33d)
- generate a canonical ABI manifest and verify wrapper signatures against it (ABI-009) (385096b)
- propagate hpsRekey failure and do not auto-accept service requests (ABI-002, ABI-004) (498b4c7)
- close the pollServiceRequests pointer scope (ABI-002) (a449e3a)
- fail closed on plain builds and build SQLCipher by default for mobile (ABI-001) (db4121c)
- bind C ABI 7 surface and propagate rekey and secret errors (ABI-002, ABI-004, ABI-005) (278bed2)
- gate release diagnostics and component-redact URLs (PLAT-008) (7401411)
- repoint the build identity and published metadata at hopmesh/hop (b2e6203)

### Chore
- bump version to 0.0.3 across workspace and SDKs (ABI-008) (e01ecbb)
- drop the root license, license per-component (FSL-1.1-ALv2) (#146) (570c680)

### Documentation
- update release runbook and references for v0.0.3 (ABI-008) (70378e0)
- document ABI 7 requirement and release runbook in Package.swift (ABI-008) (b4f219a)
- update prose claims and exclude changelog in check-abi-version (ABI-002, ABI-004, ABI-005) (903bc65)
- regenerate from conventional commits (f592a14)
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
- give the Swift SDK the hps:// channel surface (894d361)
- ship the Apple SDK as CocoaPods pods, and make the React Native iOS build work (bcb3796)
- run this repository's own CI, and repoint every canonical-repo gate at hopmesh/hop (d6f9618)
- self-certifying reachability records (core + ABI) for DNS-free endpoint discovery (#126) (ef8accd)

### Other
- publish the three pods to CocoaPods trunk (9dd5b93)

### Refactor
- enforce purpose/platform/package (collapse sdk/wrappers, apps/web -> apps/web/site) (#116) (48ec524)

### Testing
- add openKeyed encryption and wrong-key failure integration assertions (ABI-001) (7db937c)

