# Layer 3 — Nginx Worker & Event Model

> **Goal of this stage.** The kernel can now hold and feed millions of connections
> (Layers 1–2). This layer makes **Nginx itself** actually use that headroom: the epoll
> event model, high per-worker connection fan-out, `SO_REUSEPORT`, and connection economy
> (keepalive reuse, zero-copy delivery, precompressed static).

This is the first layer that replaces the whole `nginx.conf` rather than tuning the
kernel. The complete file is
[nginx/sections/layer-03-worker-events.conf](../../nginx/sections/layer-03-worker-events.conf).

## The events block — the heart of the layer

```nginx
worker_processes auto;          # one worker per CPU core
worker_rlimit_nofile 2097152;   # must match the Layer 1 systemd LimitNOFILE / ulimit

events {
    worker_connections 65535;   # max simultaneous connections per worker (was 1024 at baseline)
    use epoll;                  # Linux O(1)-readiness event interface
    multi_accept on;            # drain ALL pending connections per event-loop pass
    accept_mutex off;           # let every worker accept concurrently — lower latency
}
```

- **`use epoll`.** The stock baseline falls back to `select`/`poll`, which are **O(n)** in
  the number of watched FDs — at tens of thousands of connections the worker spends its
  time scanning FD sets instead of serving. epoll is O(1) on readiness and is the entire
  reason Linux can do C10k+.
- **`worker_connections 65535`.** Lifts the per-worker ceiling 64× from the baseline 1024.
  Combined with `worker_processes auto`, the hard connection ceiling is now
  `65535 × cores`. This is only safe because `worker_rlimit_nofile` was raised in Layer 1
  — otherwise workers cap out at the FD limit well below this number.
- **`multi_accept on`.** On each event-loop wake, accept *every* queued connection rather
  than one. At high connection-arrival rates this drains the accept queue faster.
- **`accept_mutex off`.** With `SO_REUSEPORT` (below) each worker has its own listen
  socket, so the accept-mutex serialization is pure latency overhead — turn it off and let
  all workers accept in parallel.

## SO_REUSEPORT — kernel-side load balancing

```nginx
listen 80 backlog=65535 reuseport;
```

`reuseport` gives **each worker its own listen socket** for the same port; the kernel
hashes incoming connections across them. This removes the single shared accept queue as a
contention point and spreads new connections evenly across workers — the natural partner
to `accept_mutex off`. `backlog=65535` matches the `somaxconn` raised in Layer 1.

## Connection economy

```nginx
keepalive_timeout 65;            # hold idle client conns 65s for reuse
keepalive_requests 10000;        # up to 10k requests per kept-alive connection
sendfile on;                     # zero-copy file → socket (skip userspace copy)
tcp_nopush on;                   # coalesce headers+file into full packets (with sendfile)
tcp_nodelay on;                  # disable Nagle for keepalive responses (low latency)
reset_timedout_connection on;    # free timed-out connection memory immediately
upstream backend { server 127.0.0.1:8080; keepalive 256; }   # pooled upstream keepalive
```

- **`sendfile` + `tcp_nopush`** move static files disk→socket without a userspace bounce,
  then pack full packets — the cheapest possible static delivery. `tcp_nodelay` keeps
  small keepalive responses snappy (the two are complementary, not contradictory: nopush
  for the body, nodelay for the flush).
- **`keepalive 256`** on the upstream pools connections to the loopback backend so the
  proxy path isn't paying a fresh TCP handshake per `/api/` call (paired with
  `proxy_set_header Connection ""` and `proxy_http_version 1.1` in the location).

## Compression & hardening (carried into every later layer)

```nginx
gzip_static on;          # serve Vite-prebuilt .gz — zero runtime compression CPU
server_tokens off;       # hide nginx version
client_max_body_size 1m; # app has no uploads — cap bodies
```

`gzip_static on` serves the precompressed asset twins built by Vite, so compression costs
**zero** CPU at request time. Rate-limit zones are *defined but not applied* — enabling
`limit_req` on the static path would cap the throughput benchmark; they're documented for
opt-in use during non-benchmark runs only. Security headers (CSP, X-Frame-Options, etc.)
live in a single `server` block because a child-context `add_header` **replaces** all
inherited ones — see [Section 15](15-security.md).

## Apply it

```bash
# TARGET
sudo scripts/apply-layer-3.sh    # cp the full conf → /etc/nginx/nginx.conf, nginx -t, reload, snapshot

# TESTER
scripts/load-test.sh --target https://<target-ip> --label layer-3 --tier <n>
```

## Verify

```bash
nginx -T | grep -E 'use epoll|worker_connections|reuseport|multi_accept'
ss -lnt | grep ':80'        # one listen socket per worker with reuseport
```

## Expected impact

- **The big jump.** This is typically the single largest RPS gain in the stack — epoll +
  65k connections/worker + reuseport is what turns the raised kernel capacity into actual
  served throughput.
- Lower tail latency from `accept_mutex off` + per-worker sockets (no accept serialization).
- Flat CPU on static delivery thanks to `sendfile` + `gzip_static`.

> **Measured on T1 over a sub-ms LAN (2026-07-04) — read the RPS number with care.** The
> event model did exactly its job, but a **payload confound** hides it in the headline RPS:
>
> - **Event-model wins (unambiguous):** `listen_drops_total` 1776 → **0**, `tcp_timewait_peak`
>   9061 → **0**, static latency **max 596 ms → 39 ms**, stdev 10.5 ms → **1.01 ms**,
>   `Req/Sec` stdev 1830 → **577**. reuseport + `backlog=65535` cleared the accept-queue
>   overflow, and per-worker sockets spread load **perfectly evenly across all cores** —
>   near-zero jitter. This is the real result of the layer.
> - **Static RPS *dropped* 467,522 → 384,658 (-18%) — and that is the header tax, not the
>   event model.** This is the first layer to load the full `nginx.conf`, which adds the
>   five security `add_header` lines (CSP, Permissions-Policy, X-Content-Type-Options,
>   Referrer-Policy, X-Frame-Options). Those add **≈370 bytes to every response** — measured
>   `/` grew 1040 → 1414 bytes/req. The static test is **CPU-bound at 100 %** (nginx 1206 %,
>   all cores), so at the ceiling the box serves *either* 467k tiny responses *or* 385k
>   slightly-bigger ones for the same CPU — more bytes + header assembly per request means
>   fewer requests. reuseport did not slow anything down.
> - **Watch for the confound in RPS/core.** Layers 1–2 ran the bare baseline conf (no
>   security headers); layer 3 onward carries the ~370-byte offset. So RPS across the stack
>   is **not** measured on a constant response size. When comparing RPS/core layer-to-layer,
>   normalize for bytes/req (or move the headers to [Section 15](15-security.md) and measure
>   the event model clean). Latency, drops, and TIME_WAIT are the honest layer-3 signals.
> - **UI mix:** 176.7k → 167.7k RPS, still pinned at 9.84 Gbps (one-NIC line rate) — NIC-bound,
>   not an event-model limit.

Next: [Layer 4 — Memory Allocator (jemalloc)](layer-04-jemalloc.md).
