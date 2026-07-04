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

# The config uses `aio threads` (thread-pool AIO), which needs nginx built
# --with-threads — a COMPILE flag, not a runtime lib. Verify it up front so we fail
# with a clear message instead of a cryptic `nginx -t` error. (Native `aio on` would
# instead need --with-file-aio + libaio; the config comment explains switching back.)
if ! nginx -V 2>&1 | tr ' ' '\n' | grep -q -- '--with-threads'; then
  echo "ERROR: this nginx is not built --with-threads, so 'aio threads' won't load." >&2
  echo "  Fix: rebuild nginx with --with-threads (and --with-file-aio for native 'aio on')," >&2
  echo "  or edit nginx/sections/layer-06-aio.conf to remove the aio/directio block (Layer 6 == Layer 5)." >&2
  exit 1
fi
# If you switch the config back to native `aio on`, nginx also needs libaio at
# runtime — install libaio-dev (pulls the right libaio1/libaio1t64 for the release).
if nginx -V 2>&1 | tr ' ' '\n' | grep -q -- '--with-file-aio' \
   && ! ldconfig -p | grep -q 'libaio\.so'; then
  log_step "libaio not found — installing (needed only if you use native 'aio on')"
  apt-get update -qq && apt-get install -y libaio-dev \
    || log_warn "libaio install failed; native 'aio on' may not load"
fi

# Install the AIO config (TLS + aio/directio on the static location).
nginx_install_conf "$ROOT_DIR/nginx/sections/layer-06-aio.conf"

nginx_reload
log_ok "Async file I/O active (aio on, directio 512k). Verify with:"
log_ok "  strace -e io_submit,io_getevents -p \$(pidof nginx | awk '{print \$1}')"

"$SCRIPT_DIR/snapshot.sh" --label layer-6
