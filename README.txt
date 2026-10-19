================================================================
PayPal Python SaaS Subscription MVP — Audited Edition
================================================================

CREDITS
-------
Architecture and original tutorial concept: NeuralNine
  "PayPal Python Crash Course - Integrate Payments Easily"
  https://youtu.be/zSExhXEfhJo

This repository corrects the tutorial's blocking errors (SDK import
names, OAuth parameter typos, webhook raw-body handling) and adds
Docker / Proxmox deployment, a static GitHub Pages landing page, and
a full troubleshooting guide.

WHAT THIS REPO IS (AND IS NOT)
-------------------------------
* The Flask app + SQLite + webhook listener runs in Docker or a
  Proxmox LXC container. It CANNOT run on GitHub Pages.
* GitHub Pages serves only the static `docs/` landing page.
* One-time checkout and subscription patterns are both supported;
  the subscription flow is the primary MVP.

STEP-BY-STEP SETUP
------------------
1. Clone and enter the repo
   git clone https://github.com/<owner>/paypal-saas-mvp.git
   cd paypal-saas-mvp

2. Configure environment
   cp .env.example .env
   Edit .env and fill:
     PAYPAL_CLIENT_ID / PAYPAL_CLIENT_SECRET  (Sandbox app)
     SECRET_KEY                                (long random string)
     BASE_URL                                  (your ngrok static domain)
   Get sandbox credentials:
   https://developer.paypal.com/dashboard/applications
   Enable the Catalog and Subscriptions capabilities for your app.

3. Register catalog product and plans
   python setup_plans.py
   Copy the printed PLAN_ID_BASIC and PLAN_ID_PRO into .env.

4. Expose localhost for webhooks
   Free ngrok includes ONE static dev domain. Claim it at
   https://dashboard.ngrok.com/cloud-edge/domains
   then:
     ngrok http --domain=your-static-name.ngrok-free.app 5000
   Set BASE_URL to that HTTPS URL in .env.
   In the PayPal Developer Dashboard -> your App -> Webhooks:
     URL: https://your-static-name.ngrok-free.app/webhook
     Events: BILLING.SUBSCRIPTION.* and PAYMENT.SALE.COMPLETED
   Copy the resulting Webhook ID into .env as WEBHOOK_ID.

5. Launch
   Docker:   docker compose up --build -d
   Local:    python app.py
   Open http://localhost:5000

6. Test the flow
   Register -> log in -> subscribe -> approve in PayPal sandbox ->
   check /events for BILLING.SUBSCRIPTION.ACTIVATED.

TROUBLESHOOTING — TESTED SOLUTIONS
----------------------------------
| Symptom | Cause | Fix |
|---|---|---|
| ModuleNotFoundError: paypal_server_sdk | Wrong import. Package is `paypalserversdk`. | Use `from paypalserversdk.paypal_serversdk_client import PaypalServersdkClient`. |
| 401 on every API call | Typo `oath_client_id` / `oath_client_secret`. | Use `o_auth_client_id` / `o_auth_client_secret`. |
| Webhook returns 400 Invalid signature | Parsed JSON was re-serialised before verification. | Read `request.get_data()` first; verify raw bytes with CRC32 + RSA. |
| database is locked | Concurrent webhook writes on SQLite. | WAL mode is enabled; keep `timeout=15` on connections. |
| `is a directory` on first Docker run | Bind-mounted `saas_shop.db` did not exist; Docker created a directory. | The bootstrap script now runs `touch saas_shop.db` before `docker compose up`. |
| GitHub Pages 404 | Pages enabled on root with no `index.html`, or Flask app cannot run on Pages. | Enable Pages from `/docs`; keep a static `docs/index.html`. |
| gh api Pages 422 | Used `-f` instead of `-F` for nested `source` fields. | Use `-F 'source[branch]=main' -F 'source[path]=/docs'`. |
| gh api silently “succeeds” on 404 | `gh` exits 0 on HTTP 404 and 401. | Parse stderr for `404` instead of trusting `$?`. |
| ngrok URL changes after restart | Free URLs drift unless static domain claimed. | Claim the free static domain and use `--domain`. |
| TemplateNotFound | `templates/` folder missing or incomplete. | Ensure all 9 HTML files exist. |
| setup_plans.py 401/403 | Sandbox app lacks Catalog / Subscriptions scopes. | Enable them at https://developer.paypal.com/dashboard/applications. |
| SECRET_KEY warning on startup | `SECRET_KEY` is blank or still the placeholder. | Set a long random string in `.env`. |

SECURITY NOTES
--------------
* Never commit `.env`. `.gitignore` now excludes it.
* `debug=False` is mandatory for any publicly reachable instance.
* Add Flask-WTF CSRF tokens before production.
* The webhook verification here is cryptographic self-verification;
  it does not rely on the postback CRC re-serialisation pitfall.

WHAT MAKES SENSE NEXT
---------------------
* Migrate SQLite -> PostgreSQL for multi-container deployments.
* Add Celery + Redis to offload webhook processing.
* Add Flask-WTF CSRF protection.
* Add pytest integration tests with mocked PayPal webhook payloads.
* Abstract payment providers (PayPal + Stripe) behind one interface.

OFFICIAL DOCUMENTATION
----------------------
PayPal Python Server SDK:
  https://github.com/paypal/PayPal-Python-Server-SDK
PayPal Subscriptions API:
  https://developer.paypal.com/docs/api/subscriptions/v1/
PayPal Webhooks:
  https://developer.paypal.com/api/rest/webhooks/rest/
Docker:
  https://docs.docker.com/
Proxmox LXC:
  https://pve.proxmox.com/wiki/Linux_Container
ngrok free plan:
  https://ngrok.com/docs/pricing-limits/free-plan-limits
GitHub Pages API:
  https://docs.github.com/en/rest/pages/pages
================================================================
