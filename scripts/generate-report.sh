#!/usr/bin/env bash
# Aggregate all runs in results/tier-N/ into a Markdown report with a delta column.
# Each run is a label dir holding up to three subdirs, correlated by --label:
#   <label>/load/      — wrk/k6 output   (tester,  scripts/load-test.sh, scp'd back)
#   <label>/monitor/   — live utilization (target, scripts/monitor.sh, DURING load)
#   <label>/snapshot/  — box state        (target, scripts/snapshot.sh, before load)
# Run this on the target AFTER copying the tester's load/ dirs into the results tree.
#
# The report has three tables:
#   1. Tester view  — RPS, p99, transfer/s, errors, Δ vs baseline (what clients saw)
#   2. Target view  — CPU, busiest core, softirq, RSS, conns, NIC Mbps (what it cost)
#   3. Efficiency   — RPS/core and, with --cost, RPS per $/hr (the project's thesis)
#
# Usage: scripts/generate-report.sh --tier 1 [--cost 0.41]
#   --cost  hourly price of the target box (e.g. 0.41 for m4.metal.small) —
#           adds the RPS-per-dollar-hour column to the efficiency table.
set -euo pipefail

TIER="1"
COST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tier) TIER="$2"; shift 2 ;;
    --cost) COST="$2"; shift 2 ;;
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

# ---- parsers: tester side (wrk / bombardier output) --------------------------
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

# Transfer/sec (wrk) or Throughput (bombardier) — the bandwidth the run moved.
parse_xfer() {
  local f="$1"
  [ -f "$f" ] || { echo ""; return; }
  grep -E 'Transfer/sec|^\s*Throughput' "$f" | awk '{print $2}' | head -1
}

# Error count: wrk socket errors + non-2xx/3xx, or bombardier 4xx/5xx/others.
parse_errors() {
  local f="$1" sock http others
  [ -f "$f" ] || { echo ""; return; }
  sock="$(grep -E 'Socket errors' "$f" \
    | awk -F'[ ,]+' '{s=0; for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) s+=$i; print s; exit}')"
  http="$(grep -E 'Non-2xx or 3xx' "$f" | awk '{print $NF}' | head -1)"
  if [ -z "$http" ]; then    # bombardier format
    http="$(grep -E '4xx' "$f" | awk '
      { for (i=1; i<NF; i++) if ($i=="4xx" || $i=="5xx") { v=$(i+2); gsub(",","",v); s+=v } }
      END { print s+0 }')"
  fi
  others="$(grep -E '^\s*others' "$f" | awk '{gsub(",","",$3); print $3+0}' | head -1)"
  echo "$(( ${sock:-0} + ${http:-0} + ${others:-0} ))"
}

# ---- parser: target side (monitor/summary.txt "key: value" lines) -----------
mon_get() {
  local dir="$1" key="$2"
  [ -f "$dir/summary.txt" ] || { echo ""; return; }
  grep -E "^${key}:" "$dir/summary.txt" | awk '{print $2}' | head -1
}

# Compute percentage delta of $1 vs baseline $2 (both numeric RPS). "" if unknown.
pct_delta() {
  local cur="$1" base="$2"
  if [ -z "$cur" ] || [ -z "$base" ] || [ "$base" = "0" ]; then echo ""; return; fi
  awk -v c="$cur" -v b="$base" 'BEGIN { printf "%+.1f%%", (c-b)/b*100 }'
}

# awk-formatted division helper: div NUM DEN FMT — "" when either side missing.
div() {
  local num="$1" den="$2" fmt="$3"
  if [ -z "$num" ] || [ -z "$den" ] || [ "$den" = "0" ]; then echo ""; return; fi
  awk -v n="$num" -v d="$den" -v f="$fmt" 'BEGIN { printf f, n/d }'
}

# Discover run/label directories, sorted alphabetically (baseline first, then layer-N).
LABEL_DIRS="$(find "$TIER_DIR" -mindepth 1 -maxdepth 1 -type d | sort)"

{
  echo "# Benchmark Report — Tier ${TIER}"
  echo
  echo "_Generated $(date '+%Y-%m-%d %H:%M:%S')_"
  echo
  echo "## 1. Tester view — what clients experienced"
  echo
  echo "| Layer | Label | RPS (static) | RPS (UI mix) | RPS (API) | p99 | Transfer/s | Errors | Δ vs baseline |"
  echo "|-------|-------|-------------|--------------|-----------|-----|------------|--------|---------------|"
} > "$REPORT"

BASE_RPS=""
n=0
while IFS= read -r dir; do
  [ -d "$dir" ] || continue
  label="$(basename "$dir")"
  load_dir="$dir/load"

  static_rps="$(parse_rps "$load_dir/wrk-static.txt")"
  ui_rps="$(parse_rps "$load_dir/wrk-ui.txt")"
  if [ -z "$ui_rps" ] && [ -f "$load_dir/k6-ui.txt" ]; then   # bombardier+k6 tester
    ui_rps="$(grep -E 'http_reqs' "$load_dir/k6-ui.txt" \
      | grep -oE '[0-9]+(\.[0-9]+)?/s' | head -1 | tr -d '/s' || true)"
  fi
  api_rps="$(parse_rps "$load_dir/wrk-api.txt")"
  p99="$(parse_p99 "$load_dir/wrk-static.txt")"
  xfer="$(parse_xfer "$load_dir/wrk-static.txt")"
  errs="$(parse_errors "$load_dir/wrk-static.txt")"

  # The first run (alphabetically baseline) with a load result is the comparison base.
  if [ -z "$BASE_RPS" ] && [ -n "$static_rps" ]; then
    BASE_RPS="$static_rps"
  fi
  delta="$(pct_delta "$static_rps" "$BASE_RPS")"

  printf "| %d | %s | %s | %s | %s | %s | %s | %s | %s |\n" \
    "$n" "$label" "${static_rps:-n/a}" "${ui_rps:-n/a}" "${api_rps:-n/a}" \
    "${p99:-n/a}" "${xfer:-n/a}" "${errs:-n/a}" "${delta:-—}" >> "$REPORT"
  n=$((n + 1))
