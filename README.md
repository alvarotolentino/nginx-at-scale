# 1B Nginx — One Billion Concurrent Users on a Single Nginx Instance

A performance-engineering guide and fully reproducible repository that progressively
tunes a Linux system and Nginx to handle extreme concurrency. Each optimization layer
is measured before and after, so every improvement is visible and attributable. The
thesis: bare metal, correctly configured, beats an equivalently priced cloud VM by
orders of magnitude.

The demo workload is a minimal React + Rust e-commerce app that exists only to generate
realistic static + dynamic traffic so concurrency numbers are meaningful, not synthetic.

## Architecture

Two nodes. The **target** is the tuned bare-metal box under test; the **tester** is a
separate, isolated machine that generates load. They're kept apart on purpose — running
the load generator on the target steals CPU/IRQs from the thing being measured.

```mermaid
flowchart LR
    subgraph tester["TESTER node (isolated)"]
        lt["scripts/load-test.sh<br/>wrk / wrk2 / k6<br/>--target https://IP"]
    end
    subgraph target["TARGET node (bare metal, tuned)"]
        fw["nftables<br/>only 22/80/443 inbound"]
        nginx["nginx (systemd)<br/>CAP_NET_BIND_SERVICE<br/>/ → /var/www/1b-shop (SPA)"]
        backend["backend (systemd, appsvc)<br/>127.0.0.1:8080 (loopback)"]
        lux["lux (systemd, luxsvc)<br/>127.0.0.1:6379 (loopback, 0700)"]
        mon["snapshot.sh (state, pre-load)<br/>monitor.sh (CPU/mem/net, during load)"]
    end
    lt -->|"HTTPS :443"| fw
    fw --> nginx
    nginx -->|"/api/"| backend
    backend -->|"redis RESP"| lux
```

- **No Docker on the target.** App components run as **systemd** services so the kernel,
  network stack, NUMA topology, and NIC tuning the layers exercise are the *real* host's —
  not a container's namespaced copy. (Docker is kept in [`dev/`](dev/) for local dev only.)
- **Frontend**: React + Vite, built to static files served directly by nginx from
  `/var/www/1b-shop`. Paginated dashboard; one shared bundled image for all products.
- **Backend**: Rust + Axum, bound **loopback-only** (`127.0.0.1:8080`). Connects to lux via
  `redis-rs` (auto-reconnecting `ConnectionManager`); seeds 100 products / 500 orders on
  startup (idempotent). Runs as the unprivileged `appsvc` user.
