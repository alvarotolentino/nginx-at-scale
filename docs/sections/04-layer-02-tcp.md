# Layer 2 — Linux TCP/IP Kernel Tuning

> **Goal of this stage.** Layer 1 raised the connection *count* ceiling. Layer 2 tunes the
> *behavior* of each connection: buffer autosizing for high bandwidth-delay-product links,
> a smarter congestion-control algorithm, and keepalive economy so dead connections are
> reclaimed quickly.

## Why the defaults underperform on fast links

Stock socket buffers and congestion control are tuned for a generic LAN/WAN mix on
modest hardware. On a 25/100 GbE bare-metal NIC with many concurrent flows, two things
go wrong:

1. **Buffers too small to fill the pipe.** Throughput is capped by
   `window_size / RTT`. The default 4–6 MB receive-buffer max can't open a large enough
   TCP window to saturate a high-BDP link, so each flow leaves bandwidth on the table.
2. **Loss-based congestion control overreacts.** CUBIC treats any packet loss as
   congestion and backs off hard — punishing throughput on links where loss is sporadic
   rather than a true congestion signal.

## Parameters

From [kernel/sysctl/layer-02-tcp.conf](../../kernel/sysctl/layer-02-tcp.conf), appended to
the cumulative `/etc/sysctl.d/99-nginx-perf.conf` by
[apply-layer-2.sh](../../scripts/apply-layer-2.sh):

### Socket buffer autosizing

```ini
net.ipv4.tcp_rmem = 4096 87380 16777216   # recv buffer: min / default / max (16MB)
net.ipv4.tcp_wmem = 4096 65536 16777216   # send buffer: min / default / max (16MB)
net.core.rmem_max = 16777216              # hard ceiling for SO_RCVBUF
net.core.wmem_max = 16777216              # hard ceiling for SO_SNDBUF
net.core.rmem_default = 262144            # floor for early-connection sockets
```

The kernel **autotunes** the actual window between min and max per connection — raising
`max` to 16 MB lets it grow the window large enough for a high-BDP link, without
hard-pinning a huge buffer on every idle socket. `rmem_max`/`wmem_max` must be ≥ the
`tcp_rmem`/`tcp_wmem` max or they clamp it.

### Congestion control: BBR + fq

```ini
net.ipv4.tcp_congestion_control = bbr   # model bandwidth+RTT, not loss
net.core.default_qdisc = fq             # BBR REQUIRES fq pacing to shape its send rate
```

**BBR** estimates the bottleneck bandwidth and RTT and paces to that, rather than
reacting to loss like CUBIC. On lossy or high-BDP paths this is markedly better goodput.
BBR only works correctly with the **fq** (fair queue) qdisc — setting one without the
other is a misconfiguration, so both are applied together.

### Keepalive economy

```ini
net.ipv4.tcp_slow_start_after_idle = 0   # don't collapse the window to slow-start after idle
net.ipv4.tcp_keepalive_time   = 60       # first probe after 60s idle (default: 7200s!)
net.ipv4.tcp_keepalive_intvl  = 10       # 10s between probes
net.ipv4.tcp_keepalive_probes = 6        # 6 unacked probes → declare dead
net.ipv4.tcp_mtu_probing = 1             # probe larger MTU when ICMP is blackholed
```

`tcp_slow_start_after_idle = 0` keeps HTTP-keepalive connections fast after a quiet
moment instead of restarting slow-start on every burst. The keepalive timers reclaim dead
connections in ~2 minutes instead of the 2-hour default — essential when you're holding
hundreds of thousands of connections and can't let zombies accumulate. `tcp_mtu_probing`
rescues connections on cloud/overlay networks that blackhole ICMP (common on T1).

## Apply it

```bash
# TARGET
sudo scripts/apply-layer-2.sh
#   → appends the TCP sysctls to /etc/sysctl.d/99-nginx-perf.conf, sysctl --system,
#     applies NIC packet steering (tune-network-rps.sh — see below), snapshot --label layer-2

# TESTER
scripts/load-test.sh --target https://<target-ip> --label layer-2 --tier <n>
```

