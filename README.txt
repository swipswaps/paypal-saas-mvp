================================================================
PayPal Python SaaS Subscription MVP — Audited, Idempotent Edition
================================================================
CREDITS: NeuralNine — https://youtu.be/zSExhXEfhJo
Repo:  https://github.com/swipswaps/paypal-saas-mvp
Pages: https://swipswaps.github.io/paypal-saas-mvp/

NEW IN THIS EDITION
-------------------
- Port detection with interactive conflict resolution
  The Pages site probes localhost / 127.0.0.1 / 0.0.0.0 on ports
  5000, 5001, 5002, 8000, 8080, 3000. If 5000 is taken by another
  service it shows an actionable panel with lsof/ss commands, common
  causes (AirPlay, Docker Registry, stale Flask), and a one-line .env
  edit to move the app to a different port.

- Interactive white-label and pricing on the Pages site
  Form at /config-builder on the Pages site emits a .env snippet with
  BRAND_NAME, BRAND_TAGLINE, TIER_*_NAME, TIER_*_PRICE, CURRENCY_CODE,
  CURRENCY_SYMBOL, BILLING_INTERVAL. Save those, re-run setup_plans.py,
  and rebuild — the app, the pricing, and the plan registered at PayPal
  all reflect the new values. Form state persists in localStorage.

- PORT and HOST env vars
  app.py now reads PORT (default 5000) and HOST (default 0.0.0.0).
  docker-compose.yml maps ${PORT:-5000} on both sides, so setting PORT
  in .env moves the app cleanly. Dockerfile HEALTHCHECK is PORT-aware.

- fingerprint-port.sh
  Run `bash fingerprint-port.sh 5000` to identify what is actually
  listening on any port (lsof, ss, curl headers, common-cause hints).

QUICK START
-----------
1. git clone https://github.com/swipswaps/paypal-saas-mvp.git && cd paypal-saas-mvp
2. python3 -m venv .venv && . .venv/bin/activate
   pip install flask paypal-server-sdk python-dotenv requests Werkzeug cryptography
3. cp .env.example .env — fill PAYPAL_CLIENT_ID / PAYPAL_CLIENT_SECRET / SECRET_KEY / BASE_URL.
   Enable Catalog + Subscriptions at https://developer.paypal.com/dashboard/applications
4. python setup_plans.py — copy PLAN_ID_BASIC / PLAN_ID_PRO into .env
5. ngrok http --domain=your-static-name.ngrok-free.app 5000
   set BASE_URL; add webhook .../webhook in PayPal dashboard; set WEBHOOK_ID
6. docker compose up -d --build   (or python app.py)
7. Open http://localhost:5000

WHITE-LABEL / PRICING
---------------------
Use the Config Builder form at the Pages site. It emits:
  BRAND_NAME=...
  BRAND_TAGLINE=...
  TIER_BASIC_NAME=... / TIER_BASIC_PRICE=...
  TIER_PRO_NAME=...   / TIER_PRO_PRICE=...
  CURRENCY_CODE=USD   / CURRENCY_SYMBOL=$
  BILLING_INTERVAL=MONTH
Append those to .env. Then:
  python setup_plans.py              # registers new plans at PayPal
  # copy new PLAN_ID_BASIC / PLAN_ID_PRO into .env
  docker compose up -d --build       # restarts with new branding

PORT CONFLICT RESOLUTION
------------------------
If 5000 is taken, the Pages site shows a Port conflict panel with the
diagnostic commands. To move this app:
  add PORT=5001 to .env
  docker compose up -d --build
The probe on the Pages site auto-detects the new port within a few seconds.


PORT SCAN AND /setup
--------------------
- The backend now identifies what is on each configured port
  (localhost, host.docker.internal, 172.17.0.1 x 5000/5001/5002/8000/8080/3000).
  Open http://localhost:5000/setup and click "Scan now".
- On startup the app also prints:
    localhost:5000 -> paypal-saas-backend
    localhost:5001 -> python http.server
    ...
- The Pages site has a "Scan via detected backend" button that enriches the
  browser probe with the same identities (needed because the browser cannot
  read cross-origin server headers).

CUSTOM PROBE INPUT
------------------
The Pages probe accepts "localhost:5001", "5001", "localhost", or a full URL.
HTTP endpoints on non-loopback hosts are blocked by mixed-content rules when
the page is HTTPS; the UI says so explicitly.

REQUIRE LOGIN FOR /setup (recommended for exposed deployments)
-------------------------------------------------------------
echo "SETUP_REQUIRES_LOGIN=1" >> .env
docker compose up -d --build

IDEMPOTENCY
-----------
- Managed files overwritten on each bootstrap run.
- .env created only if missing; your credentials are never clobbered.
- saas_shop.db touched, never truncated.
- .git, origin, GitHub repo, Pages config detected and reused.


FILE OWNERSHIP AND ONE-TIME HOST PREP
-------------------------------------
The container runs as ${HOST_UID:-1000}:${HOST_GID:-1000} (see .env). Set these
to match your host user so files created inside the container are owned by you:

    echo "HOST_UID=$(id -u)" >> .env
    echo "HOST_GID=$(id -g)" >> .env

One-time host prep (before the first `docker compose up --build`):

    mkdir -p config static/brand
    chmod 0777 config static/brand
    touch saas_shop.db
    chmod 0666 saas_shop.db

Then:

    docker compose up -d --build

If a previous run left root-owned files behind, either restore via:

    bash restore_brand.sh <snapshot.json>

or fix in place:

    docker exec -u root paypal-saas-mvp_fail-web-1 \
      chmod -R 0777 /app/config /app/static/brand


ACCOUNT FEATURES
----------------
Login / logout / multi-device sessions: verified by account_audit.sh.
Change-password / forgot-password / change-email / delete-account / CSRF /
rate-limiting: not implemented (404 or INFO). Documented on Pages site.

TROUBLESHOOTING
---------------
- Port 5000 in use (not our app)  ->  bash fingerprint-port.sh 5000
                                     or set PORT=5001 in .env
- "CORS blocked" in probe         ->  another service is on the port
- ModuleNotFoundError: paypal_server_sdk -> package is paypalserversdk
- ModuleNotFoundError: requests   ->  venv + pip install step 2
- 401 on every API call           ->  o_auth_client_id not oath_
- Webhook 400 Invalid signature   ->  verify raw bytes, not re-serialized JSON
- database is locked              ->  WAL mode + timeout=15
- is a directory (Docker)         ->  touch saas_shop.db

SECURITY
--------
- .gitignore excludes .env, *.db*, .venv/
- debug=False always
- Add Flask-WTF CSRF before production use

OFFICIAL DOCS
-------------
https://github.com/paypal/PayPal-Python-Server-SDK
https://developer.paypal.com/docs/api/subscriptions/v1/
https://developer.paypal.com/api/rest/webhooks/rest/
https://docs.docker.com/
https://ngrok.com/docs/pricing-limits/free-plan-limits
================================================================
