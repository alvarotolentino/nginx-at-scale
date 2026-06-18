#!/usr/bin/env bash
# Layer 7 — NUMA & CPU Affinity Pinning.
# NOTE: on T3 (2-socket) hardware, re-run Nginx under numactl to confine it to
# NUMA node 0 and compare:
#   numactl --cpunodebind=0 --membind=0 nginx
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

require_root
log_step "Layer 7: NUMA & CPU Affinity Pinning"

# numactl provides topology inspection and node binding.
if ! command -v numactl >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y numactl
fi

# Record the hardware topology alongside the run results for later analysis.
TOPO_DIR="$ROOT_DIR/results/tier-1"
mkdir -p "$TOPO_DIR"
numactl --hardware | tee "$TOPO_DIR/numa-topology.txt"

CPUS="$(nproc)"
log_ok "Detected ${CPUS} logical CPUs"

# Patch a temp copy: pin worker_processes to the real CPU count (don't mutate the
# checked-in config). sed only the standalone worker_processes line.
TMP_CONF="$(mktemp)"
sed "s/^worker_processes auto;.*/worker_processes ${CPUS};/" \
  "$ROOT_DIR/nginx/sections/layer-07-numa.conf" > "$TMP_CONF"

cp "$TMP_CONF" /etc/nginx/nginx.conf
rm -f "$TMP_CONF"

nginx_reload
log_ok "Workers pinned (worker_processes=${CPUS}, affinity auto). Topology:"
numactl --hardware

"$SCRIPT_DIR/snapshot.sh" --label layer-7
