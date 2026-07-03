# Layer 8 — DPDK & Kernel Bypass

> **Hardware scope.** DPDK is **bare metal only** — never a cloud VM, whose virtual NIC
> and shared host kernel cannot give a userspace poll-mode driver exclusive control of
> the hardware. All three tiers qualify; on T1 (`m4.metal.small`) use its second 10 GbE
> port for DPDK and keep management/SSH on the first.

## What DPDK is

The **Data Plane Development Kit** is a set of userspace libraries and **poll-mode
drivers (PMDs)** that take a NIC out of the kernel entirely and drive it directly from
a userspace application. Instead of the kernel fielding an interrupt per packet,
copying it into an `sk_buff`, and walking it up the TCP/IP stack, a dedicated CPU core
**busy-polls** the NIC's RX rings and hands packets straight to the application — no
syscalls, no interrupts, no per-packet kernel copy.

## Why this matters at 1B connections

At extreme packet rates the **kernel network stack itself becomes the bottleneck**.
Per-packet costs — interrupt handling, context switches, `sk_buff` allocation, the
syscall boundary on every `recv`/`send` — dominate CPU time long before the wire is
saturated. DPDK eliminates all of that per-packet overhead, letting a single core push
tens of millions of packets per second. That headroom is what makes a 100 GbE NIC line
rate reachable.

## Architecture

```
   Without DPDK (kernel path)            With DPDK (kernel bypass)
   ---------------------------           --------------------------
        NIC                                   NIC
         | interrupt                           | (no interrupt)
     [ kernel net stack ]                  [ DPDK PMD ] busy-poll
         | syscall copy                        | direct (mmap'd rings)
     [ socket / app ]                      [ userspace app ]
```

## Prerequisites

- **Hugepages** reserved (lowers TLB pressure for the PMD's large packet pools).
- **vfio-pci** kernel module (safely hands the device to userspace with IOMMU isolation).
- A **DPDK-supported NIC** (Intel ixgbe/i40e/ice, Mellanox mlx5, etc. — check the DPDK
  support matrix).
- **Two NICs**: DPDK claims its NIC entirely, so a *second* NIC is required for SSH /
  management access. This is non-negotiable — binding your only NIC to DPDK locks you out.

## Important limitation: mainline Nginx cannot use DPDK directly

Nginx speaks the kernel sockets API; it has no DPDK backend. Realistic options:

- **(a) DPDK + F-Stack** — a userspace TCP/IP stack (FreeBSD's, ported) presenting a
  sockets-like API on top of DPDK. Run an Nginx-compatible server against it.
- **(b) VPP (Vector Packet Processing)** — FD.io's DPDK-based L2–L4 (and L7 via plugins)
  forwarding engine, used as the kernel-bypass proxy layer.
- **(c) A custom Nginx module** bridging to DPDK — advanced, and **out of scope** here.

## What this layer actually does

This guide does **not** ship a full Nginx-DPDK integration. Instead it:

1. Configures the DPDK **environment**: hugepages, hugetlbfs mount, `vfio-pci`.
2. Lists DPDK-capable NICs (`dpdk-devbind.py --status`) and documents the manual bind.
3. Runs a raw **pktgen-dpdk** throughput test to establish the **NIC's ceiling** —
   demonstrating the packet rate a DPDK-aware application could theoretically reach,
   versus what the kernel stack delivered in earlier layers.

It also re-measures Nginx (label `layer-8-pre-dpdk`) on the kernel path so you have a
clean before/after comparison point against that NIC ceiling.

## Hardware requirement reminder

Two NICs. One for DPDK traffic, one for management. Confirm the second NIC is up and
reachable **before** binding the traffic NIC to `vfio-pci`.
