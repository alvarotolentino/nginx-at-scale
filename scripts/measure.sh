#!/usr/bin/env bash
# Capture a full snapshot of system + Nginx performance for one run.
# Output goes to results/tier-<tier>/<label>-<timestamp>/.
#
# Usage:
#   scripts/measure.sh --label baseline --tier 1 --url http://localhost --duration 30
set -euo pipefail

# ---- defaults ---------------------------------------------------------------
LABEL="run"
TIER="1"
URL="http://localhost"
DURATION="30"

# ---- arg parsing ------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --label)    LABEL="$2"; shift 2 ;;
    --tier)     TIER="$2"; shift 2 ;;
    --url)      URL="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ---- dependency check -------------------------------------------------------
if ! command -v wrk >/dev/null 2>&1; then
  echo "ERROR: wrk not installed. See docs/sections/00-prerequisites.md" >&2
  exit 1
fi

# Repo root = parent of this script's dir, so output paths are stable regardless
# of the caller's CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$ROOT_DIR/results/tier-${TIER}/${LABEL}-${TIMESTAMP}"
mkdir -p "$OUT_DIR"

echo "Measuring '${LABEL}' (tier ${TIER}) against ${URL} for ${DURATION}s..."

# ---- 1. wrk: static root ----------------------------------------------------
# 12 threads, 400 connections — a standard mid-load profile.
wrk -t12 -c400 -d"${DURATION}s" --latency "${URL}/" \
  > "$OUT_DIR/wrk-static.txt" 2>&1 || true

# ---- 2. wrk: dynamic API ----------------------------------------------------
wrk -t12 -c400 -d"${DURATION}s" --latency "${URL}/api/products" \
  > "$OUT_DIR/wrk-api.txt" 2>&1 || true

# ---- 3. socket statistics ---------------------------------------------------
# `ss -s` summarizes total/used/closed/orphaned sockets — the live concurrency view.
ss -s > "$OUT_DIR/socket-stats.txt" 2>&1 || echo "ss unavailable" > "$OUT_DIR/socket-stats.txt"

# ---- 4 & 5. kernel parameters -----------------------------------------------
{
  echo "somaxconn: $(cat /proc/sys/net/core/somaxconn 2>/dev/null || echo n/a)"
  # Backlogs + global fd caps that gate max connections.
  sysctl net.ipv4.tcp_max_syn_backlog net.core.netdev_max_backlog \
         fs.file-max fs.nr_open 2>/dev/null || true
} > "$OUT_DIR/kernel-params.txt"

# ---- 6. nginx effective params ---------------------------------------------
# `nginx -T` dumps the full resolved config; filter to the directives we tune.
nginx -T 2>/dev/null | grep -E "worker_|events|keepalive" \
  > "$OUT_DIR/nginx-params.txt" 2>&1 || echo "nginx -T unavailable" > "$OUT_DIR/nginx-params.txt"

# ---- 7. memory --------------------------------------------------------------
free -h > "$OUT_DIR/memory.txt" 2>&1 || echo "free unavailable" > "$OUT_DIR/memory.txt"

# ---- 8. summary table -------------------------------------------------------
# Parse RPS and p99 out of the static wrk run for an at-a-glance result.
RPS="$(grep -E 'Requests/sec' "$OUT_DIR/wrk-static.txt" | awk '{print $2}' | head -1)"
P99="$(grep -E '^\s*99%' "$OUT_DIR/wrk-static.txt" | awk '{print $2}' | head -1)"

echo
echo "==================== RUN SUMMARY ===================="
printf "  %-14s %s\n" "Label:"     "$LABEL"
printf "  %-14s %s\n" "Tier:"      "$TIER"
printf "  %-14s %s\n" "URL:"       "$URL"
printf "  %-14s %s\n" "RPS (static):" "${RPS:-n/a}"
printf "  %-14s %s\n" "p99 latency:"  "${P99:-n/a}"
printf "  %-14s %s\n" "Timestamp:"  "$TIMESTAMP"
printf "  %-14s %s\n" "Output:"     "$OUT_DIR"
echo "====================================================="
