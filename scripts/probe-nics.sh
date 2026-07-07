#!/usr/bin/env bash
# Read-only NIC investigation — answer "are the box's two 10GbE NICs already being
# used together, and if not, what's the cleanest path to ~20 Gbps?"
#
# WHY: the Tier-1 report shows the CPU-bound paths (static 545k / warm-h2 837k rps)
# are NOT NIC-limited, but the browser-like UI/asset mix pins at ~159k rps ≈ 9.8 Gbps
# = LINE RATE on a single 10GbE. No CPU tuning moves that wall — only spreading it
# across both NICs (LACP bond -> one 20G link, or dual-IP -> two 10G links) can.
# This script does NOT change anything; it reports the current state so you can pick.
#
# Reads only: ip, ethtool, /proc/net/bonding, /proc/interrupts, sysfs. Safe to run
# on a live benchmark target (no reload, no sysctl, no link flap).
#
# Usage:
#   scripts/probe-nics.sh                 # auto-detect physical NICs
#   scripts/probe-nics.sh --iface eno1 --iface eno2   # inspect specific ifaces
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

IFACES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --iface) IFACES+=("$2"); shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ---- discover physical NICs (skip lo, virtual, and bond masters for the phys list) --
# A "physical" NIC has a device symlink under /sys/class/net/<if>/device.
if [ "${#IFACES[@]}" -eq 0 ]; then
  for d in /sys/class/net/*; do
    ifc="$(basename "$d")"
    [ "$ifc" = "lo" ] && continue
    [ -e "$d/device" ] || continue          # real hardware only (drops bond0/veth/docker0)
    IFACES+=("$ifc")
  done
fi
if [ "${#IFACES[@]}" -eq 0 ]; then
  echo "ERROR: no physical NICs found under /sys/class/net (pass --iface)." >&2
  exit 1
fi

CPUS="$(getconf _NPROCESSORS_ONLN)"
log_step "NIC probe — $CPUS CPUs online, physical NICs: ${IFACES[*]}"

# ---- per-NIC detail ---------------------------------------------------------
for IF in "${IFACES[@]}"; do
  [ -d "/sys/class/net/$IF" ] || { log_warn "$IF: no such interface — skipping"; continue; }

  DRIVER="$(ethtool -i "$IF" 2>/dev/null | awk -F': ' '/^driver/{print $2}')"
  SPEED="$(cat "/sys/class/net/$IF/speed" 2>/dev/null || echo '?')"
  OPER="$(cat "/sys/class/net/$IF/operstate" 2>/dev/null || echo '?')"
  MASTER="$(readlink -f "/sys/class/net/$IF/master" 2>/dev/null | xargs -r basename || true)"
  RXQ="$(ls -d /sys/class/net/"$IF"/queues/rx-* 2>/dev/null | wc -l)"
  MAXQ="$(ethtool -l "$IF" 2>/dev/null | awk '/^Combined:/{print $2; exit}')"
  CURQ="$(ethtool -l "$IF" 2>/dev/null | awk 'f&&/^Combined:/{print $2; exit} /Current hardware settings/{f=1}')"

  echo
  log_ok "$IF: driver=${DRIVER:-?} speed=${SPEED}Mb/s state=${OPER}${MASTER:+ master=$MASTER}"
  log_ok "   RX queues: sysfs=${RXQ}  ethtool combined max=${MAXQ:-n/a} current=${CURQ:-n/a}"

  # IPs on this iface (won't show if it's a bond slave — the bond holds the IP).
  IPS="$(ip -o -4 addr show dev "$IF" 2>/dev/null | awk '{print $4}' | paste -sd' ' -)"
  [ -n "$IPS" ] && log_ok "   IPv4: $IPS" || log_ok "   IPv4: (none on this iface directly)"

  # How many distinct CPUs actually service this NIC's IRQs right now — the RSS spread.
  # /proc/interrupts row: "IRQ:  c0 c1 ... cN   <type>  <device>". Walk the per-CPU
  # counts (the leading numeric run after the colon) and count columns with >0 hits.
  IRQ_CPUS="$(grep -E "$IF(-|$| )" /proc/interrupts 2>/dev/null | awk '{
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^[0-9]+$/) { if ($i + 0 > 0) used[i] = 1 }
        else break            # first non-numeric col = end of the CPU counters
      }
    } END { print length(used) }')"
  if [ -n "${IRQ_CPUS:-}" ] && [ "$IRQ_CPUS" -gt 0 ] 2>/dev/null; then
    log_ok "   IRQ spread: ~${IRQ_CPUS} CPUs currently taking this NIC's interrupts"
  else
    log_warn "   IRQ spread: no matching IRQ rows in /proc/interrupts for $IF"
  fi

  # aRFS/ntuple capability (the steering the report credits for 302k->545k).
  NTUPLE="$(ethtool -k "$IF" 2>/dev/null | awk -F': ' '/ntuple-filters/{print $2}')"
  [ -n "$NTUPLE" ] && log_ok "   ntuple (aRFS) feature: $NTUPLE"
done

# ---- bonding state ----------------------------------------------------------
echo
log_step "Bonding / aggregation state"
BONDS="$(ls /proc/net/bonding/ 2>/dev/null || true)"
if [ -n "$BONDS" ]; then
  for b in $BONDS; do
    MODE="$(awk -F': ' '/^Bonding Mode/{print $2; exit}' "/proc/net/bonding/$b")"
    SLAVES="$(awk -F': ' '/^Slave Interface/{print $2}' "/proc/net/bonding/$b" | paste -sd' ' -)"
    HASH="$(awk -F': ' '/Transmit Hash Policy/{print $2; exit}' "/proc/net/bonding/$b")"
    log_ok "$b: mode='${MODE}' slaves='${SLAVES}' xmit_hash='${HASH:-n/a}'"
  done
  log_ok "=> Box IS bonded. For >10Gbps aggregate you need mode 802.3ad (LACP) or"
  log_ok "   balance-xor with xmit_hash_policy layer3+4, MANY flows, and a tester also >10G."
else
  log_warn "No bond found (/proc/net/bonding empty). The two NICs are independent."
fi

# ---- teaming (systemd/networkd alternative to bonding) -----------------------
if command -v teamdctl >/dev/null 2>&1 && teamdctl -l 2>/dev/null | grep -q .; then
  log_ok "team device(s) present: $(teamdctl -l 2>/dev/null | paste -sd' ' -)"
fi

# ---- verdict ----------------------------------------------------------------
echo
log_step "Verdict"
UP_NICS=0
for IF in "${IFACES[@]}"; do
  [ "$(cat "/sys/class/net/$IF/operstate" 2>/dev/null)" = "up" ] && UP_NICS=$(( UP_NICS + 1 ))
done
log_ok "Physical NICs UP: ${UP_NICS}/${#IFACES[@]}"

if [ -n "$BONDS" ]; then
  cat <<'EOF'
  Already aggregated. Next: confirm the mode is 802.3ad + xmit_hash_policy layer3+4
  (`cat /proc/net/bonding/bond0`). If the UI mix still caps at ~9.8 Gbps, the limit
  is elsewhere: single-flow hashing to one slave, OR the TESTER is single-10G.
  Re-run the UI-mix load test with many source flows from a 20G-capable tester.
EOF
else
  cat <<'EOF'
  Two independent 10GbE NICs — the UI-mix 9.8 Gbps wall is one NIC's line rate.
  Two ways to use both from the OS (pick per your switch):
    1) LACP bond (one 20G VIP): needs the upstream switch port set to LACP/bonded.
       On cloud bare metal that's a portal/API port-mode change — you canNOT LACP
       without the switch side. Then: mode=802.3ad, xmit_hash_policy=layer3+4.
    2) Dual-IP multipath (no switch config): leave both NICs with their own IP and
       have the load tester spread connections across BOTH target IPs. Each NIC does
       line rate independently -> ~20 Gbps aggregate for a many-connection benchmark.
  BOTH ways require the TESTER to also drive >10G (it's 2x10GbE too — bond/dual-IP it).
  A single TCP flow never exceeds one NIC either way; aggregate scales with flow count.
EOF
fi
log_ok "Read-only probe complete — nothing was changed."
