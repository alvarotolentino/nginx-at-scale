# Proposal — Tuning Beyond Layer 7 (Kernel + Nginx, no DPDK)

> **Status:** proposal, 2026-07-08. Nothing here is applied yet. Every item follows the
> project's rule: apply one change, snapshot, load-test, keep only what the numbers keep.
> DPDK (Layer 8) is explicitly out of scope for this document.

## 1. Where we are — what the Layer-7 (base tuning + aRFS) data says

Reference run: `results/latest_v1/tier-1/` (2026-07-10, T1 `m4.metal.small`, **target and
tester both bare-metal `m4.metal.small`** on a one-hop 10 GbE LAN — `ping` 0.057 ms avg,
0 % loss — 12 threads / 4000 conns / 30 s). End-state figures are Layer 7 (TLS); plaintext
peak is Layer 4.

| Test | Result | Bound by |
|---|---|---|
| wrk static (HTTP/1.1 + TLS, L7) | **566,257 RPS**, p50 6.6 ms | **CPU** — all 12 threads at 100 % |
| wrk static (plaintext, L4 peak) | **828,546 RPS** (69.0k RPS/core) | **CPU + NIC** co-limited (tx ~9.8 Gbps) |
| h2load warm HTTP/2 (L5 peak) | **765,276 RPS**, 925 MB/s | **CPU** |
| wrk UI mix | **159,207 RPS**, 1.05 GB/s | **NIC** — tx pinned 9.84 Gbps = 10 GbE line rate |

Monitor evidence (`layer-7/monitor/summary.txt`, cross-checked against `timeseries.csv`):

- `cpu_busy_avg_pct: 60.8`, `cpu_max_core_peak_pct: 100` — CPU-bound: in the static/h2
  phases nginx pegs **all 12 threads at 100 %** (`nginx_cpu_peak_pct: 1210`); the run-wide
  average is dragged down only by the NIC-bound UI phase where the cores idle.
- `softirq_busy_avg_pct: 15.7` (peak 33.7) — roughly **1.9 of 12 hyperthreads burn in
  softirq** (packet processing, ~93 % of it NET_RX), the biggest non-nginx consumer left.
- `retrans_total: 2,652,150` in a 30 s window — real loss on a 0.057 ms LAN (0 % idle ICMP
  loss), **concentrated in the line-rate UI phase** (~43–49k/s plaintext, **80–97k/s under
  TLS**) where the wire is pinned at 9.84 Gbps; static-phase retrans is ~0.
- `listen_drops_total: 50,850`, `tcp_timewait_peak: 1,093` — accept path and socket churn
  are healthy in the warm phases; the residual drops are confined to the API phase's
  backend-upstream accept burst. Layers 1–3 did their job.

So three distinct walls remain, and they need different levers:

1. **Hot-core CPU** (static + h2): shave per-packet and per-syscall kernel cost.
2. **NIC line rate** (UI mix): send fewer bytes, or use more wire.
3. **Retransmits**: find and remove the loss source — it taxes both of the above.

## 2. What the referenced articles add — and what they don't