- **DB**: [lux](https://github.com/lux-db/lux) — Redis-compatible (RESP) server, **loopback-
  only** on `:6379`, as the `luxsvc` user with a `0700` data dir.
- **Security**: TLS 1.2/1.3 + HSTS, strict CSP and security headers, nftables default-drop
  firewall, and systemd sandboxing on every service. See [Section 15](docs/sections/15-security.md).

## Hardware Tiers

| Tier | Description | Provider | Cost |
|------|-------------|----------|------|
| **T1 — Entry Bare Metal** | `m4.metal.small` — AMD EPYC 4244P (6C/12T @ 3.8 GHz), 64 GB DDR5, 2× 960 GB NVMe, 2× 10 GbE | Latitude.sh | **$0.41/hr** |
| **T2 — Mid Bare Metal** | 32-core, 128 GB RAM, 25 GbE NIC | Latitude.sh | — |
| **T3 — High-End Bare Metal** | 128-core, 512 GB RAM, 100 GbE NIC | Latitude.sh | — |

T1 is the project's thesis in miniature: $0.41/hr buys roughly the same as an 8-vCPU
shared cloud VM (e.g. c5.2xlarge) — but here it's 6 dedicated Zen 4 cores, a real NIC,
real NUMA, and no hypervisor. Tuned to its limit, the efficiency comparison is made in
**RPS per core and RPS per dollar-hour**, not raw connection counts.

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
| 06 | Layer 4 — Memory Allocator (jemalloc) | [docs/sections/06-layer-04-jemalloc.md](docs/sections/06-layer-04-jemalloc.md) |
| 07 | Layer 5 — TLS Hardening & Session Resumption | [docs/sections/07-layer-05-tls.md](docs/sections/07-layer-05-tls.md) |
| 08 | Layer 6 — Async File I/O | [docs/sections/08-layer-06-aio.md](docs/sections/08-layer-06-aio.md) |
| 09 | Layer 7 — NUMA & CPU Affinity | [docs/sections/09-layer-07-numa.md](docs/sections/09-layer-07-numa.md) |
| 10 | Layer 8 — DPDK & Kernel Bypass | [docs/sections/10-layer-08-dpdk.md](docs/sections/10-layer-08-dpdk.md) |
| 11 | Hardware Tiers Compared | [docs/sections/11-tiers.md](docs/sections/11-tiers.md) |
| 12 | Advanced: FreeBSD Networking Stack | [docs/sections/12-freebsd.md](docs/sections/12-freebsd.md) |
| 13 | Results Summary & Takeaways | [docs/sections/13-results.md](docs/sections/13-results.md) |
| 14 | Appendix: Custom Kernel Build | [docs/sections/14-kernel-build.md](docs/sections/14-kernel-build.md) |
| 15 | Security Hardening & Attack-Surface Reduction | [docs/sections/15-security.md](docs/sections/15-security.md) |

Planned next steps (kernel + nginx tuning beyond Layer 7, without DPDK) are analyzed in
[docs/proposals/post-layer-7-tuning-proposal.md](docs/proposals/post-layer-7-tuning-proposal.md).

## Measured so far — Tier 1 (`m4.metal.small`, $0.41/hr)

Full Layers 1–7 sweep on a **valid rig** — target and tester are both bare-metal
`m4.metal.small` on a one-hop 0.057 ms LAN (0 % loss), so the **target is the bottleneck**,
as intended. Layers 1–4 plaintext HTTP; 5–7 HTTPS (TLS 1.3). Profile `highconn`
(30 s, 12 threads, 4000 conns, 10 GbE). Async file I/O and kTLS stay opt-in/off — they
regressed this workload (see Layers 5–6).

| Test | Best RPS | Per core | RPS per $/hr | Bound by |
|---|---|---|---|---|
| Static — plaintext HTTP (L4) | **828,546** | 69.0 k | ~2.02 M | CPU + NIC co-limited (12 threads at 100 %, tx line rate) |
| Static — HTTPS / TLS 1.3 (L7) | **566,257** | 47.2 k | ~1.38 M | CPU (TLS −32 % vs plaintext) |
| Static — warm HTTP/2 + TLS (L5) | **765,276** | 63.8 k | ~1.87 M | CPU (h2 buys back TLS cost → ~92 % of plaintext) |
| UI mix (HTML + assets + image) | **~177,000** | — | — | NIC — tx 9.84 Gbps = 10 GbE line rate |

Findings worth stealing even if you read nothing else:

- **Layer 3 (nginx workers + event model) is the single biggest lever: +70 % static
  (485k → 822k)** and it fixes the API path in one step (listen_drops 158k → 51k, API
  broken → clean). Layers 4 (jemalloc) and 7 (NUMA) are neutral on this hardware — allocator
  isn't hot, and there's only 1 NUMA node. Layer 6 (AIO) is a mild negative on TLS.
- The **base host tuning** (performance governor, buffered access log, open_file_cache)
  roughly **doubled** throughput — more than any single layer — and **CPU pinning without
  aRFS costs −42 %** on static while pinning *with* aRFS is the optimum.
- **The wall is now physics, not config.** Static is CPU + NIC co-limited at once; the UI
  phase is pinned at 10 GbE line rate and bleeds **40–90k retransmits/s** — a line-rate
  buffer-overrun artifact, not tester weakness or a CPU wall. The two remaining levers:
  shave per-request CPU, or send fewer bytes / add wire.

Per-layer deltas and the full server-side cost breakdown live in
[`results/tier-1/REPORT.md`](results/tier-1/REPORT.md) and
[Section 09](docs/sections/09-layer-07-numa.md).

## Prerequisites

- **Target node** — Debian 13 (Trixie) or 12 (Bookworm) minimal, bare metal. Everything else (nginx,
  Rust ≥ 1.85, Node 20, numactl, nftables, libaio) is installed by `install-target.sh`.
- **Tester node** — a separate VM/instance with `wrk`, `wrk2`, `k6`.
- See [docs/sections/00-prerequisites.md](docs/sections/00-prerequisites.md) for the full
  two-node setup and load tooling.

## Quick Start

**On the target** (bare-metal Debian 12/13) — one script provisions the whole stack:

```bash
git clone https://github.com/alvarotolentino/nginx-at-scale.git && cd nginx-at-scale
sudo scripts/install-target.sh        # nginx + backend + lux (systemd), TLS, firewall, baseline

# Apply the first optimization layer and snapshot the box state
sudo scripts/apply-layer-1.sh
```

**During the load window, on the target** — sample what the load costs the box:

```bash
# --duration must cover all load stages (wrk static + UI + h2load ≈ 3 × 30 s + 20 s);
# load-test.sh prints the exact suggested value for its flags at the end of each run.
scripts/monitor.sh --label layer-1 --tier 1 --duration 110 &   # CPU/mem/net/socket time series
```

**On the tester** (separate node) — generate load against the target:

```bash
# --profile highconn (4000 conns) spreads load across all SO_REUSEPORT workers —
# the 400-conn default under-utilises cores from layer 3 on. --h2 adds the
# warm-HTTP/2 h2load stage (https target required). These flags produced the
# headline numbers below.
scripts/load-test.sh --target https://<target-ip> --label layer-1 --tier 1 \
  --profile highconn --h2
```

Full sweep (target applies + snapshots every layer, pausing for the tester between each —
the monitor is started/stopped automatically around each pause):

```bash
sudo scripts/apply-all-layers.sh --tier 1
# copy the tester's results back, then:  scripts/generate-report.sh --tier 1 --cost 0.41
# → results/tier-1/REPORT.md  (tester view + target view + RPS/core + RPS per $/hr)
```

## Measurement model — both sides of the wire

Every labeled run produces **three** result sets, merged by `--label`:

| Side | Script | When | What it captures |
|------|--------|------|------------------|
| Target | `snapshot.sh` | before load | Box *state*: kernel params, nginx config, topology, allocator |
| Target | `monitor.sh` | **during** load | Box *cost*: CPU (total, busiest core, %softirq), per-service CPU/RSS via cgroups, NIC Mbps/pps, open sockets/TIME-WAIT, retransmits, accept-queue drops — 2 s time series + summary |
| Tester | `load-test.sh` | during load | Client *experience*: RPS, latency percentiles, transfer/s, socket + HTTP errors |

`generate-report.sh` joins them into one report so each layer answers not just "did RPS
go up" but "**what did it cost**, and what is the wall now" — CPU-bound, one core pegged
on softirq, NIC at line rate, or accept queue overflowing. With `--cost`, it also computes
**RPS per $/hr**, the number that makes bare metal vs cloud comparable.

> Just want to poke at the app locally? The Docker stack in [`dev/`](dev/) brings it up in
> one command — but it is **not** the benchmark target (containers hide the very tuning
> this project measures).

## Build optimizations

The frontend and backend are compiled for production-grade efficiency:

| Side | Optimizations |
|------|---------------|
| **Frontend** | `target: es2020`, esbuild minify, `drop: [console, debugger]`, no sourcemaps, vendor chunk split, **gzip + brotli precompression** |
| **Backend** | `opt-level=3`, fat LTO, `codegen-units=1`, `panic=abort`, **`strip`**, `target-cpu=x86-64-v3` (→ `native` on dedicated bare metal); loopback-only bind, runs as `appsvc` |
| **Nginx** | `gzip_static on` serves the precompressed assets in the tuned configs (zero runtime compression CPU); `brotli_static` available if built with `ngx_brotli` |

> `target-cpu=x86-64-v3` needs a CPU from ~2015+ (AVX2). On older hardware switch to
> `x86-64-v2` in [app/backend/.cargo/config.toml](app/backend/.cargo/config.toml).

## Repository Layout

```
app/                       React frontend + Rust backend (loopback-only, RESP client)
  backend/.cargo/          codegen flags (target-cpu)
  backend/Dockerfile       backend image — used only by the dev/ Docker stack
deploy/
  systemd/                 lux.service, backend.service, nginx hardening drop-in
  firewall/                nftables.conf (default-drop; only 22/80/443)
nginx/                     baseline.conf, per-layer configs (loopback upstream, /var/www/1b-shop)
kernel/                    sysctl.d snippets per layer
benchmarks/                wrk Lua scripts, k6 scenarios, conn-holder (Rust concurrent-
                           connection holder for the connection-ceiling test)
scripts/                   install-target.sh, apply-layer-N.sh, apply-all-layers.sh,
                           tune-network-rps.sh (RSS/aRFS packet steering, run at Layer 2),
                           snapshot.sh + monitor.sh (target), load-test.sh +
                           concurrency-test.sh (tester), generate-report.sh [--cost $/hr]
results/                   benchmark output per tier (<label>/{snapshot,monitor,load})
docs/                      written guide sections
dev/                       Docker Compose — LOCAL DEV ONLY, not the benchmark target
```

> **Note:** 1B concurrent is the theoretical ceiling on T3 hardware. Each tier documents
> its realistic ceiling in [Section 13](docs/sections/13-results.md).
