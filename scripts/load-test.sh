#!/usr/bin/env bash
# Generate load against the TARGET node from the (separate, isolated) TESTER node.
# This runs ON THE TESTER — never on the target. No root required.
#
# Pair each run with, on the target, the matching scripts/snapshot.sh --label (box
# state, before load) AND scripts/monitor.sh --label (live CPU/mem/net sampling,
# DURING load). generate-report.sh merges all three halves by --label.
#
# Output: results/tier-<tier>/<label>/load/
# Copy this dir back to the target's results tree (scp) before generate-report.sh.
#
# Usage:
#   scripts/load-test.sh --target https://10.0.0.5 --label layer-3 --tier 2 --duration 30
#
# Connection profiles (--profile), which control how load hits SO_REUSEPORT (active
# from layer 3 on). reuseport pins each connection to one worker for its lifetime via
# a 4-tuple hash, so a small set of long-lived keepalive connections lands unevenly and
# leaves cores idle. The profiles below spread load across all workers/cores:
#   standard  400 keepalive conns. Few, long-lived — under-utilises cores with reuseport.
#   highconn  4000 keepalive conns. Many distinct source ports => the reuseport hash
#             spreads across all workers while keeping keepalive (measures nginx
#             efficiency, not connect overhead). Primary fix for the 50%-CPU plateau.
#   churn     1000 conns with "Connection: close" => a fresh TCP connection (new
#             4-tuple) per request, so reuseport re-hashes every request. Maximal
#             spread; also exercises the accept path / connection setup cost.
# --conns always overrides the profile's connection count.
set -euo pipefail

# ---- defaults ---------------------------------------------------------------
TARGET=""
LABEL="run"
TIER="1"
DURATION="30"
THREADS="12"
PROFILE="standard"
CONNS="400"
CONNS_SET="0"     # track whether the user overrode --conns explicitly
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
    --conns)    CONNS="$2"; CONNS_SET="1"; shift 2 ;;
    --profile)  PROFILE="$2"; shift 2 ;;
    --k6)       RUN_K6="1"; shift 1 ;;
    --api)      RUN_API="1"; shift 1 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ---- resolve connection profile ---------------------------------------------
# Each profile sets a default connection count (unless --conns was given) and,
# for churn, a "Connection: close" header that wrk applies to every request on
# both the static and UI stages (browse-ui.lua reuses wrk.headers).
WRK_EXTRA=()
case "$PROFILE" in
  standard) ;;
  highconn) [ "$CONNS_SET" = "0" ] && CONNS="4000" ;;
  churn)    [ "$CONNS_SET" = "0" ] && CONNS="1000"; WRK_EXTRA=(-H "Connection: close") ;;
  *) echo "ERROR: --profile must be standard|highconn|churn (got '$PROFILE')" >&2; exit 1 ;;
esac

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

# ---- tester FD limit ----------------------------------------------------------
# The tester needs one FD per wrk connection (plus threads and script/file
# overhead). The default soft limit of 1024 silently caps high-connection
# profiles: wrk reports thousands of 'connect' socket errors and the UI stage
# can fail outright with 'Too many open files'. Raise the soft limit up to the
# hard limit — no root needed; abort if the hard limit itself is too low.
FD_REQUIRED=$((CONNS + THREADS + 256))
FD_SOFT="$(ulimit -Sn)"
FD_HARD="$(ulimit -Hn)"
if [ "$FD_SOFT" != "unlimited" ] && [ "$FD_SOFT" -lt "$FD_REQUIRED" ]; then
  if [ "$FD_HARD" = "unlimited" ] || [ "$FD_HARD" -ge "$FD_REQUIRED" ]; then
    ulimit -Sn "$FD_REQUIRED"
    echo "Raised tester nofile soft limit ${FD_SOFT} -> ${FD_REQUIRED} (hard: ${FD_HARD})"
  else
    echo "ERROR: tester hard nofile limit ${FD_HARD} < required ${FD_REQUIRED} for ${CONNS} connections." >&2
    echo "Raise it on the tester (e.g. /etc/security/limits.d/) and re-login, or lower --conns." >&2
    exit 1
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

