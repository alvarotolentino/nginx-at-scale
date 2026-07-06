#!/usr/bin/env bash
# Network RX/TX packet steering — spread NIC softirq processing across all cores.
#
# Why: a single-RX-queue NIC (e.g. Realtek r8169) funnels every received packet's
# softirq onto the one core that handles the NIC IRQ. Under high connection load
# that core saturates at ~100% %soft while the rest idle — the real ceiling once
# nginx worker load is already balanced (see results/.../target-cpu.txt, CPU 9).
#
# What: enables RSS if the NIC supports multiple hardware queues; otherwise enables
# RPS (Receive Packet Steering, the software equivalent) so the kernel fans RX
# softirq across all CPUs, plus RFS (flow-aware steering) and XPS (TX side).
#
# Idempotent and persistent: live values are applied now and re-applied on boot via
# a systemd oneshot unit (sysfs masks reset across reboots; sysctls persist in the
# cumulative perf file).
#
# Usage:
#   sudo scripts/tune-network-rps.sh                 # auto-detect default iface
#   sudo scripts/tune-network-rps.sh --iface enp2s0
#   sudo scripts/tune-network-rps.sh --no-persist    # apply live only (used by the boot unit)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

IFACE=""
PERSIST=1
while [ $# -gt 0 ]; do
  case "$1" in
    --iface)      IFACE="$2"; shift 2 ;;
    --no-persist) PERSIST=0; shift 1 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

require_root
log_step "Network packet steering (RSS/RPS/RFS/XPS)"

# ---- resolve interface ------------------------------------------------------
if [ -z "$IFACE" ]; then
  IFACE="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
fi
if [ -z "$IFACE" ] || [ ! -d "/sys/class/net/$IFACE" ]; then
  echo "ERROR: could not resolve a network interface (got '${IFACE:-empty}'). Pass --iface." >&2
  exit 1
fi
log_ok "Interface: $IFACE ($(ethtool -i "$IFACE" 2>/dev/null | awk -F': ' '/^driver/{print $2}'))"

CPUS="$(getconf _NPROCESSORS_ONLN)"

# ---- hex CPU bitmask for sysfs (comma-separated 32-bit groups, high word first) --
cpu_mask() {
  # Assign n on its own line first: under `set -u`, referencing n in an arithmetic
  # expansion on the same `local` line fails (RHS expands before n is assigned).
  local n="$1" out="" i
  local full=$(( n / 32 )) rem=$(( n % 32 ))
  if [ "$rem" -gt 0 ]; then out="$(printf '%x' $(( (1 << rem) - 1 )))"; fi
  for (( i = 0; i < full; i++ )); do
    out="${out:+${out},}ffffffff"
  done
  echo "${out:-0}"
}
MASK="$(cpu_mask "$CPUS")"

# ---- 1. RSS: try to raise hardware RX queues (no-op on single-queue NICs) ----
RXQ="$(ls -d /sys/class/net/"$IFACE"/queues/rx-* 2>/dev/null | wc -l)"
if ethtool -l "$IFACE" >/dev/null 2>&1; then
  MAXQ="$(ethtool -l "$IFACE" 2>/dev/null | awk '/^Combined:/{print $2; exit}')"
  if [ -n "${MAXQ:-}" ] && [ "$MAXQ" -gt 1 ] 2>/dev/null; then
    ethtool -L "$IFACE" combined "$MAXQ" 2>/dev/null \
      && log_ok "RSS: set $IFACE to $MAXQ hardware queues" \
      || log_warn "RSS: ethtool -L failed; relying on RPS"
    RXQ="$(ls -d /sys/class/net/"$IFACE"/queues/rx-* 2>/dev/null | wc -l)"
  fi
else
  log_warn "RSS unavailable (driver has no multiqueue) — using RPS to compensate"
fi

