# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- a collector refusing every batch fails its health probe (a127c99)
- revive dead ingest, fail closed, bound stamps, measure bytes and carriage (1912c75)
- keep the OTLP failure log aggregate-only + panic-isolate the worker (5c865d0)

### Chore
- bump the rust-dependencies group across 1 directory with 7 updates (ce964ad)
- invert the license tiers, FSL moves from core to services (14d7fec)

### Documentation
- regenerate from conventional commits (910695c)
- regenerate from conventional commits (7160289)
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
- stream OTel to registry OTLP endpoints (P2, OTel day 1) (19916c2)
- relays + collectors read tenant keys from the registry (5b-2, reader) (f80f5b3)
- auto-generate monorepo + per-library changelogs (git-cliff) (8c64c37)
- OTLP export, forward each tenant's telemetry to their OTel endpoint (51e25c2)
- durable telemetry ledger, so metered usage actually bills (1e46b05)
- telemetry metering, tenant-attributed observability (§40 -> §37) (b823dcc)
- hop-telemetryd, the OTel-over-Hop collector (DESIGN.md §40) (3b30ae9)

### Other
- close SVC-002, SVC-003 and SVC-004 (5081fc2)
- make the writer-scoped ledger readable end to end, and stop overclaiming (5ee2555)

