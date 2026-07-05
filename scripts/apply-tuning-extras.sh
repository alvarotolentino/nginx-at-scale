#!/usr/bin/env bash
# Extra tunings the layer stack (1-8) skips but that lift RPS/core on the CPU-bound
# path — apply AFTER a layer is deployed, then re-run the load test and compare.
#
#   1. access_log buffering (or off): the layer configs log every request
#      synchronously; at ~300-400k rps that format+write() is real per-request CPU.
#   2. open_file_cache: cache the fd + stat() metadata for the hot static set so
#      each request skips open()/fstat().
#   3. CPU governor = performance: keep all cores at max clock under load instead of
#      letting a demand governor ramp.
#
# These patch the DEPLOYED /etc/nginx/nginx.conf in place (a backup is kept), so
# re-run this after each `apply-layer-N.sh` if you want the tunings on that layer.
#
# Usage:
#   sudo scripts/apply-tuning-extras.sh                 # access_log buffered (prod-like)
#   sudo scripts/apply-tuning-extras.sh --no-access-log # access_log off (max benchmark)
#   sudo scripts/apply-tuning-extras.sh --revert        # restore last backup + ondemand
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

ACCESS_LOG_MODE="buffer"   # buffer | off
REVERT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-access-log) ACCESS_LOG_MODE="off"; shift 1 ;;
    --revert)        REVERT=1; shift 1 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

require_root
CONF=/etc/nginx/nginx.conf

# ---- revert -----------------------------------------------------------------
if [ "$REVERT" = "1" ]; then
  LAST_BAK="$(ls -1t "${CONF}".pre-tuning.* 2>/dev/null | head -1 || true)"
  if [ -n "$LAST_BAK" ]; then
    cp -a "$LAST_BAK" "$CONF"
    log_ok "Restored $CONF from $LAST_BAK"
    nginx -t && nginx_reload
  else
    log_warn "no ${CONF}.pre-tuning.* backup found — nginx.conf left as-is"
  fi
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -w "$g" ] && echo ondemand > "$g" 2>/dev/null || true
  done
  systemctl disable --now nginx-cpu-governor.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/nginx-cpu-governor.service
  systemctl daemon-reload 2>/dev/null || true
  log_ok "Reverted governor to ondemand and removed the persistence unit."
  exit 0
fi

log_step "Tuning extras: CPU governor + access_log + open_file_cache"

# ---- 1. CPU governor -> performance -----------------------------------------
GOV_SET=0
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  [ -w "$g" ] || continue
  if echo performance > "$g" 2>/dev/null; then GOV_SET=$(( GOV_SET + 1 )); fi
done
if [ "$GOV_SET" -gt 0 ]; then
  log_ok "CPU governor = performance on ${GOV_SET} cores"
  # Persist across reboots (sysfs governor resets on boot).
  UNIT=/etc/systemd/system/nginx-cpu-governor.service
  cat > "$UNIT" <<'EOF'
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
  log_ok "Persistence: installed + enabled nginx-cpu-governor.service"
else
  log_warn "No writable cpufreq governor found — CPU may lack a scaling driver."
  log_warn "  Check: cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver (expect amd-pstate/acpi-cpufreq)."
  log_warn "  If empty, enable P-states/Cool'n'Quiet in BIOS or boot amd_pstate=active."
fi

# ---- 2+3. nginx: buffer access_log + add open_file_cache --------------------
[ -f "$CONF" ] || { echo "ERROR: $CONF not found — apply a layer first (apply-layer-N.sh)." >&2; exit 1; }
BAK="${CONF}.pre-tuning.$(date +%s)"
cp -a "$CONF" "$BAK"

HAS_OFC="$(grep -c 'open_file_cache ' "$CONF" || true)"
TMP="$(mktemp)"
awk -v almode="$ACCESS_LOG_MODE" -v has_ofc="$HAS_OFC" '
  # Replace the (single, http-context) access_log line, keeping its indentation,
  # and append open_file_cache right after it if the config does not already have it.
  /^[[:space:]]*access_log[[:space:]]/ && added != 1 {
    match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH)
    if (almode == "off")
      print ind "access_log off;   # tuning-extras: logging disabled for max throughput"
    else
      print ind "access_log /var/log/nginx/access.log combined buffer=256k flush=5s;   # tuning-extras: buffered"
    if (has_ofc + 0 == 0) {
      print ind "# tuning-extras: cache open fds + stat metadata for the hot static set"
      print ind "open_file_cache max=10000 inactive=60s;"
      print ind "open_file_cache_valid 60s;"
      print ind "open_file_cache_min_uses 2;"
      print ind "open_file_cache_errors on;"
    }
    added = 1
    next
  }
  { print }
' "$CONF" > "$TMP"
cat "$TMP" > "$CONF"
rm -f "$TMP"

if [ "$ACCESS_LOG_MODE" = "off" ]; then
  log_ok "access_log: disabled"
else
  log_ok "access_log: buffered (buffer=256k flush=5s)"
fi
[ "$HAS_OFC" -eq 0 ] && log_ok "open_file_cache: added (max=10000)" || log_ok "open_file_cache: already present — left as-is"

# ---- validate + reload ------------------------------------------------------
if ! nginx -t; then
  echo "ERROR: nginx -t failed after patching; restoring backup." >&2
  cp -a "$BAK" "$CONF"
  exit 1
fi
nginx_reload
log_ok "Tuning extras applied. Backup: $BAK"
log_ok "Re-run the load test and compare against the pre-tuning numbers (static ~290k / warm-h2 ~348k)."
