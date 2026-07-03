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
scripts/load-test.sh --target https://<target-ip> --label layer-7 --tier <n>
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

Next: [Layer 8 — DPDK & Kernel Bypass](layer-08-dpdk.md).
