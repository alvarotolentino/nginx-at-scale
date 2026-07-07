#!/usr/bin/env bash
# Shared functions sourced by every layer/apply script. Not executable on its own.
# Usage:  source "$(dirname "$0")/_lib.sh"

# Colors (no-op if stdout is not a TTY).
if [ -t 1 ]; then
  _C_GREEN="\033[32m"; _C_YELLOW="\033[33m"; _C_RESET="\033[0m"
else
  _C_GREEN=""; _C_YELLOW=""; _C_RESET=""
fi

# Path to the cumulative sysctl file all layers append to.
PERF_SYSCTL_FILE="/etc/sysctl.d/99-nginx-perf.conf"

log_step() { echo -e "${_C_GREEN}[STEP]${_C_RESET} $*"; }
log_ok()   { echo -e "${_C_GREEN}[OK]  ${_C_RESET} $*"; }
log_warn() { echo -e "${_C_YELLOW}[WARN]${_C_RESET} $*"; }

# Abort unless running as root (most actions write /etc and call sysctl).
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root (try: sudo $0)" >&2
    exit 1
  fi
}

# nginx_install_conf SOURCE
# Copies SOURCE to /etc/nginx/nginx.conf and fixes the `user` directive to
# match the system nginx worker account (nginx on Debian/RHEL, www-data on Ubuntu).
nginx_install_conf() {
  local src="$1"
  local nginx_user
  if getent passwd nginx >/dev/null 2>&1; then
    nginx_user="nginx"
  else
    nginx_user=$(getent passwd www-data 2>/dev/null | cut -d: -f1 || echo "www-data")
  fi
  cp "$src" /etc/nginx/nginx.conf
  sed -i "s/^user [^;]*;/user ${nginx_user};/" /etc/nginx/nginx.conf
}

# Validate config, then hot-reload Nginx. Never reloads a broken config.
nginx_reload() {
  if ! nginx -t; then
    echo "ERROR: nginx config test failed; not reloading" >&2
    return 1
  fi
  nginx -s reload
}

# sysctl_set KEY VALUE
# Applies live via `sysctl -w` and persists to PERF_SYSCTL_FILE. Idempotent:
# an existing line for KEY is replaced in place rather than duplicated.
sysctl_set() {
  local key="$1" value="$2"
  sysctl -w "${key}=${value}" >/dev/null

  touch "$PERF_SYSCTL_FILE"
  if grep -qE "^${key}\s*=" "$PERF_SYSCTL_FILE"; then
    # Replace existing line (use | as sed delimiter — keys contain dots, not pipes).
    sed -i "s|^${key}\s*=.*|${key} = ${value}|" "$PERF_SYSCTL_FILE"
  else
    echo "${key} = ${value}" >> "$PERF_SYSCTL_FILE"
  fi
}

# Systemd unit that re-pins the CPU governor on every boot (sysfs governor resets).
CPU_GOVERNOR_UNIT="/etc/systemd/system/nginx-cpu-governor.service"

# set_cpu_governor_performance
# Force every core's cpufreq governor to `performance` (max clock under load) and
# persist it across reboots via a systemd oneshot. This is part of the base host
# tuning applied at Layer 1 — the original layer sweep ran on a demand governor with
# the cores DOWNCLOCKED, so every "100% CPU" number was 100% of a throttled clock;
# forcing max frequency was a large share of the measured ~2x throughput gain.
# Idempotent: safe to re-run. Logs its own result.
set_cpu_governor_performance() {
  local g gov_set=0
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -w "$g" ] || continue
    if echo performance > "$g" 2>/dev/null; then gov_set=$(( gov_set + 1 )); fi
  done
  if [ "$gov_set" -eq 0 ]; then
    log_warn "No writable cpufreq governor — check scaling_driver (amd-pstate/acpi-cpufreq) / BIOS P-states."
    return 0
  fi
  cat > "$CPU_GOVERNOR_UNIT" <<'EOF'
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
  log_ok "CPU governor = performance on ${gov_set} cores (persisted via nginx-cpu-governor.service)"
}
