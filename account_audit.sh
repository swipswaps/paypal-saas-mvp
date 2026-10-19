#!/usr/bin/env bash
# account_audit.sh — verify what account features exist and what do not
(
set +e

BASE="http://localhost:5000"
TS=$(date +%s)
EMAIL="acct_${TS}@example.com"
PW="acct_test_1234"
COOKIE1="/tmp/acct_c1_$$"
COOKIE2="/tmp/acct_c2_$$"
BODY="/tmp/_acct_body_$$"
SQLITE_PROBE="/tmp/_acct_sqlite_$$"
PASS=0; FAIL=0; INFO=0; SKIP=0

trap 'rm -f "$COOKIE1" "$COOKIE2" "$BODY" "$SQLITE_PROBE"' EXIT

check() { local n="$1" e="$2" a="$3"
  if [ "$a" = "$e" ]; then echo "PASS  $n"; PASS=$((PASS+1));
  else echo "FAIL  $n (expected $e, got $a)"; FAIL=$((FAIL+1)); fi; }
info()  { echo "INFO  $1"; INFO=$((INFO+1)); }
skip()  { echo "SKIP  $1 ($2)"; SKIP=$((SKIP+1)); }

# Health gate
CODE=$(curl -s -o "$BODY" -w '%{http_code}' "$BASE/health")
if [ "$CODE" != "200" ]; then
  echo "ERROR: backend not running at $BASE (probe=$CODE)"
  echo "       Start: docker compose up -d --build"
  exit 2
fi

# --- registration & password hashing ---
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$BASE/register" \
  -d "email=$EMAIL" -d "password=$PW")
check "register" "302" "$CODE"

if command -v sqlite3 > "$SQLITE_PROBE" 2>&1 && [ -s "$SQLITE_PROBE" ]; then
  HASH=$(sqlite3 saas_shop.db "SELECT password FROM users WHERE email='$EMAIL';" 2>&1)
  if [ -z "$HASH" ]; then
    skip "password hash" "user not found in DB"
  elif echo "$HASH" | grep -qE '^(scrypt:|pbkdf2:)'; then
    echo "PASS  password stored as hash ($(echo "$HASH" | cut -d: -f1))"; PASS=$((PASS+1))
  elif [ "$HASH" = "$PW" ]; then
    echo "FAIL  password stored in PLAINTEXT"; FAIL=$((FAIL+1))
  else
    info "password format unrecognized: $(echo "$HASH" | cut -c1-24)..."
  fi
else
  skip "password hash" "sqlite3 not available"
fi

# --- login: wrong password rejected ---
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$BASE/login" \
  -d "email=$EMAIL" -d "password=wrong")
check "login wrong pw -> 200" "200" "$CODE"
grep -q "Invalid credentials" "$BODY" \
  && { echo "PASS  wrong pw shows error"; PASS=$((PASS+1)); } \
  || { echo "FAIL  wrong pw shows error"; FAIL=$((FAIL+1)); }

# --- login: correct password accepted ---
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -c "$COOKIE1" -X POST "$BASE/login" \
  -d "email=$EMAIL" -d "password=$PW")
check "login correct pw -> 302" "302" "$CODE"

# --- session cookie shape ---
SESSION_VAL=$(awk '$6=="session" {print $7}' "$COOKIE1")
if [ -n "$SESSION_VAL" ]; then
  echo "PASS  session cookie issued"; PASS=$((PASS+1))
  if echo "$SESSION_VAL" | grep -q '\.'; then
    echo "PASS  session cookie is signed (itsdangerous .payload.ts.sig)"; PASS=$((PASS+1))
  else
    info "session cookie does not contain '.' — unexpected format"
  fi
else
  echo "FAIL  session cookie not issued"; FAIL=$((FAIL+1))
fi

# --- multi-device sessions independent ---
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -c "$COOKIE2" -X POST "$BASE/login" \
  -d "email=$EMAIL" -d "password=$PW")
check "second device login -> 302" "302" "$CODE"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -b "$COOKIE1" "$BASE/dashboard")
check "device 1 still valid after device 2 login" "200" "$CODE"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -b "$COOKIE2" "$BASE/dashboard")
check "device 2 valid" "200" "$CODE"

# --- logout invalidates device 2 only ---
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -b "$COOKIE2" -c "$COOKIE2" "$BASE/logout")
check "logout device 2 -> 302" "302" "$CODE"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -b "$COOKIE2" "$BASE/dashboard")
check "device 2 invalid after logout" "302" "$CODE"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -b "$COOKIE1" "$BASE/dashboard")
check "device 1 remains valid (independent sessions)" "200" "$CODE"

# --- session token not leaked into HTML ---
if [ -n "$SESSION_VAL" ] && grep -q "$SESSION_VAL" "$BODY"; then
  echo "FAIL  session token leaked in HTML"; FAIL=$((FAIL+1))
else
  echo "PASS  session token not present in HTML"; PASS=$((PASS+1))
fi

# --- features that DO NOT exist (404) ---
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -b "$COOKIE1" -X POST "$BASE/change-password" \
  -d "old=$PW&new=different_1234")
check "POST /change-password -> 404 (not implemented)" "404" "$CODE"

CODE=$(curl -s -o "$BODY" -w '%{http_code}' "$BASE/forgot-password")
check "GET  /forgot-password -> 404 (not implemented)" "404" "$CODE"

CODE=$(curl -s -o "$BODY" -w '%{http_code}' -b "$COOKIE1" -X POST "$BASE/delete-account")
check "POST /delete-account -> 404 (not implemented)" "404" "$CODE"

CODE=$(curl -s -o "$BODY" -w '%{http_code}' -b "$COOKIE1" -X POST "$BASE/change-email" \
  -d "new=other@example.com")
check "POST /change-email -> 404 (not implemented)" "404" "$CODE"

# --- CSRF: not enforced (sandbox MVP) ---
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$BASE/register" \
  -d "email=csrf_${TS}@example.com" -d "password=$PW")
if [ "$CODE" = "302" ]; then
  info "no CSRF token required for POST /register (sandbox OK, prod risk)"
elif [ "$CODE" = "400" ] || [ "$CODE" = "403" ]; then
  echo "PASS  CSRF token enforced on /register"; PASS=$((PASS+1))
else
  info "/register returned $CODE without CSRF token (unexpected)"
fi

# --- rate limiting: not present (5 rapid failures all return 200) ---
BLOCKED=0
for i in 1 2 3 4 5; do
  CODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$BASE/login" \
    -d "email=$EMAIL" -d "password=bad$i")
  [ "$CODE" != "200" ] && BLOCKED=$((BLOCKED+1))
done
if [ "$BLOCKED" -eq 0 ]; then
  info "no login rate limiting (5 failed attempts all returned 200)"
else
  echo "PASS  rate limiting active ($BLOCKED of 5 blocked)"; PASS=$((PASS+1))
fi

echo ""
echo "PASS=$PASS FAIL=$FAIL INFO=$INFO SKIP=$SKIP"
[ "$FAIL" -eq 0 ] && exit 0 || exit 2
)
