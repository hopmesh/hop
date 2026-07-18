# Container image for hop-telemetryd, the OTel-over-Hop telemetry collector (DESIGN.md §40).
#
# A mesh leaf that dials the relay fleet, receives sealed hop.telemetry batches addressed to its key,
# meters them per tenant, and (managed) forwards them as OTLP to each tenant's own endpoint. Build
# context is the repo root:
#   docker build -f services/hop-telemetryd/Dockerfile -t hop-telemetryd .

FROM rust:1.97.0-bookworm@sha256:8fa55b2f3ddf97471ab6a767bfa3f37e6bad0986ba823e75fea57e2a2a5c3073 AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY core ./core
COPY services ./services
COPY examples ./examples
# firestore: durable telemetry_usage ledger. live: the OTLP-export path (reqwest). Both config-gated,
# so the image only forwards when an endpoint map is provided, and only bills to a durable store.
RUN cargo build --release -p hop-telemetryd --features firestore,live

FROM debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates=20230311+deb12u1 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/target/release/hop-telemetryd /usr/local/bin/hop-telemetryd

# Parent dir for the default --identity-file, so first-run key generation can persist (a real deploy
# mounts a read-only secret here instead). Deploy wiring (Cloud Run + the identity secret) lands in a
# later increment, matching how hop-billingd shipped its crate before its service.
RUN mkdir -p /etc/hop

# Cloud Run sets $PORT (inbound HTTP /healthz + /.well-known/hop, plus the direct-dial WS bearer). HOP_*
# come from the Cloud Run env. Telemetry arrives inbound (direct-dial) or over the outbound relay link.
ENV PORT=8080
# HOP_FIRESTORE_PROJECT / HOP_KEY_SERVER / HOP_OTLP_MAP are optional: the `${VAR:+--flag "$VAR"}` idiom
# passes the flag only when set, so a plain run still comes up on the local SQLite ledger with no
# OTLP export. HOP_OTLP_MAP is a file of `<tenant-hex> <otel-endpoint> [auth]` lines; without it, the
# collector meters + logs telemetry but forwards nothing.
ENTRYPOINT ["/bin/sh", "-c", "exec hop-telemetryd --listen 0.0.0.0:${PORT} --domain \"${HOP_DOMAIN:-telemetry.hopme.sh}\" --identity-file \"${HOP_IDENTITY_FILE:-/etc/hop/identity}\" --db \"${HOP_DB:-/tmp/hop-telemetryd.db}\" ${HOP_FIRESTORE_PROJECT:+--firestore \"$HOP_FIRESTORE_PROJECT\"} ${HOP_KEY_SERVER:+--key-server \"$HOP_KEY_SERVER\"} ${HOP_OTLP_MAP:+--otlp-map \"$HOP_OTLP_MAP\"}"]
