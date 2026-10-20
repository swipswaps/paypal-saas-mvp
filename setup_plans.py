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
