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
RUN_API="0"   # API path stresses the backend, not nginx; off by default

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
    --api)      RUN_API="1"; shift 1 ;;
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

# ---- 2. wrk: UI browse (multiple real static paths) -------------------------
# The headline metric for the "1B concurrent in nginx" goal: a browser-like mix
# of the SPA routes (/, /product/<id>, /cart — all resolve to index.html via
# try_files) plus the hashed JS/CSS bundles. Everything here is served by nginx
# directly — no backend involved (wrk does not run JS, so the SPA's API calls
# never fire). Discover the real asset hashes and a real product id from the
# target so the paths match the current Vite build and DB seed.
#
# Routes are weighted 8x over assets (path@N syntax) so the mix measures nginx
# connection concurrency rather than being dominated by the ~140 KB vendor bundle
# (an even round-robin would make 1-in-6 requests a big transfer and turn this
# into a bandwidth test instead of a concurrency test).
ASSETS="$(curl -fsSL -k "${TARGET}/" 2>/dev/null \
  | grep -oE '/assets/[^"]+\.(js|css)' | sort -u | sed 's/$/@1/' | paste -sd, -)"
SAMPLE_ID="$(curl -fsSL -k "${TARGET}/api/products" 2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null)"
UI_PATHS="/@8,/product/${SAMPLE_ID:-prod-001}@8,/cart@8${ASSETS:+,$ASSETS}"
UI_PATHS="$UI_PATHS" wrk -t"${THREADS}" -c"${CONNS}" -d"${DURATION}s" --latency \
  -s "$ROOT_DIR/benchmarks/wrk/browse-ui.lua" "${TARGET}" \
  > "$OUT_DIR/wrk-ui.txt" 2>&1 || true

# ---- 3. wrk: dynamic API (opt-in; measures the backend, not nginx) ----------
# Off by default: the API path goes nginx -> Axum -> lux, so it benchmarks the
# backend and pollutes the nginx layer-by-layer deltas. Enable with --api only
# when you specifically want a backend datapoint.
if [ "$RUN_API" = "1" ]; then
  wrk -t"${THREADS}" -c"${CONNS}" -d"${DURATION}s" --latency "${TARGET}/api/products" \
    > "$OUT_DIR/wrk-api.txt" 2>&1 || true
fi

# ---- 4. optional k6 user-journey (browser-accurate: static + API chain) -----
# The only scenario that exercises the SPA's API calls the way a real browser
# does: GET / -> GET /api/products -> GET /api/products/<real id from the list>.
# wrk can't do this (it doesn't run JS), so k6 is how you measure the full
# product-list + product-detail journey, including the backend. Enable with --k6.
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
UI_RPS="$(grep -E 'Requests/sec' "$OUT_DIR/wrk-ui.txt" 2>/dev/null | awk '{print $2}' | head -1)"
UI_P99="$(grep -E '^\s*99%' "$OUT_DIR/wrk-ui.txt" 2>/dev/null | awk '{print $2}' | head -1)"
# k6 journey: pull the http_req_duration p95 line if a k6 run happened.
K6_P95="$(grep -E 'http_req_duration' "$OUT_DIR/k6-browse.txt" 2>/dev/null \
  | grep -oE 'p\(95\)=[0-9.]+m?s' | head -1)"

echo
echo "==================== LOAD SUMMARY ===================="
printf "  %-16s %s\n" "Target:"          "$TARGET"
printf "  %-16s %s\n" "Label:"           "$LABEL"
printf "  %-16s %s\n" "RPS (static /):"  "${RPS:-n/a}"
printf "  %-16s %s\n" "p99 (static /):"  "${P99:-n/a}"
printf "  %-16s %s\n" "RPS (UI mix):"    "${UI_RPS:-n/a}"
printf "  %-16s %s\n" "p99 (UI mix):"    "${UI_P99:-n/a}"
if [ "$RUN_K6" = "1" ]; then
  printf "  %-16s %s\n" "k6 journey p95:" "${K6_P95:-n/a (see k6-browse.txt)}"
fi
printf "  %-16s %s\n" "Output:"          "$OUT_DIR"
echo
echo "  Copy results back to the target, then build the report there:"
echo "    scp -r ${OUT_DIR} target:<repo>/results/tier-${TIER}/${LABEL}/"
echo "    # on target: scripts/generate-report.sh --tier ${TIER}"
echo "======================================================"
