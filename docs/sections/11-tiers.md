# Section 11 — Hardware Tiers Compared

## The thesis, restated

The same progressive tuning is applied to three very different machines. The point is to
show **what hardware actually buys you** once software is no longer the bottleneck — and
to make the project's central claim concrete: *correctly configured bare metal beats an
equivalently priced cloud VM by orders of magnitude.*

Every tier starts from the **same baseline** ([Section 02](02-baseline.md)) and applies
the **same layers** (1–8). The delta is what differs.

## The three tiers

| Tier | Spec | Cost | Realistic ceiling |
|------|------|------|-------------------|
| **T1 — Entry Bare Metal** | `m4.metal.small`: EPYC 4244P 6C/12T @ 3.8 GHz, 64 GB DDR5, 2× 10 GbE | $0.41/hr | high hundreds of k conns |
| **T2 — Mid Bare Metal** | 32-core, 128 GB, 25 GbE | — | low millions of conns |
| **T3 — High-End Bare Metal** | 128-core, 512 GB, 100 GbE | — | ~1B (theoretical) |

T1 is small on purpose. It is the cheapest bare-metal SKU Latitude sells, and it is the
box where the *efficiency* argument is sharpest: every core is dedicated, the NIC is
real, and $0.41/hr is cloud-VM money. The T1 question is not "how big is the ceiling"
but "**how much RPS does each core and each dollar produce** once tuned" — read the
Efficiency table in `REPORT.md` (`generate-report.sh --cost 0.41`).

See [Section 00](00-prerequisites.md) for provisioning each. Final numbers land in
[Section 13](13-results.md).

## Which layers actually matter per tier

Not every layer pays off on every tier — a key lesson. Tuning a T1 VM with DPDK is
pointless; skipping NUMA pinning on T3 leaves throughput on the floor.

| Layer | T1 (6c bare metal) | T2 (32c bare metal) | T3 (128c bare metal) |
|-------|:---:|:---:|:---:|
| 1 — FD & socket limits | ✅ critical | ✅ critical | ✅ critical |
| 2 — TCP/IP tuning | ✅¹ | ✅ | ✅ |
| 3 — Worker & event model | ✅ critical | ✅ critical | ✅ critical |
| 4 — jemalloc | ✅ | ✅ | ✅ |
| 5 — TLS resumption | ✅ | ✅ | ✅ |
| 6 — Async file I/O | ➖ marginal² | ✅ | ✅ |
| 7 — NUMA & CPU affinity | ➖ minor³ | ✅ | ✅ critical |
| 8 — DPDK | ✅ possible⁴ | ✅ | ✅ |

¹ Real NIC, so BBR + buffer autosizing act on actual hardware — unlike a cloud vNIC,
  where the shared host caps the gain before the tuning does.
² Depends on whether assets are large enough and the page cache is cold; small SPA assets
  stay on the cached path (`directio 512k`).
³ Single socket / single NUMA node on the 4244P — nothing to keep local. CPU pinning still
  avoids migration churn, and with only 6 cores, IRQ-vs-worker placement is worth checking
  (watch `cpu_max_core_peak_pct` vs `cpu_peak_pct` in the monitor summary).
⁴ `m4.metal.small` ships 2× 10 GbE: DPDK claims one NIC entirely while SSH stays on the
  other. On a cloud VM this layer is impossible (virtual NIC, shared host kernel) — one of
  the concrete reasons this tier is bare metal.

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

The honest comparison is **price-equivalent**, not spec-equivalent. T1 makes this
concrete: $0.41/hr for `m4.metal.small` is almost exactly the on-demand price of an
8-vCPU/16 GB *shared* cloud VM (e.g. AWS c5.2xlarge, ~$0.34–0.39/hr). Same money, two
very different machines — one has 6 dedicated Zen 4 cores, DDR5, a real 10 GbE NIC and
zero hypervisor tax; the other has burstable shares of someone else's box.

The comparable numbers are the **Efficiency table** in `REPORT.md`
(`generate-report.sh --tier N --cost <hourly-price>`):

- **RPS / core** — how much work each core does once software stops being the wall.
- **RPS per $/hr** — the purchasing decision in one number.
- **peak conns per $** — the concurrency variant, for the connection-ceiling milestones.

That ratio — not the raw connection count — is the project's actual claim. Record both
the absolute numbers and the per-dollar figures in [Section 13](13-results.md).

Next: [Section 12 — Advanced: FreeBSD Networking Stack](12-freebsd.md).
