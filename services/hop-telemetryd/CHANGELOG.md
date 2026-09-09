# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- durable retry journal and hour-keyed base maps for usage ledgers (0792209)
- idempotent cumulative merge to prevent double billing on retry (c98f33a)
- isolate test probe assertion to avoid mutating global readiness state (a77b9f6)
- validate telemetry stamp epoch before writing dedup markers (cc7067a)
- keep bounded read timeout during websocket upgrade in endpoint and telemetryd (6a439a0)
- fail closed on corrupt or unreadable identity files in gateway and telemetryd (ce4898e)
- atomic cross-instance dedup and bounded retention sweep (SVC-006) (1489b7d)
- wire cargo-deny gate, enforce path ownership, and wire lane guards (PROC-003, INFRA-012) (037da99)
- cap OTLP export response body read (SVC-009) (c0db30f)
- reject NAT64 and IPv4-compatible internal addresses (SVC-008) (075ddde)
- use fallible critical KV writes and prevent telemetry replay across restart (STORE-005, SVC-006) (63cbcf0)

### Documentation
- regenerate from conventional commits (47a8bf6)
- regenerate from conventional commits (f67300f)
- regenerate from conventional commits (6e7dc77)
- regenerate from conventional commits (a202908)
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

### Other
- apply cargo fmt and clippy cleanups (e25ad84)

