#!/usr/bin/env bash
# Orchestrate a full layer sweep ON THE TARGET node (bare metal).
#
# This applies baseline -> layer 8, snapshotting the target state after each. It does
# NOT generate load — that runs from the separate tester node. Between layers it pauses
# (unless --no-pause) and prints the exact load-test.sh command to run from the tester,
# so the manual two-step stays in lock-step:
#
#   TARGET:  sudo scripts/apply-all-layers.sh --tier 2
#   TESTER:  scripts/load-test.sh --target https://<target-ip> --label <layer> --tier 2
#
# After every layer's load run, copy the tester's results back and build the report:
#   scripts/generate-report.sh --tier 2
#
# Usage:
#   scripts/apply-all-layers.sh --tier 1 --from 0 --to 8 [--no-pause]
set -euo pipefail

TIER="1"
FROM="0"   # 0 = baseline
TO="8"
PAUSE="1"

while [ $# -gt 0 ]; do
  case "$1" in
    --tier)     TIER="$2"; shift 2 ;;
    --from)     FROM="$2"; shift 2 ;;
    --to)       TO="$2"; shift 2 ;;
    --no-pause) PAUSE="0"; shift 1 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

require_root

# Prompt the operator to run the matching load test from the tester before moving on.
# While waiting, monitor.sh samples this box's CPU/mem/net/sockets so the report can
# show what the load COST the target, not just what the tester measured. The sampler
# is stopped (and its summary written) when the operator presses ENTER.
prompt_load() {
  local label="$1" mon_pid=""
  echo
  echo "  >>> From the TESTER node, generate load for '${label}' now:"
  echo "        scripts/load-test.sh --target https://<target-ip> --label ${label} --tier ${TIER}"
  echo "      Add --k6 to also capture the browser-accurate API journey"
  echo "      (GET / -> /api/products -> /api/products/<id>); add --api for a raw backend datapoint."
  if [ "$PAUSE" = "1" ]; then
    "$SCRIPT_DIR/monitor.sh" --label "$label" --tier "$TIER" &
    mon_pid=$!
    echo "      (target-side monitor is sampling as pid ${mon_pid} — CPU/mem/net land in"
    echo "       results/tier-${TIER}/${label}/monitor/ when you press ENTER)"
    read -rp "  Press ENTER once the tester load run for '${label}' has finished... " _
    kill -TERM "$mon_pid" 2>/dev/null || true
    wait "$mon_pid" 2>/dev/null || true
  else
    echo "      (--no-pause: not sampling — run scripts/monitor.sh manually during load)"
  fi
}

# 1. Smoke test — abort the whole sweep if the stack isn't healthy.
log_step "Pre-flight smoke test (target-side)"
if ! "$SCRIPT_DIR/smoke-test.sh"; then
  echo "ERROR: smoke test failed — fix the stack before benchmarking" >&2
  exit 1
fi

# 2. Reset to a clean baseline.
log_step "Resetting to baseline"
"$SCRIPT_DIR/reset-baseline.sh"

# 3. Baseline snapshot (only if starting from 0).
if [ "$FROM" -le 0 ]; then
  log_step "Applying + snapshotting baseline"
  "$SCRIPT_DIR/apply-baseline.sh"
  prompt_load "baseline"
fi

# 4. Walk the layers. Every layer 1..8 has an apply-layer-N.sh; if one is absent
#    (e.g. a custom build dropped it), skip it gracefully instead of aborting.
start=$FROM
[ "$start" -lt 1 ] && start=1
for N in $(seq "$start" "$TO"); do
  apply="$SCRIPT_DIR/apply-layer-${N}.sh"
  if [ ! -f "$apply" ]; then
    log_warn "No apply-layer-${N}.sh (e.g. Layer 6 is config-only) — skipping"
    continue
  fi
  log_step "Applying layer ${N}"
  bash "$apply" || log_warn "layer ${N} apply returned non-zero (continuing)"
  prompt_load "layer-${N}"

  log_step "Settling 5s before next layer"
  sleep 5
done

# 5. Aggregate the report (merges snapshot/ + any load/ dirs scp'd back from the tester).
log_step "Generating report"
"$SCRIPT_DIR/generate-report.sh" --tier "$TIER"

log_ok "Full sweep complete. Report at: results/tier-${TIER}/REPORT.md"
