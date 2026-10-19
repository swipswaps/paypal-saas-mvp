import os, json, sqlite3, zlib, base64
from flask import (Flask, g, render_template, redirect, request, session,
                   url_for, jsonify, abort)
from werkzeug.security import check_password_hash, generate_password_hash
from werkzeug.utils import secure_filename
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
    print("WARNING: SECRET_KEY not set or placeholder; using ephemeral.", flush=True)
    _secret = os.urandom(32).hex()
app.secret_key = _secret

CLIENT_ID     = os.getenv("PAYPAL_CLIENT_ID")
CLIENT_SECRET = os.getenv("PAYPAL_CLIENT_SECRET")
WEBHOOK_ID    = os.getenv("WEBHOOK_ID")
BASE_URL      = os.getenv("BASE_URL", "http://localhost:5000").rstrip("/")
API_BASE      = os.getenv("PAYPAL_API_BASE", "https://api-m.sandbox.paypal.com")
PORT          = int(os.getenv("PORT", "5000"))
HOST          = os.getenv("HOST", "0.0.0.0")

paypal = PaypalServersdkClient(
    client_credentials_auth_credentials=ClientCredentialsAuthCredentials(
        o_auth_client_id=CLIENT_ID, o_auth_client_secret=CLIENT_SECRET),
    environment=Environment.SANDBOX)

DB_NAME = "saas_shop.db"
BRAND_JSON = os.path.join("config", "brand.json")
_brand_cache = {"mtime": 0, "data": {}}

def load_brand():
    try:
        mt = os.path.getmtime(BRAND_JSON)
    except OSError:
        return {}
    if mt != _brand_cache["mtime"]:
        try:
            with open(BRAND_JSON) as f:
                _brand_cache["data"] = json.load(f)
            _brand_cache["mtime"] = mt
        except Exception as e:
            print(f"WARNING: could not parse {BRAND_JSON}: {e}", flush=True)
            return {}
    return _brand_cache["data"]

def save_brand(cfg):
    os.makedirs(os.path.dirname(BRAND_JSON), exist_ok=True)
    tmp = BRAND_JSON + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2, sort_keys=True)
    os.replace(tmp, BRAND_JSON)
    _brand_cache["mtime"] = 0

def get_plans():
    cfg = load_brand()
    return {
        "basic": {
            "name": cfg.get("tier_basic_name") or os.getenv("TIER_BASIC_NAME", "Basic Tier"),
            "price": cfg.get("tier_basic_price") or os.getenv("TIER_BASIC_PRICE", "9.99"),
            "plan_id": cfg.get("plan_id_basic") or os.getenv("PLAN_ID_BASIC"),
        },
        "pro": {
            "name": cfg.get("tier_pro_name") or os.getenv("TIER_PRO_NAME", "Pro Tier"),
            "price": cfg.get("tier_pro_price") or os.getenv("TIER_PRO_PRICE", "29.99"),
            "plan_id": cfg.get("plan_id_pro") or os.getenv("PLAN_ID_PRO"),
        },
    }

@app.context_processor
def inject_brand():
    cfg = load_brand()
    return {
        "BRAND_NAME": cfg.get("brand_name") or os.getenv("BRAND_NAME", "Demo SaaS"),
        "BRAND_TAGLINE": cfg.get("brand_tagline") or os.getenv("BRAND_TAGLINE",
            "Sandbox subscription billing with PayPal Server SDK and Flask."),
        "CURRENCY_SYMBOL": cfg.get("currency_symbol") or os.getenv("CURRENCY_SYMBOL", "$"),
        "BRAND_LOGO": cfg.get("brand_logo"),
        "BRAND_HERO_IMAGE": cfg.get("hero_image"),
        "BRAND_HERO_VIDEO": cfg.get("hero_video"),
        "BRAND_DEMO_CAST": cfg.get("demo_cast"),
    }

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

def current_user():
    uid = session.get("user_id")
    if not uid: return None
    return get_db().execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()

# -------------------------------------------------------------------
# auth + dashboard (unchanged behavior, plans loaded dynamically)
# -------------------------------------------------------------------
@app.route("/")
def index():
    return render_template("index.html", user=current_user(), plans=get_plans())

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
    return render_template("dashboard.html", user=user, plans=get_plans())

@app.route("/premium")
def premium():
    user = current_user()
    if not user or user["tier"] == "free":
        return render_template("upgrade_required.html", user=user)
    return render_template("premium.html", user=user)

