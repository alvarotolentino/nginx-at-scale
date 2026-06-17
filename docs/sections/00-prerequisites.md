# Section 00 — Prerequisites & Hardware Setup

## Hardware tiers

| Tier | Spec | Provider | Latitude.sh server type |
|------|------|----------|-------------------------|
| **T1 — Baseline** | 4–8 vCPU, 16–32 GB RAM | Any cloud (AWS/GCP/DO) | n/a (cloud VM) |
| **T2 — Mid Bare Metal** | 32-core, 128 GB RAM, 25 GbE | Latitude.sh | `c3.medium.x86` (or current 32-core SKU) |
| **T3 — High-End Bare Metal** | 128-core, 512 GB RAM, 100 GbE | Latitude.sh | `c3.large.x86` (or current 128-core SKU) |

### Provisioning T2 / T3 on Latitude.sh

1. Create a project, then **Deploy → Bare Metal Server**.
2. **Location**: pick a region with the 25/100 GbE SKU in stock.
3. **Server type**: select the 32-core (T2) or 128-core (T3) plan above.
4. **Operating System**: choose **Debian 12 (Bookworm)** — minimal image.
5. Add your SSH key, deploy, and note the public IP.
6. For DPDK (Layer 8) request/confirm a **second NIC** — DPDK claims one NIC entirely;
   you need the other for management/SSH.

> All sysctl and Nginx directives in this guide are pure kernel/Nginx — nothing is
> Debian-specific. They run unmodified on Ubuntu 24.04 LTS after the hardening step
> in [the SPEC](../../SPEC.md) (purge snapd/cloud-init, disable auto-reboot).

## Software prerequisites

```bash
# Core tooling
sudo apt-get update
sudo apt-get install -y git make curl wget build-essential

# wrk (build from source)
git clone https://github.com/wg/wrk.git /tmp/wrk
make -C /tmp/wrk -j"$(nproc)"
sudo cp /tmp/wrk/wrk /usr/local/bin/

# wrk2 (build from source — latency-accurate, constant-rate)
git clone https://github.com/giltene/wrk2.git /tmp/wrk2
make -C /tmp/wrk2 -j"$(nproc)"
sudo cp /tmp/wrk2/wrk /usr/local/bin/wrk2

# k6 (Grafana apt repo)
sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
  --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update && sudo apt-get install -y k6

# Nginx (1.26+)
sudo apt-get install -y nginx

# Rust toolchain
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

# Node.js 20 (NodeSource apt repo)
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs
```

## Verify the toolchain

```bash
nginx -v          # nginx version: 1.26.x or newer
wrk --version     # wrk 4.x
wrk2 --version    # (built above)
k6 version        # k6 v0.5x
rustc --version   # rustc 1.7x+
node --version    # v20.x
```

## Clone and initial setup

```bash
git clone <this-repo> && cd highthroughput

# Build the frontend → nginx/static
( cd app/frontend && npm install && npm run build )

# Start the lux DB (Redis-compatible) — via docker, or a local lux binary
docker run -d -p 6379:6379 -e LUX_BIND_HOST=0.0.0.0 ghcr.io/lux-db/lux:latest

# Build + run the backend (listens on :8080, connects to lux on :6379)
( cd app/backend && REDIS_URL=redis://127.0.0.1:6379 cargo run --release -p server )

# In another shell: apply the baseline and smoke-test
sudo scripts/apply-baseline.sh
scripts/smoke-test.sh
```

## What you'll build

```
[wrk / k6 load generator]
          │
          ▼
   ┌─────────────────────────────┐
   │  Nginx  (port 80 / 443)     │
   │   ├── /       → static files: React SPA  (nginx/static → /srv/static)
   │   └── /api/   → reverse proxy ──────────────┐
   └─────────────────────────────┘               │
                                                  ▼
                                     ┌───────────────────────┐
                                     │ Rust backend (:8080)  │
                                     │   Axum (RESP client)  │
                                     └───────────┬───────────┘
                                                 │ redis://lux:6379 (RESP)
                                                 ▼
                                     ┌───────────────────────┐
                                     │ lux server (:6379)    │
                                     │  Redis-compatible DB  │
                                     │    └── ./data (snaps) │
                                     └───────────────────────┘
```

Next: [Section 02 — Baseline Measurement](02-baseline.md).
