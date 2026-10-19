================================================================
PayPal Python SaaS Subscription MVP — Audited, Idempotent Edition
================================================================
CREDITS: NeuralNine, "PayPal Python Crash Course" — https://youtu.be/zSExhXEfhJo

STEP-BY-STEP
1. Fill .env: PAYPAL_CLIENT_ID, PAYPAL_CLIENT_SECRET, SECRET_KEY, BASE_URL.
   Enable Catalog + Subscriptions at https://developer.paypal.com/dashboard/applications
2. python setup_plans.py — copy PLAN_ID_BASIC / PLAN_ID_PRO into .env.
3. ngrok static domain: https://dashboard.ngrok.com/cloud-edge/domains
   ngrok http --domain=your-static-name.ngrok-free.app 5000
   Add webhook URL .../webhook in the PayPal dashboard; copy WEBHOOK_ID into .env.
4. docker compose up --build -d   (or python app.py)
5. Open http://localhost:5000, register, subscribe, check /events.

IDEMPOTENCY
- Managed files overwritten each run.
- .env created only if missing.
- saas_shop.db touched, never truncated.
- .git, origin, GitHub repo, Pages config detected and reused.

TROUBLESHOOTING
- ModuleNotFoundError: paypal_server_sdk -> package is `paypalserversdk`, class `PaypalServersdkClient`
- 401 on every API call -> use `o_auth_client_id`/`o_auth_client_secret`, not `oath_*`
- Webhook 400 Invalid signature -> read request.get_data() first; verify CRC32 + RSA on raw bytes
- database is locked -> WAL mode enabled; keep timeout=15
- `is a directory` on Docker -> touch saas_shop.db (script does this)
- GitHub Pages 404 -> enable Pages from /docs
- gh api Pages 422 -> use -F 'source[branch]=main' -F 'source[path]=/docs'
- gh exits 0 on 404 -> parse stderr for '404'
- setup_plans.py 401/403 -> enable Catalog + Subscriptions scopes

SECURITY
- .gitignore excludes .env, *.db*, .venv/
- debug=False
- Add Flask-WTF CSRF before production

OFFICIAL DOCS
https://github.com/paypal/PayPal-Python-Server-SDK
https://developer.paypal.com/docs/api/subscriptions/v1/
https://developer.paypal.com/api/rest/webhooks/rest/
https://docs.docker.com/
https://pve.proxmox.com/wiki/Linux_Container
https://ngrok.com/docs/pricing-limits/free-plan-limits
https://docs.github.com/en/rest/pages/pages
================================================================
