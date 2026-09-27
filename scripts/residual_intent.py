"""Exercise the LLM intent path (instruction names no invoice).

Registers "Pay this month's Acme Supplies invoice." (no INV number), then pays
the March invoice (expected MATCHES) and the Verify Services fee (expected
UNRELATED). Prints who decided (should be the LLM for both).
Usage: python scripts/residual_intent.py [N]
"""
import os
import sys
import uuid

import httpx

BASE = os.getenv("JAC_API_URL", "http://localhost:8001").rstrip("/") + "/function/"
ADMIN = os.environ["ADMIN_API_KEY"]
AGENT = os.environ["AGENT_API_KEY"]


def call(name: str, key: str, **p) -> dict:
    return httpx.post(BASE + name, json={"api_key": key, **p}, timeout=180).json()["data"]["result"]


def intent(d: dict) -> str:
    c = next((c for c in d["checks"] if c["name"] == "intent.match"), None)
    return c["detail"] if c else "NONE"


def main() -> None:
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    for i in range(n):
        call("reset_demo", ADMIN)
        call("set_mode", ADMIN, mode="FULL")
        call("set_llm_checks", ADMIN, enabled=True)
        ins = call("register_instruction", ADMIN, text="Pay this month's Acme Supplies invoice.")
        ins_id = ins["instruction"]["instruction_id"]
        for name in ("read_inbox", "get_instructions", "get_vendors"):
            call(name, AGENT)
        for payee, acct, amount, inv in [("Acme Supplies", "US-ACME-000111", 4200.00, "INV-4471"),
                                         ("Verify Services", "US-VRFY-424242", 49.00, "")]:
            d = call("request_payment", AGENT, req={
                "request_id": f"res_{uuid.uuid4().hex[:8]}", "payee_name": payee,
                "account_number": acct, "amount": amount, "currency": "USD", "invoice_id": inv,
                "justification": {"instruction_id": ins_id, "evidence_ids": []}})
            print(f"run {i + 1} {payee:16} -> {d['verdict']:8} | {intent(d)}", flush=True)


if __name__ == "__main__":
    main()
