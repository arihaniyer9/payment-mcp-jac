"""Phase 4: dashboard endpoints and escalation resolution through the gateway.

All tests use LLM checks OFF and MOCK_GATEWAY (the server default), so they
are fast and never hit Stripe.
Run one at a time: bash scripts/run_tests.sh tests/test_phase4.py::test_name
"""
import os
import uuid

import httpx
import pytest

BASE_URL = os.getenv("JAC_API_URL", "http://localhost:8001").rstrip("/")
ADMIN_KEY = os.environ.get("ADMIN_API_KEY", "")
AGENT_KEY = os.environ.get("AGENT_API_KEY", "")
if not ADMIN_KEY or not AGENT_KEY:
    pytest.fail("AGENT_API_KEY and ADMIN_API_KEY must be set", pytrace=False)


def call(_endpoint: str, _key: str, /, **payload) -> dict:
    r = httpx.post(f"{BASE_URL}/function/{_endpoint}", json={"api_key": _key, **payload},
                   timeout=120).json()
    return r["data"]["result"]


def fresh() -> None:
    call("reset_demo", ADMIN_KEY)
    call("set_mode", ADMIN_KEY, mode="FULL")
    call("set_llm_checks", ADMIN_KEY, enabled=False)
    for name in ("read_inbox", "get_instructions", "get_vendors"):
        call(name, AGENT_KEY)


def pay(account: str, amount: float, invoice: str = "INV-4471", payee: str = "Acme Supplies") -> dict:
    return call("request_payment", AGENT_KEY, req={
        "request_id": f"p4_{uuid.uuid4().hex[:8]}", "payee_name": payee,
        "account_number": account, "amount": amount, "currency": "USD", "invoice_id": invoice,
        "justification": {"instruction_id": "ins_001", "evidence_ids": []}})


def invoice_paid(invoice_id: str) -> bool:
    for v in call("get_vendors", AGENT_KEY)["vendors"]:
        for inv in v["open_invoices"]:
            if inv["invoice_id"] == invoice_id:
                return inv["paid"]
    raise AssertionError(f"{invoice_id} not found")


def test_resolve_approve_charges_and_marks_invoice_paid():
    fresh()
    d = pay("US-ACME-000111", 6000.00)  # over the $5,000 cap -> ESCALATE
    assert d["verdict"] == "ESCALATE", d
    assert not invoice_paid("INV-4471")
    r = call("resolve_escalation", ADMIN_KEY, request_id=d["request_id"], action="APPROVE")
    assert r["ok"] is True
    assert r["request"]["status"] == "RESOLVED_APPROVE"
    assert r["request"]["payment_ref"].startswith("mock_")
    assert invoice_paid("INV-4471")
    again = call("resolve_escalation", ADMIN_KEY, request_id=d["request_id"], action="APPROVE")
    assert again["ok"] is False and again["error"]["code"] == "CONFLICT"


def test_resolve_deny_does_not_charge():
    fresh()
    d = pay("US-ACME-000111", 6000.00)
    r = call("resolve_escalation", ADMIN_KEY, request_id=d["request_id"], action="DENY")
    assert r["ok"] is True and r["request"]["status"] == "RESOLVED_DENY"
    assert r["request"]["payment_ref"] is None
    assert not invoice_paid("INV-4471")


def test_list_decisions_newest_first_with_fields():
    fresh()
    first = pay("US-ACME-000111", 6000.00)
    second = pay("US-XFER-998877", 4200.00)
    rows = call("list_decisions", ADMIN_KEY)["decisions"]
    ids = [r["request_id"] for r in rows]
    assert ids.index(second["request_id"]) < ids.index(first["request_id"])
    row = rows[ids.index(second["request_id"])]
    for key in ("verdict", "payee_name", "amount", "timestamp", "mode", "summary"):
        assert key in row
    assert row["verdict"] == "DENY" and row["amount"] == 4200.0


def test_evidence_graph_marks_untrusted_failed_account():
    fresh()
    d = pay("US-XFER-998877", 4200.00)  # scenario 2
    g = call("get_evidence_graph", ADMIN_KEY, request_id=d["request_id"])
    assert g["ok"] is True
    by_type: dict[str, list[dict]] = {}
    for n in g["nodes"]:
        by_type.setdefault(n["type"], []).append(n)
        assert set(n) == {"id", "type", "label", "trusted", "failed"}
    assert by_type["PaymentRequest"][0]["failed"] is True
    fake = [n for n in by_type["Evidence"] if "US-XFER-998877" in n["label"]]
    assert fake and fake[0]["trusted"] is False and fake[0]["failed"] is True
    assert any(n["id"] == "em_002" for n in by_type["Email"])
    assert any(n["type"] == "Instruction" for n in g["nodes"])
    assert any(n["type"] == "Vendor" for n in g["nodes"])
    assert any(e["type"] == "MatchedTo" and e["field"] == "account_number" for e in g["edges"])
    assert any(e["type"] == "DerivedFrom" and e["to"] == "em_002" for e in g["edges"])


def test_evidence_graph_unknown_request_not_found():
    r = call("get_evidence_graph", ADMIN_KEY, request_id="nope")
    assert r["ok"] is False and r["error"]["code"] == "NOT_FOUND"
