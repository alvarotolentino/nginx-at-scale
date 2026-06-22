# Section 12 — Advanced: FreeBSD Networking Stack

> **Scope.** This section is **comparative and optional** — the benchmark target is Debian
> 12 Linux. FreeBSD is covered because, historically, it has been a serious contender for
> exactly this workload (high-concurrency static + TLS serving), and understanding *why*
> sharpens the Linux tuning the rest of the guide does. There is no `apply-layer` script
> for FreeBSD; this is a design discussion.

## Why FreeBSD enters the conversation

For network-bound serving, FreeBSD's stack has long been respected for predictability
under load and for a few features that landed there first or are particularly clean:

- **kqueue** — the event interface FreeBSD got right early. It is the conceptual sibling of
  Linux's epoll (both replace O(n) `select`/`poll` with O(1) readiness notification), and
  Nginx supports `use kqueue` natively. Netflix's Open Connect CDN famously serves
  enormous volumes of TLS video from FreeBSD boxes.
- **Kernel-mode TLS (kTLS)** — encryption offloaded into the kernel (and onward to the NIC
  where supported), so encrypted bulk data can ride `sendfile`'s zero-copy path instead of
  bouncing through userspace for the crypto. This is the headline win for TLS-heavy static
  serving. (Linux has `ktls` too now — see below.)
- **`sendfile` with TLS** — FreeBSD's `sendfile` integrates with kTLS so large encrypted
  files stay zero-copy end to end, which is hard to achieve on the classic userspace-TLS
  path.

## The Linux equivalents (what we actually use)

The honest framing: most of FreeBSD's historical edge now has a Linux answer, which is why
this project targets Linux. The mapping:

| FreeBSD feature | Linux equivalent in this guide |
|-----------------|--------------------------------|
| `kqueue` | **epoll** (Layer 3, `use epoll`) |
| kTLS | Linux **kTLS** (`tls` ULP) + NIC TLS offload — emerging |
| `sendfile` + kTLS zero-copy | `sendfile on` (Layer 3) + kTLS where the NIC supports it |
| Network stack tuning via `sysctl` | the Layer 1/2 `sysctl` work |
| DPDK / netmap kernel bypass | **DPDK** (Layer 8) |

So the architectural ideas are the same; only the knobs' names differ. The reason the
benchmark stays on Linux is ecosystem: the Rust/Node toolchains, DPDK driver support, and
the bare-metal provider images are all first-class on Debian.

## Where FreeBSD could still win

- **TLS-saturated static at the highest volumes** — kTLS + `sendfile` integration is more
  mature and battle-tested on FreeBSD (the Netflix lineage). If the workload were *purely*
  serving large encrypted files at line rate, a FreeBSD comparison run would be a fair and
  interesting addition.
- **Tail-latency predictability** under extreme load is often cited, though it's
  workload-dependent and hard to generalize.

## How you'd run a comparison (sketch)

If you want a FreeBSD data point on the same hardware:

1. Provision a T2/T3 box with **FreeBSD 14** instead of Debian.
2. Build Nginx with `use kqueue`; enable kTLS (`sysctl kern.ipc.tls.enable=1`) and
   `sendfile`.
3. Translate the Layer 1/2 `sysctl` intent to FreeBSD names (e.g. `kern.ipc.somaxconn`,
   `kern.maxfiles`, `net.inet.tcp.*` for the buffer/keepalive knobs).
4. Run the **same** [load-test.sh](../../scripts/load-test.sh) from the tester against it
   and drop the numbers into [Section 13](13-results.md) as a separate column.

## Takeaway

FreeBSD is not a detour — it's the **control group** that validates the Linux choices. The
fact that Linux now has epoll, kTLS, DPDK, and mature `sendfile` is *why* this project can
hit its targets on Debian. Knowing what FreeBSD did first tells you what each Linux layer
is really for.

Next: [Section 13 — Results Summary & Takeaways](13-results.md).
