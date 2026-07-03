# Section 02 — Baseline Measurement

## What "baseline" means here

The baseline is **stock Nginx on stock Linux**: the default `worker_connections 1024`,
no kernel tuning, no jemalloc, no TLS, no caching, no gzip. It is deliberately
unoptimized so every later layer has a fair, honest starting point to measure against.
We never tune `nginx/baseline.conf` — it is frozen as the reference.

## The baseline config, annotated

```nginx
user nginx;
worker_processes auto;          # one worker per CPU — the only "auto" we keep at baseline
events {
    worker_connections 1024;    # STOCK DEFAULT. 1024 × workers is the hard connection ceiling
}
http {
    access_log /var/log/nginx/access.log;   # logging on (a small but real cost)
    upstream backend { server 127.0.0.1:8080; } # the loopback Rust API, no keepalive pool

    server {
        listen 80;              # plain HTTP, default backlog, no reuseport
        root /var/www/1b-shop;  # React SPA build
        location /api/ {
            proxy_pass http://backend/api/;   # reverse proxy, no upstream keepalive
        }
        location / {
            try_files $uri $uri/ /index.html; # SPA fallback
        }
    }
}
```

Every directive here is the framework default. There is no `use epoll`, no
`multi_accept`, no raised `worker_rlimit_nofile`, no socket-buffer tuning — that is the
point.

## Running the baseline (two nodes)

```bash
# --- TARGET: install the baseline config + snapshot the box state ---
sudo scripts/apply-baseline.sh
#   (cp nginx/baseline.conf → /etc/nginx/nginx.conf, reload, then snapshot.sh --label baseline)

# --- TARGET: sample utilization during the load window (background) ---
scripts/monitor.sh --label baseline --tier 1 --duration 45 &

# --- TESTER: generate load against the target for the same label ---
scripts/load-test.sh --target https://<target-ip> --label baseline --tier 1

# --- read the output ---
cat results/tier-1/baseline/load/wrk-static.txt          # on the tester
cat results/tier-1/baseline/monitor/summary.txt          # on the target
cat results/tier-1/baseline/snapshot/socket-stats.txt    # on the target
```

The work is split across the two nodes — and, on the target, across *before* and *during*:

- **`snapshot.sh`** (target, before load) records *what state the box is in* —
  `socket-stats.txt`, `kernel-params.txt`, `nginx-params.txt`, `cpu-topology.txt`,
  `allocator.txt`, `memory.txt`, `services.txt` — into `results/tier-N/<label>/snapshot/`.
- **`monitor.sh`** (target, **during** load) records *what the load costs the box* — a 2 s
  time series (`timeseries.csv`) plus a parseable `summary.txt`: total CPU %, busiest
  single core %, %softirq, per-service CPU/RSS (nginx / backend / lux via cgroup v2),
  NIC Mbps/kpps, open TCP sockets and TIME-WAIT, retransmits, and accept-queue
  (listen) drops — into `results/tier-N/<label>/monitor/`.
- **`load-test.sh`** (tester) records *how it performed* — RPS, latency percentiles,
  transfer/s, socket + HTTP errors — into `results/tier-N/<label>/load/`. `wrk` accepts
  the self-signed lab cert transparently.

Copy the tester's `load/` dir back into the target's results tree, then
`scripts/generate-report.sh --tier 1 --cost 0.41` merges all three by label and computes
RPS/core and RPS per $/hr.

## What to record

Open `results/REPORT-TEMPLATE.md` and fill the **Baseline** row: the RPS and p99 you
just measured, plus the target-side picture from `monitor/summary.txt` — peak CPU %,
busiest core %, %softirq, and whether listen drops were non-zero. This is the number
every later layer's delta is computed against, and the utilization data is what tells
you *which wall* the baseline hit (CPU? one core? accept queue?) — i.e. which layer
should move the needle next.

## Understanding the numbers

- **Requests/sec vs connections.** RPS is *completed requests per second*; connections
  is *how many sockets are open at once*. A server can hold millions of idle keepalive
  connections while serving far fewer requests/sec — they measure different things. The
  guide's milestones are about **concurrent connections**; wrk's RPS measures
  **throughput** on a smaller connection count. Neither alone is "performance": always
  read RPS **with** its latency tail, its error count, and the target-side cost
  (`monitor/summary.txt`). 100k RPS at 40% CPU and 100k RPS at 100% CPU are very
  different results — only the first has headroom.
- **Latency percentiles.** Average latency hides tail pain. **p99** (the slowest 1% of
  requests) is what real users feel during contention — a good average with a bad p99
  means some users are getting hurt. We track p50/p95/p99 and care most about p99.
- **`Too many open files`.** At baseline you may see this in `error.log` or as wrk
  socket errors. It means Nginx hit the default file-descriptor limit — each connection
  is an FD, and the stock ceiling is low. **This is exactly what Layer 1 fixes**; seeing
  it here is expected and motivates the first optimization.

## Expected baseline numbers (rough)

| Tier | RPS (static) | p99 |
|------|-------------|-----|
| **T1** — `m4.metal.small` (6C/12T Zen 4) | ~40,000–110,000 | ~2–12 ms |
| **T2** — 32-core bare metal | ~80,000–200,000 | ~2–8 ms |
| **T3** — 128-core bare metal | ~150,000–400,000 | ~1–5 ms |

These are starting points, not goals. The whole guide is about how far above these the
same hardware goes once each layer is stacked on. Next: **Layer 1 — File Descriptors &
Socket Buffers** (`scripts/apply-layer-1.sh`).