## Base network tuning applied here: NIC packet steering (RSS / aRFS / RPS)

Layer 2 is the TCP/IP-stack layer, so it's also where the second piece of the *base
tuning* is applied: [tune-network-rps.sh](../../scripts/tune-network-rps.sh) aligns NIC
packet steering to the CPUs. This was **previously bolted on at Layer 7**, which meant
Layers 3–6 were measured without it; it now runs here so **every** later layer inherits it.

What it does depends on the NIC:

- **Multi-queue NIC (T1's 12-queue 10 GbE):** enables **hardware aRFS** (`ethtool -K …
  ntuple on` + the `rps_flow_cnt` table) and leaves software RPS off. aRFS steers each
  flow to the core running its socket — harmless while workers float, and **load-bearing
  once Layer 7 pins them** (it recovered static throughput **302k → 545k** with pinning on).
- **Single-queue NIC:** falls back to software **RPS/RFS** to fan RX softirq across all
  cores (a single-queue NIC otherwise funnels every packet's softirq onto one core).

Steering is persisted via a `nginx-net-rps.service` oneshot (sysfs masks reset on boot);
[reset-baseline.sh](../../scripts/reset-baseline.sh) removes it. See
[Layer 7](09-layer-07-numa.md) for the pinning-vs-aRFS interaction in full.

## Verify

```bash
sysctl net.ipv4.tcp_congestion_control   # = bbr
sysctl net.core.default_qdisc            # = fq
sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem
```

> **If BBR is missing:** `modprobe tcp_bbr` (or confirm `CONFIG_TCP_CONG_BBR` in the
> kernel). Most Debian 12 kernels ship it as a module.

## Expected impact

- **Higher per-connection throughput** on the high-GbE tiers (T2/T3) as windows open up —
  this is where RPS starts climbing meaningfully versus Layer 1.
- Faster reclamation of dead connections under churn; lower tail latency on bursty
  keepalive traffic.
- On T1 (`m4.metal.small`, 10 GbE) the buffer gains are real — the NIC is hardware, not a
  capped vNIC — but the ceiling arrives sooner than on T2/T3 simply because 10 Gbps is
  less headroom. Watch `tx_mbps_peak` in the monitor summary to see when you reach it.

> **Measured on T1 over a sub-ms LAN (2026-07-04) — expect ~no movement here.** With the
> tester one hop from the target (RTT 0.081 ms), this layer is effectively a no-op, and
> that is the correct result:
> - **Static RPS 466,850 → 467,522 (+0.1%, noise), p99 16.2 ms unchanged.** The static
>   test is CPU-bound (nginx pegged at 100% across all cores); bigger buffers and BBR do
>   nothing for per-request CPU.
> - **UI mix 176.9k → 176.7k RPS, tx pinned at 9.84 Gbps** — still one-NIC line rate, not
>   a TCP-behavior limit.
> - **Why:** BBR and 16 MB buffers pay off on **high bandwidth-delay-product** links
>   (lossy WAN, 25/100 GbE long-haul). On a 0.081 ms LAN the BDP is ~125 KB — the default
>   buffers already cover it, so there is no window to widen. The gains land on T2/T3 and
>   on real WAN clients, not on a same-rack LAN.
> - **Two costs it *does* add on LAN:** BBR fills the pipe more aggressively, so against a
>   saturated NIC `retrans_total` roughly **doubled** (1.5M → 3.3M); and 16 MB max buffers
>   raised nginx RSS (~1.9 GB → ~3.5 GB) for zero throughput gain. Keep the layer for
>   fidelity/WAN realism, but read the T1-LAN report knowing the headline metric will not
>   move until Layer 3.

Next: [Layer 3 — Nginx Worker & Event Model](05-layer-03-events.md).
