#!/usr/bin/env bash
# setup_test.sh — exercise /setup config, asset upload, plan registration.
# Skips plan registration if .env still has placeholder PayPal credentials.
(
set +e

BASE="${BASE_URL_LOCAL:-http://127.0.0.1:5000}"
BODY="/tmp/_su_body_$$"
SNAP="/tmp/_su_brand_$$"
TMPFILE="/tmp/_su_asset_$$.svg"
PASS=0; FAIL=0; SKIP=0

trap 'rm -f "$BODY" "$SNAP" "$TMPFILE"' EXIT

check() { local n="$1" e="$2" a="$3"
  if [ "$a" = "$e" ]; then echo "PASS  $n"; PASS=$((PASS+1));
  else echo "FAIL  $n (expected $e, got $a)"; FAIL=$((FAIL+1)); fi; }
skip()  { echo "SKIP  $1 ($2)"; SKIP=$((SKIP+1)); }

echo "==> Backend: $BASE"

CODE=$(curl -s -o "$BODY" -w '%{http_code}' "$BASE/health")
if [ "$CODE" != "200" ]; then
  echo "ERROR: backend not up at $BASE (probe=$CODE)"
  echo "       Try: bash verify_stack.sh"
  exit 2
fi

echo "==> Snapshotting current config/brand.json"
if [ -f config/brand.json ]; then cp config/brand.json "$SNAP"; fi

echo ""
echo "==> 1. GET /setup"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' "$BASE/setup")
check "/setup returns 200" "200" "$CODE"
grep -q 'Setup —' "$BODY" && { echo "PASS  /setup renders heading"; PASS=$((PASS+1)); } \
                          || { echo "FAIL  /setup heading missing"; FAIL=$((FAIL+1)); }
grep -q 'name="brand_name"' "$BODY" && { echo "PASS  /setup has brand_name input"; PASS=$((PASS+1)); } \
                                    || { echo "FAIL  /setup missing brand_name"; FAIL=$((FAIL+1)); }
grep -q 'Register plans with PayPal' "$BODY" && { echo "PASS  /setup has plan registration button"; PASS=$((PASS+1)); } \
                                             || { echo "FAIL  plan registration button missing"; FAIL=$((FAIL+1)); }

echo ""
echo "==> 2. POST /setup/config (change brand + prices)"
STAMP=$(date +%s)
TEST_BRAND="Test Brand ${STAMP}"
TEST_BASIC="4.${STAMP: -2}"
TEST_PRO="19.${STAMP: -2}"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$BASE/setup/config" \
  --data-urlencode "brand_name=$TEST_BRAND" \
  --data-urlencode "brand_tagline=Saving to config/brand.json" \
  --data-urlencode "tier_basic_name=Test Basic" \
  --data-urlencode "tier_basic_price=$TEST_BASIC" \
  --data-urlencode "tier_pro_name=Test Pro" \
  --data-urlencode "tier_pro_price=$TEST_PRO" \
  --data-urlencode "currency_code=USD" \
  --data-urlencode "currency_symbol=$" \
  --data-urlencode "billing_interval=MONTH")
check "/setup/config returns 200" "200" "$CODE"
grep -q '"ok"' "$BODY" && { echo "PASS  /setup/config ok=true"; PASS=$((PASS+1)); } \
                       || { echo "FAIL  /setup/config did not return ok"; FAIL=$((FAIL+1)); }

echo ""
echo "==> 3. home page reflects new brand"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' "$BASE/")
check "home returns 200" "200" "$CODE"
grep -q "$TEST_BRAND" "$BODY" && { echo "PASS  home shows new brand name"; PASS=$((PASS+1)); } \
                              || { echo "FAIL  home brand not updated"; FAIL=$((FAIL+1)); }
grep -q "$TEST_BASIC" "$BODY" && { echo "PASS  home shows new basic price"; PASS=$((PASS+1)); } \
                              || { echo "FAIL  home basic price not updated"; FAIL=$((FAIL+1)); }

echo ""
echo "==> 4. POST /setup/asset (SVG logo)"
cat > "$TMPFILE" <<'SVGEOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><circle cx="32" cy="32" r="30" fill="#38bdf8"/></svg>
SVGEOF
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$BASE/setup/asset" \
  -F "kind=logo" -F "file=@$TMPFILE;type=image/svg+xml;filename=logo.svg")
check "/setup/asset logo upload" "200" "$CODE"
grep -q '"ok"' "$BODY" && { echo "PASS  /setup/asset accepted SVG"; PASS=$((PASS+1)); } \
                       || { echo "FAIL  /setup/asset rejected SVG"; FAIL=$((FAIL+1)); }

echo ""
echo "==> 5. asset served at static path"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' "$BASE/static/brand/logo.svg")
check "GET /static/brand/logo.svg" "200" "$CODE"
grep -q 'svg' "$BODY" && { echo "PASS  asset served with SVG content"; PASS=$((PASS+1)); } \
                      || { echo "FAIL  asset content missing"; FAIL=$((FAIL+1)); }

echo ""
echo "==> 6. home page links to logo"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' "$BASE/")
grep -q 'brand/logo.svg' "$BODY" && { echo "PASS  home <img> references uploaded logo"; PASS=$((PASS+1)); } \
                                  || { echo "FAIL  logo not referenced in home"; FAIL=$((FAIL+1)); }

echo ""
echo "==> 7. reject invalid extension"
cat > "$TMPFILE" <<'XEOF'
not an image
XEOF
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$BASE/setup/asset" \
  -F "kind=logo" -F "file=@$TMPFILE;filename=evil.exe")
check "/setup/asset rejects .exe for logo" "400" "$CODE"

echo ""
echo "==> 8. reject unknown kind"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$BASE/setup/asset" \
  -F "kind=evil" -F "file=@$TMPFILE;filename=x.txt")
check "/setup/asset rejects unknown kind" "400" "$CODE"

echo ""
echo "==> 9. POST /setup/register-plans"
CLIENT_ID=$(grep -E '^PAYPAL_CLIENT_ID=' .env 2>&1 | head -1 | cut -d= -f2-)
CLIENT_SECRET=$(grep -E '^PAYPAL_CLIENT_SECRET=' .env 2>&1 | head -1 | cut -d= -f2-)
if [ -z "$CLIENT_ID" ] || [ "$CLIENT_ID" = "your_sandbox_client_id_here" ] \
   || [ -z "$CLIENT_SECRET" ] || [ "$CLIENT_SECRET" = "your_sandbox_client_secret_here" ]; then
  CODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$BASE/setup/register-plans")
  check "register-plans without credentials -> 400" "400" "$CODE"
  skip "register-plans actually calls PayPal" "sandbox credentials not set in .env"
else
  echo "  (credentials present, calling PayPal…)"
  CODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$BASE/setup/register-plans")
  if [ "$CODE" = "200" ]; then
    echo "PASS  register-plans succeeded"; PASS=$((PASS+1))
    grep -q 'plan_id_basic' "$BODY" && { echo "PASS  response contains plan_id_basic"; PASS=$((PASS+1)); } \
                                    || { echo "FAIL  no plan_id_basic in response"; FAIL=$((FAIL+1)); }
  else
    echo "FAIL  register-plans returned $CODE"
    echo "  body: $(head -c 300 "$BODY")"
    FAIL=$((FAIL+1))
  fi
fi

echo ""
echo "==> 10. restore original brand.json"
if [ -f "$SNAP" ]; then
  cp "$SNAP" config/brand.json
  echo "  restored from snapshot"
fi

echo ""
echo "==> 11. home page reflects restored config"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' "$BASE/")
grep -q "$TEST_BRAND" "$BODY" && { echo "FAIL  test brand still present after restore"; FAIL=$((FAIL+1)); } \
                              || { echo "PASS  home no longer shows test brand"; PASS=$((PASS+1)); }

echo ""
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] && exit 0 || exit 2
)