done <<< "$LABEL_DIRS"

{
  echo
  echo "## 2. Target view — what the box spent (from monitor.sh, sampled during load)"
  echo
  echo "| Label | CPU avg/peak % | Max core % | softirq peak % | nginx CPU % / RSS MB | Conns peak | TIME-WAIT peak | TX peak Mbps | Retrans | Listen drops |"
  echo "|-------|----------------|------------|----------------|----------------------|------------|----------------|--------------|---------|--------------|"
} >> "$REPORT"

while IFS= read -r dir; do
  [ -d "$dir" ] || continue
  label="$(basename "$dir")"
  mon="$dir/monitor"
  [ -f "$mon/summary.txt" ] || continue

  cpu_avg="$(mon_get "$mon" cpu_busy_avg_pct)"
  cpu_pk="$(mon_get "$mon" cpu_peak_pct)"
  core_pk="$(mon_get "$mon" cpu_max_core_peak_pct)"
  soft_pk="$(mon_get "$mon" softirq_peak_pct)"
  ngx_cpu="$(mon_get "$mon" nginx_cpu_peak_pct)"
  ngx_rss="$(mon_get "$mon" nginx_rss_peak_mb)"
  conns="$(mon_get "$mon" tcp_inuse_peak)"
  tw="$(mon_get "$mon" tcp_timewait_peak)"
  tx="$(mon_get "$mon" tx_mbps_peak)"
  retr="$(mon_get "$mon" retrans_total)"
  drops="$(mon_get "$mon" listen_drops_total)"

  printf "| %s | %s / %s | %s | %s | %s / %s | %s | %s | %s | %s | %s |\n" \
    "$label" "${cpu_avg:-n/a}" "${cpu_pk:-n/a}" "${core_pk:-n/a}" "${soft_pk:-n/a}" \
    "${ngx_cpu:-n/a}" "${ngx_rss:-n/a}" "${conns:-n/a}" "${tw:-n/a}" "${tx:-n/a}" \
    "${retr:-n/a}" "${drops:-n/a}" >> "$REPORT"
done <<< "$LABEL_DIRS"

{
  echo
  echo "_No monitor rows? Run \`scripts/monitor.sh --label <label> --tier ${TIER}\` on the target during each load run._"
  echo
  echo "## 3. Efficiency — performance per core and per dollar"
  echo
  if [ -n "$COST" ]; then
    echo "_Target box cost: \$${COST}/hr_"
    echo
    echo "| Label | RPS (static) | RPS / core | RPS per \$/hr |"
    echo "|-------|-------------|------------|---------------|"
  else
    echo "_Pass \`--cost <hourly-price>\` (e.g. \`--cost 0.41\` for m4.metal.small) to add the RPS-per-dollar column._"
    echo
    echo "| Label | RPS (static) | RPS / core |"
    echo "|-------|-------------|------------|"
  fi
} >> "$REPORT"

while IFS= read -r dir; do
  [ -d "$dir" ] || continue
  label="$(basename "$dir")"
  static_rps="$(parse_rps "$dir/load/wrk-static.txt")"
  [ -n "$static_rps" ] || continue
  nproc_val="$(mon_get "$dir/monitor" nproc)"
  if [ -z "$nproc_val" ]; then
    nproc_val="$(grep -E '^nproc:' "$dir/snapshot/cpu-topology.txt" 2>/dev/null | awk '{print $2}' || true)"
  fi
  case "$nproc_val" in (*[!0-9]*) nproc_val="" ;; esac   # "n/a" etc. → unknown

  rps_core="$(div "$static_rps" "${nproc_val:-}" '%.0f')"
  if [ -n "$COST" ]; then
    rps_dollar="$(div "$static_rps" "$COST" '%.0f')"
    printf "| %s | %s | %s | %s |\n" "$label" "$static_rps" "${rps_core:-n/a}" "${rps_dollar:-n/a}" >> "$REPORT"
  else
    printf "| %s | %s | %s |\n" "$label" "$static_rps" "${rps_core:-n/a}" >> "$REPORT"
  fi
done <<< "$LABEL_DIRS"

{
  echo
  echo "### How to read this"
  echo
  echo "- **RPS up + CPU peak < ~85%** — the layer removed a software wall; there is more left."
  echo "- **RPS flat + one core pegged (max core ≈ 100%, softirq high)** — packet-steering ceiling; see \`tune-network-rps.sh\`."
  echo "- **RPS flat + TX Mbps ≈ line rate** — the NIC is the wall, not nginx; tune the payload mix or add bandwidth."
  echo "- **Listen drops > 0** — accept queue overflowed; connections were refused (Layer 1 backlogs)."
  echo "- **Retrans rising** — buffer/network pressure; check Layer 2 socket buffers before blaming nginx."
  echo "- **RPS/core and RPS per \$/hr** are the comparable numbers across tiers and against cloud VMs — the project's actual thesis."
  echo
  echo "_Hand-fill qualitative observations in results/REPORT-TEMPLATE.md._"
} >> "$REPORT"

echo "Report written to $REPORT"
echo
cat "$REPORT"