# ---- 2+3. RPS/RFS: ONLY on single-queue NICs --------------------------------
# RPS is the SOFTWARE emulation of hardware RSS. On a multi-queue NIC the hardware
# already steers each flow to its own RX queue/core, so layering RPS on top is
# redundant and actively harmful: it re-dispatches packets across cores in software,
# adding IPIs and cache-line bouncing. Measured on T1 (12-queue 10GbE): applying RPS
# raised softirq ~22%→27% and cost the low-connection h2 test ~6%. So only enable
# RPS/RFS when there is exactly ONE hardware RX queue (no RSS to lean on); otherwise
# clear any stale mask and let hardware RSS do its job.
if [ "$RXQ" -le 1 ]; then
  for q in /sys/class/net/"$IFACE"/queues/rx-*; do
    echo "$MASK" > "$q/rps_cpus"
  done
  log_ok "RPS: single-queue NIC — rps_cpus=$MASK, RX softirq now spreads over $CPUS cores"

  # RFS keeps each flow on the core running its socket (cache locality). Works through
  # the RPS path, so it's only meaningful when RPS is active (single-queue).
  RFS_TOTAL=32768
  sysctl_set net.core.rps_sock_flow_entries "$RFS_TOTAL"
  PERQ=$(( RFS_TOTAL / (RXQ > 0 ? RXQ : 1) ))
  for q in /sys/class/net/"$IFACE"/queues/rx-*; do
    echo "$PERQ" > "$q/rps_flow_cnt"
  done
  log_ok "RFS: rps_sock_flow_entries=$RFS_TOTAL, rps_flow_cnt=$PERQ/queue"
else
  # Multi-queue: hardware RSS steers packets per-core, so DON'T add software RPS
  # (rps_cpus) — it's redundant and adds IPIs/cache-bouncing. But RSS hashes a flow
  # to a queue/core independently of which core nginx pinned that flow's worker to
  # (Layer 7). When they disagree, every packet bounces cache lines cross-core —
  # MEASURED: static -42% (522k->302k). aRFS fixes it: NIC ntuple filters steer each
  # flow to the core running its worker. MEASURED: static recovered 302k->545k while
  # h2 kept its gain (~837k). aRFS uses the rps_flow_cnt table + hardware ntuple,
  # WITHOUT rps_cpus. Enable it by default on multi-queue — beneficial with pinned
  # workers, harmless without.
  for q in /sys/class/net/"$IFACE"/queues/rx-*; do
    echo 0 > "$q/rps_cpus" 2>/dev/null || true       # no software RPS on multi-queue
  done
  if ethtool -K "$IFACE" ntuple on 2>/dev/null; then
    RFS_TOTAL=32768
    sysctl_set net.core.rps_sock_flow_entries "$RFS_TOTAL"
    PERQ=$(( RFS_TOTAL / (RXQ > 0 ? RXQ : 1) ))
    for q in /sys/class/net/"$IFACE"/queues/rx-*; do
      echo "$PERQ" > "$q/rps_flow_cnt" 2>/dev/null || true
    done
    log_ok "aRFS: ntuple on + rps_flow_cnt=${PERQ}/queue on ${RXQ} queues — flow steered to its worker's core"
    log_ok "RSS: ${RXQ} hardware RX queues; software RPS left off (aRFS handles locality)."
  else
    for q in /sys/class/net/"$IFACE"/queues/rx-*; do
      echo 0 > "$q/rps_flow_cnt" 2>/dev/null || true
    done
    log_warn "aRFS unavailable (ethtool -K $IFACE ntuple on failed) — relying on plain RSS."
    log_warn "  If nginx workers are CPU-pinned (Layer 7), expect cross-core bouncing on high-pps workloads."
  fi
fi

# ---- 4. XPS: spread TX completion softirq across CPUs -----------------------
# Best-effort: some drivers (e.g. r8169) expose xps_cpus but reject writes. XPS is
# TX-side only and not the bottleneck here, so a failed write is logged, not fatal.
TXQ=0
for q in /sys/class/net/"$IFACE"/queues/tx-*; do
  [ -e "$q/xps_cpus" ] || continue
  if echo "$MASK" > "$q/xps_cpus" 2>/dev/null; then TXQ=$(( TXQ + 1 )); fi
done
if [ "$TXQ" -gt 0 ]; then
  log_ok "XPS: xps_cpus=$MASK on $TXQ TX queue(s)"
else
  log_warn "XPS: driver rejected xps_cpus writes (TX steering unsupported) — skipping (harmless)"
fi

# ---- 5. persist across reboots ----------------------------------------------
# sysfs masks (rps_cpus/xps_cpus/rps_flow_cnt) are volatile; re-apply on boot.
if [ "$PERSIST" -eq 1 ]; then
  UNIT=/etc/systemd/system/nginx-net-rps.service
  cat > "$UNIT" <<EOF
[Unit]
Description=Re-apply NIC RPS/RFS/XPS packet steering for high-concurrency nginx
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/tune-network-rps.sh --iface ${IFACE} --no-persist
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable nginx-net-rps.service >/dev/null 2>&1 || true
  log_ok "Persistence: installed + enabled nginx-net-rps.service (re-applies on boot)"
fi

log_ok "Packet steering applied. Re-run the load test and check %soft is now spread across cores."
