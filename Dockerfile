# Multi-stage build for horcrux-relay.
# NOTE: this pin no longer matches the workspace's `rust-version = "1.80"`.
# `zeroize_derive` 1.5.0 (pulled in by zeroize 1.9) requires `edition2024`,
# which is only stabilised from Rust 1.85 — 1.80 can no longer resolve the
# dependency graph at all. The declared workspace MSRV is therefore stale
# and needs a separate decision; do not "restore" this to 1.80.
FROM rust:1.98-slim-bookworm AS builder

# L3 (audit `docs/security-audit-2026-04.md`): build as a non-root user.
# No runtime impact (the build artefact is the same), but it eliminates the
# CVE class where a malicious build script in a transitive dependency would
# otherwise execute with uid 0 inside the build container.
RUN useradd --create-home --shell /bin/bash --uid 1000 builder
USER builder
WORKDIR /home/builder/build

COPY --chown=builder:builder Cargo.toml Cargo.lock ./
COPY --chown=builder:builder horcrux-core/ horcrux-core/
COPY --chown=builder:builder horcrux-relay/ horcrux-relay/
COPY --chown=builder:builder uniffi-bindgen/ uniffi-bindgen/
# Required purely so `[patch.crates-io] gmp-mpfr-sys` in the root
# Cargo.toml resolves — without it cargo aborts while loading the
# workspace manifest. horcrux-core is only a dev-dependency of
# horcrux-relay, so nothing here is actually compiled for this image.
COPY --chown=builder:builder third_party/ third_party/

RUN cargo build --release -p horcrux-relay && \
    strip target/release/horcrux-relay

# Runtime image
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash relay
USER relay

COPY --from=builder /home/builder/build/target/release/horcrux-relay /usr/local/bin/

ENV RELAY_HOST=0.0.0.0
ENV RELAY_PORT=8080

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s \
  CMD curl -f http://localhost:8080/health || exit 1

ENTRYPOINT ["horcrux-relay"]
