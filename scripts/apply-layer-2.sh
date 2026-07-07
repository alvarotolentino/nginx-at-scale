#!/usr/bin/env bash
# Layer 2 — Linux TCP/IP Stack Tuning.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

require_root
log_step "Layer 2: Linux TCP/IP Stack Tuning"

# BBR lives in a module on stock kernels — load it before sysctl sets it, or the
# tcp_congestion_control write silently falls back to cubic.
modprobe tcp_bbr 2>/dev/null || log_warn "tcp_bbr module not loadable (may be built-in)"

# Append (do not overwrite) so Layer 1's FD limits stay in the same file. Guard
# against double-appending if the script is re-run.
if ! grep -q "Layer 2: Linux TCP/IP" "$PERF_SYSCTL_FILE" 2>/dev/null; then
  {
    echo ""
    cat "$ROOT_DIR/kernel/sysctl/layer-02-tcp.conf"
  } >> "$PERF_SYSCTL_FILE"
fi

sysctl --system >/dev/null
nginx_reload
log_ok "Layer 2 applied. Congestion control: $(sysctl -n net.ipv4.tcp_congestion_control)"

# ---- base network tuning: NIC packet steering (RSS/aRFS/RPS) ----------------
# Part of the base tuning every layer inherits. Introduced here at Layer 2 (the
# TCP/IP-stack layer) so every subsequent layer is tested WITH flow steering active,
# not just Layer 7. On a multi-queue NIC this enables hardware aRFS (ntuple) — the
# steering that recovered static throughput 302k→545k once workers are pinned at
# Layer 7; on a single-queue NIC it fans RX softirq across cores via RPS/RFS. aRFS is
# harmless before pinning and load-bearing after, so applying it early is safe. The
# script installs a systemd unit that re-applies on boot.
"$SCRIPT_DIR/tune-network-rps.sh"

"$SCRIPT_DIR/snapshot.sh" --label layer-2
