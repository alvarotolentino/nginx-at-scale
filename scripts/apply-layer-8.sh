#!/usr/bin/env bash
# Layer 8 — DPDK Hugepages & Environment Setup.
# This sets up the DPDK *environment* only; binding the traffic NIC and running
# a DPDK-aware data plane is a documented manual step (see layer-08-dpdk.md).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

require_root
log_step "Layer 8: DPDK Hugepages & Environment Setup"

# Guard: DPDK is bare-metal only. The vfio-pci driver sysfs path exists once the
# module is loadable; on a T1 cloud VM it is typically absent. Warn and bail.
if [ ! -d /sys/bus/pci/drivers/vfio-pci ] && ! modprobe -n vfio-pci >/dev/null 2>&1; then
  log_warn "vfio-pci not available — this looks like a cloud VM (T1)."
  log_warn "DPDK requires bare metal (T2/T3). Skipping Layer 8."
  exit 1
fi

# DPDK tooling + hugepage helpers.
apt-get update -qq
apt-get install -y dpdk dpdk-dev hugepages || log_warn "some DPDK packages may differ by release"

# Apply hugepage reservation from the layer sysctl snippet.
if ! grep -q "Hugepages for DPDK" "$PERF_SYSCTL_FILE" 2>/dev/null; then
  {
    echo ""
    cat "$ROOT_DIR/kernel/sysctl/layer-08-hugepages.conf"
  } >> "$PERF_SYSCTL_FILE"
fi
sysctl --system >/dev/null
log_ok "Hugepages reserved: $(cat /proc/sys/vm/nr_hugepages) × 2MB"

# Mount hugetlbfs so the PMD can mmap hugepage-backed memory.
mkdir -p /mnt/huge
if ! mountpoint -q /mnt/huge; then
  mount -t hugetlbfs nodev /mnt/huge
fi
# Persist across reboots (idempotent — only append if not already present).
if ! grep -q "/mnt/huge" /etc/fstab; then
  echo "nodev /mnt/huge hugetlbfs defaults 0 0" >> /etc/fstab
fi
log_ok "hugetlbfs mounted at /mnt/huge"

# Load the userspace I/O driver DPDK binds NICs to.
modprobe vfio-pci
log_ok "vfio-pci module loaded"

# Show which NICs are DPDK-compatible / currently bound.
log_step "DPDK-compatible NIC status:"
dpdk-devbind.py --status 2>/dev/null || log_warn "dpdk-devbind.py not found in PATH"

log_warn "Manual step required: bind your TRAFFIC NIC to vfio-pci (NOT your mgmt NIC):"
log_warn "  dpdk-devbind.py --bind=vfio-pci <PCI_ADDR>"
log_warn "See docs/sections/layer-08-dpdk.md for the full walkthrough."

# Measure Nginx on the kernel path now, as the before/after comparison baseline
# against the NIC ceiling a DPDK data plane could reach.
"$SCRIPT_DIR/measure.sh" --label layer-8-pre-dpdk
