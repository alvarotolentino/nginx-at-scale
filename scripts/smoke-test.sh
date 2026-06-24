#!/usr/bin/env bash
# Fast integration check before benchmarking. Two modes:
#
#   (default, on the TARGET)   scripts/smoke-test.sh
#       Verifies the systemd services are up and the app answers on loopback.
#
#   (from the TESTER)          scripts/smoke-test.sh --target https://<target-ip>
#       Verifies the target is reachable over the network and serves the app + API.
#
# Each check prints PASS or FAIL with a reason. Runs ALL checks even if some fail
# (note: -e is intentionally NOT set).
set -uo pipefail

TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

PASS=0
TOTAL=0

check() {
  # check "<name>" <0|1 result> "<reason>"
  local name="$1" ok="$2" reason="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$ok" -eq 0 ]; then
    echo "PASS  $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL  $name — $reason"
  fi
}

# json_nonempty_array: read stdin, exit 0 if it's a JSON array with length > 0.
json_nonempty_array() {
  python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d,list) and len(d)>0" 2>/dev/null
}

# =============================================================================
# TESTER mode — remote reachability only (no root, no local services).
# =============================================================================
if [ -n "$TARGET" ]; then
  # At baseline nginx only listens on :80 (no TLS until Layer 5). If the caller
  # passed https:// but the connection is refused, silently fall back to http://
  # so the smoke test works at every layer without changing the invocation.
  BASE_URL="$TARGET"
  if ! curl -fsSk --max-time 3 "${TARGET}/" >/dev/null 2>&1; then
    HTTP_FALLBACK="${TARGET/https:\/\//http://}"
    if curl -fsSL --max-time 3 "${HTTP_FALLBACK}/" >/dev/null 2>&1; then
      echo "Note: ${TARGET} unreachable, falling back to ${HTTP_FALLBACK} (TLS not yet active)"
      BASE_URL="$HTTP_FALLBACK"
    fi
  fi

  echo "Smoke-testing target ${BASE_URL} from the tester..."

  # 1. Static index reachable over the network (-k for the self-signed lab cert,
  #    -L to follow the :80 -> :443 redirect once TLS layers are applied).
  if curl -fsSL -k "${BASE_URL}/" 2>/dev/null | grep -qi "<html"; then
    check "remote static index" 0 ""
  else
    check "remote static index" 1 "GET ${BASE_URL}/ did not contain <html"
  fi

  # 2. API reachable and non-empty.
  if curl -fsSL -k "${BASE_URL}/api/products" 2>/dev/null | json_nonempty_array; then
    check "remote api products" 0 ""
  else
    check "remote api products" 1 "GET ${BASE_URL}/api/products not a non-empty JSON array"
  fi

  # 3. Backend port must NOT be exposed (it binds loopback; firewall drops it).
  TARGET_HOST="$(echo "$BASE_URL" | sed 's|https\?://||; s|/.*||; s|:.*||')"
  if curl -sf --connect-timeout 3 "http://${TARGET_HOST}:8080/health" >/dev/null 2>&1; then
    check "backend port closed" 1 "port 8080 answered remotely — it must be loopback-only!"
  else
    check "backend port closed" 0 ""
  fi

  # 4. wrk present on the tester (needed to actually load-test).
  if command -v wrk >/dev/null 2>&1; then
    check "wrk installed (tester)" 0 ""
  else
    check "wrk installed (tester)" 1 "wrk not in PATH"
  fi

  echo
  echo "${PASS}/${TOTAL} checks passed"
  [ "$PASS" -eq "$TOTAL" ] && exit 0 || exit 1
fi

# =============================================================================
# TARGET mode — systemd services + loopback app.
# =============================================================================
echo "Smoke-testing the target (loopback)..."

# 1. systemd services active.
for svc in lux backend nginx; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    check "service ${svc} active" 0 ""
  else
    check "service ${svc} active" 1 "systemctl is-active ${svc} != active"
  fi
done

# 2. Backend health on loopback.
if [ "$(curl -sf http://127.0.0.1:8080/health 2>/dev/null)" = "ok" ]; then
  check "backend /health" 0 ""
else
  check "backend /health" 1 "curl http://127.0.0.1:8080/health != 'ok'"
fi

# 3. Static index served through nginx (-k/-L to handle the TLS redirect).
if curl -fsSL -k http://127.0.0.1/ 2>/dev/null | grep -qi "<html"; then
  check "static index served" 0 ""
else
  check "static index served" 1 "GET / did not contain <html"
fi

# 4. API returns a non-empty product array.
if curl -fsSL -k http://127.0.0.1/api/products 2>/dev/null | json_nonempty_array; then
  check "api products non-empty" 0 ""
else
  check "api products non-empty" 1 "GET /api/products not a non-empty JSON array"
fi

# 5. A single product is fetchable (ids are UUIDs — derive a real one from the list).
FIRST_ID="$(curl -fsSL -k http://127.0.0.1/api/products 2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null)"
if [ -n "$FIRST_ID" ] && \
   curl -fsSL -k "http://127.0.0.1/api/products/${FIRST_ID}" 2>/dev/null \
     | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
  check "single product fetchable" 0 ""
else
  check "single product fetchable" 1 "GET /api/products/<id> failed"
fi

# 6. fd limit sufficient (Layer 1).
FILE_MAX="$(cat /proc/sys/fs/file-max 2>/dev/null || echo 0)"
if [ "$FILE_MAX" -gt 100000 ]; then
  check "fs.file-max > 100000" 0 ""
else
  check "fs.file-max > 100000" 1 "fs.file-max=$FILE_MAX (apply Layer 1)"
fi

echo
echo "${PASS}/${TOTAL} checks passed"
[ "$PASS" -eq "$TOTAL" ] && exit 0 || exit 1
