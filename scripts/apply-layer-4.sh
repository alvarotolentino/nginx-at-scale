#!/usr/bin/env bash
# Layer 4 — jemalloc Memory Allocator (injected via LD_PRELOAD, no recompile).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

require_root
log_step "Layer 4: jemalloc Memory Allocator"

# Install jemalloc if missing (Debian/Ubuntu package names).
if ! dpkg -s libjemalloc2 >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y libjemalloc2 libjemalloc-dev
fi

# Locate the shared object shipped by the package.
JEMALLOC_PATH="$(dpkg -L libjemalloc2 | grep '\.so\.' | head -1)"
if [ -z "$JEMALLOC_PATH" ]; then
  echo "ERROR: could not locate libjemalloc .so" >&2
  exit 1
fi
log_ok "jemalloc found at $JEMALLOC_PATH"

# Add LD_PRELOAD to the same systemd override Layer 1 created (or create it).
OVERRIDE=/etc/systemd/system/nginx.service.d/limits.conf
mkdir -p "$(dirname "$OVERRIDE")"
touch "$OVERRIDE"
grep -q '^\[Service\]' "$OVERRIDE" || echo "[Service]" >> "$OVERRIDE"
# Idempotent: replace any existing LD_PRELOAD line, else append.
if grep -q 'LD_PRELOAD=' "$OVERRIDE"; then
  sed -i "s|Environment=\"LD_PRELOAD=.*\"|Environment=\"LD_PRELOAD=${JEMALLOC_PATH}\"|" "$OVERRIDE"
else
  echo "Environment=\"LD_PRELOAD=${JEMALLOC_PATH}\"" >> "$OVERRIDE"
fi

systemctl daemon-reload
# Full restart (not reload) so the new process inherits LD_PRELOAD.
systemctl restart nginx

# Verify jemalloc is actually mapped into the running process.
NGINX_PID="$(pidof nginx | awk '{print $1}')"
if grep -q jemalloc "/proc/${NGINX_PID}/maps"; then
  log_ok "jemalloc active in pid ${NGINX_PID}"
else
  log_warn "jemalloc not found in /proc/${NGINX_PID}/maps — check LD_PRELOAD"
fi

"$SCRIPT_DIR/snapshot.sh" --label layer-4
