#!/usr/bin/env bash
# Aggregate all runs in results/tier-N/ into a Markdown report with a delta column.
#
# Usage: scripts/generate-report.sh --tier 1
set -euo pipefail

TIER="1"
while [ $# -gt 0 ]; do
  case "$1" in
    --tier) TIER="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TIER_DIR="$ROOT_DIR/results/tier-${TIER}"
REPORT="$TIER_DIR/REPORT.md"

if [ ! -d "$TIER_DIR" ]; then
  echo "ERROR: $TIER_DIR not found" >&2
  exit 1
fi

# Extract "Requests/sec:" value from a wrk output file (numeric, may be "n/a").
parse_rps() {
  local f="$1"
  [ -f "$f" ] || { echo ""; return; }
  grep -E 'Requests/sec' "$f" | awk '{print $2}' | head -1
}

# Extract the 99th-percentile latency line from wrk --latency output.
parse_p99() {
  local f="$1"
  [ -f "$f" ] || { echo ""; return; }
  grep -E '^\s*99(\.000)?%' "$f" | awk '{print $2}' | head -1
}

# Compute percentage delta of $1 vs baseline $2 (both numeric RPS). "" if unknown.
pct_delta() {
  local cur="$1" base="$2"
  if [ -z "$cur" ] || [ -z "$base" ] || [ "$base" = "0" ]; then echo ""; return; fi
  awk -v c="$cur" -v b="$base" 'BEGIN { printf "%+.1f%%", (c-b)/b*100 }'
}

{
  echo "# Benchmark Report — Tier ${TIER}"
  echo
  echo "_Generated $(date '+%Y-%m-%d %H:%M:%S')_"
  echo
  echo "| Layer | Label | RPS (static) | RPS (API) | p99 Latency | Δ vs baseline |"
  echo "|-------|-------|-------------|-----------|-------------|---------------|"
} > "$REPORT"

# Discover run directories, sorted by timestamp suffix (and thus chronological).
BASE_RPS=""
n=0
# Sort so "baseline-*" and "layer-N-*" appear in run order.
while IFS= read -r dir; do
  [ -d "$dir" ] || continue
  label="$(basename "$dir")"
  static_rps="$(parse_rps "$dir/wrk-static.txt")"
  api_rps="$(parse_rps "$dir/wrk-api.txt")"
  p99="$(parse_p99 "$dir/wrk-static.txt")"

  # The first run (alphabetically baseline, or first chronologically) is the base.
  if [ -z "$BASE_RPS" ] && [ -n "$static_rps" ]; then
    BASE_RPS="$static_rps"
  fi
  delta="$(pct_delta "$static_rps" "$BASE_RPS")"

  printf "| %d | %s | %s | %s | %s | %s |\n" \
    "$n" "$label" "${static_rps:-n/a}" "${api_rps:-n/a}" "${p99:-n/a}" "${delta:-—}" \
    >> "$REPORT"
  n=$((n + 1))
done < <(find "$TIER_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

echo >> "$REPORT"
echo "_Hand-fill qualitative observations in results/REPORT-TEMPLATE.md._" >> "$REPORT"

echo "Report written to $REPORT"
echo
cat "$REPORT"
