"""Acceptance tests (build prompt section 9), driven through the replay agent
-> MCP (stdio) -> Jac. Phase 2 covers scenarios 1 and 2 with LLM checks OFF
(the headline demo must not depend on an LLM), plus RULES_ONLY, idempotency
and duplicate payment.
"""
import asyncio
import os
import sys
import uuid
from pathlib import Path

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "agent"))
import replay_agent  # noqa: E402

BASE_URL = os.getenv("JAC_API_URL", "http://localhost:8001").rstrip("/")
ADMIN_KEY = os.environ.get("ADMIN_API_KEY", "")
if not ADMIN_KEY or not os.environ.get("AGENT_API_KEY"):
    pytest.fail("AGENT_API_KEY and ADMIN_API_KEY must be set", pytrace=False)


def admin(name: str, **payload) -> dict:
    r = httpx.post(f"{BASE_URL}/function/{name}",
                   json={"api_key": ADMIN_KEY, **payload}, timeout=60).json()
    result = r["data"]["result"]
    assert result["ok"] is True, result
    return result


def run(*scenarios: str) -> dict[str, list[dict]]:
    return asyncio.run(replay_agent.run_scenarios(list(scenarios), uuid.uuid4().hex[:6]))


def run_evidence_reads() -> None:
    agent_key = os.environ["AGENT_API_KEY"]
    for name in ("read_inbox", "get_instructions", "get_vendors"):
        r = httpx.post(f"{BASE_URL}/function/{name}",
                       json={"api_key": agent_key}, timeout=60).json()
        assert r["data"]["result"]["ok"] is True


def failed(decision: dict) -> dict[str, str]:
    return {c["name"]: c["severity"] for c in decision["checks"] if not c["passed"]}


@pytest.fixture
def full_mode_no_llm():
    admin("reset_demo")
    admin("set_mode", mode="FULL")
    admin("set_llm_checks", enabled=False)


@pytest.fixture
def rules_only():
    admin("reset_demo")
    admin("set_mode", mode="RULES_ONLY")


# ---------- FULL mode, LLM checks disabled ----------

def test_scenario1_legit_invoice_approves(full_mode_no_llm):
    d = run("1")["1"][0]
    assert d["verdict"] == "APPROVE", failed(d)
    assert d["payment_ref"].startswith("mock_")
    assert d["mode"] == "FULL"


def test_scenario2_fake_bank_change_denied_without_llm(full_mode_no_llm):
    d = run("2")["2"][0]
    assert d["verdict"] == "DENY"
    assert d["payment_ref"] is None
    f = failed(d)
    assert f.get("provenance.account_number") == "HARD"
    assert f.get("history.account_matches_vendor") == "HARD"
    detail = next(c["detail"] for c in d["checks"] if c["name"] == "provenance.account_number")
    assert "em_002" in detail and "untrusted" in detail


def test_scenario2_does_not_mark_invoice_paid(full_mode_no_llm):
    run("2")
    d = run("1")["1"][0]
    assert d["verdict"] == "APPROVE", "invoice must still be payable after a denied attempt"


def test_duplicate_payment_of_paid_invoice_denied(full_mode_no_llm):
    assert run("1")["1"][0]["verdict"] == "APPROVE"
    d = run("1")["1"][0]
    assert d["verdict"] == "DENY"
    assert failed(d).get("history.duplicate_payment") == "HARD"


def test_idempotent_retry_does_not_charge_twice(full_mode_no_llm):
    # replay_agent.run() skips read_inbox/get_vendors, so after a reset no
    # evidence exists yet; register it first like a real agent would.
    run_evidence_reads()
    rid = f"idem_{uuid.uuid4().hex[:6]}"
    first = asyncio.run(replay_agent.run(rid))
    second = asyncio.run(replay_agent.run(rid))
    assert first["verdict"] == "APPROVE", failed(first)
    assert second["idempotent_replay"] is True
    assert second["payment_ref"] == first["payment_ref"]
    assert second["verdict"] == "APPROVE", "a replay must not be re-checked as a duplicate"


def test_every_failed_check_has_readable_detail(full_mode_no_llm):
    d = run("2")["2"][0]
    for c in d["checks"]:
        assert len(c["detail"]) > 15, c


# ---------- RULES_ONLY baseline: approves the attacks ----------

def test_rules_only_approves_scenario1(rules_only):
    d = run("1")["1"][0]
    assert d["verdict"] == "APPROVE" and d["mode"] == "RULES_ONLY"


def test_rules_only_approves_scenario2_attack(rules_only):
    d = run("2")["2"][0]
    assert d["verdict"] == "APPROVE"
    assert d["payment_ref"].startswith("mock_")
