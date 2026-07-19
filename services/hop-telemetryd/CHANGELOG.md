# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- keep the OTLP failure log aggregate-only + panic-isolate the worker (5c865d0)

### Features
- OTLP export, forward each tenant's telemetry to their OTel endpoint (51e25c2)
- durable telemetry ledger, so metered usage actually bills (1e46b05)
- telemetry metering, tenant-attributed observability (§40 -> §37) (b823dcc)
- hop-telemetryd, the OTel-over-Hop collector (DESIGN.md §40) (3b30ae9)

