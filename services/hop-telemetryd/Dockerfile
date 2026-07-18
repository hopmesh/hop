# Container image for hop-telemetryd, the OTel-over-Hop telemetry collector (DESIGN.md §40).
#
# A mesh leaf that dials the relay fleet, receives sealed hop.telemetry batches addressed to its
# key, and forwards them to a sink. Build context is the repo root:
#   docker build -f services/hop-telemetryd/Dockerfile -t hop-telemetryd .

FROM rust:1-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY core ./core
COPY services ./services
COPY examples ./examples
RUN cargo build --release -p hop-telemetryd --features firestore

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/target/release/hop-telemetryd /usr/local/bin/hop-telemetryd

# Parent dir for the default --identity-file, so first-run key generation can persist (a real deploy
# mounts a read-only secret here instead). Deploy wiring (Cloud Run + the identity secret) lands in a
# later increment, matching how hop-billingd shipped its crate before its service.
RUN mkdir -p /etc/hop

# Cloud Run sets $PORT (inbound HTTP /healthz + /.well-known/hop, plus the direct-dial WS bearer). HOP_*
# come from the Cloud Run env. Telemetry arrives inbound (direct-dial) or over the outbound relay link.
ENV PORT=8080
# HOP_FIRESTORE_PROJECT / HOP_KEY_SERVER are optional: the `${VAR:+--flag "$VAR"}` idiom passes the
# flag only when the env var is set, so a plain run still comes up on the local SQLite ledger.
ENTRYPOINT ["/bin/sh", "-c", "exec hop-telemetryd --listen 0.0.0.0:${PORT} --domain \"${HOP_DOMAIN:-telemetry.hopme.sh}\" --identity-file \"${HOP_IDENTITY_FILE:-/etc/hop/identity}\" --db \"${HOP_DB:-/tmp/hop-telemetryd.db}\" ${HOP_FIRESTORE_PROJECT:+--firestore \"$HOP_FIRESTORE_PROJECT\"} ${HOP_KEY_SERVER:+--key-server \"$HOP_KEY_SERVER\"}"]
