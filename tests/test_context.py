"""Context Registration API + end-user messages.

- register_vendor / register_invoice / register_instruction are admin-only and
  feed the same evidence path the demo seed uses.
- user_message / summary never leak internal IDs or jargon.
"""
import asyncio
import os
import re
import sys
import uuid
from pathlib import Path

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "agent"))
import replay_agent  # noqa: E402

BASE_URL = os.getenv("JAC_API_URL", "http://localhost:8001").rstrip("/")
ADMIN_KEY = os.environ.get("ADMIN_API_KEY", "")
AGENT_KEY = os.environ.get("AGENT_API_KEY", "")
if not ADMIN_KEY or not AGENT_KEY:
    pytest.fail("AGENT_API_KEY and ADMIN_API_KEY must be set", pytrace=False)

JARGON = re.compile(
    r"\b(ev_\d+|em_\d+|ins_\d+|provenance|evidence|untrusted|HARD|SOFT|INFO|node|"
    r"normaliz\w*|UNSOURCED|UNTRUSTED_ONLY)\b", re.IGNORECASE)


def call(name: str, key: str, **payload) -> dict:
    r = httpx.post(f"{BASE_URL}/function/{name}", json={"api_key": key, **payload},
                   timeout=60).json()
    return r["data"]["result"]


def pay(req: dict) -> dict:
    return call("request_payment", AGENT_KEY, req=req)


@pytest.fixture
def clean():
    assert call("reset_demo", ADMIN_KEY)["ok"] is True
    call("set_mode", ADMIN_KEY, mode="FULL")
    call("set_llm_checks", ADMIN_KEY, enabled=False)


# ---------- registration API ----------

@pytest.mark.parametrize("endpoint,payload", [
    ("register_vendor", {"name": "X Co", "known_account": "US-X-1"}),
    ("register_invoice", {"invoice_id": "INV-9", "vendor_name": "Acme Supplies",
                          "amount": 10, "period": "May"}),
    ("register_instruction", {"text": "Pay X Co."}),
])
def test_registration_rejects_agent_key(clean, endpoint, payload):
    r = call(endpoint, AGENT_KEY, **payload)
    assert r["ok"] is False and r["error"]["code"] == "UNAUTHORIZED"


def test_registration_validates_input(clean):
    assert call("register_vendor", ADMIN_KEY, name="", known_account="x")["ok"] is False
    assert call("register_invoice", ADMIN_KEY, invoice_id="INV-1", vendor_name="Acme Supplies",
                amount=-5, period="May")["ok"] is False
    r = call("register_invoice", ADMIN_KEY, invoice_id="INV-1", vendor_name="Nobody Inc",
             amount=5, period="May")
    assert r["ok"] is False and r["error"]["code"] == "NOT_FOUND"


def test_developer_registered_context_approves_a_payment(clean):
    """A brand-new vendor/invoice/instruction registered via the API is enough
    ground truth to approve a payment, through the unchanged pipeline."""
    assert call("register_vendor", ADMIN_KEY, name="Globex Corp",
                known_account="GB-GLBX-7788")["ok"]
    assert call("register_invoice", ADMIN_KEY, invoice_id="INV-7001",
                vendor_name="Globex Corp", amount=1250.00, period="May")["ok"]
    ins = call("register_instruction", ADMIN_KEY,
               text="Pay the Globex Corp invoice INV-7001 for May.")
    ins_id = ins["instruction"]["instruction_id"]
    call("get_vendors", AGENT_KEY)
    call("get_instructions", AGENT_KEY)
    d = pay({"request_id": f"glx_{uuid.uuid4().hex[:6]}", "payee_name": "Globex Corp",
             "account_number": "GB-GLBX-7788", "amount": 1250.00, "currency": "USD",
             "invoice_id": "INV-7001",
             "justification": {"instruction_id": ins_id, "evidence_ids": []}})
    assert d["verdict"] == "APPROVE", [c["detail"] for c in d["checks"] if not c["passed"]]


def test_reregistered_account_revokes_old_trust(clean):
    """If the developer updates a vendor's account, the old one stops vouching."""
    call("get_vendors", AGENT_KEY)  # old account shown to agent -> trusted evidence
    call("register_vendor", ADMIN_KEY, name="Acme Supplies", known_account="US-ACME-222333")
    call("get_vendors", AGENT_KEY)
    call("read_inbox", AGENT_KEY)
    d = pay({"request_id": f"old_{uuid.uuid4().hex[:6]}", "payee_name": "Acme Supplies",
             "account_number": "US-ACME-000111", "amount": 4200.00, "currency": "USD",
             "invoice_id": "INV-4471", "justification": {"instruction_id": "ins_001"}})
    assert d["verdict"] != "APPROVE"


def test_reset_restores_seed_after_registration(clean):
    call("register_vendor", ADMIN_KEY, name="Acme Supplies", known_account="US-ACME-222333")
    call("reset_demo", ADMIN_KEY)
    vendors = call("get_vendors", AGENT_KEY)["vendors"]
    assert [v["known_account"] for v in vendors if v["name"] == "Acme Supplies"] == ["US-ACME-000111"]


# ---------- end-user messages ----------

def _all_messages(d: dict) -> list[str]:
    return [d["summary"]] + [c["user_message"] for c in d["checks"]]


@pytest.mark.parametrize("scenario", ["1", "2", "3", "4"])
def test_user_messages_are_plain_language(clean, scenario):
    decisions = asyncio.run(replay_agent.run_scenarios([scenario], uuid.uuid4().hex[:6]))[scenario]
    for d in decisions:
        assert d["summary"], d
        for text in _all_messages(d):
            assert text, f"empty user text in {d['request_id']}"
            assert not JARGON.search(text), f"jargon in user text: {text!r}"
        for c in d["checks"]:
            assert "detail" in c and "evidence_node_ids" in c  # old fields kept
