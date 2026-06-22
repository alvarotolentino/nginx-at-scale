# Section 11 — Hardware Tiers Compared

## The thesis, restated

The same progressive tuning is applied to three very different machines. The point is to
show **what hardware actually buys you** once software is no longer the bottleneck — and
to make the project's central claim concrete: *correctly configured bare metal beats an
equivalently priced cloud VM by orders of magnitude.*

Every tier starts from the **same baseline** ([Section 02](02-baseline.md)) and applies
the **same layers** (1–8). The delta is what differs.

## The three tiers

| Tier | Spec | Provider | Realistic ceiling |
|------|------|----------|-------------------|
| **T1 — Baseline** | 4–8 vCPU, 16–32 GB RAM | Any cloud (AWS/GCP/DO) | hundreds of k conns |
| **T2 — Mid Bare Metal** | 32-core, 128 GB, 25 GbE | Latitude.sh | low millions of conns |
| **T3 — High-End Bare Metal** | 128-core, 512 GB, 100 GbE | Latitude.sh | ~1B (theoretical) |

See [Section 00](00-prerequisites.md) for provisioning each. Final numbers land in
[Section 13](13-results.md).

## Which layers actually matter per tier

Not every layer pays off on every tier — a key lesson. Tuning a T1 VM with DPDK is
pointless; skipping NUMA pinning on T3 leaves throughput on the floor.

| Layer | T1 (cloud VM) | T2 (32c bare metal) | T3 (128c bare metal) |
|-------|:---:|:---:|:---:|
| 1 — FD & socket limits | ✅ critical | ✅ critical | ✅ critical |
| 2 — TCP/IP tuning | ⚠️ partial¹ | ✅ | ✅ |
| 3 — Worker & event model | ✅ critical | ✅ critical | ✅ critical |
| 4 — jemalloc | ✅ | ✅ | ✅ |
| 5 — TLS resumption | ✅ | ✅ | ✅ |
| 6 — Async file I/O | ➖ marginal² | ✅ | ✅ |
| 7 — NUMA & CPU affinity | ➖ none³ | ✅ | ✅ critical |
| 8 — DPDK | ❌ impossible⁴ | ✅ | ✅ |

¹ Buffer autosizing gains are capped by the virtual NIC and shared host; BBR + MTU probing
  still help on lossy/overlay paths.
² Depends on whether assets are large enough and the page cache is cold; small SPA assets
  stay on the cached path (`directio 512k`).
³ Single NUMA node — nothing to keep local. CPU pin only avoids migration churn.
⁴ A virtual NIC + shared host kernel cannot give a userspace poll-mode driver exclusive
  hardware control. DPDK is bare-metal only — `apply-layer-8.sh` detects this and bails on T1.

## Why bare metal wins (the mechanisms)

The advantage is not just "more cores." It's that bare metal removes layers the cloud
inserts:

- **No hypervisor tax.** No vCPU scheduling jitter, no steal time, no virtual-NIC packet
  copy. The kernel/NIC/NUMA tuning the layers exercise act on the **real** hardware, not a
  namespaced copy — which is precisely why this project runs the stack as **systemd
  services, not Docker** ([Section 01](01-demo-app.md), README "Architecture").
- **Real NIC, real offloads.** A 25/100 GbE NIC with hardware offload + DPDK headroom; a
  cloud vNIC caps you well before the wire.
- **Real NUMA topology.** Layer 7 has something to optimize; a 1-vCPU VM does not.
- **Predictable IRQ/CPU placement.** You own the interrupt affinity and the cores.

## Cost framing

The honest comparison is **price-equivalent**, not spec-equivalent: take the monthly cost
of the T1 cloud VM and the T2/T3 bare-metal box, and compare *peak concurrency per dollar*.
That ratio — not the raw connection count — is the project's actual claim. Record both the
absolute numbers and the $/peak-conn in [Section 13](13-results.md).

Next: [Section 12 — Advanced: FreeBSD Networking Stack](12-freebsd.md).
