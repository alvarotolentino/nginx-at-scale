#!/usr/bin/env bash
# Capture the TARGET node's system + Nginx state for one layer.
# This runs ON THE TARGET (the tuned bare-metal box) — it does NOT generate load.
# Load is produced separately from the tester node with scripts/load-test.sh, and
# the two are correlated by --label.
#
# Output: results/tier-<tier>/<label>/snapshot/
#
# Usage:
#   scripts/snapshot.sh --label baseline --tier 1
set -euo pipefail

# ---- defaults ---------------------------------------------------------------
LABEL="run"
TIER="1"

# ---- arg parsing ------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --label) LABEL="$2"; shift 2 ;;
    --tier)  TIER="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Repo root = parent of this script's dir, so output paths are stable regardless
# of the caller's CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

OUT_DIR="$ROOT_DIR/results/tier-${TIER}/${LABEL}/snapshot"
mkdir -p "$OUT_DIR"

echo "Snapshotting target state for '${LABEL}' (tier ${TIER})..."

# ---- 1. socket statistics ---------------------------------------------------
# `ss -s` summarizes total/used/closed/orphaned sockets — the live concurrency view.
ss -s > "$OUT_DIR/socket-stats.txt" 2>&1 || echo "ss unavailable" > "$OUT_DIR/socket-stats.txt"

# ---- 2. kernel parameters that gate concurrency -----------------------------
{
  echo "somaxconn: $(cat /proc/sys/net/core/somaxconn 2>/dev/null || echo n/a)"
  sysctl net.ipv4.tcp_max_syn_backlog net.core.netdev_max_backlog \
         net.ipv4.tcp_congestion_control net.core.default_qdisc \
         fs.file-max fs.nr_open 2>/dev/null || true
} > "$OUT_DIR/kernel-params.txt"

# ---- 3. nginx effective params ---------------------------------------------
# `nginx -T` dumps the full resolved config; filter to the directives we tune.
nginx -T 2>/dev/null | grep -E "worker_|events|keepalive|server_tokens|ssl_" \
  > "$OUT_DIR/nginx-params.txt" 2>&1 || echo "nginx -T unavailable" > "$OUT_DIR/nginx-params.txt"

# ---- 4. CPU / NUMA topology -------------------------------------------------
{
  echo "nproc: $(nproc 2>/dev/null || echo n/a)"
  echo
  echo "---- lscpu ----"
  lscpu 2>/dev/null || echo "lscpu unavailable"
  echo
  echo "---- numactl --hardware ----"
  numactl --hardware 2>/dev/null || echo "numactl unavailable (single NUMA node or not installed)"
} > "$OUT_DIR/cpu-topology.txt"

# ---- 4b. NIC packet steering (RPS/RFS/XPS) ----------------------------------
# Records whether RX softirq is spread across cores or funneled to one (the
# single-queue-NIC bottleneck). "rps_cpus=0000" means RPS is off.
{
  IFACE="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
  echo "iface: ${IFACE:-unknown}"
  echo "rps_sock_flow_entries: $(cat /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || echo n/a)"
  for q in /sys/class/net/"$IFACE"/queues/rx-*; do
    [ -e "$q/rps_cpus" ] && echo "$(basename "$(dirname "$q")")/$(basename "$q") rps_cpus=$(cat "$q/rps_cpus") rps_flow_cnt=$(cat "$q/rps_flow_cnt" 2>/dev/null)"
  done
} > "$OUT_DIR/net-steering.txt" 2>&1 || echo "net steering unavailable" > "$OUT_DIR/net-steering.txt"

# ---- 5. memory --------------------------------------------------------------
free -h > "$OUT_DIR/memory.txt" 2>&1 || echo "free unavailable" > "$OUT_DIR/memory.txt"

# ---- 6. allocator in use ----------------------------------------------------
# Layer 4 preloads jemalloc via the nginx systemd Environment=LD_PRELOAD override.
# Confirm it's actually mapped into the running worker rather than glibc malloc.
{
  NGINX_PID="$(pidof -s nginx 2>/dev/null || true)"
  if [ -n "$NGINX_PID" ] && grep -q jemalloc "/proc/${NGINX_PID}/maps" 2>/dev/null; then
    echo "jemalloc: ACTIVE (mapped into nginx pid ${NGINX_PID})"
  else
    echo "jemalloc: not detected (glibc malloc — pre-Layer-4 or LD_PRELOAD missing)"
  fi
} > "$OUT_DIR/allocator.txt"

# ---- 7. services ------------------------------------------------------------
systemctl is-active nginx backend lux > "$OUT_DIR/services.txt" 2>&1 || true

echo
echo "==================== SNAPSHOT SAVED ===================="
printf "  %-10s %s\n" "Label:"  "$LABEL"
printf "  %-10s %s\n" "Tier:"   "$TIER"
printf "  %-10s %s\n" "Output:" "$OUT_DIR"
echo
echo "  Next: sample this box DURING the load (background or second shell):"
echo "    scripts/monitor.sh --label ${LABEL} --tier ${TIER} --duration 45 &"
echo "  ...and from the TESTER node, generate load for this layer:"
echo "    scripts/load-test.sh --target https://<target-ip> --label ${LABEL} --tier ${TIER}"
echo "========================================================"
