import os, json, sqlite3, zlib, base64, socket, time, sys
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

# ---------- secrets helpers ----------
SECRETS_PATH = "config/secrets.json"
CREDS_FROM_ENV_ONLY = os.getenv("CREDS_FROM_ENV_ONLY", "0") == "1"

def _is_placeholder(v):
    if not v: return True
    if v.startswith("your_") or v.startswith("replace-"): return True
    if "your_sandbox" in v: return True
    return False

def _read_secrets():
    try:
        with open(SECRETS_PATH) as f:
            return json.load(f)
    except Exception:
        return {}

def _write_secrets(sec):
    d = os.path.dirname(SECRETS_PATH) or "."
    os.makedirs(d, mode=0o700, exist_ok=True)
    tmp = SECRETS_PATH + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(sec, f, indent=2)
        os.replace(tmp, SECRETS_PATH)
        try: os.chmod(SECRETS_PATH, 0o600)
        except Exception: pass
    except Exception:
        try: os.unlink(tmp)
        except Exception: pass
        raise

def _cred(name, default=""):
    envv = os.getenv(name, "")
    if envv and not _is_placeholder(envv):
        return envv
    sec = _read_secrets()
    if sec.get(name):
        return sec[name]
    return envv or default

# ---------- app + initial config ----------
app = Flask(__name__)
_secret = _cred("SECRET_KEY")
if not _secret or _secret == "replace-with-a-long-random-string":
    print("WARNING: SECRET_KEY not set; using ephemeral value", flush=True)
    _secret = os.urandom(32).hex()
app.secret_key = _secret

CLIENT_ID     = _cred("PAYPAL_CLIENT_ID")
CLIENT_SECRET = _cred("PAYPAL_CLIENT_SECRET")
WEBHOOK_ID    = _cred("WEBHOOK_ID")
BASE_URL      = os.getenv("BASE_URL", "http://localhost:5000").rstrip("/")
API_BASE      = os.getenv("PAYPAL_API_BASE", "https://api-m.sandbox.paypal.com")
PAYPAL_DASHBOARD_URL = os.getenv(
    "PAYPAL_DASHBOARD_URL",
    "https://developer.paypal.com/dashboard/applications/sandbox")
PAYPAL_SANDBOX_ACCOUNTS_URL = os.getenv(
    "PAYPAL_SANDBOX_ACCOUNTS_URL",
    "https://developer.paypal.com/dashboard/accounts")
PORT          = int(os.getenv("PORT", "5000"))
HOST          = os.getenv("HOST", "0.0.0.0")
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

def _make_paypal():
    return PaypalServersdkClient(
        client_credentials_auth_credentials=ClientCredentialsAuthCredentials(
            o_auth_client_id=CLIENT_ID, o_auth_client_secret=CLIENT_SECRET),
        environment=Environment.SANDBOX)

paypal = _make_paypal()

def _reload_creds():
    global CLIENT_ID, CLIENT_SECRET, WEBHOOK_ID, paypal
    CLIENT_ID     = _cred("PAYPAL_CLIENT_ID")
    CLIENT_SECRET = _cred("PAYPAL_CLIENT_SECRET")
    WEBHOOK_ID    = _cred("WEBHOOK_ID")
    paypal = _make_paypal()

_oauth_attempts = {}

def _creds_ok():
    return (not _is_placeholder(CLIENT_ID)) and (not _is_placeholder(CLIENT_SECRET))

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

def _mask_id(s):
    if not s or _is_placeholder(s): return "not configured"
    if len(s) <= 8: return "set (short)"
    return s[:4] + "..." + s[-4:]

def _mask_sec(s):
    if not s or _is_placeholder(s): return "not configured"
    return "set (" + str(len(s)) + " chars)"

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
        "CORS_PAGES_ORIGIN": CORS_PAGES_ORIGIN,
        "SETUP_REQUIRES_LOGIN": str(SETUP_REQUIRES_LOGIN),
        "CREDS_FROM_ENV_ONLY": str(CREDS_FROM_ENV_ONLY),
    }
    creds_hint = {
        "client_id":     _mask_id(CLIENT_ID),
        "client_secret": _mask_sec(CLIENT_SECRET),
        "webhook_id":    _mask_sec(WEBHOOK_ID),
        "secret_key":    _mask_sec(app.secret_key if isinstance(app.secret_key, str) else app.secret_key.hex() if isinstance(app.secret_key, bytes) else ""),
    }
    return render_template("setup.html",
        brand=_brand()["name"], cfg=cfg, plans=_plans(),
        current_brand=_brand(), scan_hosts=SCAN_HOSTS, scan_ports=SCAN_PORTS,
        creds_ok=_creds_ok(), creds_locked=CREDS_FROM_ENV_ONLY, creds_hint=creds_hint,
        dashboard_url=PAYPAL_DASHBOARD_URL,
        sandbox_accounts_url=PAYPAL_SANDBOX_ACCOUNTS_URL,
        setup_url=f"http://localhost:{PORT}/setup")

# ---------- secrets endpoints ----------
@app.route("/setup/secrets", methods=["GET"])
def setup_secrets_get():
    return jsonify({
        "locked": CREDS_FROM_ENV_ONLY,
        "paypal_client_id_set": not _is_placeholder(CLIENT_ID),
        "paypal_client_secret_set": not _is_placeholder(CLIENT_SECRET),
        "webhook_id_set": not _is_placeholder(WEBHOOK_ID),
        "secret_key_set": bool(app.secret_key),
        "paypal_client_id_hint": _mask_id(CLIENT_ID),
    })

