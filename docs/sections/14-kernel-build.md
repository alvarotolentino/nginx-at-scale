# Section 14 — Appendix: Custom Kernel Build

> **Optional, last-mile, bare-metal only.** Everything in Layers 1–8 works on the **stock
> Debian 12 kernel** — you do not need to rebuild the kernel to reproduce this guide. This
> appendix is for squeezing the final few percent when the stock kernel's generic-distro
> compromises become the measurable bottleneck. All three tiers are bare metal, so a custom
> kernel boots anywhere — but the payoff is mainly T2/T3; on T1 spend the effort on Layers
> 1–8 first.

## When a custom kernel is actually worth it

Only after Layers 1–8 are exhausted and a profile shows the kernel itself in the way.
Concretely:

- You need a feature/driver **not compiled into** the stock kernel (a specific NIC PMD
  dependency, a newer `tcp_bbr`, IOMMU/`vfio` options for DPDK).
- The generic kernel's **preemption / tick / scheduler** defaults add measurable jitter to
  p99 at extreme load.
- You want to **strip** unused subsystems/drivers to shrink the kernel's cache and syscall
  footprint.

If you can't point at a profile justifying it, **skip this** — a custom kernel is
maintenance debt (you own security updates and rebuilds).

## Config options that matter for this workload

Starting from the running config (`/boot/config-$(uname -r)`), the high-signal knobs:

| Option | Setting | Why |
|--------|---------|-----|
| `CONFIG_HZ` | `1000` (or tickless) | Finer timer granularity → tighter timeouts/latency |
| `CONFIG_NO_HZ_FULL` | `y` | Tickless on isolated cores → fewer interrupts on Nginx CPUs |
| `CONFIG_PREEMPT` | `y` (or voluntary) | Lower scheduling latency for the event loop |
| `CONFIG_TCP_CONG_BBR` | `y` (built-in) | BBR (Layer 2) always present, not a module |
| `CONFIG_DEFAULT_TCP_CONG` | `bbr` | Skip the runtime `sysctl` switch |
| `CONFIG_VFIO` / `CONFIG_VFIO_PCI` | `y` | DPDK (Layer 8) device assignment |
| `CONFIG_TRANSPARENT_HUGEPAGE` | considered | Interacts with the Layer 8 hugepage reservation |
| `CONFIG_HZ_PERIODIC` / extra drivers | **off** | Strip unused subsystems → smaller footprint |
| `CONFIG_RETPOLINE` / mitigations | **measure** | Speculative-exec mitigations cost syscall-heavy throughput; only relax on an isolated, trusted bench box ([Section 15](15-security.md)) |

> The mitigation knobs are a **security trade-off**, not a free win. Disabling CPU
> vulnerability mitigations can lift syscall-heavy throughput noticeably, but only do it on
> an **isolated benchmark box you fully trust** — never on anything multi-tenant or
> internet-exposed beyond the lab firewall.

## Build steps (Debian)

```bash
sudo apt-get install -y build-essential libncurses-dev bison flex libssl-dev \
  libelf-dev bc rsync

# Get a source tree (distro source or mainline)
apt-get source linux-image-$(uname -r)        # or: git clone the stable tree
cd linux-*

# Start from the running config, then edit
cp /boot/config-$(uname -r) .config
make olddefconfig                              # fill new options with defaults
make menuconfig                                # set the options in the table above

# Build (use all cores) and install
make -j"$(nproc)" bindeb-pkg                   # produces ../linux-image-*.deb
sudo dpkg -i ../linux-image-*.deb ../linux-headers-*.deb
sudo update-grub
sudo reboot
```

After reboot:

```bash
uname -r                                        # confirm the custom version booted
grep -E 'CONFIG_HZ|BBR' /boot/config-$(uname -r)
```

## Measure it like any other layer

A custom kernel is **not** in the automated `apply-layer-N.sh` sweep — it's a manual,
infrequent change. Treat it as its own labeled run so the gain is attributable:

```bash
# TARGET (after booting the custom kernel)
scripts/snapshot.sh --label custom-kernel
# TESTER
scripts/load-test.sh --target https://<ip> --label custom-kernel --tier <n> \
  --profile highconn --h2
```

Then `generate-report.sh` folds it in alongside the layers. If the delta vs. the stock
kernel doesn't clear the noise floor, **revert** — the maintenance cost isn't worth a
result you can't measure.

## Caveats

- **You own updates.** A custom kernel drops out of Debian's security-update path — you
  must rebuild on CVEs. For a throwaway bench box that's fine; for anything long-lived it's
  a real cost.
- **Reproducibility.** Pin the exact source tree + `.config` in the repo if you want others
  to reproduce the custom-kernel row.
- **Diminishing returns.** This is the last 1–3%. If Layers 1–8 aren't fully applied,
  spend your time there first.

Next: [Section 15 — Security Hardening](15-security.md).
