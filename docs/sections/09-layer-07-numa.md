# Layer 7 — NUMA & CPU Affinity

> **Goal of this stage.** On multi-socket bare metal (T2/T3), stop workers from paying the
> **cross-socket memory tax**. Pin each Nginx worker to a distinct CPU so its cache stays
> hot and its memory stays local to one NUMA node. This is a **multi-socket** optimization —
> single-socket boxes like T1 (`m4.metal.small`, one NUMA node) have no cross-socket tax to
> remove; there, pinning only buys reduced worker-migration churn.

The config is [nginx/sections/layer-07-numa.conf](../../nginx/sections/layer-07-numa.conf),
applied by [apply-layer-7.sh](../../scripts/apply-layer-7.sh).

## What NUMA is and why it costs you

On a multi-socket server, RAM is **partitioned per socket** — each socket (NUMA node) owns
a slice of memory. A core reading from its **own** node's memory is fast; reaching across
the inter-socket link (UPI/Infinity Fabric) to the **other** node's memory roughly
**doubles memory latency** and pollutes caches.

The failure mode: if the scheduler keeps **migrating a worker** between cores (and across
sockets), the worker's working set ends up stranded on the wrong node, and every request
pays the cross-socket penalty. At baseline the kernel is free to bounce workers around for
fairness — which is exactly wrong for a steady, cache-heavy server process.

## The fix: pin workers 1:1 to CPUs

```nginx
worker_processes auto;     # apply-layer-7.sh sed-replaces "auto" with $(nproc)
worker_cpu_affinity auto;  # bind worker N to CPU N via sched_setaffinity() — a 1:1 pin
```

`worker_cpu_affinity auto` calls `sched_setaffinity()` to bind each worker to a distinct
CPU. A pinned worker:

- keeps its **L1/L2 cache hot** (no migration → no cold-cache refills),
- keeps its **allocations local** to one NUMA node (no cross-socket reads),

so cache hit rate climbs and inter-socket traffic falls. Note `worker_processes` is set to
an **explicit** count (`$(nproc)`) rather than `auto`, because the 1:1 affinity map needs a
concrete worker-to-CPU correspondence — [apply-layer-7.sh](../../scripts/apply-layer-7.sh)
patches a temp copy of the config so the checked-in file stays clean.

## CPU pinning vs. full NUMA binding

`worker_cpu_affinity` pins the **CPU** but not the **memory policy**. For *strict*
NUMA-node binding (CPU **and** memory allocation confined to one node), launch Nginx under
`numactl`:

```bash
numactl --cpunodebind=0 --membind=0 nginx
```

This is the right move on **T3 (2-socket)** hardware when you want to confine Nginx to one
socket — e.g. leaving the other socket's cores for the backend, lux, or NIC interrupt
handling. The apply script prints the topology and documents this; re-run pinned on T3 and
compare.

## Apply it

```bash
# TARGET
sudo scripts/apply-layer-7.sh
#   → installs numactl if needed, records `numactl --hardware` to
#     results/tier-N/numa-topology.txt, sets worker_processes=$(nproc), reload,
#     snapshot --label layer-7

# TESTER
scripts/load-test.sh --target https://<target-ip> --label layer-7 --tier <n> \
  --profile highconn --h2
```

## Verify

```bash
numactl --hardware                                   # node count, per-node CPUs + memory
# confirm workers are pinned to distinct CPUs:
for p in $(pgrep -f 'nginx: worker'); do taskset -cp "$p"; done
numastat -p $(pidof nginx | awk '{print $1}')        # watch for low "other_node" access
```

## Expected impact

- **T2/T3:** lower and more stable p99 (no cross-socket stalls), higher cache hit rate,
  measurable RPS gain on memory-bound paths.
- **T1 (single socket):** little to no effect — there's one NUMA node, so there's nothing
  to keep local. The CPU pin still prevents migration churn but the win is small. This is
  expected; the layer is documented as bare-metal-focused.

