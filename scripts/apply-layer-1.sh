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

# Capture the post-change numbers.
"$SCRIPT_DIR/measure.sh" --label layer-1
