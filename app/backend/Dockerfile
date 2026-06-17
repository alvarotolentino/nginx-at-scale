# syntax=docker/dockerfile:1
# Multi-stage build: compile a fully-optimized release binary, then ship it in a
# minimal runtime image. The dev compose `cargo run`s from source; production
# uses this to produce a small, fast, immutable image (no toolchain at runtime).

# ---- Stage 1: builder -------------------------------------------------------
FROM rust:1-slim AS builder
WORKDIR /build

# Cache dependencies separately from source: copy manifests + cargo config first,
# build a dummy crate, then copy real sources. Edits to src/ won't re-fetch/rebuild
# the dependency graph.
COPY .cargo ./.cargo
COPY Cargo.toml ./Cargo.toml
COPY server/Cargo.toml ./server/Cargo.toml
RUN mkdir -p server/src && echo 'fn main() {}' > server/src/main.rs
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    cargo build --release -p server || true

# Now the real sources; rebuild only the app crate.
COPY server/src ./server/src
# Touch so cargo notices the real main.rs over the dummy.
RUN touch server/src/main.rs
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    cargo build --release -p server

# ---- Stage 2: runtime -------------------------------------------------------
# glibc base matching the builder; no Rust toolchain, no build deps. The redis
# client is pure-Rust with no TLS here, so only libc is needed at runtime.
FROM debian:bookworm-slim AS runtime
RUN useradd --system --uid 10001 --no-create-home appuser
WORKDIR /app

COPY --from=builder /build/target/release/server /usr/local/bin/server

USER appuser
EXPOSE 8080
ENV RUST_LOG=info \
    REDIS_URL=redis://lux:6379
ENTRYPOINT ["/usr/local/bin/server"]
