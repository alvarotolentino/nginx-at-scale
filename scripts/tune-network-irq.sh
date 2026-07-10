#!/usr/bin/env bash
# Post-Layer-7 network/IRQ tuning — companion to tune-network-rps.sh.
#
# Each optimization is a SEPARATE opt-in flag so you can apply ONE, snapshot, and
# load-test it in isolation (the project's one-change-one-measurement rule). Nothing
# here runs unless you pass its flag. Every item is idempotent and re-applied on boot
# via a systemd oneshot that re-runs this script with the same flags.
#
# Map to the post-layer-7 proposal (docs/proposals/post-layer-7-tuning-proposal.md):
#   --notrack        K1  stop conntrack-ing 80/443 benchmark flows (per-packet CPU)
#   --irq-affinity   K2  pin NIC queue IRQs 1:1 to CPUs, disable irqbalance
#   --rings          K3  grow NIC RX/TX ring buffers to the driver max
#   --pause          K3  enable Ethernet pause frames (LAN-only flow control)
#   --coalesce       K4  interrupt coalescing (adaptive, fewer/fatter IRQs)
#   --jumbo[=MTU]    K6  raise MTU (default 9000) — MUST match tester + switch
#   --budget         K7  raise NAPI softirq budget (net.core.netdev_budget)
# (K5 mitigations=off is deliberately NOT here — it's a separate, security-gated boot
#  change, excluded by request.)
#
# Usage (one item at a time, then snapshot + load-test):
#   sudo scripts/tune-network-irq.sh --rings
#   sudo scripts/snapshot.sh --label l7-k3-rings
#   # ...run the trio from the tester with --label l7-k3-rings...
#
#   sudo scripts/tune-network-irq.sh --notrack --irq-affinity   # combine once proven
#   sudo scripts/tune-network-irq.sh --revert                   # undo everything below
#
# Diagnose first (K3): see per-phase loss before touching rings/pause —
#   watch -n1 'ethtool -S <iface> | grep -iE "drop|miss|err|no_?buf|fifo"'
#   tc -s qdisc show dev <iface>;  nstat -az | grep -i retrans
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

IFACE=""
PERSIST=1
JUMBO_MTU=9000
DO_NOTRACK=0 DO_IRQ=0 DO_RINGS=0 DO_PAUSE=0 DO_COALESCE=0 DO_JUMBO=0 DO_BUDGET=0
DO_REVERT=0
NFT_MARK="bench-notrack"   # marker for the idempotent nftables block

while [ $# -gt 0 ]; do
  case "$1" in
    --iface)        IFACE="$2"; shift 2 ;;
    --no-persist)   PERSIST=0; shift 1 ;;
    --notrack)      DO_NOTRACK=1; shift 1 ;;
    --irq-affinity) DO_IRQ=1; shift 1 ;;
    --rings)        DO_RINGS=1; shift 1 ;;
    --pause)        DO_PAUSE=1; shift 1 ;;
    --coalesce)     DO_COALESCE=1; shift 1 ;;
    --jumbo)        DO_JUMBO=1; shift 1 ;;
    --jumbo=*)      DO_JUMBO=1; JUMBO_MTU="${1#*=}"; shift 1 ;;
    --budget)       DO_BUDGET=1; shift 1 ;;
    --revert)       DO_REVERT=1; shift 1 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

require_root

# ---- resolve interface ------------------------------------------------------
if [ -z "$IFACE" ]; then
  IFACE="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
fi
if [ -z "$IFACE" ] || [ ! -d "/sys/class/net/$IFACE" ]; then
  echo "ERROR: could not resolve a network interface (got '${IFACE:-empty}'). Pass --iface." >&2
  exit 1
fi

NFT_FILE="/etc/nftables.conf"   # main ruleset (install-target.sh copies our file here)
UNIT="/etc/systemd/system/nginx-net-irq.service"

