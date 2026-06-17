#!/usr/bin/env bash
# Run a standard 3×60s wrk sweep against static and dynamic endpoints, saving
# results. Uses wrk2 for latency-accurate runs (constant --rate, full HDR latency).
#
# Usage: benchmarks/wrk/run-baseline.sh --url http://localhost
set -euo pipefail

URL="http://localhost"
while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if ! command -v wrk >/dev/null 2>&1; then
  echo "ERROR: wrk (or wrk2) not installed. See docs/sections/00-prerequisites.md" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$ROOT_DIR/results/tier-1/wrk-${TIMESTAMP}"
mkdir -p "$OUT_DIR"

# wrk2 parameters: 12 threads, 400 connections, 60s, fixed 10k req/s rate so the
# latency percentiles are coordinated-omission-free.
THREADS=12
CONNS=400
DUR=60
RATE=10000

declare -A TARGETS=(
  ["static"]="${URL}/"
  ["api"]="${URL}/api/products"
)

for name in "${!TARGETS[@]}"; do
  target="${TARGETS[$name]}"
  for run in 1 2 3; do
    echo ">>> ${name} run ${run}/3 → ${target}"
    out="$OUT_DIR/wrk-${name}-run${run}.txt"
    # --rate triggers wrk2's constant-throughput mode; --latency prints the full
    # percentile spectrum. (Plain wrk ignores --rate harmlessly.)
    wrk -t"$THREADS" -c"$CONNS" -d"${DUR}s" --rate "$RATE" --latency "$target" \
      | tee "$out"
  done
done

echo
echo "==================== SWEEP SUMMARY ===================="
for f in "$OUT_DIR"/wrk-*.txt; do
  rps="$(grep -E 'Requests/sec' "$f" | awk '{print $2}')"
  p99="$(grep -E '^\s*99.000%|^\s*99%' "$f" | awk '{print $2}' | head -1)"
  printf "  %-28s RPS=%-12s p99=%s\n" "$(basename "$f")" "${rps:-n/a}" "${p99:-n/a}"
done
echo "Results: $OUT_DIR"
echo "======================================================="
