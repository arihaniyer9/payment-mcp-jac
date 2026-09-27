"""Auth integration tests against a running Jac API.

Contract under test: every endpoint returns a top-level "ok". Auth failures
return HTTP 200 with {"ok": false, "error": {...}} (Jac 0.34.20 limitation),
so tests assert on "ok" AND verify that side effects never happened.

Run:  JAC_API_URL=http://localhost:8001 AGENT_API_KEY=... ADMIN_API_KEY=... \
      python -m pytest tests/test_auth.py -v
"""
import os
import uuid

import httpx
import pytest

BASE_URL = os.getenv("JAC_API_URL", "http://localhost:8001").rstrip("/")
AGENT_KEY = os.environ.get("AGENT_API_KEY", "")
ADMIN_KEY = os.environ.get("ADMIN_API_KEY", "")

if not AGENT_KEY or not ADMIN_KEY:
    pytest.fail("AGENT_API_KEY and ADMIN_API_KEY must be set", pytrace=False)

ADMIN_ONLY = {
    "resolve_escalation": {"request_id": "x", "action": "APPROVE"},
    "set_mode": {"mode": "RULES_ONLY"},
    "set_llm_checks": {"enabled": False},
    "reset_demo": {},
    "list_escalations": {},
    "get_settings": {},
    "list_decisions": {},
    "get_evidence_graph": {"request_id": "x"},
    "get_decision": {"request_id": "x"},
}


def call(name: str, **payload) -> dict:
    """POST a Jac function endpoint and return the unwrapped result.

    Rejects any response that does not follow the ok-field contract.
    """
    resp = httpx.post(f"{BASE_URL}/function/{name}", json=payload, timeout=120)
    resp.raise_for_status()
    envelope = resp.json()
    assert envelope.get("ok") is True, f"transport error: {envelope}"
    result = envelope["data"]["result"]
    assert isinstance(result, dict) and isinstance(result.get("ok"), bool), (
        f"{name} broke the ok-field contract: {result!r}"
    )
    if result["ok"] is False:
        assert isinstance(result.get("error"), dict), result
        assert result["error"].get("code"), result
    return result


def new_escalation() -> str:
    """Create a REAL pending escalation through request_payment: the right
    vendor, account and invoice, but an amount over the per-transaction cap.
    With LLM checks off this ESCALATEs deterministically (no LLM call)."""
    call("reset_demo", api_key=ADMIN_KEY)
    call("set_mode", api_key=ADMIN_KEY, mode="FULL")
    call("set_llm_checks", api_key=ADMIN_KEY, enabled=False)
    for name in ("read_inbox", "get_instructions", "get_vendors"):
        call(name, api_key=AGENT_KEY)
    rid = f"esc_{uuid.uuid4().hex[:8]}"
    d = call("request_payment", api_key=AGENT_KEY, req={
        "request_id": rid, "payee_name": "Acme Supplies", "account_number": "US-ACME-000111",
        "amount": 6000.00, "currency": "USD", "invoice_id": "INV-4471",
        "justification": {"instruction_id": "ins_001", "evidence_ids": []}})
    assert d["ok"] is True and d["verdict"] == "ESCALATE", d
    return rid


def status_of(rid: str) -> str:
    r = call("get_request_status", api_key=ADMIN_KEY, request_id=rid)
    assert r["ok"] is True
    return r["request"]["status"]


# ---- basic key handling ----

def test_agent_key_accepted_on_agent_endpoint():
    assert call("agent_ping", api_key=AGENT_KEY)["ok"] is True


@pytest.mark.parametrize("key", [None, "", "wrong-key", ADMIN_KEY])
def test_agent_endpoint_rejects_missing_wrong_and_admin_key(key):
    payload = {} if key is None else {"api_key": key}
    r = call("agent_ping", **payload)
    assert r["ok"] is False
    assert r["error"]["code"] == "UNAUTHORIZED"


def test_admin_key_accepted_on_admin_endpoint():
    assert call("get_settings", api_key=ADMIN_KEY)["ok"] is True


@pytest.mark.parametrize("endpoint", sorted(ADMIN_ONLY))
@pytest.mark.parametrize("key", [None, "", "wrong-key", AGENT_KEY],
                         ids=["missing", "empty", "wrong", "agent"])
def test_admin_endpoints_reject_non_admin_keys(endpoint, key):
    payload = dict(ADMIN_ONLY[endpoint])
    if key is not None:
        payload["api_key"] = key
    r = call(endpoint, **payload)
    assert r["ok"] is False
    assert r["error"]["code"] == "UNAUTHORIZED"


# ---- side effects never happen ----

@pytest.mark.parametrize("action", ["APPROVE", "DENY"])
def test_agent_key_cannot_resolve_escalation(action):
    rid = new_escalation()
    r = call("resolve_escalation", api_key=AGENT_KEY, request_id=rid, action=action)
    assert r["ok"] is False
    assert status_of(rid) == "PENDING"
    pending = call("list_escalations", api_key=ADMIN_KEY)["escalations"]
    assert rid in [e["request_id"] for e in pending]


def test_agent_key_cannot_change_mode_or_llm_checks():
    before = call("get_settings", api_key=ADMIN_KEY)["settings"]
    new_mode = "RULES_ONLY" if before["mode"] == "FULL" else "FULL"
    assert call("set_mode", api_key=AGENT_KEY, mode=new_mode)["ok"] is False
    assert call("set_llm_checks", api_key=AGENT_KEY,
                enabled=not before["llm_checks_enabled"])["ok"] is False
    assert call("get_settings", api_key=ADMIN_KEY)["settings"] == before


def test_agent_key_cannot_reset_demo():
    rid = new_escalation()
    assert call("reset_demo", api_key=AGENT_KEY)["ok"] is False
    assert status_of(rid) == "PENDING"


def test_admin_key_can_resolve_escalation():
    rid = new_escalation()
    r = call("resolve_escalation", api_key=ADMIN_KEY, request_id=rid, action="DENY")
    assert r["ok"] is True
    assert status_of(rid) == "RESOLVED_DENY"