# =============================================================================
# revert
# =============================================================================
if [ "$DO_REVERT" -eq 1 ]; then
  log_step "Reverting post-L7 network/IRQ tuning on $IFACE"
  # notrack: drop the marked block from the persisted ruleset and reload.
  if [ -f "$NFT_FILE" ] && grep -q "$NFT_MARK" "$NFT_FILE"; then
    sed -i "/# >>> ${NFT_MARK}/,/# <<< ${NFT_MARK}/d" "$NFT_FILE"
    nft -f "$NFT_FILE" 2>/dev/null || log_warn "nft reload failed after removing notrack block — inspect $NFT_FILE"
    log_ok "notrack: removed benchmark notrack block, ruleset reloaded"
  fi
  systemctl enable --now irqbalance >/dev/null 2>&1 && log_ok "irqbalance: re-enabled" || true
  ip link set "$IFACE" mtu 1500 2>/dev/null && log_ok "MTU: reset to 1500" || true
  ethtool -A "$IFACE" autoneg on rx off tx off 2>/dev/null && log_ok "pause: disabled (autoneg back on)" || true
  ethtool -C "$IFACE" adaptive-rx off adaptive-tx off 2>/dev/null || true
  # Budget: only undo if we ever set it (keys present in the perf sysctl file), and
  # never let a rejected write abort the rest of the revert (kernel builds differ on
  # accepted values — a failed reset here must not leave the boot unit behind).
  for k in net.core.netdev_budget net.core.netdev_budget_usecs; do
    if [ -f "$PERF_SYSCTL_FILE" ] && grep -qE "^${k}\s*=" "$PERF_SYSCTL_FILE"; then
      d=300; [ "$k" = "net.core.netdev_budget_usecs" ] && d=2000
      sysctl -w "${k}=${d}" >/dev/null 2>&1 || log_warn "budget: could not reset $k (non-fatal)"
      sed -i "\|^${k}\s*=|d" "$PERF_SYSCTL_FILE"
    fi
  done
  systemctl disable --now nginx-net-irq.service >/dev/null 2>&1 || true
  rm -f "$UNIT"; systemctl daemon-reload 2>/dev/null || true
  log_ok "Revert complete. Rings/IRQ-affinity reset to driver default on next boot."
  exit 0
fi

if [ $((DO_NOTRACK+DO_IRQ+DO_RINGS+DO_PAUSE+DO_COALESCE+DO_JUMBO+DO_BUDGET)) -eq 0 ]; then
  echo "No optimization selected. Pass one or more of:" >&2
  echo "  --notrack --irq-affinity --rings --pause --coalesce --jumbo[=MTU] --budget" >&2
  echo "  (or --revert). See the header of this script for the proposal mapping." >&2
  exit 1
fi

DRV="$(ethtool -i "$IFACE" 2>/dev/null | awk -F': ' '/^driver/{print $2}')"
log_step "Post-L7 network/IRQ tuning on $IFACE (driver: ${DRV:-unknown})"

# =============================================================================
# K1 — notrack for 80/443 benchmark flows
# =============================================================================
# Idempotent: a marked `table inet bench_notrack` is inserted right after the
# `flush ruleset` line so it is re-declared on every boot AFTER the flush (survives
# nftables reloads). Uses the `raw` prerouting hook (priority -300) so packets skip
# conntrack before the stateful filter ever sees them. SSH stays fully stateful.
if [ "$DO_NOTRACK" -eq 1 ]; then
  if [ ! -f "$NFT_FILE" ]; then
    log_warn "notrack: $NFT_FILE not found — is nftables installed? Skipping."
  elif grep -q "$NFT_MARK" "$NFT_FILE"; then
    log_ok "notrack: already present in $NFT_FILE (idempotent)"
  else
    local_block=$(cat <<EOF
# >>> ${NFT_MARK} (post-L7 K1: skip conntrack for 80/443 benchmark flows) >>>
table inet bench_notrack {
    chain prerouting {
        type filter hook prerouting priority raw; policy accept;
        tcp dport { 80, 443 } notrack
        tcp sport { 80, 443 } notrack
    }
}
# <<< ${NFT_MARK} <<<
EOF
)
    # Insert the block immediately after the first `flush ruleset` line.
    awk -v blk="$local_block" '
      { print }
      !done && /flush ruleset/ { print ""; print blk; done=1 }
    ' "$NFT_FILE" > "${NFT_FILE}.tmp" && mv "${NFT_FILE}.tmp" "$NFT_FILE"
    if nft -f "$NFT_FILE"; then
      log_ok "notrack: benchmark 80/443 flows now skip conntrack (SSH stays stateful)"
    else
      log_warn "notrack: nft -f failed; reverting file edit"
      sed -i "/# >>> ${NFT_MARK}/,/# <<< ${NFT_MARK}/d" "$NFT_FILE"
    fi
  fi
