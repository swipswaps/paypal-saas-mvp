#!/usr/bin/env bash
# verify_stack.sh — ensure backend is up (poll 60s), then run extended tests
(
set +e

BASE="${BASE_URL_LOCAL:-http://localhost:5000}"
BODY="/tmp/_vs_body_$$"
PASS=0; FAIL=0

trap 'rm -f "$BODY"' EXIT

echo "==> Container status:"
docker compose ps

echo ""
echo "==> Polling $BASE/health (up to 60s)"
UP=0
for i in $(seq 1 30); do
  CODE=$(curl -s -o "$BODY" -w '%{http_code}' "$BASE/health")
  echo "  probe $i: HTTP $CODE"
  if [ "$CODE" = "200" ]; then UP=1; break; fi
  sleep 2
done
if [ "$UP" -ne 1 ]; then
  echo ""
  echo "ERROR: $BASE/health still not reachable after 60s."
  echo ""
  echo "=== Container logs ==="
  docker compose logs --tail=50 web
  echo ""
  echo "=== Port check ==="
  ss -tlnp | grep ":${BASE##*:}" || echo "  nothing on ${BASE##*:}"
  exit 2
fi

echo ""
echo "==> Health payload:"
cat "$BODY"; echo ""

echo ""
echo "==> Brand in home page:"
curl -s "$BASE/" | grep -oE '<h1>[^<]+</h1>|<strong>[^<]+</strong>' | head -3

echo ""
echo "==> CORS:"
curl -s -i -H 'Origin: https://swipswaps.github.io' "$BASE/health" | grep -i 'access-control'

echo ""
echo "==> Running extended_test.sh (override BASE if needed):"
BASE_OVERRIDE="$BASE" bash extended_test.sh

echo ""
echo "==> /setup reachable:"
curl -s -o "$BODY" -w 'HTTP %{http_code}\n' "$BASE/setup"
grep -q 'Setup —' "$BODY" && echo "PASS  /setup renders" || echo "FAIL  /setup missing expected header"

echo ""
echo "DONE."
)
