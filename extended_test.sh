#!/usr/bin/env bash
# extended_test.sh — route/error/DB coverage without PayPal credentials
(
set +e

BASE="http://localhost:5000"
TS=$(date +%s)
EMAIL="ext_${TS}@example.com"
PW="ext_test_1234"
COOKIE="/tmp/ext_cookies_$$"
BODY="/tmp/_ext_body_$$"
PASS=0; FAIL=0; SKIP=0

trap 'rm -f "$COOKIE" "$BODY"' EXIT

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then echo "PASS  $name"; PASS=$((PASS+1))
  else echo "FAIL  $name (expected $expected, got $actual)"; FAIL=$((FAIL+1)); fi
}
gcheck() {
  local name="$1" pattern="$2" file="$3"
  if grep -q "$pattern" "$file"; then echo "PASS  $name"; PASS=$((PASS+1))
  else echo "FAIL  $name"; FAIL=$((FAIL+1)); fi
}
skip() { echo "SKIP  $1 ($2)"; SKIP=$((SKIP+1)); }

CODE=$(curl -s -o "$BODY" -w '%{http_code}' "$BASE/health")
if [ "$CODE" != "200" ]; then
  echo "ERROR: backend not running at $BASE (probe=$CODE)."
  echo "       Run: docker compose up -d --build"
  exit 2
fi

# ---- public pages ----
CODE=$(curl -s -o "$BODY" -w '%{http_code}' "$BASE/");           check "GET /" "200" "$CODE"
gcheck "/ contains title" "Demo SaaS" "$BODY"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' "$BASE/login");      check "GET /login" "200" "$CODE"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' "$BASE/register");   check "GET /register" "200" "$CODE"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' "$BASE/events");     check "GET /events" "200" "$CODE"

# ---- unauthenticated access ----
CODE=$(curl -s -o "$BODY" -w '%{http_code}' "$BASE/dashboard")
check "GET /dashboard unauth -> 302" "302" "$CODE"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' "$BASE/premium")
check "GET /premium unauth -> 200 upgrade page" "200" "$CODE"
gcheck "/premium shows upgrade" "Upgrade required" "$BODY"

# ---- register ----
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$BASE/register" -d "email=$EMAIL" -d "password=$PW")
check "register new user" "302" "$CODE"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$BASE/register" -d "email=$EMAIL" -d "password=$PW")
check "register duplicate -> 200" "200" "$CODE"
gcheck "duplicate error message" "already registered" "$BODY"

# ---- login ----
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$BASE/login" -d "email=$EMAIL" -d "password=wrong")
check "login wrong pw -> 200" "200" "$CODE"
gcheck "login error message" "Invalid credentials" "$BODY"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -c "$COOKIE" -X POST "$BASE/login" -d "email=$EMAIL" -d "password=$PW")
check "login correct -> 302" "302" "$CODE"

# ---- authed pages ----
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -b "$COOKIE" "$BASE/dashboard")
check "dashboard authed -> 200" "200" "$CODE"
gcheck "dashboard shows email" "$EMAIL" "$BODY"
gcheck "dashboard shows free tier" "free" "$BODY"

# ---- subscribe without PLAN_ID ----
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -b "$COOKIE" "$BASE/subscribe/basic")
if grep -q "PLAN_ID not configured" "$BODY"; then
  echo "PASS  subscribe without PLAN_ID -> 500 with guidance"; PASS=$((PASS+1))
elif [ "$CODE" = "302" ]; then
  echo "PASS  subscribe redirects to PayPal (PLAN_ID set)"; PASS=$((PASS+1))
else
  echo "FAIL  subscribe (expected 500 guidance or 302, got $CODE)"; FAIL=$((FAIL+1))
fi

# ---- cancel without subscription ----
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -b "$COOKIE" "$BASE/cancel-subscription")
check "cancel without sub -> 302" "302" "$CODE"

# ---- logout (save invalidating Set-Cookie into the jar) ----
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -b "$COOKIE" -c "$COOKIE" "$BASE/logout")
check "logout -> 302" "302" "$CODE"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -b "$COOKIE" "$BASE/dashboard")
check "dashboard after logout -> 302" "302" "$CODE"

# ---- webhook: unsigned, malformed, forged headers ----
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$BASE/webhook" -H 'Content-Type: application/json' -d '{}')
check "webhook empty -> 400" "400" "$CODE"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$BASE/webhook" -H 'Content-Type: application/json' -d 'not-json')
check "webhook malformed -> 400" "400" "$CODE"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$BASE/webhook" \
  -H 'Content-Type: application/json' \
  -H 'PAYPAL-TRANSMISSION-ID: fake' \
  -H 'PAYPAL-TRANSMISSION-TIME: 2026-01-01T00:00:00Z' \
  -H 'PAYPAL-CERT-URL: https://example.invalid/cert.pem' \
  -H 'PAYPAL-TRANSMISSION-SIG: deadbeef' \
  -d '{"event_type":"BILLING.SUBSCRIPTION.ACTIVATED","resource":{}}')
check "webhook forged sig -> 400" "400" "$CODE"

# ---- DB invariants ----
WAL=""
if command -v sqlite3 > /tmp/_has_sqlite3_$$ 2>&1 && [ -s /tmp/_has_sqlite3_$$ ]; then
  WAL=$(sqlite3 saas_shop.db "PRAGMA journal_mode;" 2>&1)
fi
rm -f /tmp/_has_sqlite3_$$
if [ -n "$WAL" ]; then
  check "sqlite WAL mode" "wal" "$WAL"
else
  skip "sqlite WAL mode" "sqlite3 binary not available"
fi

echo ""
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] && exit 0 || exit 2
)
