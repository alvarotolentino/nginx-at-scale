#!/usr/bin/env bash
# Install the stock baseline Nginx config and capture a baseline measurement.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

require_root
log_step "Applying baseline Nginx config"

cp "$ROOT_DIR/nginx/baseline.conf" /etc/nginx/nginx.conf
nginx_reload
log_ok "Baseline config active"

# Snapshot the starting target state everything else is compared against.
# Load is generated separately from the tester (scripts/load-test.sh --label baseline).
"$SCRIPT_DIR/snapshot.sh" --label baseline
