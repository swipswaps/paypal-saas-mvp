#!/usr/bin/env bash
# setup_test.sh — /setup config, asset upload, register-plans flows
(
set +e
BASE="${BASE:-http://127.0.0.1:5000}"
TS=$(date +%s)
SNAPSHOT="/tmp/setup_test_brand_snapshot_$$.json"
BODY="/tmp/_setup_body_$$"
LOGO="/tmp/_setup_test_logo_$$.svg"
BAD="/tmp/_setup_test_bad_$$.exe"
TEST_BRAND="Test Brand $TS"
TEST_PRICE="42.42"
PASS=0; FAIL=0; SKIP=0

trap 'rm -f "$SNAPSHOT" "$BODY" "$LOGO" "$BAD"' EXIT

check() { local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then echo "PASS  $name"; PASS=$((PASS+1))
  else echo "FAIL  $name (expected $expected, got $actual)"; FAIL=$((FAIL+1)); fi; }
gcheck() { local name="$1" pattern="$2" file="$3"
  if grep -q "$pattern" "$file"; then echo "PASS  $name"; PASS=$((PASS+1))
  else echo "FAIL  $name"; FAIL=$((FAIL+1)); fi; }
skip() { echo "SKIP  $1 ($2)"; SKIP=$((SKIP+1)); }

echo "==> Backend: $BASE"

echo "==> Snapshotting current config/brand.json"
if [ -f config/brand.json ] && ! grep -q '"Test Brand' config/brand.json 2>/dev/null; then
  cp config/brand.json "$SNAPSHOT"
  echo "    saved to $SNAPSHOT"
else
  echo '{}' > "$SNAPSHOT"
  echo "    using empty snapshot (no prior real brand, or prior Test Brand)"
fi

echo ""
echo "==> 1. GET /setup"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' "$BASE/setup")
check "/setup returns 200" "200" "$CODE"
gcheck "/setup renders heading" "Setup" "$BODY"
gcheck "/setup has brand_name input" 'name="brand_name"' "$BODY"
grep -qiE 'register.?plans' "$BODY" && { echo "PASS  /setup has plan registration button"; PASS=$((PASS+1)); } || { echo "FAIL  /setup has plan registration button"; FAIL=$((FAIL+1)); }

echo ""
echo "==> 2. POST /setup/config (change brand + prices)"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$BASE/setup/config" \
  -H 'Content-Type: application/json' \
  -d "{\"brand_name\":\"$TEST_BRAND\",\"tier_basic_price\":\"$TEST_PRICE\"}")
check "/setup/config returns 200" "200" "$CODE"
gcheck "/setup/config ok=true" '"ok":true' "$BODY"

echo ""
echo "==> 3. home page reflects new brand"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' "$BASE/")
check "home returns 200" "200" "$CODE"
gcheck "home shows new brand name" "$TEST_BRAND" "$BODY"
gcheck "home shows new basic price" "$TEST_PRICE" "$BODY"

echo ""
echo "==> 4. POST /setup/asset (SVG logo)"
echo '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><circle cx="20" cy="20" r="18" fill="#38bdf8"/></svg>' > "$LOGO"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$BASE/setup/asset" \
  -F 'kind=logo' -F "file=@$LOGO;type=image/svg+xml")
check "/setup/asset logo upload" "200" "$CODE"
gcheck "/setup/asset accepted SVG" '"ok":true' "$BODY"

echo ""
echo "==> 5. asset served at static path"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' "$BASE/static/brand/logo.svg")
check "GET /static/brand/logo.svg" "200" "$CODE"
gcheck "asset served with SVG content" '<svg' "$BODY"

echo ""
echo "==> 6. home page links to logo"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' "$BASE/")
gcheck "home <img> references uploaded logo" 'static/brand/logo.svg' "$BODY"

echo ""
echo "==> 7. reject invalid extension"
echo 'MZ' > "$BAD"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$BASE/setup/asset" \
  -F 'kind=logo' -F "file=@$BAD;type=application/x-msdownload")
check "/setup/asset rejects .exe for logo" "400" "$CODE"

echo ""
echo "==> 8. reject unknown kind"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$BASE/setup/asset" \
  -F 'kind=bogus' -F "file=@$LOGO;type=image/svg+xml")
check "/setup/asset rejects unknown kind" "400" "$CODE"

echo ""
echo "==> 9. POST /setup/register-plans"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$BASE/setup/register-plans" \
  -H 'Content-Type: application/json' -d '{}')
check "register-plans without credentials -> 400" "400" "$CODE"
if grep -q '"ok":true' "$BODY"; then
  echo "PASS  register-plans actually calls PayPal"; PASS=$((PASS+1))
else
  skip "register-plans actually calls PayPal" "sandbox credentials not set in .env"
fi

echo ""
echo "==> 10. restore original brand.json"
RESTORE_OK=0
if cp "$SNAPSHOT" config/brand.json 2>&1; then
  echo "    restored via host cp"
  RESTORE_OK=1
else
  CONT=$(docker compose ps -q web 2>&1)
  if [ -n "$CONT" ] && docker cp "$SNAPSHOT" "$CONT:/app/config/brand.json" 2>&1; then
    echo "    restored via docker cp"
    RESTORE_OK=1
  else
    echo "    restore FAILED"
  fi
fi
if [ "$RESTORE_OK" -ne 1 ]; then
  echo "FAIL  restore original brand.json"; FAIL=$((FAIL+1))
fi

echo ""
echo "==> 11. home page reflects restored config"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' "$BASE/")
check "home returns 200" "200" "$CODE"
if grep -q "$TEST_BRAND" "$BODY"; then
  echo "FAIL  test brand still present after restore"; FAIL=$((FAIL+1))
else
  echo "PASS  home no longer shows test brand"; PASS=$((PASS+1))
fi

echo ""
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] && exit 0 || exit 2
)
