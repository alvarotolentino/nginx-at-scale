# Section 00 — Prerequisites & Hardware Setup

## Hardware tiers

| Tier | Spec | Cost | Latitude.sh server type |
|------|------|------|-------------------------|
| **T1 — Entry Bare Metal** | AMD EPYC 4244P, 6C/12T @ 3.8 GHz, 64 GB DDR5, 2× 960 GB NVMe, 2× 10 GbE | $0.41/hr | `m4.metal.small` |
| **T2 — Mid Bare Metal** | 32-core, 128 GB RAM, 25 GbE | — | `c3.medium.x86` (or current 32-core SKU) |
| **T3 — High-End Bare Metal** | 128-core, 512 GB RAM, 100 GbE | — | `c3.large.x86` (or current 128-core SKU) |

T1 is deliberately the **cheapest bare-metal SKU**: 6 dedicated Zen 4 cores at $0.41/hr —
about the hourly price of an 8-vCPU *shared* cloud VM. The tier exists to prove the
efficiency thesis: tuned correctly, this small box's **RPS per core / RPS per $** beats a
price-equivalent VM by a wide margin. Its 2× 10 GbE also matters: one NIC can serve
traffic while the other keeps SSH alive during DPDK (Layer 8), and 10 Gbps is a real,
reachable line rate — the monitor will show you when you hit it.

### Provisioning on Latitude.sh

1. Create a project, then **Deploy → Bare Metal Server**.
2. **Location**: pick a region with the SKU in stock.
3. **Server type**: `m4.metal.small` (T1), 32-core (T2), or 128-core (T3).
4. **Operating System**: choose **Debian 12 (Bookworm)** — minimal image.
5. Add your SSH key, deploy, and note the public IP.
6. For DPDK (Layer 8) confirm the box has a **second NIC** — DPDK claims one NIC entirely;
   you need the other for management/SSH. (`m4.metal.small` ships with 2× 10 GbE.)

> All sysctl and Nginx directives in this guide are pure kernel/Nginx — nothing is
> Debian-specific. They run unmodified on Ubuntu 24.04 LTS after a small hardening step
> (purge snapd/cloud-init, disable unattended auto-reboot).

## Two nodes

This is a **two-node** setup. Keep them separate — co-locating the load generator on the
target steals CPU/IRQs from the thing you're measuring and pollutes the numbers.

| Node | Role | What runs there |
|------|------|-----------------|
| **Target** | The tuned bare-metal box under test | nginx + backend + lux (systemd), the sysctl/nginx tuning layers, `snapshot.sh` (state, before load) + `monitor.sh` (CPU/mem/net sampling, during load) |
| **Tester** | A separate, isolated VM/instance | `wrk` / `wrk2` / `k6` (or `bombardier`) load generators only |

`monitor.sh` is target-side by design and costs almost nothing (pure `/proc` + `/sys`
reads every 2 s) — unlike running the load generator on the target, which would steal
the very CPU being measured.

## Target node — provisioning

The target is provisioned by one script. On a fresh **Debian 12** box:

```bash
git clone https://github.com/alvarotolentino/nginx-at-scale.git && cd nginx-at-scale
sudo scripts/install-target.sh
```

`install-target.sh` installs nginx + the Rust/Node toolchains, creates the `appsvc` /
`luxsvc` service users, builds the frontend → `/var/www/1b-shop` and the backend →
`/usr/local/bin/1b-backend`, builds lux from source, installs the systemd units (with
sandboxing), generates the self-signed TLS cert, applies the nftables firewall (only
22/80/443 inbound), brings up the baseline nginx config, and runs the target smoke test.

Verify afterwards:

```bash
systemctl is-active lux backend nginx     # all "active"
scripts/smoke-test.sh                      # loopback checks pass
nft list ruleset                           # only 22/80/443 exposed
```

> The backend (`:8080`) and lux (`:6379`) bind to `127.0.0.1` and are never in a firewall
> rule — they're reachable only through nginx, never from the tester or the network.

## Tester node — load tooling

The tester needs only the load generators (no nginx, no Rust, no app):

```bash
sudo apt-get update && sudo apt-get install -y git build-essential curl

# wrk (build from source)
git clone https://github.com/wg/wrk.git /tmp/wrk
make -C /tmp/wrk -j"$(nproc)" && sudo cp /tmp/wrk/wrk /usr/local/bin/

# wrk2 (latency-accurate, constant-rate)
git clone https://github.com/giltene/wrk2.git /tmp/wrk2
make -C /tmp/wrk2 -j"$(nproc)" && sudo cp /tmp/wrk2/wrk /usr/local/bin/wrk2

# k6 (Grafana apt repo)
sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
  --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update && sudo apt-get install -y k6
```

Then clone the repo on the tester too (for `scripts/load-test.sh` and the k6 scenarios)
and confirm reachability:

```bash
git clone https://github.com/alvarotolentino/nginx-at-scale.git && cd nginx-at-scale
scripts/smoke-test.sh --target https://<target-ip>   # remote checks pass
```

## Running a layer (the manual three-step)

```bash
# TARGET: apply + snapshot one layer (or the whole sweep with apply-all-layers.sh,
# which starts/stops the monitor for you around each load pause)
sudo scripts/apply-layer-1.sh

# TARGET: start sampling utilization for the load window (background)
scripts/monitor.sh --label layer-1 --tier 1 --duration 45 &

# TESTER: generate load against the target for that same label
scripts/load-test.sh --target https://<target-ip> --label layer-1 --tier 1

# Copy the tester's load/ results back to the target, then build the report there:
scp -r results/tier-1/layer-1/load target:nginx-at-scale/results/tier-1/layer-1/
# on TARGET:
scripts/generate-report.sh --tier 1 --cost 0.41    # --cost adds RPS per $/hr
```

## What you'll build

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

Next: [Section 02 — Baseline Measurement](02-baseline.md).
