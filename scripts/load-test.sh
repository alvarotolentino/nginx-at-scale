#!/usr/bin/env bash
# Generate load against the TARGET node from the (separate, isolated) TESTER node.
# This runs ON THE TESTER — never on the target. No root required.
#
# Pair each run with the matching scripts/snapshot.sh --label on the target so the
# report can merge "what state the box was in" (snapshot) with "how it performed"
# (load) by --label.
#
# Output: results/tier-<tier>/<label>/load/
# Copy this dir back to the target's results tree (scp) before generate-report.sh.
#
# Usage:
#   scripts/load-test.sh --target https://10.0.0.5 --label layer-3 --tier 2 --duration 30
set -euo pipefail

# ---- defaults ---------------------------------------------------------------
TARGET=""
LABEL="run"
TIER="1"
DURATION="30"
THREADS="12"
CONNS="400"
RUN_K6="0"

# ---- arg parsing ------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --target)   TARGET="$2"; shift 2 ;;
    --label)    LABEL="$2"; shift 2 ;;
    --tier)     TIER="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --threads)  THREADS="$2"; shift 2 ;;
    --conns)    CONNS="$2"; shift 2 ;;
    --k6)       RUN_K6="1"; shift 1 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$TARGET" ]; then
  echo "ERROR: --target is required (e.g. --target https://10.0.0.5)" >&2
  echo "Usage: scripts/load-test.sh --target https://<ip> --label <label> --tier <n>" >&2
  exit 1
fi

# ---- dependency check -------------------------------------------------------
if ! command -v wrk >/dev/null 2>&1; then
  echo "ERROR: wrk not installed on the tester. See docs/sections/00-prerequisites.md" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

OUT_DIR="$ROOT_DIR/results/tier-${TIER}/${LABEL}/load"
mkdir -p "$OUT_DIR"

echo "Loading ${TARGET} as '${LABEL}' (tier ${TIER}) for ${DURATION}s (${THREADS}t/${CONNS}c)..."

# Record what produced this run so the report is self-describing.
{
  echo "target:   $TARGET"
  echo "label:    $LABEL"
  echo "tier:     $TIER"
  echo "duration: ${DURATION}s"
  echo "threads:  $THREADS"
  echo "conns:    $CONNS"
  echo "date:     $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "tester:   $(hostname 2>/dev/null || echo unknown)"
} > "$OUT_DIR/meta.txt"

# wrk speaks TLS via OpenSSL and does not verify the cert chain, so the self-signed
# lab certificate is accepted transparently — no extra flag needed.

# ---- 1. wrk: static root ----------------------------------------------------
wrk -t"${THREADS}" -c"${CONNS}" -d"${DURATION}s" --latency "${TARGET}/" \
  > "$OUT_DIR/wrk-static.txt" 2>&1 || true

# ---- 2. wrk: dynamic API ----------------------------------------------------
wrk -t"${THREADS}" -c"${CONNS}" -d"${DURATION}s" --latency "${TARGET}/api/products" \
  > "$OUT_DIR/wrk-api.txt" 2>&1 || true

# ---- 3. optional k6 concurrency ramp ---------------------------------------
if [ "$RUN_K6" = "1" ]; then
  if command -v k6 >/dev/null 2>&1; then
    # --insecure-skip-tls-verify so k6 accepts the self-signed lab cert.
    BASE_URL="$TARGET" k6 run --insecure-skip-tls-verify \
      "$ROOT_DIR/benchmarks/k6/browse-products.js" \
      > "$OUT_DIR/k6-browse.txt" 2>&1 || true
  else
    echo "k6 not installed — skipping k6 scenario" | tee "$OUT_DIR/k6-browse.txt"
  fi
fi

# ---- summary ----------------------------------------------------------------
RPS="$(grep -E 'Requests/sec' "$OUT_DIR/wrk-static.txt" | awk '{print $2}' | head -1)"
P99="$(grep -E '^\s*99%' "$OUT_DIR/wrk-static.txt" | awk '{print $2}' | head -1)"

echo
echo "==================== LOAD SUMMARY ===================="
printf "  %-14s %s\n" "Target:"       "$TARGET"
printf "  %-14s %s\n" "Label:"        "$LABEL"
printf "  %-14s %s\n" "RPS (static):" "${RPS:-n/a}"
printf "  %-14s %s\n" "p99 latency:"  "${P99:-n/a}"
printf "  %-14s %s\n" "Output:"       "$OUT_DIR"
echo
echo "  Copy results back to the target, then build the report there:"
echo "    scp -r ${OUT_DIR} target:<repo>/results/tier-${TIER}/${LABEL}/"
echo "    # on target: scripts/generate-report.sh --tier ${TIER}"
echo "======================================================"
