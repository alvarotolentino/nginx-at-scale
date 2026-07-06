#!/usr/bin/env bash
# Layer 1 — File Descriptor & Socket Buffer Limits.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

require_root
log_step "Layer 1: File Descriptor & Socket Buffer Limits"

# Install the kernel parameters as the cumulative perf sysctl file. Layer 1 is the
# base, so it *creates* the file; later layers append to it.
cp "$ROOT_DIR/kernel/sysctl/layer-01-fd-limits.conf" "$PERF_SYSCTL_FILE"
sysctl --system >/dev/null   # apply every /etc/sysctl.d file, including ours
log_ok "Kernel FD/socket limits applied"

# Per-user ulimits: the kernel cap (fs.nr_open) is meaningless unless the user
# nofile limit is raised too. nginx runs as 'nginx'; root included for foreground tests.
mkdir -p /etc/security/limits.d
cat > /etc/security/limits.d/nginx.conf <<'EOF'
# Raised file-descriptor limits for high-concurrency Nginx (Layer 1).
nginx  soft  nofile  2097152
nginx  hard  nofile  2097152
root   soft  nofile  2097152
root   hard  nofile  2097152
EOF
log_ok "Updated /etc/security/limits.d/nginx.conf"

# systemd ignores /etc/security/limits.* for services — it needs its own override.
mkdir -p /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/nginx.service.d/limits.conf <<'EOF'
[Service]
LimitNOFILE=2097152
EOF
log_ok "Updated nginx systemd LimitNOFILE override"

systemctl daemon-reload
nginx_reload
log_ok "Layer 1 applied"

# CPU governor = performance — folded in from tuning-extras (2026-07-05). The layers
# were originally measured on a demand governor with the cores DOWNCLOCKED, so every
# "100% CPU" number was 100% of a throttled clock; forcing max frequency here alone
# was a large share of the ~2x throughput gain. Set it as part of the base host tuning
# so every tier runs at full clock, and persist it (sysfs governor resets on boot).
GOV_SET=0
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  [ -w "$g" ] || continue
  if echo performance > "$g" 2>/dev/null; then GOV_SET=$(( GOV_SET + 1 )); fi
done
if [ "$GOV_SET" -gt 0 ]; then
  cat > /etc/systemd/system/nginx-cpu-governor.service <<'EOF'
[Unit]
Description=Pin CPU governor to performance for high-throughput nginx
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$g" 2>/dev/null || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable nginx-cpu-governor.service >/dev/null 2>&1 || true
  log_ok "CPU governor = performance on ${GOV_SET} cores (persisted via nginx-cpu-governor.service)"
else
  log_warn "No writable cpufreq governor — check scaling_driver (amd-pstate/acpi-cpufreq) / BIOS P-states."
fi

# Snapshot the post-change target state (load comes from the tester separately).
"$SCRIPT_DIR/snapshot.sh" --label layer-1
