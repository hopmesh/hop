# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- revive dead ingest, fail closed, bound stamps, measure bytes and carriage (1912c75)
- integrate the storage dimension onto current main (aedcfb2)
- history must never gate revenue, and never double-count (cbf43b6)

### Build
- Dockerfiles for hop-billingd and hop-accountd (20d6d81)

### Chore
- invert the license tiers, FSL moves from core to services (14d7fec)

### Documentation
- regenerate from conventional commits (3b47a5f)
- regenerate from conventional commits (ffb2acb)
- regenerate from conventional commits (e19ed95)
- regenerate from conventional commits (7a81fb6)
- regenerate from conventional commits (e6b97f2)
- regenerate from conventional commits (2741000)
- regenerate from conventional commits (b96e019)
- regenerate from conventional commits (330c8c6)
- regenerate from conventional commits (096180b)
- regenerate from conventional commits (102ae67)
- regenerate from conventional commits (1572ae2)
- regenerate from conventional commits (a355901)

### Features
- §35 storage dimension, per-tenant held-byte occupancy (d58a544)
- auto-generate monorepo + per-library changelogs (git-cliff) (8c64c37)
- record usage history in our BigQuery, not just Stripe (4908c1a)
- the ledger source, closing the reconcile chain end to end (ba6b6b8)
- Stripe meter-event emitter, with the money path unit-tested (41c9360)
- telemetry metering, tenant-attributed observability (§40 -> §37) (b823dcc)
- reach-based pricing (bill for offline delivery, not device count) (9635702)
- storage-dimension reconcile (windowed occupancy + own watermark) (e5aaa05)
- storage-dimension math in the reconciler (occupancy integral + GB-month) (6ca7f82)
- §37 reconciler crate (hop-billingd) - pure, idempotent, watermarked (3816c74)

### Other
- make the writer-scoped ledger readable end to end, and stop overclaiming (5ee2555)
- writer-scope the usage ledger rows so concurrent flushes compose (SVC-005) (b66cac9)
- rework the console deploy onto the new GitHub-is-change-management pipeline (b53b9d0)

