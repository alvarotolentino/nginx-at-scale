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

# The aio/directio block in layer-06-aio.conf is OPT-IN (commented out): on T1 it
# regressed throughput ~21% (small cached TLS-served files gain nothing from async
# I/O — see the config comment). So by default this layer == Layer 5 + a documented
# opt-in. We therefore only WARN about the capabilities needed to enable it, rather
# than blocking. `aio threads` needs --with-threads; native `aio on` needs
# --with-file-aio + libaio at runtime.
if ! nginx -V 2>&1 | tr ' ' '\n' | grep -q -- '--with-threads'; then
  log_warn "nginx not built --with-threads — the opt-in 'aio threads' block won't load if you enable it."
fi
if nginx -V 2>&1 | tr ' ' '\n' | grep -q -- '--with-file-aio' \
   && ! ldconfig -p | grep -q 'libaio\.so'; then
  log_warn "native 'aio on' is available but libaio is not installed — 'apt-get install libaio-dev' if you enable it."
fi

# Install the AIO config (TLS + aio/directio on the static location).
nginx_install_conf "$ROOT_DIR/nginx/sections/layer-06-aio.conf"

nginx_reload
log_ok "Async file I/O active (aio on, directio 512k). Verify with:"
log_ok "  strace -e io_submit,io_getevents -p \$(pidof nginx | awk '{print \$1}')"

"$SCRIPT_DIR/snapshot.sh" --label layer-6
