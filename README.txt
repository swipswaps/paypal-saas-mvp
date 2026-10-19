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

IDEMPOTENCY
-----------
- Managed files overwritten on each bootstrap run.
- .env created only if missing; your credentials are never clobbered.
- saas_shop.db touched, never truncated.
- .git, origin, GitHub repo, Pages config detected and reused.

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
