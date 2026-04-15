# ---------- Build stage ----------
FROM rust:1.75-slim AS builder

WORKDIR /app

# Copy workspace files
COPY Cargo.toml Cargo.lock ./
COPY horcrux-core/ horcrux-core/
COPY horcrux-relay/ horcrux-relay/

RUN cargo build --release -p horcrux-relay

# ---------- Runtime stage ----------
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/release/horcrux-relay /usr/local/bin/horcrux-relay

ENV RELAY_HOST=0.0.0.0
ENV RELAY_PORT=3210

EXPOSE 3210

CMD ["horcrux-relay"]