fi

# =============================================================================
# K2 — NIC IRQ affinity 1:1 with CPUs, irqbalance off
# =============================================================================
# NOTE: on the v1 valid-rig run the CPU-bound static phase was already perfectly
# balanced (every core 100 %), so the "hot-core skew" this targets was NOT observed
# there. Kept because it is cheap and reversible — but check per-core in the UI phase
# (monitor cpu_max_core vs cpu_avg) before trusting a win. Weak-premise, low-priority.
if [ "$DO_IRQ" -eq 1 ]; then
  systemctl disable --now irqbalance >/dev/null 2>&1 \
    && log_ok "irqbalance: disabled (was reshuffling IRQs under load)" \
    || log_warn "irqbalance: not active / not installed (fine)"
  # Map each NIC queue IRQ to a distinct CPU, wrapping if IRQs > CPUs.
  CPUS="$(getconf _NPROCESSORS_ONLN)"
  i=0
  mapfile -t IRQS < <(awk -v ifc="$IFACE" '$0 ~ ifc {gsub(":","",$1); print $1}' /proc/interrupts)
  if [ "${#IRQS[@]}" -eq 0 ]; then
    log_warn "IRQ affinity: no IRQs matched '$IFACE' in /proc/interrupts — skipping"
  else
    for irq in "${IRQS[@]}"; do
      cpu=$(( i % CPUS ))
      if echo "$cpu" > "/proc/irq/${irq}/smp_affinity_list" 2>/dev/null; then
        i=$(( i + 1 ))
      fi
    done
    log_ok "IRQ affinity: pinned ${i} $IFACE queue IRQ(s) 1:1 to CPUs (queue i -> CPU i)"
  fi
fi

# =============================================================================
# K3 — RX/TX ring buffers to driver max
# =============================================================================
if [ "$DO_RINGS" -eq 1 ]; then
  RXMAX="$(ethtool -g "$IFACE" 2>/dev/null | awk '/^Pre-set/{p=1} p&&/^RX:/{print $2; exit}')"
  TXMAX="$(ethtool -g "$IFACE" 2>/dev/null | awk '/^Pre-set/{p=1} p&&/^TX:/{print $2; exit}')"
  if [ -n "${RXMAX:-}" ] && [ -n "${TXMAX:-}" ]; then
    ethtool -G "$IFACE" rx "$RXMAX" tx "$TXMAX" 2>/dev/null \
      && log_ok "rings: RX=$RXMAX TX=$TXMAX (driver max)" \
      || log_warn "rings: ethtool -G failed (driver may fix ring size)"
  else
    log_warn "rings: could not read ring maxima from ethtool -g — skipping"
  fi
fi

# =============================================================================
# K3 — Ethernet pause frames (LAN-only flow control)
# =============================================================================
if [ "$DO_PAUSE" -eq 1 ]; then
  # MUST disable pause autoneg or the link renegotiates it back OFF (the NIC defaults
  # to letting the switch decide, which here left RX/TX off). Set on BOTH nodes.
  ethtool -A "$IFACE" autoneg off rx on tx on 2>/dev/null \
    && log_ok "pause: autoneg off, RX/TX flow control on (set the SAME on the tester; LAN-only)" \
    || log_warn "pause: ethtool -A failed (driver may not support it)"
