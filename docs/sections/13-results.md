# Section 13 — Results Summary & Takeaways

> **This is a template, not a claim.** The repo does not ship fabricated numbers. This
> section explains **how to produce** the results table from your own runs and how to read
> it. You fill it in from `results/tier-N/REPORT.md` (auto-generated) and
> [results/REPORT-TEMPLATE.md](../../results/REPORT-TEMPLATE.md) (hand-filled story).

## How the numbers are produced

Each layer is measured the same way, split across the two nodes:

1. **TARGET** applies + snapshots a layer: `sudo scripts/apply-layer-N.sh` → records box
   state into `results/tier-N/<label>/snapshot/`.
2. **TARGET** samples utilization during the load window:
   `scripts/monitor.sh --label layer-N --tier N --duration 45 &` → records the CPU /
   softirq / per-service / NIC / socket time series into `results/tier-N/<label>/monitor/`.
   (`apply-all-layers.sh` starts and stops this automatically around each load pause.)
3. **TESTER** generates load for that label: `scripts/load-test.sh --target https://<ip>
   --label layer-N --tier N` → records `wrk-static.txt`, `wrk-api.txt` into
   `results/tier-N/<label>/load/`.
4. Copy the tester's `load/` dirs back, then on the target run
   `scripts/generate-report.sh --tier N --cost <hourly-price>`.

[generate-report.sh](../../scripts/generate-report.sh) writes `results/tier-N/REPORT.md`
with three tables:

1. **Tester view** — RPS (static / UI mix / API), p99, transfer/s, error count, and the
   **Δ vs baseline**. The first run (baseline, alphabetically first) is the comparison
   base for every delta.
2. **Target view** — from `monitor/summary.txt`: CPU avg/peak, busiest single core,
   %softirq, nginx CPU/RSS, peak open connections, TIME-WAIT, peak NIC Mbps,
   retransmits, and listen (accept-queue) drops. This is what tells you **which wall**
   each layer hit — a flat RPS with one core pegged is a packet-steering problem, not
   an nginx problem; a flat RPS at NIC line rate is a bandwidth problem.
3. **Efficiency** — RPS/core, and with `--cost`, RPS per $/hr — the numbers that make
   tiers (and cloud VMs) comparable.

## Results table (fill from `tier-N/REPORT.md`)

| Layer | Label | RPS (static) | RPS (API) | p99 | Δ vs baseline |
|-------|-------|-------------|-----------|-----|---------------|
| 0 | baseline | _fill_ | _fill_ | _fill_ | — |
| 1 | layer-1 (FD & sockets) | _fill_ | _fill_ | _fill_ | _fill_ |
| 2 | layer-2 (TCP/IP) | _fill_ | _fill_ | _fill_ | _fill_ |
| 3 | layer-3 (workers/events) | _fill_ | _fill_ | _fill_ | _fill_ |
| 4 | layer-4 (jemalloc) | _fill_ | _fill_ | _fill_ | _fill_ |
| 5 | layer-5 (TLS) | _fill_ | _fill_ | _fill_ | _fill_ |
| 6 | layer-6 (AIO) | _fill_ | _fill_ | _fill_ | _fill_ |
| 7 | layer-7 (NUMA) | _fill_ | _fill_ | _fill_ | _fill_ |
| 8 | layer-8-pre-dpdk | _fill_ | _fill_ | _fill_ | _fill_ |

Repeat per tier (`tier-1`, `tier-2`, `tier-3`). The qualitative "what surprised you"
column lives in [REPORT-TEMPLATE.md](../../results/REPORT-TEMPLATE.md).

## Reading the deltas — what each layer *should* show

This is the expected **shape** of the curve (your magnitudes depend on hardware):

- **Layer 1** — RPS barely moves, but the baseline's `Too many open files` errors vanish.
  It unblocks *capacity*, not throughput. A flat RPS here is correct.
- **Layer 2** — first real RPS gain on T2/T3 as socket windows open and BBR improves
  goodput. Smaller on T1 (virtual NIC caps it).
- **Layer 3** — typically the **largest single jump**. epoll + 65k conns/worker + reuseport
  is what converts kernel capacity into served requests.
- **Layer 4** — small RPS change but **lower, flatter p99** and bounded RSS over long runs.
  Watch the *tail* and a multi-hour RSS curve, not peak RPS.
- **Layer 5** — RPS dips on cold connections, returns near Layer-3 parity on warm/resumed
  ones. The win is "TLS for free in steady state."
- **Layer 6** — gains only on disk-bound large-asset workloads; near-zero on cached small
  assets (by design, `directio 512k`).
- **Layer 7** — T2/T3 gain from cache locality; **near-zero on T1** (one NUMA node) — and
  that null result is itself a documented finding.
- **Layer 8** — not an Nginx RPS number; it establishes the **raw NIC packet ceiling**
  (`pktgen-dpdk`) that a kernel-bypass data plane could approach, versus the kernel-path
  Nginx number (`layer-8-pre-dpdk`).

## Headline takeaways (state these once you have data)

1. **Software is the first wall, not hardware.** Layers 1–3 move the needle most, on every
   tier — most "the server can't scale" problems are unconfigured defaults.
2. **Hardware sets the ceiling, tuning reaches it.** Same layers, wildly different ceilings
   across T1→T2→T3 ([Section 11](11-tiers.md)).
3. **Bare metal wins per-dollar.** Compare price-equivalent boxes on RPS per $/hr and
   peak concurrency/$, not spec sheets (T1: `--cost 0.41`). This is the project's actual
   thesis.
4. **A result is RPS + tail + errors + cost.** The same RPS at 40% CPU vs 100% CPU are
   different findings; an RPS "win" with listen drops is a loss. The monitor table is
   what keeps the deltas honest.
4. **Some layers are tier-specific.** DPDK is impossible on T1; NUMA is moot on T1. Knowing
   *which* layer matters *where* is the engineering judgment this guide teaches.

## The 1B framing

1B concurrent connections is the **theoretical ceiling on T3** — memory-bound: each
connection costs kernel + Nginx state, so 512 GB RAM and 128 cores is the envelope. Each
tier documents its **realistic** ceiling and the bottleneck it hit first in
[REPORT-TEMPLATE.md](../../results/REPORT-TEMPLATE.md). Report the honest measured number,
not the theoretical one.

Next: [Section 14 — Appendix: Custom Kernel Build](14-kernel-build.md).
