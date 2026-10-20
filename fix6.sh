#!/usr/bin/env bash
# fix6.sh — fix setup heading, register-plans 400, rewrite setup_test.sh
# Run: bash fix6.sh
(
set +e
trap 'echo "Interrupted — re-run bash fix6.sh"; exit 2' INT

if [ -n "${BASH_SOURCE[0]}" ]; then
  _d="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  [ -n "$_d" ] && cd "$_d"
fi

echo "==> cwd: $(pwd)"

# ---- 1. app.py: detect placeholder credentials ----------------
echo ""
echo "==> Patching app.py register-plans credential check"
python3 <<'PYEOF'
with open('app.py') as f: s = f.read()

old = '''@app.route("/setup/register-plans", methods=["POST"])
def setup_register_plans():
    if not CLIENT_ID or not CLIENT_SECRET:
        return jsonify({"ok": False, "error": "PayPal credentials not configured in .env"}), 400'''

new = '''def _creds_ok():
    cid = CLIENT_ID or ""
    cs = CLIENT_SECRET or ""
    if not cid or not cs: return False
    if cid.startswith("your_") or cs.startswith("your_"): return False
    if "your_sandbox" in cid or "your_sandbox" in cs: return False
    return True

@app.route("/setup/register-plans", methods=["POST"])
def setup_register_plans():
    if not _creds_ok():
        return jsonify({"ok": False, "error": "PayPal credentials not configured in .env (placeholders detected)"}), 400'''

if old in s:
    s = s.replace(old, new, 1)
    with open('app.py', 'w') as f: f.write(s)
    print("  patched: placeholder credentials now return 400")
elif '_creds_ok' in s:
    print("  already patched")
else:
    print("  WARNING: pattern not found; inspect app.py manually")
PYEOF

# ---- 2. Setup heading: add "& diagnostics" ----
echo ""
echo "==> Updating /setup heading"
python3 <<'PYEOF'
with open('templates/setup.html') as f: s = f.read()
if 'Setup &amp; diagnostics' in s:
    print("  already updated")
elif '<h1>Setup</h1>' in s:
    s = s.replace('<h1>Setup</h1>', '<h1>Setup &amp; diagnostics</h1>', 1)
    with open('templates/setup.html', 'w') as f: f.write(s)
    print("  heading updated to 'Setup &amp; diagnostics'")
else:
    print("  WARNING: unexpected heading; inspect templates/setup.html")
PYEOF

# ---- 3. Rewrite setup_test.sh with robust snapshot/restore ----
echo ""
echo "==> Rewriting setup_test.sh"
cat > setup_test.sh <<'SETUPEOF'
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
SETUPEOF
chmod +x setup_test.sh

# ---- 4. Rewrite restore_brand.sh (optional arg + fallbacks) ----
echo ""
echo "==> Rewriting restore_brand.sh"
cat > restore_brand.sh <<'RSEOF'
#!/usr/bin/env bash
# restore_brand.sh — restore config/brand.json from a snapshot
# Usage: bash restore_brand.sh [snapshot.json] [service]
(
set +e
SNAP="${1:-}"
SERVICE="${2:-web}"

if [ -z "$SNAP" ]; then
  for candidate in config/brand.json.bak /tmp/brand_snapshot.json /tmp/_brand_snapshot.json; do
    if [ -f "$candidate" ]; then SNAP="$candidate"; break; fi
  done
fi

if [ -z "$SNAP" ] || [ ! -f "$SNAP" ]; then
  echo "restore_brand.sh: no snapshot found"
  echo "  Usage: bash restore_brand.sh <snapshot.json> [service]"
  exit 2
fi

if cp "$SNAP" config/brand.json 2>&1; then
  echo "restore_brand.sh: restored $SNAP to config/brand.json (host)"
  exit 0
fi

CONT=$(docker compose ps -q "$SERVICE" 2>&1)
if [ -z "$CONT" ]; then
  echo "restore_brand.sh: host cp failed and no '$SERVICE' container running"
  exit 2
fi

docker cp "$SNAP" "$CONT:/tmp/_restore_brand.json" 2>&1 || { echo "restore_brand.sh: docker cp failed"; exit 2; }
docker exec -u root "$CONT" sh -c \
  'mkdir -p /app/config && cp /tmp/_restore_brand.json /app/config/brand.json && chmod 666 /app/config/brand.json && rm -f /tmp/_restore_brand.json' 2>&1 \
  || { echo "restore_brand.sh: docker exec failed"; exit 2; }
echo "restore_brand.sh: restored $SNAP via docker"
)
RSEOF
chmod +x restore_brand.sh

# ---- 5. Rebuild ----
echo ""
echo "==> Rebuilding image"
docker compose up -d --build 2>&1 | tail -4

# ---- 6. Readiness ----
echo ""
echo "==> Readiness (up to 60s)"
READY=0
for i in $(seq 1 30); do
  CODE=$(curl -s -o /tmp/_f6_$$ -w '%{http_code}' http://localhost:5000/health)
  echo "  probe $i: HTTP $CODE"
  if [ "$CODE" = "200" ]; then READY=1; break; fi
  sleep 2
done
rm -f /tmp/_f6_$$
if [ "$READY" -ne 1 ]; then
  echo "ERROR: backend not ready"
  docker compose logs --tail=30 web
  exit 2
fi

echo ""
echo "==> Smoke: register-plans (expect 400)"
curl -s -o /tmp/_f6_sm_$$ -w '  POST /setup/register-plans -> %{http_code}\n' -X POST http://localhost:5000/setup/register-plans
echo "  body: $(head -c 200 /tmp/_f6_sm_$$)"
rm -f /tmp/_f6_sm_$$

echo ""
echo "==> Smoke: /setup heading"
curl -s http://localhost:5000/setup | grep -oE '<h1>[^<]+</h1>' | head -1

# ---- 7. Tests ----
echo ""
echo "==> extended_test.sh"
bash extended_test.sh
EXT_RC=$?

echo ""
echo "==> setup_test.sh"
bash setup_test.sh
SETUP_RC=$?

echo ""
echo "DONE."
echo "  extended_test.sh exit: $EXT_RC"
echo "  setup_test.sh exit:    $SETUP_RC"
exit 0
)