OUT_DIR="$ROOT_DIR/results/tier-${TIER}/${LABEL}/load"
mkdir -p "$OUT_DIR"

echo "Loading ${TARGET} as '${LABEL}' (tier ${TIER}) for ${DURATION}s (${THREADS}t/${CONNS}c, profile=${PROFILE})..."

# Record what produced this run so the report is self-describing.
{
  echo "target:   $TARGET"
  echo "label:    $LABEL"
  echo "tier:     $TIER"
  echo "duration: ${DURATION}s"
  echo "threads:  $THREADS"
  echo "conns:    $CONNS"
  echo "profile:  $PROFILE"
  echo "date:     $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "tester:   $(hostname 2>/dev/null || echo unknown)"
} > "$OUT_DIR/meta.txt"

# wrk speaks TLS via OpenSSL and does not verify the cert chain, so the self-signed
# lab certificate is accepted transparently — no extra flag needed.

# ---- 1. wrk: static root ----------------------------------------------------
wrk -t"${THREADS}" -c"${CONNS}" -d"${DURATION}s" --latency "${WRK_EXTRA[@]}" "${TARGET}/" \
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
UI_PATHS="$UI_PATHS" wrk -t"${THREADS}" -c"${CONNS}" -d"${DURATION}s" --latency "${WRK_EXTRA[@]}" \
  -s "$ROOT_DIR/benchmarks/wrk/browse-ui.lua" "${TARGET}" \
  > "$OUT_DIR/wrk-ui.txt" 2>&1 || true

# ---- 3. wrk: dynamic API (opt-in; measures the backend, not nginx) ----------
# Off by default: the API path goes nginx -> Axum -> lux, so it benchmarks the
# backend and pollutes the nginx layer-by-layer deltas. Enable with --api only
# when you specifically want a backend datapoint.
if [ "$RUN_API" = "1" ]; then
  wrk -t"${THREADS}" -c"${CONNS}" -d"${DURATION}s" --latency "${WRK_EXTRA[@]}" "${TARGET}/api/products" \
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
# Throughput (bandwidth) and error counts — RPS alone hides both. A "fast" run
# that returned errors or was NIC-bound tells a different story than raw RPS.
XFER="$(grep -E 'Transfer/sec' "$OUT_DIR/wrk-static.txt" | awk '{print $2}' | head -1)"
SOCK_ERRS="$(grep -E 'Socket errors' "$OUT_DIR/wrk-static.txt" \
  | awk -F'[ ,]+' '{s=0; for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) s+=$i; print s; exit}')"
NON2XX="$(grep -E 'Non-2xx or 3xx' "$OUT_DIR/wrk-static.txt" | awk '{print $NF}' | head -1)"
ERRS="sock:${SOCK_ERRS:-0} http:${NON2XX:-0}"
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
printf "  %-16s %s\n" "Transfer/sec:"    "${XFER:-n/a}"
printf "  %-16s %s\n" "Errors (static):" "$ERRS"
printf "  %-16s %s\n" "RPS (UI mix):"    "${UI_RPS:-n/a}"
printf "  %-16s %s\n" "p99 (UI mix):"    "${UI_P99:-n/a}"
if [ "$RUN_K6" = "1" ]; then
  printf "  %-16s %s\n" "k6 journey p95:" "${K6_P95:-n/a (see k6-browse.txt)}"
fi
printf "  %-16s %s\n" "Output:"          "$OUT_DIR"
echo
echo "  Pair with the target-side sampler for the same label (run DURING the load):"
echo "    # on target: scripts/monitor.sh --label ${LABEL} --tier ${TIER} --duration $((DURATION + 10))"
echo
echo "  Copy results back to the target, then build the report there:"
echo "    scp -r ${OUT_DIR} target:<repo>/results/tier-${TIER}/${LABEL}/"
echo "    # on target: scripts/generate-report.sh --tier ${TIER}"
echo "======================================================"
