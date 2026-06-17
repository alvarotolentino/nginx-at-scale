#!/usr/bin/env bash
# Orchestrate a full end-to-end benchmark sweep across all optimization layers.
#
# Usage:
#   scripts/run-all-layers.sh --tier 1 --from 0 --to 8
set -euo pipefail

TIER="1"
FROM="0"   # 0 = baseline
TO="8"

while [ $# -gt 0 ]; do
  case "$1" in
    --tier) TIER="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --to)   TO="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

# 1. Smoke test — abort the whole sweep if the stack isn't healthy.
log_step "Pre-flight smoke test"
if ! "$SCRIPT_DIR/smoke-test.sh"; then
  echo "ERROR: smoke test failed — fix the stack before benchmarking" >&2
  exit 1
fi

# 2. Reset to a clean baseline.
log_step "Resetting to baseline"
"$SCRIPT_DIR/reset-baseline.sh"

# 3. Baseline measurement (only if starting from 0).
if [ "$FROM" -le 0 ]; then
  log_step "Measuring baseline"
  "$SCRIPT_DIR/measure.sh" --label baseline --tier "$TIER"
fi

# 4. Walk the layers. Layer 6 has no apply script (folded into Layer 5 config), so
#    we skip it gracefully if the file is absent.
start=$FROM
[ "$start" -lt 1 ] && start=1
for N in $(seq "$start" "$TO"); do
  apply="$SCRIPT_DIR/apply-layer-${N}.sh"
  if [ ! -x "$apply" ] && [ ! -f "$apply" ]; then
    log_warn "No apply-layer-${N}.sh (e.g. Layer 6 is config-only) — skipping"
    continue
  fi
  log_step "Applying layer ${N}"
  bash "$apply" || log_warn "layer ${N} apply returned non-zero (continuing)"

  # measure.sh is already called inside each apply-layer script with its own label,
  # but re-measure here with the tier flag so results land under the right tier dir.
  "$SCRIPT_DIR/measure.sh" --label "layer-${N}" --tier "$TIER"

  log_step "Settling 5s before next layer"
  sleep 5
done

# 5. Aggregate the report.
log_step "Generating report"
"$SCRIPT_DIR/generate-report.sh" --tier "$TIER"

log_ok "Full run complete. Report at: results/tier-${TIER}/REPORT.md"
