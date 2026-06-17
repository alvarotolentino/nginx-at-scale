# 1B Nginx — One Billion Concurrent Users on a Single Nginx Instance

A performance-engineering guide and fully reproducible repository that progressively
tunes a Linux system and Nginx to handle extreme concurrency. Each optimization layer
is measured before and after, so every improvement is visible and attributable. The
thesis: bare metal, correctly configured, beats an equivalently priced cloud VM by
orders of magnitude.

The demo workload is a minimal React + Rust e-commerce app that exists only to generate
realistic static + dynamic traffic so concurrency numbers are meaningful, not synthetic.

## Architecture

```
[wrk / k6]  →  Nginx (:80/:443)
                 ├── /      → static React SPA  (nginx/static → /srv/static)
                 └── /api/  → Rust backend (:8080, Axum)
                                 └── redis://lux:6379 (RESP) → lux server (Redis-compatible DB)
```

- **Frontend**: React + Vite, built to static files, served directly by Nginx. Paginated
  product dashboard; one shared bundled image for all products.
- **Backend**: Rust + Axum. Connects to **lux** as a Redis client (`redis-rs`,
  auto-reconnecting `ConnectionManager`). Seeds 100 products / 500 orders on startup
  (idempotent).
- **DB**: [lux](https://github.com/lux-db/lux) — a Redis-compatible (RESP) server, run as
  its own service on `:6379`. Configured via `LUX_*` env vars (default in-memory + snapshots).

## Hardware Tiers

| Tier | Description | Provider |
|------|-------------|----------|
| **T1 — Baseline** | Mid-range cloud VM (4–8 vCPU, 16–32 GB RAM) | Any cloud (AWS/GCP/DO) |
| **T2 — Mid Bare Metal** | 32-core, 128 GB RAM, 25 GbE NIC | Latitude.sh |
| **T3 — High-End Bare Metal** | 128-core, 512 GB RAM, 100 GbE NIC | Latitude.sh |

Each tier starts from the same baseline and applies the same progressive tuning, making
the improvement delta clearly visible across hardware.

## Sections

| # | Section | Doc |
|---|---------|-----|
| 00 | Prerequisites & Hardware Setup | [docs/sections/00-prerequisites.md](docs/sections/00-prerequisites.md) |
| 01 | The Demo App | [docs/sections/01-demo-app.md](docs/sections/01-demo-app.md) |
| 02 | Baseline Measurement | [docs/sections/02-baseline.md](docs/sections/02-baseline.md) |
| 03 | Layer 1 — File Descriptors & Socket Buffers | [docs/sections/03-layer-01-fd.md](docs/sections/03-layer-01-fd.md) |
| 04 | Layer 2 — Linux TCP/IP Kernel Tuning | [docs/sections/04-layer-02-tcp.md](docs/sections/04-layer-02-tcp.md) |
| 05 | Layer 3 — Nginx Worker & Event Model | [docs/sections/05-layer-03-events.md](docs/sections/05-layer-03-events.md) |
| 06 | Layer 4 — Memory Allocator (jemalloc) | [docs/sections/layer-04-jemalloc.md](docs/sections/layer-04-jemalloc.md) |
| 07 | Layer 5 — TLS Hardening & Session Resumption | [docs/sections/07-layer-05-tls.md](docs/sections/07-layer-05-tls.md) |
| 08 | Layer 6 — Async File I/O | [docs/sections/layer-06-aio.md](docs/sections/layer-06-aio.md) |
| 09 | Layer 7 — NUMA & CPU Affinity | [docs/sections/09-layer-07-numa.md](docs/sections/09-layer-07-numa.md) |
| 10 | Layer 8 — DPDK & Kernel Bypass | [docs/sections/layer-08-dpdk.md](docs/sections/layer-08-dpdk.md) |
| 11 | Hardware Tiers Compared | [docs/sections/11-tiers.md](docs/sections/11-tiers.md) |
| 12 | Advanced: FreeBSD Networking Stack | [docs/sections/12-freebsd.md](docs/sections/12-freebsd.md) |
| 13 | Results Summary & Takeaways | [docs/sections/13-results.md](docs/sections/13-results.md) |
| 14 | Appendix: Custom Kernel Build | [docs/sections/14-kernel-build.md](docs/sections/14-kernel-build.md) |

## Prerequisites

- **OS**: Debian 12 (Bookworm) minimal install (runs unmodified on Ubuntu 24.04 LTS after hardening)
- `git`, `make`, `curl`
- **Docker** + **Docker Compose v2** (for the local stack)
- For native (non-Docker) builds: Rust (latest stable, ≥ 1.85), Node 20
- See [docs/sections/00-prerequisites.md](docs/sections/00-prerequisites.md) for the full toolchain (wrk, wrk2, k6, Rust, Node 20).

## Quick Start

```bash
git clone <this-repo> && cd highthroughput

# Build the demo app (frontend static + Rust backend) and bring it up
docker compose --profile build run --rm frontend-build   # builds React → nginx/static
docker compose up -d lux backend nginx                   # lux DB + backend + baseline nginx

# Apply the first optimization layer and measure
sudo scripts/apply-layer-1.sh
sudo scripts/measure.sh --label layer-1 --tier 1
```

Run a full sweep across every layer:

```bash
sudo scripts/run-all-layers.sh --tier 1
# → results/tier-1/REPORT.md
```

## Production Build

The dev stack above compiles the backend from source on each boot (`cargo run`). For a
production-grade run, use the optimized build: a minified + precompressed frontend and an
immutable backend image built from a multi-stage Dockerfile.

```bash
# Frontend: minified bundle (es2020, console/debugger stripped) + .gz/.br assets
docker compose --profile build run --rm frontend-build

# Backend: optimized release binary baked into a slim image; lux pinned; restart policies
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build
```

Build/compile optimizations in effect:

| Side | Optimizations |
|------|---------------|
| **Frontend** | `target: es2020`, esbuild minify, `drop: [console, debugger]`, no sourcemaps, vendor chunk split, **gzip + brotli precompression** |
| **Backend** | `opt-level=3`, fat LTO, `codegen-units=1`, `panic=abort`, **`strip`**, `target-cpu=x86-64-v3` (→ `native` on dedicated bare metal), multi-stage → `debian:bookworm-slim` (no toolchain at runtime, non-root) |
| **Nginx** | `gzip_static on` serves the precompressed assets in the tuned configs (zero runtime compression CPU); `brotli_static` available if built with `ngx_brotli` |
| **DB** | lux pinned to a fixed tag for reproducibility |

> `target-cpu=x86-64-v3` needs a CPU from ~2015+ (AVX2). On older hardware switch to
> `x86-64-v2` in [app/backend/.cargo/config.toml](app/backend/.cargo/config.toml).

## Repository Layout

```
app/                       React frontend + Rust backend (connects to lux over RESP)
  backend/Dockerfile       multi-stage production backend image
  backend/.cargo/          codegen flags (target-cpu)
nginx/                     baseline.conf, per-layer configs, static build output
kernel/                    sysctl.d snippets per layer
benchmarks/                wrk Lua scripts, k6 scenarios
scripts/                   apply-layer-N.sh, measure.sh, reset-baseline.sh, orchestration
results/                   raw benchmark output per tier
docs/                      written guide sections
docker-compose.yml         dev stack (lux + backend-from-source + nginx)
docker-compose.prod.yml    production override (built backend image, pinned lux)
```

> **Note:** 1B concurrent is the theoretical ceiling on T3 hardware. Each tier documents
> its realistic ceiling in [Section 13](docs/sections/13-results.md).