@app.route("/subscribe/<tier>")
def subscribe(tier):
    user = current_user()
    if not user or tier not in ("basic", "pro"): return redirect(url_for("login"))
    plans = get_plans()
    plan_id = plans[tier]["plan_id"]
    if not plan_id:
        return "PLAN_ID not configured. Open /setup to register plans.", 500
    from paypalserversdk.models.create_subscription_request import CreateSubscriptionRequest
    from paypalserversdk.models.subscription_application_context import SubscriptionApplicationContext
    brand = load_brand().get("brand_name") or os.getenv("BRAND_NAME", "Demo SaaS")
    req = CreateSubscriptionRequest(plan_id=plan_id, custom_id=str(user["id"]),
        application_context=SubscriptionApplicationContext(brand_name=brand,
            return_url=f"{BASE_URL}/subscription/success",
            cancel_url=f"{BASE_URL}/dashboard", user_action="SUBSCRIBE_NOW"))
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

def verify_webhook(raw: bytes, headers) -> bool:
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
    if etype == "BILLING.SUBSCRIPTION.ACTIVATED":
        plan_id = res.get("plan_id")
        plans = get_plans()
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
    resp = jsonify({"status": "healthy",
                    "brand": load_brand().get("brand_name") or os.getenv("BRAND_NAME", "Demo SaaS")})
    resp.headers["Access-Control-Allow-Origin"] = "https://swipswaps.github.io"
    resp.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
    resp.headers["Vary"] = "Origin"
    return resp

# -------------------------------------------------------------------
# /setup — interactive white-label, asset upload, plan registration
# -------------------------------------------------------------------
def _guard_setup():
    if os.getenv("ALLOW_SETUP") == "1":
        return
    if request.remote_addr in ("127.0.0.1", "::1"):
        return
    abort(403)

SETUP_FIELDS = ("brand_name", "brand_tagline",
                "tier_basic_name", "tier_basic_price",
                "tier_pro_name", "tier_pro_price",
                "currency_code", "currency_symbol", "billing_interval")

SETUP_DEFAULTS = {
    "brand_name": "Demo SaaS",
    "brand_tagline": "Sandbox subscription billing with PayPal Server SDK and Flask.",
    "tier_basic_name": "Basic Tier",
    "tier_basic_price": "9.99",
    "tier_pro_name": "Pro Tier",
    "tier_pro_price": "29.99",
    "currency_code": "USD",
    "currency_symbol": "$",
    "billing_interval": "MONTH",
}

ASSET_KINDS = {
    "logo":       {"exts": {"png","jpg","jpeg","svg"}, "key": "brand_logo"},
    "hero_image": {"exts": {"png","jpg","jpeg","svg"}, "key": "hero_image"},
    "hero_video": {"exts": {"mp4"},                    "key": "hero_video"},
    "demo_cast":  {"exts": {"cast"},                   "key": "demo_cast"},
}

@app.route("/setup")
def setup_page():
    _guard_setup()
    cfg = load_brand()
    merged = {}
    for k in SETUP_FIELDS:
        merged[k] = cfg.get(k) or SETUP_DEFAULTS[k]
    assets = {kind: cfg.get(meta["key"]) for kind, meta in ASSET_KINDS.items()}
    return render_template("setup.html", cfg=merged, assets=assets,
                           plans=get_plans(),
                           in_docker=os.path.exists("/.dockerenv"),
                           creds_ok=bool(CLIENT_ID and CLIENT_SECRET
                                         and CLIENT_ID != "your_sandbox_client_id_here"))

@app.route("/setup/config", methods=["POST"])
def setup_config():
    _guard_setup()
    cfg = load_brand() or {}
    for k in SETUP_FIELDS:
        v = (request.form.get(k) or "").strip()
        if v:
            cfg[k] = v
    save_brand(cfg)
    return jsonify({"ok": True, "applied_at": "next request"})

