import os, json, sqlite3, zlib, base64
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
    print("WARNING: SECRET_KEY is not set or is the placeholder value.", flush=True)
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

PLANS = {
    "basic": {
        "name": os.getenv("TIER_BASIC_NAME", "Basic Tier"),
        "price": os.getenv("TIER_BASIC_PRICE", "9.99"),
        "plan_id": os.getenv("PLAN_ID_BASIC"),
    },
    "pro": {
        "name": os.getenv("TIER_PRO_NAME", "Pro Tier"),
        "price": os.getenv("TIER_PRO_PRICE", "29.99"),
        "plan_id": os.getenv("PLAN_ID_PRO"),
    },
}

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
    return {
        "BRAND_NAME": os.getenv("BRAND_NAME", "Demo SaaS"),
        "BRAND_TAGLINE": os.getenv("BRAND_TAGLINE",
            "Sandbox subscription billing with PayPal Server SDK and Flask."),
        "CURRENCY_SYMBOL": os.getenv("CURRENCY_SYMBOL", "$"),
    }

def current_user():
    uid = session.get("user_id")
    if not uid: return None
    return get_db().execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()

@app.route("/")
def index():
    return render_template("index.html", user=current_user(), plans=PLANS)

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
    return render_template("dashboard.html", user=user, plans=PLANS)

@app.route("/premium")
def premium():
    user = current_user()
    if not user or user["tier"] == "free":
        return render_template("upgrade_required.html", user=user)
    return render_template("premium.html", user=user)

@app.route("/subscribe/<tier>")
def subscribe(tier):
    user = current_user()
    if not user or tier not in PLANS: return redirect(url_for("login"))
    plan_id = PLANS[tier]["plan_id"]
    if not plan_id:
        return "PLAN_ID not configured. Run setup_plans.py and update .env.", 500
    from paypalserversdk.models.create_subscription_request import CreateSubscriptionRequest
    from paypalserversdk.models.subscription_application_context import SubscriptionApplicationContext
    req = CreateSubscriptionRequest(plan_id=plan_id, custom_id=str(user["id"]),
        application_context=SubscriptionApplicationContext(brand_name=os.getenv("BRAND_NAME", "Demo SaaS"),
            return_url=f"{BASE_URL}/subscription/success", cancel_url=f"{BASE_URL}/dashboard",
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
        tier = next((t for t, p in PLANS.items() if p["plan_id"] == plan_id), "free")
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
    resp = jsonify({"status": "healthy", "brand": os.getenv("BRAND_NAME", "Demo SaaS")})
    resp.headers["Access-Control-Allow-Origin"] = "https://swipswaps.github.io"
    resp.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
    resp.headers["Vary"] = "Origin"
    return resp

if __name__ == "__main__":
    print(f"Starting {os.getenv('BRAND_NAME', 'Demo SaaS')} on {HOST}:{PORT}", flush=True)
    app.run(host=HOST, port=PORT, debug=False)