fi

# =============================================================================
# K4 — interrupt coalescing (adaptive)
# =============================================================================
if [ "$DO_COALESCE" -eq 1 ]; then
  if ethtool -C "$IFACE" adaptive-rx on adaptive-tx on 2>/dev/null; then
    log_ok "coalesce: adaptive-rx/tx on (fewer, fatter IRQs -> less softirq)"
  else
    # Fallback: a modest static rx-usecs (bigger rings from K3 tolerate this).
    ethtool -C "$IFACE" rx-usecs 32 2>/dev/null \
      && log_ok "coalesce: adaptive unsupported -> static rx-usecs=32" \
      || log_warn "coalesce: ethtool -C failed (driver has no coalescing knobs)"
  fi
fi

# =============================================================================
# K6 — jumbo frames
# =============================================================================
# MUST be consistent end-to-end (target + tester + switch) or PMTU pain. tcp_mtu_probing
# stays as the safety net. Static (~1.4 KB) barely moves; the win is the UI mix's frame
# count (~860k frames/s at 1500 B -> ~6x fewer at 9000).
if [ "$DO_JUMBO" -eq 1 ]; then
  if ip link set "$IFACE" mtu "$JUMBO_MTU" 2>/dev/null; then
    sysctl_set net.ipv4.tcp_mtu_probing 1
    log_ok "jumbo: $IFACE MTU=$JUMBO_MTU (set the SAME on the tester + switch, or expect PMTU stalls)"
  else
    log_warn "jumbo: ip link set mtu $JUMBO_MTU failed (driver/switch may cap MTU) — skipping"
  fi
fi

# =============================================================================
# K7 — NAPI softirq budget
# =============================================================================
# Only worth it if /proc/net/softnet_stat column 3 (time_squeeze) is climbing.
if [ "$DO_BUDGET" -eq 1 ]; then
  sysctl_set net.core.netdev_budget 600
  sysctl_set net.core.netdev_budget_usecs 4000
  log_ok "budget: netdev_budget=600 netdev_budget_usecs=4000 (check softnet_stat time_squeeze)"
fi

# =============================================================================
# persist (re-apply the SAME selected flags on boot)
# =============================================================================
# sysfs/ethtool/ip state is volatile; sysctls persist via _lib.sh. notrack persists in
# the nftables file itself. Re-run the volatile items on boot with the same flags.
if [ "$PERSIST" -eq 1 ]; then
  FLAGS=""
  [ "$DO_IRQ" -eq 1 ]      && FLAGS="$FLAGS --irq-affinity"
  [ "$DO_RINGS" -eq 1 ]    && FLAGS="$FLAGS --rings"
  [ "$DO_PAUSE" -eq 1 ]    && FLAGS="$FLAGS --pause"
  [ "$DO_COALESCE" -eq 1 ] && FLAGS="$FLAGS --coalesce"
  [ "$DO_JUMBO" -eq 1 ]    && FLAGS="$FLAGS --jumbo=${JUMBO_MTU}"
  # (notrack + budget are self-persisting; no need to re-run them here.)
  if [ -n "$FLAGS" ]; then
    cat > "$UNIT" <<EOF
[Unit]
Description=Re-apply post-L7 NIC/IRQ tuning for high-throughput nginx
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/tune-network-irq.sh --iface ${IFACE} --no-persist${FLAGS}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable nginx-net-irq.service >/dev/null 2>&1 || true
    log_ok "Persistence: nginx-net-irq.service re-applies '${FLAGS# }' on boot"
  fi
fi

log_ok "Done. Now: sudo scripts/snapshot.sh --label <this-item>, then run the trio from the tester."