Sources reviewed:
[dev.to nginx tuning](https://dev.to/ramer2b58cbe46bc8/performance-tuning-for-nginx-6-tips-to-cut-latency-boost-throughput-4e6m),
[DigitalOcean Linux tuning](https://www.digitalocean.com/community/tutorials/tuning-linux-performance-optimization),
[cpnginx optimization guide](https://cpnginx.com/nginx-on-cpanel/nginx-optimization-and-performance-tuning-guide-boost-speed-reduce-load-and-improve-scalability/).

Cross-checked against the repo, their recommendations fall into four buckets:

| Bucket | Article recommendation | Repo status |
|---|---|---|
| **Already applied — often beyond the article's values** | `worker_processes auto`/pinned, `epoll`, `multi_accept on`, `worker_rlimit_nofile`, `worker_connections`, keepalive tuning, gzip + static precompression, `open_file_cache`, buffered `access_log`, `ssl_session_cache`, OCSP stapling, HTTP/2, BBR + window scaling, `somaxconn`/`netdev_max_backlog`/`tcp_max_syn_backlog`, `tcp_tw_reuse`, `fs.file-max`/`nr_open`, 16 MB `tcp_rmem`/`tcp_wmem`, RSS via `ethtool -L`, IRQ affinity concept | Done in Layers 1–7; repo values are equal or larger (e.g. `worker_connections 65535` vs 8192, `open_file_cache max=10000` vs 2000) |
| **Rejected by our own measurements** | `thread_pool` + `aio threads` (cpnginx) | Measured **-21 % on T1** — TLS responses can't use `sendfile`, so aio adds copies. Kept opt-in/off (see [Layer 6](../sections/08-layer-06-aio.md)) |
| **Not applicable to this workload** | `proxy_cache`/`fastcgi_cache` for PHP, upload buffer sizing (`client_max_body_size 512m`), browser `expires` for benchmark traffic | No PHP; no uploads (capped at 1 m deliberately); the load generators don't honor caches |
| **Genuinely new candidates** | HTTP/3 + `ssl_early_data` (cpnginx), brotli (dev.to), `tcp_max_tw_buckets` / `tcp_mem` ceilings (cpnginx), swappiness (DO) | Adopted below where the data supports them |

The articles are aimed at untuned shared-hosting boxes; this repo is past that point. The
proposals below therefore come mostly from the run data, with the article items folded in
where they survive contact with it.

## 3. Proposed optimizations

Each item: what → why (from our data) → how → expected effect → risk. Priorities:
**P1** = attack a measured wall, do first; **P2** = solid single-digit candidates;
**P3** = exploratory / real-world-relevant but benchmark-neutral.

### 3.1 Kernel / OS

#### K1 (P1) — Stop conntrack-ing benchmark flows (`notrack`)

- **Why:** [deploy/firewall/nftables.conf](../../deploy/firewall/nftables.conf) uses
  `ct state established,related accept` — **every packet of every benchmark flow does a
  conntrack lookup**, and every new connection allocates a tracking entry. At 545 k RPS /
  1.1 M pps that is pure per-packet overhead inside the 21 % softirq bill.
- **How:** add a `prerouting` chain with `tcp dport { 80, 443 } notrack`, and accept
  80/443 statelessly in `input`. Keep conntrack for SSH so the admin path stays stateful.
- **Expected:** softirq share drops measurably; static/h2 RPS up single digits.
- **Risk:** low — 80/443 rules become stateless (they were open inbound anyway).

#### K2 (P1) — Align NIC IRQ affinity with the pinned workers, disable `irqbalance`

- **Why:** Layer 7 pins worker N → CPU N, and aRFS steers each flow's *RX processing*
  to its worker's core. But the 12 queue **IRQs** land wherever `irqbalance` last put
  them — and irqbalance re-shuffles them under load, fighting aRFS. The hot-core skew
  (`cpu_max_core_peak 100 %` while average is 72 %) is the signature.
- **How:** `systemctl disable --now irqbalance`, then write
  `/proc/irq/<n>/smp_affinity_list` to map queue *i* → CPU *i*, 1:1 with the worker
  pinning. Extend `tune-network-rps.sh` so it persists with the rest of the steering.
- **Expected:** flattens per-core skew; the pegged core is the ceiling, so any
  flattening converts directly into RPS.
- **Risk:** low; fully reversible.

#### K3 (P1) — Hunt the 2.4 M retransmits

- **Why:** ~2.4 M retransmitted segments per 30 s run, essentially unchanged across
  Layer-7 variants. On a sub-ms LAN this is loss, not latency. Prime suspects:
  (a) the UI phase saturates the 10 GbE wire and overruns a switch/NIC buffer,
  (b) RX ring too small on either node, (c) fq qdisc drops at 1 M+ pps.
- **How (diagnose first):** `ethtool -S eno1 | grep -iE 'drop|miss|err'` on both nodes,
  `tc -s qdisc show dev eno1`, and `nstat -az TcpRetransSegs` per phase to attribute
  loss to static vs UI windows. Then, in order: `ethtool -G eno1 rx <max> tx <max>`
  (ring buffers), `ethtool -A eno1 rx on tx on` (pause frames — LAN-only, two nodes,
  no head-of-line concerns), raise `net.core.default_qdisc` fq `limit` if qdisc drops.
- **Expected:** each recovered retransmit is a segment not re-encrypted and not re-sent;
  at multi-percent loss this is one of the larger CPU refunds available.
- **Risk:** low. Pause frames are contentious in datacenters, fine on a two-node lab LAN.

#### K4 (P2) — Interrupt coalescing + ring sizing (`ethtool -C` / `-G`)

- **Why:** 1.1 M pps peak; default coalescing on most 10 GbE drivers is tuned for
  latency, not IRQ economy. Fewer, fatter interrupts = less softirq.
- **How:** try `ethtool -C eno1 adaptive-rx on adaptive-tx on`; if the driver lacks
  adaptive, sweep static `rx-usecs` (e.g. 8 → 64). Pair with K3's ring-size increase
  (bigger rings tolerate longer coalesce intervals without drops).
- **Expected:** softirq down 2–5 points; slight p50 latency increase (µs-scale) —
  acceptable, we are throughput-first.
- **Risk:** low; measured trade, easy revert.

#### K5 (P2) — CPU vulnerability mitigations audit (`mitigations=off`)

- **Why:** this workload is syscall- and context-switch-dense (epoll, accept, sendfile,
  TLS reads/writes at 545 k+ RPS). Spectre-class mitigations tax exactly that path.
  Zen 4 pays less than older cores, but retbleed/IBRS-adjacent costs are still real —
  published numbers for syscall-heavy loads range 5–15 %.
- **How:** boot once with `mitigations=off` (GRUB), run the standard trio, compare, and
  document. Decide with data whether the guide recommends it for **dedicated,
  single-tenant benchmark boxes only**.
- **Expected:** mid single digits on static/h2.
- **Risk:** **security** — never on multi-tenant or internet-facing production. The doc
  must carry that warning verbatim.

#### K6 (P2) — Jumbo frames (MTU 9000) on the benchmark LAN

- **Why:** the UI mix moves 1.05 GB/s in 1500-byte frames ≈ 860 k frames/s of per-frame
  kernel work. MTU 9000 cuts frame count ~6× for large responses, directly attacking
  the softirq bill; framing efficiency also nudges usable line rate up a few percent.
- **How:** `ip link set eno1 mtu 9000` on target *and* tester (+ switch support);
  keep `tcp_mtu_probing 1` as the safety net. Persist in the steering unit.
- **Expected:** UI mix +3–4 % RPS (framing efficiency at the same line rate); softirq
  down noticeably during UI phase. Static (~1.4 KB responses) barely moves.
- **Risk:** medium-low — must be consistent end-to-end or PMTU pain; lab LAN makes
  that easy to guarantee.

#### K7 (P3) — Softirq batch budget (`net.core.netdev_budget`, `netdev_budget_usecs`)

- **Why:** at ~1 M pps, NAPI polls can exhaust the default budget (300 packets /
  2000 µs), deferring work to `ksoftirqd` and adding scheduling latency. Check
  `/proc/net/softnet_stat` column 3 (time_squeeze) first — only act if it's climbing.
- **How:** `net.core.netdev_budget=600`, `netdev_budget_usecs=4000` if squeezes show.
- **Expected:** smoother tail latency under peak pps; small RPS effect.
- **Risk:** negligible.

#### K8 (P3) — TCP Fast Open (`net.ipv4.tcp_fastopen=3` + `listen … fastopen=4096`)

- **Why:** saves one RTT on *cold* connections. The wrk/h2load phases are keepalive-warm,
  so the benchmark will barely see it — but the concurrency-test tooling (cold-connection
  floods) and any real-world reader will. Cheap to add alongside the other listen flags.
- **Expected:** benchmark-neutral; documented as a real-world win.
- **Risk:** low (idempotent GET workload; the classic TFO replay caveat doesn't bite).

*Considered and dropped:* `vm.swappiness` (64 GB box using 2 GB — nothing swaps),
`tcp_max_tw_buckets`/`ip_local_port_range` (TIME-WAIT peak is **1** on the target; these
matter on the *tester*, where the concurrency tooling already handles them), `tcp_mem`
ceilings (nowhere near pressure), busy-polling `net.core.busy_read/busy_poll` (spends CPU
to save latency — wrong trade on a CPU-bound box).

### 3.2 Nginx

#### N1 (P1) — Brotli static (`ngx_brotli`, precompressed)

- **Why:** the UI mix is **NIC-bound at line rate** — the only software lever left is
  *fewer bytes per response*. Vite already emits `.br` files (see build pipeline);
  nginx just isn't serving them (`brotli_static` commented out — needs the module).
  Brotli-11 static assets run 15–20 % smaller than gzip-9.
- **How:** build/load `ngx_brotli` (filter not needed — static only), enable
  `brotli_static on;` in the L3+ configs. Load generators must send
  `Accept-Encoding: br` (add to wrk/h2load headers).
- **Expected:** UI mix RPS up roughly in proportion to the byte savings on the
  text-asset share of the mix — the first UI-mix gain since Layer 1 that doesn't
  require new hardware. Zero runtime CPU (precompressed).
- **Risk:** low; nginx build change only.

#### N2 (P1) — Use the second 10 GbE port

- **Why:** both T1 nodes have **2× 10 GbE**; the UI wall is a single port at line rate.
  This is the only way to raise the UI ceiling itself (brotli shrinks bytes; this adds
  wire). No switch LACP needed for the lab: give the second port its own subnet/IP,
  have nginx listen on both, and run two tester processes, one per target IP.
- **How:** configure `eno2` (or the actual second port), extend `tune-network-rps.sh`
  to steer both NICs, split the load-test across both IPs, sum the results
  (`load-test.sh` may need a `--target2` or a documented two-invocation recipe).
- **Expected:** UI mix ceiling toward ~2× (until CPU becomes the new wall — softirq
  for a second NIC will bite, which is exactly the kind of finding the guide wants).
- **Risk:** medium effort (network config + tooling), no correctness risk.

#### N3 (P2) — TLS session tickets ON for the benchmark profile

- **Why:** `ssl_session_tickets off` is the privacy-conservative choice, but it forces
  every resumption through the **shared-memory session cache** — a lock shared by 12
  pinned workers. Tickets are stateless: no shared cache contention, and TLS 1.3
  tickets are per-connection keys anyway (the forward-secrecy objection is largely a
  TLS-1.2 story with long-lived ticket keys).
- **How:** benchmark profile: `ssl_session_tickets on;` (+ document key-rotation caveat
  for production). Measure the *cold-connection* phase (wrk without keepalive, or the
  concurrency tool) — warm phases won't show it.
- **Expected:** faster handshake path under connection churn; static keepalive numbers
  unchanged.
- **Risk:** low in the lab; production guidance needs the key-rotation note.

#### N4 (P2) — `ssl_buffer_size` + `tcp_notsent_lowat` pairing

- **Why:** nginx encrypts in 16 KB TLS records by default — good for throughput, but
  for the ~1.4 KB static response it means buffer slack, and for large UI responses it
  interacts with kTLS/sendfile behavior. Worth a two-point sweep now that TLS is the
  dominant CPU consumer.
- **How:** compare `ssl_buffer_size 4k;` vs default 16k; optionally
  `net.ipv4.tcp_notsent_lowat=16384` alongside. Three runs each, keep the winner.
- **Expected:** small; possibly p99 improvement on static. This is a cheap experiment,
  not a promised win.
- **Risk:** none.

#### N5 (P3) — HTTP/3 / QUIC as an *experiment*, not an expectation

- **Why:** cpnginx recommends `http3 on` as a speed feature. On this workload the
  honest expectation is the opposite: QUIC moves TLS+transport into userspace, costs
  more CPU per request than kernel-TCP HTTP/2, and forfeits `sendfile`. On a sub-ms
  LAN its RTT advantages don't apply. It *is* worth one measured run — the guide's
  value is showing where fashionable advice loses to a pegged core.
- **How:** nginx ≥1.25 `--with-http_v3_module`, `listen 443 quic reuseport;`, UDP
  buffer sysctls (`net.core.rmem_max` already sized), h2load `--npn-list` /
  `nghttp3`-based client or `h2load --alpn-list=h3`.
- **Expected:** h3 below warm-h2 numbers on this LAN; documented as a finding.
- **Risk:** build + tooling effort; no target risk.

#### N6 (P3) — API-path microcache (`proxy_cache` + 1 s validity)

- **Why:** the backend sits at ~0 % CPU in the current phases, so this changes nothing
  *today* — but the moment an API-heavy profile is benchmarked, a 1-second microcache
  collapses identical GETs into one upstream hit. It is the one article suggestion
  (cpnginx/dev.to `proxy_cache`) that will eventually matter here.
- **How:** `proxy_cache_path … keys_zone=api:10m inactive=10s; proxy_cache_valid 200 1s;
  proxy_cache_use_stale updating;` on `location /api/`, opt-in like the rate limits.
- **Expected:** API-profile RPS decouples from backend capacity.
- **Risk:** staleness ≤1 s on a read-mostly catalog — acceptable, documented.

*Considered and dropped:* `thread_pool`/`aio threads` (measured -21 % on T1 — see
[Layer 6](../sections/08-layer-06-aio.md)); bigger proxy/client buffers (no uploads, tiny
headers — the cpnginx `large_client_header_buffers 16 128k` would just waste RAM ×
connections); `expires`/browser caching (load generators ignore caches; already
documented for production readers); raising `keepalive_requests` (already 10,000);
`multi_accept off` (current `on` is correct for accept-storm phases).

### 3.3 Suggested execution order

| Step | Items | Gate |
|---|---|---|
| 1 | K3 diagnose (retrans attribution) | pure measurement, informs K4/K6 |
| 2 | K1 notrack + K2 IRQ affinity | re-run trio; keep if static/h2 ≥ +2 % or softirq drops |
| 3 | K4 coalescing + K3 fixes (rings/pause) | retrans_total should fall an order of magnitude |
| 4 | N1 brotli + K6 jumbo | UI-mix focused re-run |
| 5 | K5 mitigations audit | separate boot, separate writeup, security-flagged |
| 6 | N3, N4 | cold-connection + latency-focused runs |
| 7 | N2 second port | tooling work; do when steps 1–4 have banked the easy wins |
| 8 | N5, N6, K7, K8 | exploratory / profile-dependent |

Every step: `snapshot.sh` → `monitor.sh` during load → the standard
wrk-static / h2load / wrk-UI trio from the tester → keep or revert on the numbers,
same as Layers 1–7. Candidate packaging once proven: a `tune-network-irq.sh` companion
to `tune-network-rps.sh` (K2–K4, K6, K7) and opt-in blocks in the L7 nginx config
(N1, N3, N4), keeping the one-change-one-measurement discipline intact.

## 4. What this proposal deliberately does not touch

- **Layer 8 / DPDK** — excluded by request.
- **The tester node** — its ephemeral-port and CPU limits are handled by the
  concurrency-test tooling; this document is about the target.
- **Hardware changes beyond what T1 already has** (the second NIC port is on-box).
- **The 1 GB/s UI wall via caching tricks** — the benchmark intentionally measures
  full-response serving; browser-cache advice stays in the production notes.
