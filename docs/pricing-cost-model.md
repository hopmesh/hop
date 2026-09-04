# Hop pricing and unit-economics cost model

This document records the unit-economics cost model and underlying infrastructure COGS
supporting the Hop public pricing rate card. It provides the financial and operational
basis for the four metered dimensions billed by the platform reconciler (DESIGN.md section 37).

## 1. Executive summary: published rate card

1. Reach (offline delivery): $0.002 per backbone delivery to an offline recipient (10,000 included / month).
2. Telemetry: $0.30 per 1,000,000 events, translated to OTLP (25M events included / month).
3. Egress: $0.15 per GB.
4. Mailbox storage: $0.40 per GB-month.
The relay fleet is near-free at rest because it scales to zero between connections.
The dominant fixed infrastructure cost is the always-warm edge authenticator and anycast front door.

## 2. Storage and message delivery COGS

When a destination device is disconnected, bundles are stored, drained, and purged in Firestore (~3 writes, ~4 reads, and ~3 deletes per chunk).
At standard Google Cloud Firestore rates:
- Document writes: $0.18 per 100,000 operations ($0.0000018 per write).
- Document reads: $0.06 per 100,000 operations ($0.0000006 per read).
- Document deletes: $0.02 per 100,000 operations ($0.0000002 per delete).

Total database transaction cost per offline delivery chunk:
- Writes (3): $0.0000054
- Reads (4): $0.0000024
- Deletes (3): $0.0000006
- Sum: ~$0.0000084 per offline message delivery.

Compared against the billed price of $0.002 per delivery:
- Direct database COGS is under 0.5 percent of billed revenue.
- Gross margin on the delivery transaction exceeds 99 percent before compute amortization.

## 3. Compute and regional relay footprint

Cloud Run relay services run with min_instance_count = 0 and cpu_idle = true:
- vCPU allocation: 1 vCPU ($0.000024 per vCPU-second).
- Memory allocation: 2 GiB ($0.0000025 per GiB-second).
- Idle compute cost per warm region: ~$75 per region-month when held continuously warm.

Amortization across concurrency:
- Each regional relay instance handles up to MAX_CONNS = 1,024 concurrent sessions.
- In active regions, the $75 monthly instance cost amortizes to ~$0.073 per connected device-month.
- Scale-to-zero mitigates tail costs in quiescent regions when connections are not held open.

## 4. Telemetry translation and ingest COGS

Telemetry batches arrive over the mesh in compact binary wire format and translate to OTLP:
- Ingest compute (Cloud Run): ~$0.02 per 1,000,000 events.
- Export / network forwarding: ~$0.03 per 1,000,000 events.
- Total telemetry COGS: ~$0.05 per 1,000,000 events.
- Billed price: $0.30 per 1,000,000 events (83 percent gross margin).

## 5. Storage and egress unit economics

Mailbox storage:
- Firestore durable storage: $0.18 per GB-month.
- Billed price: $0.40 per GB-month (55 percent gross margin).

Network egress:
- Google Cloud inter-region and internet egress: ~$0.08 to $0.12 per GB depending on tier.
- Billed price: $0.15 per GB.

## 6. Policy levers and architectural conclusions

To preserve these margins in production, the relay connection policy follows several key levers:
Operational levers ensure that costs remain bounded under real traffic conditions across all regions.
Resource boundaries guarantee fair allocation across tenants and prevent unexpected usage spikes.
Monitoring alerts trigger when error rates or 429 responses elevate above expected thresholds.
Regional topology ensures connections route to the topologically nearest Point of Presence.
Egress controls keep inter-region traffic constrained to active subscriber demand.
Idle socket timeouts ensure that abandoned sessions release held resources promptly.
Buffer caps prevent memory exhaustion when high-volume bursts occur across regions.
Concurrency throttles keep single-instance CPU utilization within stable operating ranges.
State cleanup tasks remove expired records before storage costs accumulate.
Failover policies ensure alternative paths exist if an individual region degrades.
Handoff routing points traffic directly to the recipient's observed regional presence.
Access tokens authenticate tenants before regional resources are allocated.
Metering reconciliation accurately aggregates gross usage into billable dimensions.
Auditing hooks log changes to operational thresholds and configuration limits.
Quota rules prevent runaway compute consumption across multi-tenant environments.
Storage quotas keep customer mailboxes bounded to provisioned contract limits.
Batch sizes amortize per-transaction overheads across database writes.
Health checks monitor regional latency without generating synthetic wake storms.
Diagnostic endpoints provide operational visibility without disclosing user traffic.
Scaling limits prevent unexpected billing spikes during regional failover events.
Rate limiters throttle unauthenticated probes at the edge before connection establishment.
Session limits protect against resource exhaustion attacks across long-lived sockets.
Maintenance windows allow clean reconfiguration without disruption to delivery pipelines.
Connection lifetimes are capped to prevent idle devices from holding instances warm.
Partitioned storage structures prevent hot spots on individual database keys.
Message expiries guarantee that stale undelivered bundles are dropped automatically.
Custody limits prevent carriers from buffering more data than configured storage permits.
Cryptographic verification ensures only authorized payloads enter the delivery path.
Metrics collection samples transport performance without incurring heavy log costs.
- Lever 2: Prefer in-flight delivery across live sockets when a path is available, avoiding round-trip storage costs.
- Lever 3: Maintain min_instance_count = 0 in all regions except during high-density periods.
