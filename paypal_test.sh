#!/usr/bin/env bash
# paypal_test.sh — verify PayPal connectivity without touching the app.
# Skips every check that needs credentials not yet configured.
(
set +e

ENVF=".env"
SECRETS="config/secrets.json"
BODY="/tmp/_pp_body_$$"
HDRS="/tmp/_pp_hdrs_$$"
PASS=0; FAIL=0; SKIP=0

trap 'rm -f "$BODY" "$HDRS"' EXIT

pass() { echo "PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL  $1"; [ -n "$2" ] && echo "      $2"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP  $1 ($2)"; SKIP=$((SKIP+1)); }

_get() {
  if [ -f "$ENVF" ]; then
    grep -E "^$1=" "$ENVF" | head -1 | cut -d= -f2-
  fi
}
_getsec() {
  if [ -f "$SECRETS" ]; then
    grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$SECRETS" \
      | head -1 | cut -d'"' -f4
  fi
}
_ph() {
  [ -z "$1" ] && return 0
  case "$1" in your_*|replace-*) return 0 ;; esac
  case "$1" in *your_sandbox*) return 0 ;; esac
  return 1
}

CLIENT_ID=$(_get PAYPAL_CLIENT_ID)
CLIENT_SECRET=$(_get PAYPAL_CLIENT_SECRET)
WEBHOOK_ID=$(_get WEBHOOK_ID)
PLAN_BASIC=$(_get PLAN_ID_BASIC)
PLAN_PRO=$(_get PLAN_ID_PRO)
API_BASE=$(_get PAYPAL_API_BASE)
[ -z "$API_BASE" ] && API_BASE="https://api-m.sandbox.paypal.com"

if _ph "$CLIENT_ID";     then CLIENT_ID=$(_getsec PAYPAL_CLIENT_ID); fi
if _ph "$CLIENT_SECRET"; then CLIENT_SECRET=$(_getsec PAYPAL_CLIENT_SECRET); fi
if _ph "$WEBHOOK_ID";    then WEBHOOK_ID=$(_getsec WEBHOOK_ID); fi

echo "==> API base: $API_BASE"

if _ph "$CLIENT_ID" || _ph "$CLIENT_SECRET"; then
  skip "PayPal OAuth" "credentials are placeholders or absent"
  skip "Catalog products API" "no credentials"
  skip "Billing plans API" "no credentials"
  TOKEN=""
else
  HTTP=$(curl -s -o "$BODY" -w '%{http_code}' \
    -u "$CLIENT_ID:$CLIENT_SECRET" \
    -d 'grant_type=client_credentials' "$API_BASE/v1/oauth2/token")
  if [ "$HTTP" = "200" ]; then
    TOKEN=$(grep -o '"access_token":"[^"]*"' "$BODY" | cut -d'"' -f4)
    pass "PayPal OAuth (HTTP 200)"
  else
    TOKEN=""
    fail "PayPal OAuth (HTTP $HTTP)" "$(head -c 200 "$BODY")"
  fi

  if [ -n "$TOKEN" ]; then
    HTTP=$(curl -s -o "$BODY" -w '%{http_code}' \
      -H "Authorization: Bearer $TOKEN" \
      "$API_BASE/v1/catalogs/products?page_size=5")
    if [ "$HTTP" = "200" ]; then
      pass "Catalog products API (HTTP 200)"
    else
      fail "Catalog products API (HTTP $HTTP)" "$(head -c 200 "$BODY")"
    fi

    HTTP=$(curl -s -o "$BODY" -w '%{http_code}' \
      -H "Authorization: Bearer $TOKEN" \
      "$API_BASE/v1/billing/plans?page_size=5")
    if [ "$HTTP" = "200" ]; then
      pass "Billing plans API (HTTP 200)"
    else
      fail "Billing plans API (HTTP $HTTP)" "$(head -c 200 "$BODY")"
    fi
  else
    skip "Catalog products API" "no token"
    skip "Billing plans API" "no token"
  fi
fi

if [ -z "$PLAN_BASIC" ] || [ -z "$PLAN_PRO" ]; then
  skip "Plan IDs configured" "PLAN_ID_BASIC / PLAN_ID_PRO empty"
else
  echo "PASS  Plan IDs configured (basic=$PLAN_BASIC pro=$PLAN_PRO)"
  PASS=$((PASS+1))
fi

if _ph "$WEBHOOK_ID"; then
  skip "Webhook ID configured" "WEBHOOK_ID empty or placeholder"
else
  echo "PASS  Webhook ID configured"
  PASS=$((PASS+1))
fi

echo ""
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] && exit 0 || exit 2
)
