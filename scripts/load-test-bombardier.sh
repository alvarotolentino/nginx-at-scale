#!/usr/bin/env bash
# Load test using bombardier + k6 — drop-in replacement for load-test.sh on testers
# that have bombardier but not wrk (e.g. Windows bash environments).
#
# Output filenames (wrk-static.txt, wrk-api.txt) match load-test.sh so
# generate-report.sh works without modification.
#
# Requires: bombardier  https://github.com/codesenberg/bombardier/releases
# Optional: k6          https://k6.io/docs/get-started/installation/
#
# Usage:
#   scripts/load-test-bombardier.sh --target http://192.168.1.54 --label baseline --tier 1
#   scripts/load-test-bombardier.sh --target http://192.168.1.54 --label layer-1 --tier 1 --duration 60
#   scripts/load-test-bombardier.sh --target http://192.168.1.54 --label baseline --tier 1 --api --k6
set -euo pipefail

# ---- defaults ---------------------------------------------------------------
TARGET=""
LABEL="run"
TIER="1"
DURATION="30"
PROFILE="standard"
CONNS="400"
CONNS_SET="0"     # track whether the user overrode --conns explicitly
RUN_API="0"
RUN_K6="0"

# ---- arg parsing ------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --target)   TARGET="$2";   shift 2 ;;
    --label)    LABEL="$2";    shift 2 ;;
    --tier)     TIER="$2";     shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --conns)    CONNS="$2"; CONNS_SET="1"; shift 2 ;;
    --profile)  PROFILE="$2";  shift 2 ;;
    --api)      RUN_API="1";   shift 1 ;;
    --k6)       RUN_K6="1";    shift 1 ;;
    --threads)  shift 2 ;;     # accepted but ignored — bombardier is goroutine-based
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$TARGET" ]; then
  echo "ERROR: --target is required (e.g. --target http://192.168.1.54)" >&2
  echo "Usage: scripts/load-test-bombardier.sh --target http://<ip> --label <label> --tier <n>" >&2
  exit 1
fi

# ---- resolve connection profile ---------------------------------------------
# Controls how load hits SO_REUSEPORT (active from layer 3 on). reuseport pins each
# connection to one worker for its lifetime via a 4-tuple hash, so a few long-lived
# keepalive connections land unevenly and leave cores idle (~50% CPU plateau).
#   standard  400 keepalive conns — few, long-lived; under-utilises cores.
#   highconn  4000 keepalive conns — many source ports spread the hash across all
#             workers while keeping keepalive. Primary fix for the CPU plateau.
#   churn     1000 conns + "Connection: close" — fresh connection (new 4-tuple) per
#             request, so reuseport re-hashes every request. Also stresses accept path.
# --conns overrides the profile's connection count. The churn header applies to the
# bombardier static/API stages; the k6 UI stage keeps keepalive.
BOMB_EXTRA=()
case "$PROFILE" in
  standard) ;;
  highconn) [ "$CONNS_SET" = "0" ] && CONNS="4000" ;;
  churn)    [ "$CONNS_SET" = "0" ] && CONNS="1000"; BOMB_EXTRA=(-H "Connection: close") ;;
  *) echo "ERROR: --profile must be standard|highconn|churn (got '$PROFILE')" >&2; exit 1 ;;
esac

if ! command -v bombardier >/dev/null 2>&1; then
  echo "ERROR: bombardier not found in PATH." >&2
  echo "Download from https://github.com/codesenberg/bombardier/releases" >&2
  echo "Windows: place bombardier.exe somewhere on PATH (e.g. C:\\Windows\\System32)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# On Windows/Git-Bash, MSYS translates POSIX paths (e.g. /@8 → C:/Program Files/Git/@8)
# when passing env vars to native .exe binaries. MSYS_NO_PATHCONV=1 suppresses that —
# but then the script path also won't be translated, so we pre-convert it with cygpath.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else echo "$1"; fi
}
OUT_DIR="$ROOT_DIR/results/tier-${TIER}/${LABEL}/load"
mkdir -p "$OUT_DIR"

echo "Loading ${TARGET} as '${LABEL}' (tier ${TIER}) for ${DURATION}s (${CONNS}c, profile=${PROFILE})..."

{
  echo "target:   $TARGET"
  echo "label:    $LABEL"
  echo "tier:     $TIER"
  echo "duration: ${DURATION}s"
  echo "conns:    $CONNS"
  echo "profile:  $PROFILE"
  echo "tool:     bombardier + k6"
  echo "date:     $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "tester:   $(hostname 2>/dev/null || echo unknown)"
} > "$OUT_DIR/meta.txt"

# Run bombardier and produce output compatible with generate-report.sh.
# -l          print full latency percentile table (50/75/90/95/99)
# --insecure  skip TLS cert verification (-k is an alias for the same flag)
# keep-alive is ON by default — no extra flag needed.
#
# generate-report.sh parse_rps() greps for "Requests/sec:"; bombardier emits
# "Reqs/sec" so we append a compat line. parse_p99() greps "^\s*99%" which
# bombardier already outputs correctly.
run_bombardier() {
  local url="$1" out="$2"
  bombardier -c "$CONNS" -d "${DURATION}s" -l --insecure "${BOMB_EXTRA[@]}" "$url" \
    > "$out" 2>&1 || true

  local rps
  rps="$(grep -E '^\s+Reqs/sec' "$out" | awk '{print $2}' | head -1)"
  [ -n "$rps" ] && printf "Requests/sec: %s\n" "$rps" >> "$out"
}

