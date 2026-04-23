# Multi-stage build for horcrux-relay.
# Pinned Rust version tracks the workspace's rust-version field in Cargo.toml.
FROM rust:1.80-slim-bookworm AS builder

WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY horcrux-core/ horcrux-core/
COPY horcrux-relay/ horcrux-relay/
COPY uniffi-bindgen/ uniffi-bindgen/

RUN cargo build --release -p horcrux-relay && \
    strip target/release/horcrux-relay

# Runtime image
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash relay
USER relay

COPY --from=builder /build/target/release/horcrux-relay /usr/local/bin/

ENV RELAY_HOST=0.0.0.0
ENV RELAY_PORT=8080

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s \
  CMD curl -f http://localhost:8080/health || exit 1

ENTRYPOINT ["horcrux-relay"]