@app.route("/setup/secrets/test", methods=["POST"])
def setup_secrets_test():
    data = request.get_json(silent=True) or {}
    cid = (data.get("paypal_client_id") or "").strip() or CLIENT_ID
    cs  = (data.get("paypal_client_secret") or "").strip() or CLIENT_SECRET
    if _is_placeholder(cid) or _is_placeholder(cs):
        return jsonify({"ok": False, "error": "no credentials to test"}), 400
    ip = request.remote_addr or "?"
    now = time.time()
    hits = [t for t in _oauth_attempts.get(ip, []) if now - t < 60]
    if len(hits) >= 5:
        return jsonify({"ok": False, "error": "rate limited (5/min)"}), 429
    _oauth_attempts[ip] = hits + [now]
    try:
        r = requests.post(f"{API_BASE}/v1/oauth2/token",
            auth=(cid, cs),
            data={"grant_type": "client_credentials"}, timeout=15)
        return jsonify({"ok": r.status_code == 200,
                        "status": r.status_code,
                        "detail": "OK" if r.status_code == 200 else r.text[:200]})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 502

@app.route("/setup/secrets", methods=["POST"])
def setup_secrets_post():
    global paypal
    if CREDS_FROM_ENV_ONLY:
        return jsonify({"ok": False, "error": "CREDS_FROM_ENV_ONLY=1; use .env"}), 403
    data = request.get_json(silent=True) or {}
    cid = (data.get("paypal_client_id") or "").strip()
    cs  = (data.get("paypal_client_secret") or "").strip()
    wh  = (data.get("webhook_id") or "").strip()
    sk  = (data.get("secret_key") or "").strip()

    if not cid or not cs:
        return jsonify({"ok": False, "error": "client_id and client_secret required"}), 400
    if _is_placeholder(cid) or _is_placeholder(cs):
        return jsonify({"ok": False, "error": "values look like placeholders"}), 400

    ip = request.remote_addr or "?"
    now = time.time()
    hits = [t for t in _oauth_attempts.get(ip, []) if now - t < 60]
    if len(hits) >= 5:
        return jsonify({"ok": False, "error": "rate limited (5/min)"}), 429
    _oauth_attempts[ip] = hits + [now]

    try:
        r = requests.post(f"{API_BASE}/v1/oauth2/token",
            auth=(cid, cs),
            data={"grant_type": "client_credentials"}, timeout=15)
    except Exception as e:
        return jsonify({"ok": False, "error": f"PayPal OAuth failed: {e}"}), 502
    if r.status_code != 200:
        return jsonify({"ok": False,
                        "error": f"PayPal OAuth {r.status_code}",
                        "detail": r.text[:200]}), 400

    sec = _read_secrets()
    sec["PAYPAL_CLIENT_ID"] = cid
    sec["PAYPAL_CLIENT_SECRET"] = cs
    if wh: sec["WEBHOOK_ID"] = wh
    if sk: sec["SECRET_KEY"] = sk
    try:
        _write_secrets(sec)
    except Exception as e:
        return jsonify({"ok": False, "error": f"save failed: {e}"}), 500

    _reload_creds()
    if sk:
        app.secret_key = sk
    return jsonify({"ok": True, "validated": True, "session_invalidated": bool(sk)})

# ---------- brand/asset endpoints ----------
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
    if not _creds_ok():
        return jsonify({"ok": False, "error": "PayPal credentials not configured (placeholders detected)"}), 400
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

# ---------- auth & app routes ----------
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
        return "PLAN_ID not configured. Use /setup to register plans.", 500
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
    return jsonify({"status": "healthy", "brand": _brand()["name"],
                    "creds_configured": _creds_ok()})

def _cli_prompt_creds():
    if not sys.stdin.isatty():
        print("PayPal credentials not set; skipping interactive prompt (stdin not a TTY).", flush=True)
        print("Configure at /setup in the browser.", flush=True)
        return
    if _creds_ok():
        return
    print("", flush=True)
    print("PayPal credentials are not configured.", flush=True)
    print("Enter them now (validated against PayPal), or use /setup in the browser.", flush=True)
    try:
        ans = input("Prompt now? [y/N] ").strip().lower()
    except EOFError:
        return
    if ans != "y":
        return
    import getpass
    try:
        cid = input("PayPal Client ID: ").strip()
        cs = getpass.getpass("PayPal Client Secret: ")
    except (EOFError, KeyboardInterrupt):
        print("Aborted; continuing without creds.", flush=True)
        return
    if not cid or not cs:
        print("Empty input; continuing without creds.", flush=True)
        return
    try:
        r = requests.post(f"{API_BASE}/v1/oauth2/token",
            auth=(cid, cs),
            data={"grant_type": "client_credentials"}, timeout=15)
    except Exception as e:
        print(f"Validation failed: {e}. Continuing without creds.", flush=True)
        return
    if r.status_code == 200:
        sec = _read_secrets()
        sec["PAYPAL_CLIENT_ID"] = cid
        sec["PAYPAL_CLIENT_SECRET"] = cs
        try:
            _write_secrets(sec)
            _reload_creds()
            print("Saved to config/secrets.json (mode 0600).", flush=True)
        except Exception as e:
            print(f"Save failed: {e}. Continuing without persisting.", flush=True)
    else:
        print(f"Validation failed: HTTP {r.status_code}. Continuing without creds.", flush=True)

if __name__ == "__main__":
    print(f"Starting {_brand()['name']} on {HOST}:{PORT}", flush=True)
    _cli_prompt_creds()
    app.run(host=HOST, port=PORT, debug=False)
