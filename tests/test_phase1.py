"""Phase 1: replay agent -> MCP (stdio) -> Jac -> APPROVE + mock payment ref."""
import asyncio
import os
import sys
import uuid
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "agent"))
import replay_agent  # noqa: E402

if not os.environ.get("AGENT_API_KEY"):
    pytest.fail("AGENT_API_KEY must be set", pytrace=False)


def run(request_id: str) -> dict:
    return asyncio.run(replay_agent.run(request_id))


def test_end_to_end_approve_with_mock_ref():
    rid = f"p1_{uuid.uuid4().hex[:8]}"
    d = run(rid)
    assert d["ok"] is True
    assert d["verdict"] == "APPROVE"
    assert d["payment_ref"] == f"mock_{rid}"
    assert d["idempotent_replay"] is False


def test_retry_is_idempotent():
    rid = f"p1_{uuid.uuid4().hex[:8]}"
    first = run(rid)
    second = run(rid)
    assert second["idempotent_replay"] is True
    assert second["payment_ref"] == first["payment_ref"]


def test_bad_agent_key_surfaces_as_tool_error(monkeypatch):
    monkeypatch.setenv("AGENT_API_KEY", "bogus")
    d = run(f"p1_{uuid.uuid4().hex[:8]}")
    assert "UNAUTHORIZED" in d.get("tool_error", "")
