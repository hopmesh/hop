# hop-telemetryd

The Hop telemetry collector (OTel-over-Hop, DESIGN.md §40). A mesh leaf that receives
device-reported telemetry and forwards it to a sink.

Devices call `Node::send_telemetry(collector_addr, batch)`, which routes a statically sealed
`hop.telemetry` bundle to this node's address. The core decodes and bounds-checks it
(`hop_core::telemetry`) and surfaces it via `take_telemetry`; this daemon drains those batches and
hands each to a `TelemetrySink`.

Why a Hop transport and not OTLP-over-HTTP: pure-P2P traffic never touches a server, so the only
telemetry a collector can see is what a device self-reports, and the devices that most need Hop have
no internet to POST OTLP over. Riding a bundle makes it delay-tolerant: a field device that was
offline for hours still lands its telemetry once a path opens.

## Mesh attachment

Like `hop-endpoint`, this is a leaf that never relays others' traffic (`set_max_relayed(0)`) and
becomes addressable by DIALING a relay as the Noise `Role::Initiator`. It also LISTENS: an SDK can
direct-dial `wss://<domain>/` and become an inbound bearer, so telemetry reaches the collector even
with the relay fleet down. It serves a signed reach record at `/.well-known/hop` so the SDK can
resolve `telemetry.<domain>` to this collector's address (what telemetry is sealed and routed to).

## The sink

`TelemetrySink` is the seam a later increment fills with a BigQuery/warehouse forwarder plus
per-tenant Stripe metering (the `hop_telemetry_events` dimension, DESIGN.md §37), mirroring
hop-billingd's `live` feature. The built-in `AggregateSink` only counts and logs aggregates
(never per-record or per-device lines, services-03), so nothing here is a traffic-analysis surface.

## Run

```sh
hop-telemetryd --listen 0.0.0.0:9445 --domain telemetry.hopme.sh \
               --identity-file /etc/hop/identity --relay wss://relay.hopme.sh/
```

`--no-relay` (or `HOP_NO_RELAY=1`) runs it isolated (health + reach record only, receives nothing),
which is how it degrades while the relay fleet is off.

Licensed Apache-2.0 (the SDK/tooling tier). Internal; not mirrored to the public repos.
