#!/usr/bin/env bash
# backend_test.sh — ensure backend is up, wait for readiness, run smoke suite
(
set +e

BASE="http://localhost:5000"
EMAIL="smoke_$(date +%s)@example.com"
PW="smoke_test_1234"
COOKIE="/tmp/smoke_cookies_$$"
BODY="/tmp/_smoke_body_$$"
HAS_DOCKER="/tmp/_has_docker_$$"
PASS=0; FAIL=0

trap 'rm -f "$COOKIE" "$BODY" "$HAS_DOCKER"' EXIT

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "PASS  $name"
    PASS=$((PASS+1))
  else
    echo "FAIL  $name (expected $expected, got $actual)"
    FAIL=$((FAIL+1))
  fi
}

probe() { curl -s -o "$BODY" -w '%{http_code}' "$BASE/health"; }

# --- ensure backend is up ---
CODE=$(probe)
if [ "$CODE" != "200" ]; then
  command -v docker > "$HAS_DOCKER" 2>&1
  if [ -s "$HAS_DOCKER" ] && [ -f docker-compose.yml ]; then
    echo "==> Backend not up. Starting: docker compose up -d --build"
    touch saas_shop.db
    docker compose up -d --build || { echo "ERROR: docker compose up failed"; exit 2; }
  else
    echo "ERROR: backend not running and docker compose unavailable."
    echo "       Start manually:"
    echo "         docker compose up -d --build"
    echo "       or:"
    echo "         . .venv/bin/activate && python app.py"
    exit 2
  fi
fi

# --- wait for readiness (up to 60s) ---
READY=0
for i in $(seq 1 30); do
  CODE=$(probe)
  echo "  probe $i: HTTP $CODE"
  if [ "$CODE" = "200" ]; then READY=1; break; fi
  sleep 2
done
if [ "$READY" -ne 1 ]; then echo "ERROR: /health never returned 200"; exit 2; fi

# --- suite ---
PRE=$(curl -s -o "$BODY" -w '%{http_code}' "$BASE/health")
check "health status" "200" "$PRE"
grep -q '"status":"healthy"' "$BODY" && { echo "PASS  health payload"; PASS=$((PASS+1)); } || { echo "FAIL  health payload"; FAIL=$((FAIL+1)); }

CODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$BASE/register" \
  -d "email=$EMAIL" -d "password=$PW")
check "register" "302" "$CODE"

CODE=$(curl -s -o "$BODY" -w '%{http_code}' -c "$COOKIE" -X POST "$BASE/login" \
  -d "email=$EMAIL" -d "password=$PW")
check "login" "302" "$CODE"

CODE=$(curl -s -o "$BODY" -w '%{http_code}' -b "$COOKIE" "$BASE/dashboard")
check "dashboard" "200" "$CODE"
grep -q 'free' "$BODY" && { echo "PASS  dashboard tier=free"; PASS=$((PASS+1)); } || { echo "FAIL  dashboard tier=free"; FAIL=$((FAIL+1)); }

CODE=$(curl -s -o "$BODY" -w '%{http_code}' -b "$COOKIE" "$BASE/premium")
check "premium gated" "200" "$CODE"
grep -qi 'upgrade required' "$BODY" && { echo "PASS  premium gate content"; PASS=$((PASS+1)); } || { echo "FAIL  premium gate content"; FAIL=$((FAIL+1)); }

CODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$BASE/webhook" \
  -H 'Content-Type: application/json' \
  -d '{"event_type":"BILLING.SUBSCRIPTION.ACTIVATED"}')
check "webhook rejects unsigned" "400" "$CODE"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 2
)
