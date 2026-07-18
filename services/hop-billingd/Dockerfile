# Container image for hop-billingd, the §37 billing reconciler.
#
# RUN-ONCE: read the persisted watermarks (BigQuery), collect the relays' + collectors' durable
# usage rows (Firestore, read-only), reconcile into idempotent Stripe meter events, append the
# advanced watermarks, then EXIT. There is no server here; a real deploy runs it as a scheduled
# Cloud Run Job (that deploy wiring, plus the trusted-layer plumbing, lands in a later increment,
# matching how hop-telemetryd shipped its crate + Dockerfile before its service). Build context is
# the repo root:
#   docker build -f services/hop-billingd/Dockerfile -t hop-billingd .

FROM rust:1.97.0-bookworm@sha256:8fa55b2f3ddf97471ab6a767bfa3f37e6bad0986ba823e75fea57e2a2a5c3073 AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY core ./core
COPY services ./services
COPY examples ./examples
# `live` pulls in reqwest + hop-store-firestore (the Firestore/Stripe/BigQuery wiring). A default
# build has no network surface; the image is the live path by definition.
RUN cargo build --release -p hop-billingd --features live

FROM debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818
# ca-certificates: the reconciler makes TLS calls to Stripe, Firestore, and BigQuery.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates=20230311+deb12u1 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/target/release/hop-billingd /usr/local/bin/hop-billingd

# Parent dir for the operator-mounted tenant->customer map (a real deploy mounts a read-only secret
# or config volume here); HOP_CUSTOMER_MAP points at a file under it.
RUN mkdir -p /etc/hop

# Config is entirely env-driven (no CLI flags). STRIPE_API_KEY is REQUIRED (the process exits 2
# without it). HOP_FIRESTORE_PROJECT / HOP_BQ_DATASET / HOP_BQ_WATERMARKS default to
# hop-mesh / hop_usage / reconcile_watermarks. HOP_CUSTOMER_MAP is the tenant->customer file.
# On Cloud Run the SA supplies credentials via the metadata server; FIRESTORE_ACCESS_TOKEN is a
# local-run override only. The container just runs the reconciler once and exits.
ENTRYPOINT ["hop-billingd"]