@app.route("/setup/asset", methods=["POST"])
def setup_asset():
    _guard_setup()
    kind = request.form.get("kind")
    if kind not in ASSET_KINDS:
        return jsonify({"error": "invalid kind"}), 400
    f = request.files.get("file")
    if not f or not f.filename:
        return jsonify({"error": "no file"}), 400
    safe = secure_filename(f.filename)
    if not safe or "." not in safe:
        return jsonify({"error": "invalid filename"}), 400
    ext = safe.rsplit(".", 1)[-1].lower()
    if ext not in ASSET_KINDS[kind]["exts"]:
        return jsonify({"error": f"extension .{ext} not allowed for {kind}"}), 400
    os.makedirs(os.path.join("static", "brand"), exist_ok=True)
    final_name = f"{kind}.{ext}"
    dest = os.path.join("static", "brand", final_name)
    f.save(dest)
    cfg = load_brand() or {}
    cfg[ASSET_KINDS[kind]["key"]] = f"brand/{final_name}"
    save_brand(cfg)
    return jsonify({"ok": True, "url": url_for("static", filename=cfg[ASSET_KINDS[kind]["key"]])})

@app.route("/setup/register-plans", methods=["POST"])
def setup_register_plans():
    _guard_setup()
    if not CLIENT_ID or not CLIENT_SECRET or CLIENT_ID == "your_sandbox_client_id_here":
        return jsonify({"error": "PayPal credentials not set in .env"}), 400
    cfg = load_brand() or {}
    brand = cfg.get("brand_name") or SETUP_DEFAULTS["brand_name"]
    tagline = cfg.get("brand_tagline") or SETUP_DEFAULTS["brand_tagline"]
    currency = cfg.get("currency_code") or SETUP_DEFAULTS["currency_code"]
    interval = cfg.get("billing_interval") or SETUP_DEFAULTS["billing_interval"]
    basic_name = cfg.get("tier_basic_name") or SETUP_DEFAULTS["tier_basic_name"]
    basic_price = cfg.get("tier_basic_price") or SETUP_DEFAULTS["tier_basic_price"]
    pro_name = cfg.get("tier_pro_name") or SETUP_DEFAULTS["tier_pro_name"]
    pro_price = cfg.get("tier_pro_price") or SETUP_DEFAULTS["tier_pro_price"]

    tok_resp = requests.post(f"{API_BASE}/v1/oauth2/token",
        auth=(CLIENT_ID, CLIENT_SECRET),
        data={"grant_type": "client_credentials"}, timeout=15)
    if tok_resp.status_code != 200:
        return jsonify({"error": f"PayPal OAuth {tok_resp.status_code}",
                        "detail": tok_resp.text[:300]}), 502
    tok = tok_resp.json()["access_token"]
    headers = {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"}

    prod_resp = requests.post(f"{API_BASE}/v1/catalogs/products", headers=headers, json={
        "name": brand, "description": tagline, "type": "SERVICE", "category": "SOFTWARE"
    }, timeout=20)
    if prod_resp.status_code not in (200, 201):
        return jsonify({"error": f"Product create {prod_resp.status_code}",
                        "detail": prod_resp.text[:300]}), 502
    product_id = prod_resp.json()["id"]

    def create_plan(name, price):
        body = {"product_id": product_id, "name": name,
                "description": f"{name} {interval.lower()}ly subscription", "status": "ACTIVE",
                "billing_cycles": [{"frequency": {"interval_unit": interval, "interval_count": 1},
                    "tenure_type": "REGULAR", "sequence": 1, "total_cycles": 0,
                    "pricing_scheme": {"fixed_price": {"value": price, "currency_code": currency}}}],
                "payment_preferences": {"auto_bill_outstanding": True, "payment_failure_threshold": 3}}
        r = requests.post(f"{API_BASE}/v1/billing/plans", headers=headers, json=body, timeout=20)
        if r.status_code not in (200, 201):
            return None, r.status_code, r.text[:300]
        return r.json()["id"], 200, None

    basic_id, bs, bd = create_plan(basic_name, basic_price)
    if not basic_id:
        return jsonify({"error": f"Basic plan {bs}", "detail": bd}), 502
    pro_id, ps, pd = create_plan(pro_name, pro_price)
    if not pro_id:
        return jsonify({"error": f"Pro plan {ps}", "detail": pd}), 502

    cfg["plan_id_basic"] = basic_id
    cfg["plan_id_pro"] = pro_id
    save_brand(cfg)
    return jsonify({"ok": True, "product_id": product_id,
                    "plan_id_basic": basic_id, "plan_id_pro": pro_id})

if __name__ == "__main__":
    print(f"Starting on {HOST}:{PORT}", flush=True)
    app.run(host=HOST, port=PORT, debug=False)
