================================================================
PayPal Python SaaS Subscription MVP — Audited, Idempotent Edition
================================================================
CREDITS: NeuralNine, "PayPal Python Crash Course" — https://youtu.be/zSExhXEfhJo
Repo: https://github.com/swipswaps/paypal-saas-mvp
Pages: https://swipswaps.github.io/paypal-saas-mvp/

QUICK START
-----------
1. Clone
     git clone https://github.com/swipswaps/paypal-saas-mvp.git
     cd paypal-saas-mvp

2. Install Python dependencies (skip if using Docker only)
     python3 -m venv .venv
     . .venv/bin/activate
     pip install flask paypal-server-sdk python-dotenv requests Werkzeug cryptography
   Skipping this step makes `python setup_plans.py` fail with
   ModuleNotFoundError: requests (or a broken urllib3 import).

3. Configure environment
     cp .env.example .env
     Edit .env:
       PAYPAL_CLIENT_ID, PAYPAL_CLIENT_SECRET  from https://developer.paypal.com/dashboard/applications
       SECRET_KEY                              a long random string
       BASE_URL                                your ngrok static HTTPS URL (step 5)
     Enable "Catalog" and "Subscriptions" scopes on the PayPal app.

4. Register subscription plans
     python setup_plans.py
     Copy the printed PLAN_ID_BASIC / PLAN_ID_PRO into .env.

5. Expose webhooks with ngrok
     Claim a free static domain at https://dashboard.ngrok.com/cloud-edge/domains
     ngrok http --domain=your-static-name.ngrok-free.app 5000
     Add webhook URL https://your-static-name.ngrok-free.app/webhook in the
     PayPal dashboard; subscribe to BILLING.SUBSCRIPTION.* and
     PAYMENT.SALE.COMPLETED; copy WEBHOOK_ID into .env.

6. Launch
     Docker:  docker compose up -d --build
     Local:   python app.py
     App runs at http://localhost:5000

7. Test
     Open http://localhost:5000, register, subscribe, approve in the
     PayPal sandbox, inspect http://localhost:5000/events.

IDEMPOTENCY
- Managed files overwritten each run.
- .env created only if missing.
- saas_shop.db touched, never truncated.
- .git, origin, GitHub repo, Pages config detected and reused.

TROUBLESHOOTING
---------------
- ModuleNotFoundError: paypal_server_sdk -> package is `paypalserversdk`, class `PaypalServersdkClient`
- ModuleNotFoundError: requests -> run step 2 above (venv + pip install), then re-run setup_plans.py
- 401 on every API call -> use `o_auth_client_id` / `o_auth_client_secret`, not `oath_*`
- Webhook 400 Invalid signature -> read request.get_data() first; verify CRC32 + RSA on raw bytes
- database is locked -> WAL mode is enabled; keep timeout=15
- `is a directory` on Docker -> touch saas_shop.db (script does this)
- GitHub Pages 404 -> enable Pages from /docs on the main branch
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
