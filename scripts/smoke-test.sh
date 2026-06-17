#!/usr/bin/env bash
# Fast integration check that every component is wired up before benchmarking.
# Each check prints PASS or FAIL with a reason. Runs ALL checks even if some fail
# (note: -e is intentionally NOT set).
set -uo pipefail

PASS=0
TOTAL=8

check() {
  # check "<name>" <0|1 result> "<reason>"
  local name="$1" ok="$2" reason="$3"
  if [ "$ok" -eq 0 ]; then
    echo "PASS  $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL  $name — $reason"
  fi
}

# 1. Nginx running
if pidof nginx >/dev/null 2>&1; then
  check "nginx running" 0 ""
else
  check "nginx running" 1 "pidof nginx found nothing"
fi

# 2. Backend health
if [ "$(curl -sf http://localhost:8080/health 2>/dev/null)" = "ok" ]; then
  check "backend /health" 0 ""
else
  check "backend /health" 1 "curl http://localhost:8080/health != 'ok'"
fi

# 3. Static files served
if curl -sf http://localhost/ 2>/dev/null | grep -qi "<html"; then
  check "static index served" 0 ""
else
  check "static index served" 1 "GET / did not contain <html"
fi

# 4. API returns a non-empty product array
if curl -sf http://localhost/api/products 2>/dev/null \
     | python3 -c "import json,sys; d=json.load(sys.stdin); assert len(d)>0" 2>/dev/null; then
  check "api products non-empty" 0 ""
else
  check "api products non-empty" 1 "GET /api/products not a JSON array with length>0"
fi

# 5. A single product is fetchable. The seeded ids are UUIDs, so derive a real id
#    from the list rather than assuming "prod-001".
FIRST_ID="$(curl -sf http://localhost/api/products 2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null)"
if [ -n "$FIRST_ID" ] && \
   curl -sf "http://localhost/api/products/${FIRST_ID}" 2>/dev/null \
     | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
  check "single product fetchable" 0 ""
else
  check "single product fetchable" 1 "GET /api/products/<id> failed"
fi

# 6. wrk installed
if command -v wrk >/dev/null 2>&1; then
  check "wrk installed" 0 ""
else
  check "wrk installed" 1 "wrk not in PATH"
fi

# 7. k6 installed
if command -v k6 >/dev/null 2>&1; then
  check "k6 installed" 0 ""
else
  check "k6 installed" 1 "k6 not in PATH"
fi

# 8. fd limit sufficient
FILE_MAX="$(cat /proc/sys/fs/file-max 2>/dev/null || echo 0)"
if [ "$FILE_MAX" -gt 100000 ]; then
  check "fs.file-max > 100000" 0 ""
else
  check "fs.file-max > 100000" 1 "fs.file-max=$FILE_MAX (apply Layer 1)"
fi

echo
echo "${PASS}/${TOTAL} checks passed"
[ "$PASS" -eq "$TOTAL" ] && exit 0 || exit 1
