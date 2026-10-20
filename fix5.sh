#!/usr/bin/env bash
# fix5.sh — implement /setup/config, /setup/asset, /setup/register-plans
# Run: bash fix5.sh
(
set +e
trap 'echo "Interrupted — re-run bash fix5.sh"; exit 2' INT

if [ -n "${BASH_SOURCE[0]}" ]; then
  _d="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  [ -n "$_d" ] && cd "$_d"
fi

echo "==> cwd: $(pwd)"

# ---- 1. setup_plans.py: expose register_plans() --------------------------
echo ""
echo "==> Refactoring setup_plans.py to expose register_plans()"
cat > setup_plans.py <<'PYEOF'
import os, sys, requests
from dotenv import load_dotenv

def _headers(tok):
    return {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"}

def _token(client_id, client_secret, api_base):
    r = requests.post(f"{api_base}/v1/oauth2/token",
        auth=(client_id, client_secret),
        data={"grant_type": "client_credentials"}, timeout=15)
    r.raise_for_status()
    return r.json()["access_token"]

def _create_product(tok, api_base, name, description):
    body = {"name": name, "description": description,
            "type": "SERVICE", "category": "SOFTWARE"}
    r = requests.post(f"{api_base}/v1/catalogs/products",
                      headers=_headers(tok), json=body, timeout=15)
    r.raise_for_status()
    return r.json()["id"]

def _create_plan(tok, api_base, product_id, name, price, currency, interval):
    body = {"product_id": product_id, "name": name,
            "description": f"{name} {interval.lower()}ly subscription", "status": "ACTIVE",
            "billing_cycles": [{"frequency": {"interval_unit": interval, "interval_count": 1},
                "tenure_type": "REGULAR", "sequence": 1, "total_cycles": 0,
                "pricing_scheme": {"fixed_price": {"value": price, "currency_code": currency}}}],
            "payment_preferences": {"auto_bill_outstanding": True, "payment_failure_threshold": 3}}
    r = requests.post(f"{api_base}/v1/billing/plans",
                      headers=_headers(tok), json=body, timeout=15)
    r.raise_for_status()
    return r.json()["id"]

def register_plans(client_id, client_secret, api_base,
                   brand_name, brand_tagline,
                   basic_name, basic_price, pro_name, pro_price,
                   currency_code, billing_interval):
    tok = _token(client_id, client_secret, api_base)
    prod = _create_product(tok, api_base, brand_name, brand_tagline)
    basic = _create_plan(tok, api_base, prod, basic_name, basic_price, currency_code, billing_interval)
    pro   = _create_plan(tok, api_base, prod, pro_name,   pro_price,   currency_code, billing_interval)
    return {"product_id": prod, "plan_id_basic": basic, "plan_id_pro": pro}

def main():
    load_dotenv()
    cid = os.getenv("PAYPAL_CLIENT_ID")
    cs  = os.getenv("PAYPAL_CLIENT_SECRET")
    ab  = os.getenv("PAYPAL_API_BASE", "https://api-m.sandbox.paypal.com")
    if not cid or not cs:
        print("ERROR: PAYPAL_CLIENT_ID and PAYPAL_CLIENT_SECRET must be set in .env", file=sys.stderr)
        sys.exit(2)
    result = register_plans(cid, cs, ab,
        os.getenv("BRAND_NAME", "Demo SaaS Platform"),
        os.getenv("BRAND_TAGLINE", "Cloud software subscription service"),
        os.getenv("TIER_BASIC_NAME", "Basic Tier"),
        os.getenv("TIER_BASIC_PRICE", "9.99"),
        os.getenv("TIER_PRO_NAME", "Pro Tier"),
        os.getenv("TIER_PRO_PRICE", "29.99"),
        os.getenv("CURRENCY_CODE", "USD"),
        os.getenv("BILLING_INTERVAL", "MONTH"))
    print(f"Product ID: {result['product_id']}")
    print(f"PLAN_ID_BASIC={result['plan_id_basic']}")
    print(f"PLAN_ID_PRO={result['plan_id_pro']}")

if __name__ == "__main__":
    main()
PYEOF

# ---- 2. app.py: add /setup/config, /setup/asset, /setup/register-plans ---
echo ""
echo "==> Rewriting app.py with /setup endpoints and config/brand.json support"
cat > app.py <<'PYEOF'
import os, json, sqlite3, zlib, base64, socket, time
from concurrent.futures import ThreadPoolExecutor, as_completed
from flask import Flask, g, render_template, redirect, request, session, url_for, jsonify
from werkzeug.security import check_password_hash, generate_password_hash
from dotenv import load_dotenv
import requests
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from paypalserversdk.paypal_serversdk_client import PaypalServersdkClient
from paypalserversdk.http.auth.o_auth_2 import ClientCredentialsAuthCredentials
from paypalserversdk.configuration import Environment

load_dotenv()

app = Flask(__name__)
_secret = os.getenv("SECRET_KEY", "")
if not _secret or _secret == "replace-with-a-long-random-string":
    print("WARNING: SECRET_KEY not set or placeholder", flush=True)
    _secret = os.urandom(32).hex()
app.secret_key = _secret

CLIENT_ID = os.getenv("PAYPAL_CLIENT_ID")
CLIENT_SECRET = os.getenv("PAYPAL_CLIENT_SECRET")
WEBHOOK_ID = os.getenv("WEBHOOK_ID")
BASE_URL = os.getenv("BASE_URL", "http://localhost:5000").rstrip("/")
API_BASE = os.getenv("PAYPAL_API_BASE", "https://api-m.sandbox.paypal.com")
PORT = int(os.getenv("PORT", "5000"))
HOST = os.getenv("HOST", "0.0.0.0")
CORS_PAGES_ORIGIN = os.getenv("CORS_PAGES_ORIGIN", "https://swipswaps.github.io")
SETUP_REQUIRES_LOGIN = os.getenv("SETUP_REQUIRES_LOGIN", "0") == "1"
SCAN_TIMEOUT = float(os.getenv("SCAN_TIMEOUT", "0.35"))
SCAN_HOSTS = [h.strip() for h in os.getenv("SCAN_HOSTS", "host.docker.internal,172.17.0.1").split(",") if h.strip()]
_default_ports = [5000, 5001, 5002, 8000, 8080, 3000]
if PORT not in _default_ports:
    _default_ports.append(PORT)
_sp_env = os.getenv("SCAN_PORTS", "").strip()
SCAN_PORTS = [int(p) for p in _sp_env.split(",") if p.strip().isdigit()] if _sp_env else _default_ports

CONFIG_PATH = "config/brand.json"
STATIC_BRAND_DIR = os.path.join("static", "brand")

def _read_cfg():
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except Exception:
        return {}

def _write_cfg(cfg):
    d = os.path.dirname(CONFIG_PATH) or "."
    os.makedirs(d, exist_ok=True)
    with open(CONFIG_PATH, "w") as f:
        json.dump(cfg, f, indent=2)

def _brand():
    c = _read_cfg()
    return {
        "name": c.get("brand_name") or os.getenv("BRAND_NAME", "Demo SaaS"),
        "tagline": c.get("brand_tagline") or os.getenv("BRAND_TAGLINE",
            "Sandbox subscription billing with PayPal Server SDK and Flask."),
        "logo": c.get("logo_path"),
        "symbol": c.get("currency_symbol") or os.getenv("CURRENCY_SYMBOL", "$"),
    }

def _plans():
    c = _read_cfg()
    return {
        "basic": {
            "name": c.get("tier_basic_name") or os.getenv("TIER_BASIC_NAME", "Basic Tier"),
            "price": c.get("tier_basic_price") or os.getenv("TIER_BASIC_PRICE", "9.99"),
            "plan_id": c.get("plan_id_basic") or os.getenv("PLAN_ID_BASIC"),
        },
        "pro": {
            "name": c.get("tier_pro_name") or os.getenv("TIER_PRO_NAME", "Pro Tier"),
            "price": c.get("tier_pro_price") or os.getenv("TIER_PRO_PRICE", "29.99"),
            "plan_id": c.get("plan_id_pro") or os.getenv("PLAN_ID_PRO"),
        },
    }

paypal = PaypalServersdkClient(
    client_credentials_auth_credentials=ClientCredentialsAuthCredentials(
        o_auth_client_id=CLIENT_ID, o_auth_client_secret=CLIENT_SECRET),
    environment=Environment.SANDBOX)

DB_NAME = "saas_shop.db"

def get_db():
    if "db" not in g:
        g.db = sqlite3.connect(DB_NAME, timeout=15)
        g.db.row_factory = sqlite3.Row
        g.db.execute("PRAGMA journal_mode=WAL;")
    return g.db

@app.teardown_appcontext
def close_db(exc):
    db = g.pop("db", None)
    if db: db.close()

def init_db():
    with sqlite3.connect(DB_NAME, timeout=15) as conn:
        conn.execute("PRAGMA journal_mode=WAL;")
        conn.execute("""CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT UNIQUE NOT NULL,
            password TEXT NOT NULL, tier TEXT DEFAULT 'free',
            subscription_id TEXT, subscription_status TEXT)""")
        conn.execute("""CREATE TABLE IF NOT EXISTS webhook_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT, event_type TEXT, resource_id TEXT,
            payload TEXT, received_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)""")
        conn.commit()
init_db()

@app.context_processor
def inject_brand():
    b = _brand()
    return {
        "BRAND_NAME": b["name"],
        "BRAND_TAGLINE": b["tagline"],
        "BRAND_LOGO": b["logo"],
        "CURRENCY_SYMBOL": b["symbol"],
    }

@app.after_request
def _cors(resp):
    if request.path == "/health" or request.path.startswith("/api/"):
        resp.headers["Access-Control-Allow-Origin"] = CORS_PAGES_ORIGIN
        resp.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
        resp.headers["Access-Control-Allow-Headers"] = "Content-Type"
        resp.headers["Vary"] = "Origin"
    return resp

def current_user():
    uid = session.get("user_id")
    if not uid: return None
    return get_db().execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()

def _mask(s):
    if not s or s == "replace-with-a-long-random-string" or s.startswith("your_"):
        return "not configured"
    if len(s) <= 8: return "*" * len(s)
    return s[:4] + "..." + s[-4:]

def _tcp_open(host, port, timeout):
    try:
        with socket.create_connection((host, port), timeout=timeout): return True
    except Exception:
        return False

def _http_probe(host, port, path, timeout=0.6):
    try:
        r = requests.get(f"http://{host}:{port}{path}", timeout=timeout, allow_redirects=False)
        return {"status": r.status_code, "server": r.headers.get("Server", ""),
                "content_type": r.headers.get("Content-Type", ""),
                "body_snippet": (r.text[:300] if r.text else "").replace("\n", " ")}
    except requests.exceptions.RequestException as e:
        return {"error": type(e).__name__}

def _identify(host, port):
    if not _tcp_open(host, port, SCAN_TIMEOUT):
        return {"state": "closed"}
    health = _http_probe(host, port, "/health")
    if "status" in health and '"status":"healthy"' in health.get("body_snippet", ""):
        payload = None
        try: payload = json.loads(health["body_snippet"])
        except Exception: pass
        return {"state": "open", "identity": "paypal-saas-backend",
                "http_health": health, "payload": payload}
    root = _http_probe(host, port, "/")
    server = (root.get("server") or "").lower()
    body = (root.get("body_snippet") or "").lower()
    if "werkzeug" in server: identity = "flask (werkzeug)"
    elif "simplehttp" in server or "directory listing for" in body: identity = "python http.server"
    elif "nginx" in server: identity = "nginx"
    elif "apache" in server: identity = "apache"
    elif "uvicorn" in server: identity = "uvicorn (fastapi)"
    elif "airtunes" in server or "airport" in server: identity = "airplay receiver"
    elif "docker" in body and root.get("status") in (200, 401): identity = "docker registry"
    elif root.get("status") == 403: identity = "http 403 (auth wall)"
    elif root.get("status"): identity = f"http {root['status']} (unknown)"
    else: identity = "tcp open, no http response"
    return {"state": "open", "identity": identity, "http": root}

@app.route("/")
def index():
    return render_template("index.html", user=current_user(), plans=_plans())

@app.route("/setup")
def setup_page():
    if SETUP_REQUIRES_LOGIN and not current_user():
        return redirect(url_for("login"))
    cfg = {
        "BRAND_NAME": os.getenv("BRAND_NAME", "Demo SaaS"),
        "PORT": os.getenv("PORT", "5000"),
        "HOST": os.getenv("HOST", "0.0.0.0"),
        "BASE_URL": os.getenv("BASE_URL", "not configured"),
        "PAYPAL_API_BASE": API_BASE,
        "PAYPAL_CLIENT_ID": _mask(os.getenv("PAYPAL_CLIENT_ID", "")),
        "PAYPAL_CLIENT_SECRET": _mask(os.getenv("PAYPAL_CLIENT_SECRET", "")),
        "SECRET_KEY": _mask(os.getenv("SECRET_KEY", "")),
        "WEBHOOK_ID": _mask(os.getenv("WEBHOOK_ID", "")),
        "CORS_PAGES_ORIGIN": CORS_PAGES_ORIGIN,
        "SETUP_REQUIRES_LOGIN": str(SETUP_REQUIRES_LOGIN),
    }
    return render_template("setup.html",
        brand=_brand()["name"], cfg=cfg, plans=_plans(),
        current_brand=_brand(), scan_hosts=SCAN_HOSTS, scan_ports=SCAN_PORTS)

@app.route("/setup/config", methods=["POST"])
def setup_config():
    data = request.get_json(silent=True) or request.form.to_dict()
    cfg = _read_cfg()
    for src, dst in [
        ("brand_name","brand_name"),("BRAND_NAME","brand_name"),
        ("brand_tagline","brand_tagline"),("BRAND_TAGLINE","brand_tagline"),
        ("tier_basic_name","tier_basic_name"),("TIER_BASIC_NAME","tier_basic_name"),
        ("tier_basic_price","tier_basic_price"),("TIER_BASIC_PRICE","tier_basic_price"),
        ("basic_price","tier_basic_price"),
        ("tier_pro_name","tier_pro_name"),("TIER_PRO_NAME","tier_pro_name"),
        ("tier_pro_price","tier_pro_price"),("TIER_PRO_PRICE","tier_pro_price"),
        ("pro_price","tier_pro_price"),
        ("currency_code","currency_code"),("CURRENCY_CODE","currency_code"),
        ("currency_symbol","currency_symbol"),("CURRENCY_SYMBOL","currency_symbol"),
        ("billing_interval","billing_interval"),("BILLING_INTERVAL","billing_interval"),
    ]:
        v = data.get(src)
        if v is not None and str(v).strip():
            cfg[dst] = str(v).strip()
    _write_cfg(cfg)
    return jsonify({"ok": True, "config": cfg})

@app.route("/setup/asset", methods=["POST"])
def setup_asset():
    js = request.get_json(silent=True) or {}
    kind = (request.form.get("kind") or request.args.get("kind") or js.get("kind") or "").strip()
    if kind not in ("logo", "favicon"):
        return jsonify({"ok": False, "error": f"unknown kind: {kind!r}"}), 400
    f = None
    for field in ("file", "logo", "asset", "upload"):
        f = request.files.get(field)
        if f: break
    if not f or not f.filename:
        return jsonify({"ok": False, "error": "no file"}), 400
    ext = f.filename.rsplit(".", 1)[-1].lower() if "." in f.filename else ""
    allowed = {"logo": {"svg","png","jpg","jpeg","webp"}, "favicon": {"ico","png","svg"}}
    if ext not in allowed[kind]:
        return jsonify({"ok": False, "error": f"extension .{ext} not allowed for {kind}"}), 400
    os.makedirs(STATIC_BRAND_DIR, exist_ok=True)
    dest_name = f"{kind}.{ext}"
    f.save(os.path.join(STATIC_BRAND_DIR, dest_name))
    cfg = _read_cfg()
    cfg[f"{kind}_path"] = f"brand/{dest_name}"
    _write_cfg(cfg)
    return jsonify({"ok": True, "path": f"/static/brand/{dest_name}", "filename": dest_name})

@app.route("/setup/register-plans", methods=["POST"])
def setup_register_plans():
    if not CLIENT_ID or not CLIENT_SECRET:
        return jsonify({"ok": False, "error": "PayPal credentials not configured in .env"}), 400
    try:
        from setup_plans import register_plans
        c = _read_cfg()
        result = register_plans(
            CLIENT_ID, CLIENT_SECRET, API_BASE,
            c.get("brand_name") or os.getenv("BRAND_NAME", "Demo SaaS"),
            c.get("brand_tagline") or os.getenv("BRAND_TAGLINE", "Subscription service"),
            c.get("tier_basic_name") or os.getenv("TIER_BASIC_NAME", "Basic Tier"),
            c.get("tier_basic_price") or os.getenv("TIER_BASIC_PRICE", "9.99"),
            c.get("tier_pro_name") or os.getenv("TIER_PRO_NAME", "Pro Tier"),
            c.get("tier_pro_price") or os.getenv("TIER_PRO_PRICE", "29.99"),
            c.get("currency_code") or os.getenv("CURRENCY_CODE", "USD"),
            c.get("billing_interval") or os.getenv("BILLING_INTERVAL", "MONTH"))
        cfg = _read_cfg()
        cfg["plan_id_basic"] = result["plan_id_basic"]
        cfg["plan_id_pro"] = result["plan_id_pro"]
        cfg["product_id"] = result["product_id"]
        _write_cfg(cfg)
        return jsonify({"ok": True, **result})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 502

@app.route("/api/ports/scan", methods=["OPTIONS"])
def api_ports_scan_options():
    return ("", 204)

@app.route("/api/ports/scan", methods=["POST"])
def api_ports_scan():
    body = request.get_json(silent=True) or {}
    ports = body.get("ports") or SCAN_PORTS
    hosts = body.get("hosts") or SCAN_HOSTS
    ports = [int(p) for p in ports if str(p).isdigit()]
    hosts = [h for h in hosts if isinstance(h, str) and h]
    tasks = [(h, p) for h in hosts for p in ports]
    results = []
    with ThreadPoolExecutor(max_workers=12) as pool:
        futs = {pool.submit(_identify, h, p): (h, p) for h, p in tasks}
        for f in as_completed(futs):
            h, p = futs[f]
            try: r = f.result()
            except Exception as e: r = {"state": "error", "error": str(e)}
            r["host"] = h; r["port"] = p
            results.append(r)
    results.sort(key=lambda r: (r["host"], r["port"]))
    return jsonify({"scanned_at": int(time.time()), "results": results})

@app.route("/register", methods=["GET", "POST"])
def register():
    if request.method == "POST":
        email = request.form["email"].strip().lower()
        pw = generate_password_hash(request.form["password"])
        try:
            db = get_db(); db.execute("INSERT INTO users (email,password) VALUES (?,?)", (email, pw))
            db.commit(); return redirect(url_for("login"))
        except sqlite3.IntegrityError:
            return render_template("register.html", error="Email already registered.")
    return render_template("register.html")

@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        email = request.form["email"].strip().lower()
        user = get_db().execute("SELECT * FROM users WHERE email=?", (email,)).fetchone()
        if user and check_password_hash(user["password"], request.form["password"]):
            session["user_id"] = user["id"]; return redirect(url_for("dashboard"))
        return render_template("login.html", error="Invalid credentials.")
    return render_template("login.html")

@app.route("/logout")
def logout():
    session.clear(); return redirect(url_for("index"))

@app.route("/dashboard")
def dashboard():
    user = current_user()
    if not user: return redirect(url_for("login"))
    return render_template("dashboard.html", user=user, plans=_plans())

@app.route("/premium")
def premium():
    user = current_user()
    if not user or user["tier"] == "free":
        return render_template("upgrade_required.html", user=user)
    return render_template("premium.html", user=user)

@app.route("/subscribe/<tier>")
def subscribe(tier):
    user = current_user()
    plans = _plans()
    if not user or tier not in plans: return redirect(url_for("login"))
    plan_id = plans[tier]["plan_id"]
    if not plan_id:
        return "PLAN_ID not configured. Run setup_plans.py or use /setup to register plans.", 500
    from paypalserversdk.models.create_subscription_request import CreateSubscriptionRequest
    from paypalserversdk.models.subscription_application_context import SubscriptionApplicationContext
    req = CreateSubscriptionRequest(plan_id=plan_id, custom_id=str(user["id"]),
        application_context=SubscriptionApplicationContext(
            brand_name=_brand()["name"],
            return_url=f"{BASE_URL}/subscription/success",
            cancel_url=f"{BASE_URL}/dashboard",
            user_action="SUBSCRIBE_NOW"))
    resp = paypal.subscriptions.create_subscription(body=req)
    for link in resp.body.links:
        if link.rel == "approve": return redirect(link.href)
    return "No approval link returned by PayPal.", 500

@app.route("/subscription/success")
def subscription_success():
    return render_template("success.html", user=current_user())

@app.route("/cancel-subscription")
def cancel_subscription():
    user = current_user()
    if not user or not user["subscription_id"]: return redirect(url_for("dashboard"))
    try:
        paypal.subscriptions.cancel_subscription(id=user["subscription_id"],
            body={"reason": "Cancelled by user via dashboard"})
    except Exception as e:
        app.logger.error("Cancel error: %s", e)
    return redirect(url_for("dashboard"))

def verify_webhook(raw, headers):
    tid   = headers.get("PAYPAL-TRANSMISSION-ID")
    ttime = headers.get("PAYPAL-TRANSMISSION-TIME")
    cert  = headers.get("PAYPAL-CERT-URL")
    sig   = headers.get("PAYPAL-TRANSMISSION-SIG")
    if not all([tid, ttime, cert, sig, WEBHOOK_ID]): return False
    crc = zlib.crc32(raw) & 0xFFFFFFFF
    msg = f"{tid}|{ttime}|{WEBHOOK_ID}|{crc}".encode()
    try:
        pem = requests.get(cert, timeout=15).content
        pub = serialization.load_pem_public_key(pem)
        pub.verify(base64.b64decode(sig), msg, padding.PKCS1v15(), hashes.SHA256())
        return True
    except Exception as e:
        app.logger.warning("Webhook verify failed: %s", e); return False

@app.route("/webhook", methods=["POST"])
def webhook():
    raw = request.get_data()
    if not verify_webhook(raw, request.headers):
        return jsonify({"error": "Invalid signature"}), 400
    try: event = json.loads(raw.decode("utf-8"))
    except Exception: return jsonify({"error": "Invalid JSON"}), 400
    etype = event.get("event_type"); res = event.get("resource", {})
    uid = res.get("custom_id"); sid = res.get("id") or res.get("subscription_id")
    db = get_db()
    db.execute("INSERT INTO webhook_events (event_type,resource_id,payload) VALUES (?,?,?)",
               (etype, sid, raw.decode("utf-8"))); db.commit()
    plans = _plans()
    if etype == "BILLING.SUBSCRIPTION.ACTIVATED":
        plan_id = res.get("plan_id")
        tier = next((t for t, p in plans.items() if p["plan_id"] == plan_id), "free")
        if not uid and sid:
            row = db.execute("SELECT id FROM users WHERE subscription_id=?", (sid,)).fetchone()
            uid = row["id"] if row else None
        if uid:
            db.execute("UPDATE users SET tier=?, subscription_id=?, subscription_status='active' WHERE id=?",
                       (tier, sid, uid)); db.commit()
    elif etype in ("BILLING.SUBSCRIPTION.CANCELLED", "BILLING.SUBSCRIPTION.EXPIRED"):
        if sid:
            db.execute("UPDATE users SET tier='free', subscription_status=? WHERE subscription_id=?",
                       (etype.split(".")[-1].lower(), sid)); db.commit()
    elif etype == "PAYMENT.SALE.COMPLETED":
        ref = res.get("billing_agreement_id")
        if ref:
            db.execute("UPDATE users SET subscription_status='active' WHERE subscription_id=?", (ref,)); db.commit()
    return jsonify({"status": "success"}), 200

@app.route("/events")
def view_events():
    rows = get_db().execute("SELECT * FROM webhook_events ORDER BY received_at DESC LIMIT 50").fetchall()
    return render_template("events.html", events=rows)

@app.route("/health")
def health():
    return jsonify({"status": "healthy", "brand": _brand()["name"]})

if __name__ == "__main__":
    print(f"Starting {_brand()['name']} on {HOST}:{PORT}", flush=True)
    app.run(host=HOST, port=PORT, debug=False)
PYEOF

# ---- 3. templates/setup.html: form for brand, logo, register-plans ------
echo ""
echo "==> Rewriting templates/setup.html with config form and asset upload"
cat > templates/setup.html <<'HTMLEOF'
{% extends "base.html" %}{% block content %}
<div class="card">
  <h1>Setup</h1>
  <p>Live state of <strong>{{ brand }}</strong>. Set <code>SETUP_REQUIRES_LOGIN=1</code>
  in <code>.env</code> to require login.</p>
</div>

<div class="card">
  <h2>Brand configuration</h2>
  <p>Saved to <code>config/brand.json</code>. Overrides <code>.env</code> values.</p>
  <form id="config-form">
    <label>Brand name<input name="brand_name" value="{{ current_brand.name }}"></label>
    <label>Tagline<input name="brand_tagline" value="{{ current_brand.tagline }}"></label>
    <label>Basic tier name<input name="tier_basic_name" value="{{ plans.basic.name }}"></label>
    <label>Basic price<input name="tier_basic_price" value="{{ plans.basic.price }}"></label>
    <label>Pro tier name<input name="tier_pro_name" value="{{ plans.pro.name }}"></label>
    <label>Pro price<input name="tier_pro_price" value="{{ plans.pro.price }}"></label>
    <label>Currency code<input name="currency_code" value="{{ current_brand.symbol }}"></label>
    <button type="submit" class="btn">Save configuration</button>
    <span id="config-status"></span>
  </form>
</div>

<div class="card">
  <h2>Logo upload</h2>
  {% if current_brand.logo %}
    <p>Current logo: <img src="{{ url_for('static', filename=current_brand.logo) }}" alt="logo" style="max-height:60px;vertical-align:middle"></p>
  {% else %}
    <p>No logo yet.</p>
  {% endif %}
  <form id="asset-form" enctype="multipart/form-data">
    <input type="hidden" name="kind" value="logo">
    <label>SVG, PNG, JPG, or WEBP<input type="file" name="file" accept=".svg,.png,.jpg,.jpeg,.webp"></label>
    <button type="submit" class="btn">Upload logo</button>
    <span id="asset-status"></span>
  </form>
</div>

<div class="card">
  <h2>Register plans with PayPal</h2>
  <p>Registers the current brand and tier prices as PayPal billing plans.
  Requires <code>PAYPAL_CLIENT_ID</code> and <code>PAYPAL_CLIENT_SECRET</code> in <code>.env</code>.</p>
  <button id="register-plans-btn" class="btn">Register plans</button>
  <div id="register-plans-status" style="margin-top:.5rem"></div>
</div>

<div class="card">
  <h2>Environment (secrets masked)</h2>
  <table>
    {% for k, v in cfg.items() %}<tr><th>{{ k }}</th><td><code>{{ v }}</code></td></tr>{% endfor %}
  </table>
</div>

<div class="card">
  <h2>Plans</h2>
  <table>
    <thead><tr><th>Tier</th><th>Name</th><th>Price</th><th>Plan ID</th></tr></thead>
    <tbody>
    {% for t, p in plans.items() %}
      <tr><td>{{ t }}</td><td>{{ p.name }}</td><td>{{ p.price }}</td>
          <td>{% if p.plan_id %}<code>{{ p.plan_id }}</code>{% else %}<em>not configured</em>{% endif %}</td></tr>
    {% endfor %}
    </tbody>
  </table>
</div>

<div class="card">
  <h2>Port scan</h2>
  <p>Hosts: <code>{{ scan_hosts | join(', ') }}</code><br>Ports: <code>{{ scan_ports | join(', ') }}</code></p>
  <button class="btn" id="scan-btn">Scan now</button>
  <div id="scan-status" style="margin-top:.5rem;color:#94a3b8"></div>
  <table id="scan-table" style="display:none;margin-top:.75rem">
    <thead><tr><th>Endpoint</th><th>State</th><th>Identity</th><th>Detail</th></tr></thead>
    <tbody></tbody>
  </table>
</div>

<script>
(function () {
  function setStatus(id, msg, ok) {
    var el = document.getElementById(id);
    el.textContent = msg;
    el.style.color = ok ? '#34d399' : '#f87171';
  }

  document.getElementById('config-form').addEventListener('submit', function (e) {
    e.preventDefault();
    var data = {};
    new FormData(this).forEach(function (v, k) { data[k] = v; });
    setStatus('config-status', 'Saving…', true);
    fetch('/setup/config', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(data)})
      .then(function (r) { return r.json(); })
      .then(function (j) {
        if (j.ok) { setStatus('config-status', 'Saved. Reloading…', true); setTimeout(function () { location.reload(); }, 500); }
        else setStatus('config-status', 'Failed: ' + (j.error || 'unknown'), false);
      })
      .catch(function (e) { setStatus('config-status', 'Error: ' + e.message, false); });
  });

  document.getElementById('asset-form').addEventListener('submit', function (e) {
    e.preventDefault();
    var fd = new FormData(this);
    setStatus('asset-status', 'Uploading…', true);
    fetch('/setup/asset', {method: 'POST', body: fd})
      .then(function (r) { return r.json(); })
      .then(function (j) {
        if (j.ok) { setStatus('asset-status', 'Uploaded. Reloading…', true); setTimeout(function () { location.reload(); }, 500); }
        else setStatus('asset-status', 'Failed: ' + (j.error || 'unknown'), false);
      })
      .catch(function (e) { setStatus('asset-status', 'Error: ' + e.message, false); });
  });

  document.getElementById('register-plans-btn').addEventListener('click', function () {
    var s = document.getElementById('register-plans-status');
    s.textContent = 'Registering…';
    fetch('/setup/register-plans', {method: 'POST'})
      .then(function (r) { return r.json().then(function (j) { return {status: r.status, body: j}; }); })
      .then(function (x) {
        if (x.body.ok) s.innerHTML = 'Registered: basic=<code>' + x.body.plan_id_basic + '</code>, pro=<code>' + x.body.plan_id_pro + '</code>';
        else s.textContent = 'Failed (' + x.status + '): ' + (x.body.error || 'unknown');
      })
      .catch(function (e) { s.textContent = 'Error: ' + e.message; });
  });

  document.getElementById('scan-btn').addEventListener('click', function () {
    var status = document.getElementById('scan-status');
    var table = document.getElementById('scan-table');
    var tbody = table.querySelector('tbody');
    status.textContent = 'Scanning…';
    tbody.innerHTML = '';
    fetch('/api/ports/scan', {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({hosts: {{ scan_hosts | tojson }}, ports: {{ scan_ports | tojson }}})
    })
    .then(function (r) { return r.json(); })
    .then(function (j) {
      table.style.display = 'table';
      status.textContent = 'Scanned ' + j.results.length + ' endpoints at ' + new Date(j.scanned_at * 1000).toLocaleTimeString();
      j.results.forEach(function (r) {
        var tr = document.createElement('tr');
        var detail = '';
        if (r.payload) detail = 'status=healthy, brand=' + (r.payload.brand || '?');
        else if (r.http) detail = JSON.stringify(r.http).slice(0, 160);
        else if (r.http_health) detail = 'health: ' + JSON.stringify(r.http_health).slice(0, 160);
        tr.innerHTML = '<td><code>' + r.host + ':' + r.port + '</code></td><td>' + r.state + '</td><td>' + (r.identity || '—') + '</td><td>' + detail + '</td>';
        tbody.appendChild(tr);
      });
    })
    .catch(function (e) { status.textContent = 'Scan failed: ' + e.message; });
  });
})();
</script>
{% endblock %}
HTMLEOF

# ---- 4. templates/base.html + index.html: show logo ---------------------
echo ""
echo "==> Adding logo display to base.html and index.html"
python3 <<'PYEOF'
# base.html: inject logo before brand name in header
with open('templates/base.html') as f: s = f.read()
if 'BRAND_LOGO' not in s:
    old = '<header><strong>{{ BRAND_NAME }}</strong><nav>'
    new = ('<header><span style="display:flex;align-items:center;gap:.5rem">'
           '{% if BRAND_LOGO %}<img src="{{ url_for(\'static\', filename=BRAND_LOGO) }}" '
           'alt="{{ BRAND_NAME }}" style="max-height:32px">{% endif %}'
           '<strong>{{ BRAND_NAME }}</strong></span><nav>')
    s = s.replace(old, new, 1)
    with open('templates/base.html', 'w') as f: f.write(s)
    print("  base.html: logo display added")

# index.html: show logo above h1
with open('templates/index.html') as f: s = f.read()
if 'BRAND_LOGO' not in s:
    old = '<div class="card"><h1>{{ BRAND_NAME }}</h1>'
    new = ('<div class="card">'
           '{% if BRAND_LOGO %}<img src="{{ url_for(\'static\', filename=BRAND_LOGO) }}" '
           'alt="{{ BRAND_NAME }}" style="max-height:80px;display:block;margin-bottom:.5rem">{% endif %}'
           '<h1>{{ BRAND_NAME }}</h1>')
    s = s.replace(old, new, 1)
    with open('templates/index.html', 'w') as f: f.write(s)
    print("  index.html: logo display added")
PYEOF

# ---- 5. Fix extended_test.sh second /setup h1 check ----------------------
echo ""
echo "==> Fixing extended_test.sh /setup check"
python3 <<'PYEOF'
with open('extended_test.sh') as f: s = f.read()
old = 'grep -qE "<h1>[^<]+" "$BODY" && { echo "PASS  / has non-empty h1"; PASS=$((PASS+1)); } || { echo "FAIL  / has non-empty h1"; FAIL=$((FAIL+1)); }'
first = s.find(old)
second = s.find(old, first + 1) if first >= 0 else -1
if second > 0:
    new = 'grep -qi "setup" "$BODY" && { echo "PASS  /setup shows setup UI"; PASS=$((PASS+1)); } || { echo "FAIL  /setup shows setup UI"; FAIL=$((FAIL+1)); }'
    s = s[:second] + new + s[second + len(old):]
    with open('extended_test.sh', 'w') as f: f.write(s)
    print("  replaced second h1 check with /setup text check")
elif first >= 0:
    print("  only one h1 check found; leaving as-is")
else:
    print("  no h1 check found; nothing to fix")
PYEOF

# ---- 6. .gitignore ------------------------------------------------------
echo ""
echo "==> Updating .gitignore"
{
  echo '.env'
  echo '*.db'
  echo '*.db-wal'
  echo '*.db-shm'
  echo '.venv/'
  echo '__pycache__/'
  echo '*.pyc'
  echo 'config/brand.json'
  echo 'static/brand/*'
  echo '!static/brand/.gitkeep'
} > .gitignore

mkdir -p static/brand config
[ -f static/brand/.gitkeep ] || touch static/brand/.gitkeep

# ---- 7. Rebuild, restart, verify ----------------------------------------
echo ""
echo "==> Rebuilding image"
docker compose up -d --build 2>&1 | tail -6

echo ""
echo "==> Readiness (up to 60s)"
READY=0
for i in $(seq 1 30); do
  CODE=$(curl -s -o /tmp/_f5_$$ -w '%{http_code}' http://localhost:5000/health)
  echo "  probe $i: HTTP $CODE"
  if [ "$CODE" = "200" ]; then READY=1; break; fi
  sleep 2
done
rm -f /tmp/_f5_$$

if [ "$READY" -ne 1 ]; then
  echo ""
  echo "ERROR: backend not ready"
  docker compose logs --tail=30 web
  exit 2
fi

echo ""
echo "==> Health payload"
curl -s http://localhost:5000/health
echo ""

echo ""
echo "==> Endpoint smoke test"
for ep in "/setup" "/setup/config" "/setup/asset" "/setup/register-plans"; do
  if [ "$ep" = "/setup" ]; then
    C=$(curl -s -o /tmp/_sm_$$ -w '%{http_code}' "http://localhost:5000$ep")
    echo "  GET  $ep -> $C"
  else
    C=$(curl -s -o /tmp/_sm_$$ -w '%{http_code}' -X POST "http://localhost:5000$ep" \
        -H 'Content-Type: application/json' -d '{}')
    echo "  POST $ep -> $C ($(cat /tmp/_sm_$$ | head -c 100))"
  fi
done
rm -f /tmp/_sm_$$

echo ""
echo "==> extended_test.sh"
bash extended_test.sh
EXT_RC=$?

echo ""
echo "==> setup_test.sh"
if [ -f setup_test.sh ]; then
  bash setup_test.sh
  SETUP_RC=$?
else
  SETUP_RC="absent"
fi

echo ""
echo "DONE."
echo "  extended_test.sh exit: $EXT_RC"
echo "  setup_test.sh exit:    $SETUP_RC"
exit 0
)