# ---- 1. Static root — primary nginx metric ----------------------------------
echo "  → bombardier: static /"
run_bombardier "${TARGET}/" "$OUT_DIR/wrk-static.txt"

# ---- 2. k6 UI mix — multi-path static load (replaces wrk + browse-ui.lua) --
# Discovers real asset hashes + a product id from the target at runtime so
# paths always match the current Vite build and DB seed. Falls back to SPA
# routes only. Routes weighted 8x over asset bundles (same logic as Lua script).
echo "  → k6: UI mix (static paths)"
ASSETS="$(curl -fsSL --insecure "${TARGET}/" 2>/dev/null \
  | grep -oE '/assets/[^"]+\.(js|css)' | sort -u \
  | sed 's/$/@1/' | paste -sd, - || true)"
SAMPLE_ID="$(curl -fsSL --insecure "${TARGET}/api/products" 2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" \
  2>/dev/null || true)"
UI_PATHS="/@8,/product/${SAMPLE_ID:-prod-001}@8,/cart@8${ASSETS:+,$ASSETS}"

if command -v k6 >/dev/null 2>&1; then
  MSYS_NO_PATHCONV=1 BASE_URL="$TARGET" UI_PATHS="$UI_PATHS" K6_VUS="$CONNS" K6_DURATION="${DURATION}s" \
    k6 run --insecure-skip-tls-verify \
    "$(native_path "$ROOT_DIR/benchmarks/k6/browse-ui.js")" \
    > "$OUT_DIR/k6-ui.txt" 2>&1 || true
else
  echo "k6 not found — UI mix skipped (install k6 to enable)" | tee "$OUT_DIR/k6-ui.txt"
fi

# ---- 3. API (opt-in) — measures backend, not nginx -------------------------
# Off by default: proxy path goes nginx → Axum → lux and skews layer deltas.
if [ "$RUN_API" = "1" ]; then
  echo "  → bombardier: API /api/products"
  run_bombardier "${TARGET}/api/products" "$OUT_DIR/wrk-api.txt"
fi

# ---- 4. k6 full user journey (opt-in) --------------------------------------
# The only scenario that exercises API calls the way a real browser does:
# GET / → GET /api/products → GET /api/products/<id>. Uses the ramp-up scenario
# defined in browse-products.js (~17 min). Enable only for soak/capacity testing.
if [ "$RUN_K6" = "1" ]; then
  if command -v k6 >/dev/null 2>&1; then
    echo "  → k6: full user journey (browse-products.js — ~17 min)"
    MSYS_NO_PATHCONV=1 BASE_URL="$TARGET" K6_MAX_VUS="$CONNS" \
      k6 run --insecure-skip-tls-verify \
      "$(native_path "$ROOT_DIR/benchmarks/k6/browse-products.js")" \
      > "$OUT_DIR/k6-browse.txt" 2>&1 || true
  else
    echo "k6 not found — full journey skipped" | tee "$OUT_DIR/k6-browse.txt"
  fi
fi

# ---- summary ----------------------------------------------------------------
RPS="$(grep -E 'Requests/sec' "$OUT_DIR/wrk-static.txt" | awk '{print $2}' | head -1)"
P99="$(grep -E '^\s*99%' "$OUT_DIR/wrk-static.txt" | awk '{print $2}' | head -1)"
UI_RPS="$(grep -E 'http_reqs' "$OUT_DIR/k6-ui.txt" 2>/dev/null \
  | grep -oE '[0-9]+\.[0-9]+/s' | head -1)"
UI_P99="$(grep -E 'http_req_duration' "$OUT_DIR/k6-ui.txt" 2>/dev/null \
  | grep -oE 'p\(99\)=[0-9.]+.?s' | head -1 | sed 's/p(99)=//')"
K6_P95="$(grep -E 'http_req_duration' "$OUT_DIR/k6-browse.txt" 2>/dev/null \
  | grep -oE 'p\(95\)=[0-9.]+.?s' | head -1 || true)"

echo
echo "==================== LOAD SUMMARY ===================="
printf "  %-18s %s\n" "Target:"           "$TARGET"
printf "  %-18s %s\n" "Label:"            "$LABEL"
printf "  %-18s %s\n" "RPS (static /):"   "${RPS:-n/a}"
printf "  %-18s %s\n" "p99 (static /):"   "${P99:-n/a}"
printf "  %-18s %s\n" "RPS (UI mix):"     "${UI_RPS:-n/a (k6 missing?)}"
printf "  %-18s %s\n" "p99 (UI mix):"     "${UI_P99:-n/a}"
if [ "$RUN_K6" = "1" ]; then
  printf "  %-18s %s\n" "k6 journey p95:"  "${K6_P95:-n/a (see k6-browse.txt)}"
fi
printf "  %-18s %s\n" "Output:"           "$OUT_DIR"
echo
echo "  Copy results back to the target, then build the report there:"
echo "    scp -r ${OUT_DIR} target:<repo>/results/tier-${TIER}/${LABEL}/"
echo "    # on target: scripts/generate-report.sh --tier ${TIER}"
echo "======================================================"
