# Container image for hop-accountd, the account/invoice backend behind the console's billing pages.
#
# A persistent HTTP service: it reads Stripe with the restricted stripe-account-key (invoice list +
# line items, payments, card on file, server-driven pay) and serves the console over an
# authenticated front. Deploy wiring (a Cloud Run service + the stripe-account-key / HOP_API_TOKEN
# secrets + the trusted-layer plumbing) lands in a later increment, matching how hop-telemetryd
# shipped its crate + Dockerfile before its service. Build context is the repo root:
#   docker build -f services/hop-accountd/Dockerfile -t hop-accountd .

FROM rust:1.97.0-bookworm@sha256:8fa55b2f3ddf97471ab6a767bfa3f37e6bad0986ba823e75fea57e2a2a5c3073 AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY core ./core
COPY services ./services
COPY examples ./examples
# `live` pulls in reqwest (the Stripe transport). A default build has no network surface; the image
# is the live path by definition.
# live = the reqwest Stripe/Resend/OAuth transports; firestore = the tenant-registry projection
# (HOP_TENANT_SYNC_PROJECT) + the near-realtime usage read off the fleet Firestore ledgers.
RUN cargo build --release -p hop-accountd --features live,firestore

FROM debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818
# ca-certificates: the service makes TLS calls to the Stripe API.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates=20230311+deb12u1 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/target/release/hop-accountd /usr/local/bin/hop-accountd

# Parent dir for the operator-mounted tenant->customer map (a real deploy mounts a read-only secret
# or config volume here); HOP_TENANT_MAP points at a file under it.
RUN mkdir -p /etc/hop

# Config is entirely env-driven (no CLI flags). The service refuses to start without
# STRIPE_ACCOUNT_KEY and a >=16-byte HOP_API_TOKEN. HOP_TENANT_MAP is the tenant->customer file.
# Cloud Run sets $PORT for inbound HTTP; accountd binds 0.0.0.0:$PORT (default 9446 off Cloud Run).
ENV PORT=8080
ENTRYPOINT ["hop-accountd"]
