"""Ask the intent model N times for its verdict + reasoning on the scenario 3
payments, to see why the authorized invoice (INV-4471) is sometimes flagged.

Usage: python scripts/explain_intent.py [N]
"""
import os
import sys

import httpx

BASE = os.getenv("JAC_API_URL", "http://localhost:8001").rstrip("/") + "/function/"
ADMIN = os.environ["ADMIN_API_KEY"]

CASES = [("INV-4471 (authorized)", "Acme Supplies", 4200.00, "INV-4471"),
         ("INV-4502 (not authorized)", "Acme Supplies", 4350.00, "INV-4502")]


def main() -> None:
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    for label, payee, amount, inv in CASES:
        for i in range(n):
            r = httpx.post(BASE + "debug_explain_intent", timeout=180, json={
                "api_key": ADMIN, "payee_name": payee, "amount": amount, "invoice_id": inv,
            }).json()["data"]["result"]
            if i == 0:
                print(f"\n== {label}  inputs={r.get('inputs')}")
            print(f"  [{i + 1}] {r.get('verdict')}: {r.get('rationale') or r.get('error')}", flush=True)


if __name__ == "__main__":
    main()