> **Measured on T1 (2026-07-05) — confirmed no-op / slight regression, as predicted.**
> `lscpu` confirmed **1 NUMA node** (CPUs 0–11), so there is nothing to keep local.
>
> | Test | Layer 5 | Layer 7 | Δ |
> |---|---|---|---|
> | wrk static (H1.1+TLS) | 290,200 | 287,824 | flat (noise) |
> | h2load (warm H2)      | 347,732 | 327,324 | **-6 %** |
>
> - **Static is flat; the h2 test lost ~6 %.** Two single-NUMA effects, both net-negative
>   here:
>   1. **`worker_cpu_affinity` 1:1 pinning hurts the low-connection case.** With reuseport,
>      h2's 400 connections hash to ~33/worker; pinning each worker to a fixed core means an
>      unlucky-heavy worker can't be migrated to an idle one. wrk's 4000 conns average the
>      imbalance out (static flat); 400 conns expose it (h2 -6 %). With one NUMA node there's
>      no locality gain to offset the lost scheduler flexibility.
>   2. **RPS/RFS was redundant on the 12-queue NIC.** `eno1` has **12 hardware RX queues**
>      (RSS already steers per-core). The old `tune-network-rps.sh` applied software RPS on
>      top unconditionally, which only adds IPIs + cache bouncing — softirq rose 22 %→27 %.
>      The script now **gates RPS/RFS to single-queue NICs** and skips them here (multi-queue
>      → leave hardware RSS alone; enable hardware aRFS via `ethtool -K eno1 ntuple on` if you
>      want flow-to-core locality).
> - **Takeaway (untuned):** like Layer 6, this looked like a **wrong-hardware** layer for T1.
>   But see below — with the base tuning applied it becomes load-bearing once paired with aRFS.

> **With base tuning + aRFS, Layer 7 becomes the OPTIMAL config (2026-07-05).** The base
> tuning is now folded into the layers themselves — CPU governor at [Layer 1](03-layer-01-fd.md),
> buffered `access_log` + `open_file_cache` in the L3+ nginx configs, and aRFS at
> [Layer 2](04-layer-02-tcp.md) — so by the time you reach Layer 7 everything but the pin is
> already active. With that base roughly doubling the baseline, worker pinning first *hurt*
> and then *won*:
>
> | Config (all tuned) | wrk static | h2load |
> |---|---|---|
> | no pinning (layer-5/6-tuned) | 522,475 | 709,877 |
> | + pinning, **no** aRFS | 302,217 (**-42%**) | 844,790 (+19%) |
> | + pinning **+ aRFS** | **545,529** | **836,843** |
>
> - **Pinning without aRFS wrecks static (-42%).** The 12-queue NIC's RSS hashes a flow to a
>   queue/core independently of the core nginx pinned that flow's worker to. When they
>   disagree, every packet bounces cache lines cross-core — savage at 4000-conn/high-pps
>   static, mild at 400-conn h2 (which even benefits from the pin's cache locality, +19%).
> - **aRFS realigns them.** `ethtool -K eno1 ntuple on` programs NIC filters to steer each
>   flow to its worker's core. Static recovered **302k → 545k** (and edged past the no-pin
>   522k) while h2 kept ~837k. Best latency too (static p50 6.98 ms). `tune-network-rps.sh`
>   enables aRFS by default on multi-queue NICs, and now runs at **Layer 2** — so aRFS is
>   already active by the time you pin here; Layer 7 supplies only the worker pin it needs.
> - **Optimal T1 config = base tuning + Layer-7 pinning + aRFS:** static **545,529**
>   (91k rps/core), h2 **836,843** (139k rps/core) — vs the raw pre-tuning layer-5 (290k/348k),
>   i.e. **+88% / +140%**. Pin workers ONLY with aRFS on; without it, don't pin.

For what comes after this layer *without* kernel bypass — conntrack, IRQ affinity,
retransmit hunting, brotli, the second 10 GbE port — see the
[post-Layer-7 tuning proposal](../proposals/post-layer-7-tuning-proposal.md).

Next: [Layer 8 — DPDK & Kernel Bypass](10-layer-08-dpdk.md).
