#!/usr/bin/env bash
# Post-Layer-7 nginx opt-in tunings (N1/N3/N4). Patches the LIVE /etc/nginx/nginx.conf
# (the Layer-7 config already installed on the target), validates, hot-reloads, and
# snapshots. One flag at a time so each is snapshot + load-tested in isolation.
#
#   --brotli          N1  brotli_static on (precompressed .br) — needs build-brotli-module.sh first.
#                         Attacks the UI NIC-line-rate wall: fewer bytes/response.
#                         Measure with the tester's `load-test.sh --brotli`.
#   --tickets         N3  ssl_session_tickets on — stateless resumption, no shared-cache
#                         lock. Shows only on the COLD-connection phase (churn profile).
#   --ssl-buffer SZ   N4  ssl_buffer_size SZ (e.g. 4k) vs default 16k. Small; p99 on static.
#   --revert          undo all of the above, restore the pre-tuning backup.
#
# Usage:
#   sudo scripts/build-brotli-module.sh        # once, if using --brotli
#   sudo scripts/apply-tune-nginx.sh --brotli
#   sudo scripts/snapshot.sh --label l7-n1-brotli
#   # ...run the trio from the tester (add --brotli for the N1 case)...
#
# NOTE: re-running apply-layer-7.sh reinstalls the stock L7 config and drops these.
# Re-apply this script afterwards.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
require_root

CONF="/etc/nginx/nginx.conf"
BACKUP="/etc/nginx/nginx.conf.pre-l7tune"
MOD_DIR="$(nginx -V 2>&1 | sed -n 's|.*--modules-path=\([^ ]*\).*|\1|p')"; MOD_DIR="${MOD_DIR:-/usr/lib/nginx/modules}"

DO_BROTLI=0 DO_TICKETS=0 DO_SSLBUF=0 DO_REVERT=0 SSLBUF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --brotli)     DO_BROTLI=1; shift 1 ;;
    --tickets)    DO_TICKETS=1; shift 1 ;;
    --ssl-buffer) DO_SSLBUF=1; SSLBUF="$2"; shift 2 ;;
    --revert)     DO_REVERT=1; shift 1 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[ -f "$CONF" ] || { echo "ERROR: $CONF not found (is Layer 7 applied?)." >&2; exit 1; }

if [ "$DO_REVERT" -eq 1 ]; then
  if [ -f "$BACKUP" ]; then
    cp "$BACKUP" "$CONF"
    nginx_reload && log_ok "Reverted to pre-tuning config ($BACKUP)."
  else
    log_warn "No backup at $BACKUP — nothing to revert."
  fi
  exit 0
fi

if [ $((DO_BROTLI+DO_TICKETS+DO_SSLBUF)) -eq 0 ]; then
  echo "No tuning selected. Pass one of: --brotli | --tickets | --ssl-buffer <size> (or --revert)." >&2
  exit 1
fi

# One-time backup of the clean L7 config so --revert is exact.
[ -f "$BACKUP" ] || { cp "$CONF" "$BACKUP"; log_ok "Backed up L7 config -> $BACKUP"; }

# ---- N1: brotli_static ------------------------------------------------------
if [ "$DO_BROTLI" -eq 1 ]; then
  if [ ! -f "${MOD_DIR}/ngx_http_brotli_static_module.so" ]; then
    echo "ERROR: brotli module missing in ${MOD_DIR}. Run: sudo scripts/build-brotli-module.sh" >&2
    exit 1
  fi
  # load_module must be at the very top (main context), before `events`. Static module
  # only — N1 serves precompressed .br, so the runtime filter module isn't needed.
  if ! grep -q 'ngx_http_brotli_static_module.so' "$CONF"; then
    sed -i "1i load_module ${MOD_DIR}/ngx_http_brotli_static_module.so;" "$CONF"
  fi
  # SCOPE brotli_static to /assets/ ONLY. A GLOBAL brotli_static makes nginx stat a
  # missing <file>.br on every request to '/' (index.html has no .br) — MEASURED warm-h2
  # -14% for zero benefit there. The .br payoff is entirely in /assets/ (the JS/CSS
  # bundles), which is also where the UI-mix bytes live (MEASURED UI +128%). So enable
  # it where the .br files are, nowhere else.
  #
  # 1) neutralize any stray GLOBAL brotli_static from an earlier (unscoped) run.
  sed -i 's|^\(\s*\)brotli_static on;.*|\1# brotli_static on;  # (disabled: scoped to /assets/ below)|' "$CONF"
  # 2) drop any previously-inserted scoped block, then re-insert fresh (idempotent).
  sed -i '/# >>> n1-brotli-assets/,/# <<< n1-brotli-assets/d' "$CONF"
  awk '
    !done && /^[[:space:]]*location \/ \{/ {
      print "        # >>> n1-brotli-assets (N1: precompressed .br, assets only) >>>"
      print "        location /assets/ {"
      print "            brotli_static on;"
      print "            gzip_static on;"
      print "        }"
      print "        # <<< n1-brotli-assets <<<"
      done=1
    }
    { print }
  ' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
  grep -q 'location /assets/' "$CONF" \
    && log_ok "N1: brotli_static scoped to location /assets/ (tester sends Accept-Encoding: br via load-test.sh --brotli)" \
    || log_warn "N1: could not find 'location / {' to anchor the /assets/ block — check $CONF"
fi

# ---- N3: TLS session tickets ------------------------------------------------
if [ "$DO_TICKETS" -eq 1 ]; then
  if grep -qE '^\s*ssl_session_tickets\s+off;' "$CONF"; then
    sed -i 's|^\(\s*\)ssl_session_tickets\s\+off;.*|\1ssl_session_tickets on;   # N3: stateless resumption (benchmark profile)|' "$CONF"
  elif ! grep -qE '^\s*ssl_session_tickets\s+on;' "$CONF"; then
    log_warn "N3: no ssl_session_tickets directive found to flip — check $CONF manually."
  fi
  log_ok "N3: ssl_session_tickets on (measure the churn/cold-connection profile; production needs key rotation)"
fi

# ---- N4: ssl_buffer_size ----------------------------------------------------
if [ "$DO_SSLBUF" -eq 1 ]; then
  [ -n "$SSLBUF" ] || { echo "ERROR: --ssl-buffer needs a size (e.g. 4k)." >&2; exit 1; }
  if grep -qE '^\s*ssl_buffer_size\s' "$CONF"; then
    sed -i "s|^\(\s*\)ssl_buffer_size\s.*|\1ssl_buffer_size ${SSLBUF};   # N4|" "$CONF"
  else
    # Insert after the first ssl_session_tickets line (http context, near TLS block).
    sed -i "0,/^\s*ssl_session_tickets/s||    ssl_buffer_size ${SSLBUF};   # N4\n&|" "$CONF"
  fi
  log_ok "N4: ssl_buffer_size ${SSLBUF} (compare vs default 16k on static p99)"
fi

nginx_reload && log_ok "nginx reloaded. Now: sudo scripts/snapshot.sh --label <this-item>, then run the trio."
