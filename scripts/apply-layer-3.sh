#!/usr/bin/env bash
# Layer 3 — Nginx Worker & Event Model.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

require_root
log_step "Layer 3: Nginx Worker & Event Model"

nginx_install_conf "$ROOT_DIR/nginx/sections/layer-03-worker-events.conf"
nginx_reload
log_ok "Active worker_connections: $(nginx -T 2>/dev/null | grep worker_connections | head -1 | xargs)"

"$SCRIPT_DIR/snapshot.sh" --label layer-3
