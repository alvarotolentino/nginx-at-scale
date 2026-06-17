#!/usr/bin/env bash
# Layer 5 — TLS Hardening & Session Resumption.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

require_root
log_step "Layer 5: TLS Hardening & Session Resumption"

# libaio is needed if you later enable Layer 6 (aio on); install it here so the
# TLS+AIO combo config can be dropped in without a second package step.
if ! dpkg -s libaio-dev >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y libaio-dev || log_warn "libaio-dev install skipped"
fi

# Generate a self-signed cert if none exists yet.
if [ ! -f "$ROOT_DIR/certs/nginx.crt" ]; then
  log_step "No cert found — generating self-signed cert"
  "$SCRIPT_DIR/generate-certs.sh"
fi

# Install certs and the TLS config.
mkdir -p /etc/nginx/certs
cp "$ROOT_DIR/certs/nginx.crt" "$ROOT_DIR/certs/nginx.key" /etc/nginx/certs/
chmod 600 /etc/nginx/certs/nginx.key
cp "$ROOT_DIR/nginx/sections/layer-05-tls.conf" /etc/nginx/nginx.conf

nginx_reload
log_ok "TLS active. Test: curl -k https://localhost/health"

"$SCRIPT_DIR/measure.sh" --label layer-5 --url https://localhost
