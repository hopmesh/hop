# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- a collector refusing every batch fails its health probe (a127c99)
- revive dead ingest, fail closed, bound stamps, measure bytes and carriage (1912c75)
- keep the OTLP failure log aggregate-only + panic-isolate the worker (5c865d0)

### Features
- stream OTel to registry OTLP endpoints (P2, OTel day 1) (19916c2)
- relays + collectors read tenant keys from the registry (5b-2, reader) (f80f5b3)
- auto-generate monorepo + per-library changelogs (git-cliff) (8c64c37)
- OTLP export, forward each tenant's telemetry to their OTel endpoint (51e25c2)
- durable telemetry ledger, so metered usage actually bills (1e46b05)
- telemetry metering, tenant-attributed observability (§40 -> §37) (b823dcc)
- hop-telemetryd, the OTel-over-Hop collector (DESIGN.md §40) (3b30ae9)

