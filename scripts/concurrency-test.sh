#!/usr/bin/env bash
# Connection-CONCURRENCY test — runs ON THE TESTER.
#
# Measures how many connections the target can HOLD open at once (its concurrency
# ceiling + memory-per-connection), which is a different question from RPS. Drives
# the Rust `conn-holder` (benchmarks/conn-holder), which opens N keepalive
# connections and holds them.
#
# The ceiling is usually the TESTER's ephemeral ports: one source IP reaches
# ~28-64k connections to a single target ip:port. `--setup-ips N` adds N secondary
# addresses to the tester NIC so the holder can spread connections across them and
# multiply the reachable count (N × ~50k).
#
# Pair with, on the TARGET, `scripts/monitor.sh` during the hold: its
# `tcp_inuse_peak` is the peak concurrent connections and `mem_used_peak_mb` ÷ that
# is memory-per-connection.
#
# Usage:
#   # 500k conns over TLS, spread across 16 tester source IPs 10.0.0.20..35:
#   sudo scripts/concurrency-test.sh --target 10.0.0.5 --port 443 \
#        --connections 500000 --rate 8000 --hold 60 \
#        --setup-ips 16 --ip-base 10.0.0. --ip-start 20 --iface eno1
#
#   # plain :80 (isolates the raw connection ceiling; no TLS handshake CPU):
#   sudo scripts/concurrency-test.sh --target 10.0.0.5 --port 80 --no-tls --connections 300000
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- defaults ---------------------------------------------------------------
TARGET=""; PORT="443"; TLS="auto"
CONNS="100000"; RATE="5000"; HOLD="60"; KEEPALIVE="50"
SETUP_IPS="0"; IP_BASE=""; IP_START="20"; IFACE=""
LABEL="concurrency"; TIER="1"; BUILD="0"

while [ $# -gt 0 ]; do
  case "$1" in
    --target)      TARGET="$2"; shift 2 ;;
    --port)        PORT="$2"; shift 2 ;;
    --tls)         TLS="1"; shift 1 ;;
    --no-tls)      TLS="0"; shift 1 ;;
    --connections) CONNS="$2"; shift 2 ;;
    --rate)        RATE="$2"; shift 2 ;;
    --hold)        HOLD="$2"; shift 2 ;;
    --keepalive)   KEEPALIVE="$2"; shift 2 ;;
    --setup-ips)   SETUP_IPS="$2"; shift 2 ;;
    --ip-base)     IP_BASE="$2"; shift 2 ;;
    --ip-start)    IP_START="$2"; shift 2 ;;
    --iface)       IFACE="$2"; shift 2 ;;
    --label)       LABEL="$2"; shift 2 ;;
    --tier)        TIER="$2"; shift 2 ;;
    --build)       BUILD="1"; shift 1 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[ -n "$TARGET" ] || { echo "ERROR: --target <ip> is required" >&2; exit 1; }
[ "$TLS" = "auto" ] && { [ "$PORT" = "443" ] && TLS="1" || TLS="0"; }

# ---- tester FD limit (one FD per held connection) ---------------------------
FD_NEED=$(( CONNS + 4096 ))
if [ "$(ulimit -Sn)" -lt "$FD_NEED" ]; then
  if ulimit -Sn "$FD_NEED" 2>/dev/null; then
    echo "Raised tester nofile soft limit to ${FD_NEED}"
  else
    echo "ERROR: need nofile >= ${FD_NEED} but hard limit is $(ulimit -Hn)." >&2
    echo "Raise it in /etc/security/limits.d/ on the tester and re-login." >&2
    exit 1
  fi
fi
# More source ports help even without extra IPs.
sysctl -w net.ipv4.ip_local_port_range="1024 65535" >/dev/null 2>&1 || true

# ---- optional: add secondary source IPs to spread ephemeral ports -----------
SRC_ARGS=()
CLEANUP_IPS=()
cleanup() {
  for ip in "${CLEANUP_IPS[@]}"; do
    ip addr del "${ip}/24" dev "$IFACE" 2>/dev/null || true
  done
}
if [ "$SETUP_IPS" -gt 0 ]; then
  [ -n "$IP_BASE" ] || { echo "ERROR: --setup-ips needs --ip-base (e.g. 10.0.0.)" >&2; exit 1; }
  [ -n "$IFACE" ]   || { echo "ERROR: --setup-ips needs --iface (e.g. eno1)" >&2; exit 1; }
  [ "$(id -u)" -eq 0 ] || { echo "ERROR: --setup-ips needs root (ip addr add)" >&2; exit 1; }
  echo "Adding ${SETUP_IPS} source IP(s) on ${IFACE}: ${IP_BASE}${IP_START}..$((IP_START+SETUP_IPS-1))"
  for i in $(seq "$IP_START" $((IP_START + SETUP_IPS - 1))); do
    ip="${IP_BASE}${i}"
    ip addr add "${ip}/24" dev "$IFACE" 2>/dev/null && CLEANUP_IPS+=("$ip") || true
    SRC_ARGS+=(--source-ip "$ip")
  done
  trap cleanup EXIT   # remove the addresses we added when the run ends
  echo "  → these addresses are removed automatically when the test finishes."
fi

# ---- build the holder if needed ---------------------------------------------
BIN="$ROOT_DIR/benchmarks/conn-holder/target/release/conn-holder"
if [ "$BUILD" = "1" ] || [ ! -x "$BIN" ]; then
  command -v cargo >/dev/null 2>&1 || { echo "ERROR: cargo not installed on the tester." >&2; exit 1; }
  echo "Building conn-holder (release)…"
  cargo build --release --manifest-path "$ROOT_DIR/benchmarks/conn-holder/Cargo.toml"
fi

# ---- run --------------------------------------------------------------------
OUT_DIR="$ROOT_DIR/results/tier-${TIER}/${LABEL}"
mkdir -p "$OUT_DIR"
TLS_FLAG=(); [ "$TLS" = "1" ] && TLS_FLAG=(--tls)

echo
echo "==> holding ${CONNS} connections to ${TARGET}:${PORT} (tls=${TLS}) for ${HOLD}s"
echo "    On the TARGET, run NOW (during the hold):"
echo "      scripts/monitor.sh --label ${LABEL} --tier ${TIER} --duration $(( CONNS / RATE + HOLD + 20 ))"
echo

"$BIN" \
  --target "${TARGET}:${PORT}" \
  --connections "$CONNS" --rate "$RATE" --hold "$HOLD" --keepalive "$KEEPALIVE" \
  "${TLS_FLAG[@]}" "${SRC_ARGS[@]}" --json \
  | tee "$OUT_DIR/conn-holder.txt"

echo
echo "Result: $OUT_DIR/conn-holder.txt"
echo "Concurrency ceiling = the TARGET's tcp_inuse_peak (scripts/monitor.sh summary)."
echo "Memory / connection  = mem_used_peak_mb ÷ tcp_inuse_peak, from the same summary."
