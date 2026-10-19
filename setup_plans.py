import os, sys, requests
from dotenv import load_dotenv
load_dotenv()
CLIENT_ID = os.getenv("PAYPAL_CLIENT_ID")
CLIENT_SECRET = os.getenv("PAYPAL_CLIENT_SECRET")
API_BASE = os.getenv("PAYPAL_API_BASE", "https://api-m.sandbox.paypal.com")
if not CLIENT_ID or not CLIENT_SECRET:
    print("ERROR: PAYPAL_CLIENT_ID and PAYPAL_CLIENT_SECRET must be set in .env", file=sys.stderr)
    sys.exit(2)
def token():
    r = requests.post(f"{API_BASE}/v1/oauth2/token",
        auth=(CLIENT_ID, CLIENT_SECRET),
        data={"grant_type": "client_credentials"}, timeout=15)
    if r.status_code == 401:
        print("ERROR: PayPal returned 401. Check credentials.", file=sys.stderr); sys.exit(2)
    r.raise_for_status()
    return r.json()["access_token"]
def headers(tok):
    return {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"}
def create_product(tok):
    body = {"name": "Demo SaaS Platform", "description": "Cloud software subscription service",
            "type": "SERVICE", "category": "SOFTWARE"}
    r = requests.post(f"{API_BASE}/v1/catalogs/products", headers=headers(tok), json=body, timeout=15)
    if r.status_code in (401, 403):
        print("ERROR: Catalog API 401/403. Enable Catalog and Subscriptions at "
              "https://developer.paypal.com/dashboard/applications", file=sys.stderr); sys.exit(2)
    r.raise_for_status()
    pid = r.json()["id"]; print(f"Product ID: {pid}"); return pid
def create_plan(tok, product_id, name, price):
    body = {"product_id": product_id, "name": name,
            "description": f"{name} monthly subscription", "status": "ACTIVE",
            "billing_cycles": [{"frequency": {"interval_unit": "MONTH", "interval_count": 1},
                "tenure_type": "REGULAR", "sequence": 1, "total_cycles": 0,
                "pricing_scheme": {"fixed_price": {"value": price, "currency_code": "USD"}}}],
            "payment_preferences": {"auto_bill_outstanding": True, "payment_failure_threshold": 3}}
    r = requests.post(f"{API_BASE}/v1/billing/plans", headers=headers(tok), json=body, timeout=15)
    if r.status_code in (401, 403):
        print("ERROR: Billing Plans API 401/403. Enable Subscriptions for your app.", file=sys.stderr); sys.exit(2)
    r.raise_for_status()
    plan_id = r.json()["id"]; print(f"{name} plan ID: {plan_id}"); return plan_id
if __name__ == "__main__":
    tok = token(); prod = create_product(tok)
    basic = create_plan(tok, prod, "Basic Tier", "9.99")
    pro   = create_plan(tok, prod, "Pro Tier", "29.99")
    print("\nAdd these to .env:")
    print(f"PLAN_ID_BASIC={basic}")
    print(f"PLAN_ID_PRO={pro}")
