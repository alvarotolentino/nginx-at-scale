#!/usr/bin/env bash
# Layer 6 — Async File I/O: kernel AIO + directio for large static assets.
# Installs layer-06-aio.conf (= the Layer 5 TLS config + aio/directio on the static
# location). Requires libaio on the host; apply-layer-5.sh already installs libaio-dev,
# but we guard here so this script is safe to run standalone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

require_root
log_step "Layer 6: Async File I/O (kernel AIO + directio)"

# Layer 6 builds on Layer 5: it needs the TLS certs in place. If they're missing the
# config will fail nginx -t, so generate/install them like apply-layer-5.sh does.
if [ ! -f /etc/nginx/certs/nginx.crt ]; then
  log_step "TLS cert not installed — generating (Layer 6 extends the TLS config)"
  [ -f "$ROOT_DIR/certs/nginx.crt" ] || "$SCRIPT_DIR/generate-certs.sh"
  mkdir -p /etc/nginx/certs
  cp "$ROOT_DIR/certs/nginx.crt" "$ROOT_DIR/certs/nginx.key" /etc/nginx/certs/
  chmod 600 /etc/nginx/certs/nginx.key
fi

# kernel AIO needs libaio at runtime. nginx links it dynamically when aio is enabled;
# without the lib, `aio on` fails the config test. Install if absent.
if ! ldconfig -p | grep -q 'libaio\.so'; then
  log_step "libaio not found — installing"
  apt-get update -qq && apt-get install -y libaio1 libaio-dev \
    || log_warn "libaio install failed; aio on may not load"
fi

# Install the AIO config (TLS + aio/directio on the static location).
cp "$ROOT_DIR/nginx/sections/layer-06-aio.conf" /etc/nginx/nginx.conf

nginx_reload
log_ok "Async file I/O active (aio on, directio 512k). Verify with:"
log_ok "  strace -e io_submit,io_getevents -p \$(pidof nginx | awk '{print \$1}')"

"$SCRIPT_DIR/snapshot.sh" --label layer-6
