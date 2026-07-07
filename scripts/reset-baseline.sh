#!/usr/bin/env bash
# Revert all tuning back to a vanilla kernel + stock Nginx state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

require_root
log_step "Resetting all tuning to baseline"

# Reset sysctl keys to their documented kernel defaults. Comment = default value.
sysctl -w net.core.somaxconn=4096               # default: 4096 (modern kernels; 128 on older)
sysctl -w net.ipv4.tcp_max_syn_backlog=1024     # default: 1024
sysctl -w net.core.netdev_max_backlog=1000      # default: 1000
sysctl -w net.ipv4.tcp_rmem="4096 131072 6291456"   # default: 4096 131072 6291456
sysctl -w net.ipv4.tcp_wmem="4096 16384 4194304"    # default: 4096 16384 4194304
sysctl -w fs.file-max=$(( $(nproc) * 100000 )) >/dev/null 2>&1 || true  # roughly memory-derived default
sysctl -w vm.nr_hugepages=0                      # default: 0 (no hugepages reserved)

# Remove the cumulative perf sysctl file so nothing re-applies on boot.
if [ -f "$PERF_SYSCTL_FILE" ]; then
  rm -f "$PERF_SYSCTL_FILE"
  log_ok "Removed $PERF_SYSCTL_FILE"
fi

# Reload remaining sysctl.d files so the defaults above are the live truth.
sysctl --system >/dev/null

# ---- undo the base host/network tuning (governor + packet-steering units) ----
# These are applied by Layer 1 (governor) and Layer 2 (aRFS/RPS) and persist via
# systemd oneshots, so a clean baseline must disable + remove them. Live governor is
# reverted to ondemand now; live NIC steering (ntuple/rps masks) clears on next boot
# once the re-apply unit is gone.
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  [ -w "$g" ] && echo ondemand > "$g" 2>/dev/null || true
done
for unit in nginx-cpu-governor nginx-net-rps; do
  systemctl disable --now "${unit}.service" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${unit}.service"
done
systemctl daemon-reload 2>/dev/null || true
log_ok "Reverted CPU governor to ondemand and removed governor + packet-steering units"

# Restore the stock Nginx config and reload.
if [ -f "$ROOT_DIR/nginx/baseline.conf" ]; then
  cp "$ROOT_DIR/nginx/baseline.conf" /etc/nginx/nginx.conf
  nginx_reload
  log_ok "Restored baseline nginx.conf"
fi

log_ok "Baseline restored"
