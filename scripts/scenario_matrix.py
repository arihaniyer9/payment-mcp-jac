"""Run scenarios 1-4 in FULL (LLM checks off) and RULES_ONLY via the replay
agent -> MCP -> Jac, and print a verdict table. Each run starts from reset_demo.
"""
import asyncio
import os
import sys
import uuid
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "agent"))
import replay_agent  # noqa: E402

BASE = os.getenv("JAC_API_URL", "http://localhost:8001").rstrip("/") + "/function/"
ADMIN = os.environ["ADMIN_API_KEY"]


def admin(name: str, **p) -> None:
    r = httpx.post(BASE + name, json={"api_key": ADMIN, **p}, timeout=60).json()
    assert r["data"]["result"]["ok"] is True, r


def main() -> None:
    for mode in ("FULL", "RULES_ONLY"):
        for s in ("1", "2", "3", "4"):
            admin("reset_demo")
            admin("set_mode", mode=mode)
            admin("set_llm_checks", enabled=False)
            decisions = asyncio.run(replay_agent.run_scenarios([s], uuid.uuid4().hex[:6]))[s]
            for i, d in enumerate(decisions):
                inv = replay_agent.SCENARIOS[s][i]["invoice_id"] or "(none)"
                fails = [f"{c['severity']}:{c['name']}" for c in d.get("checks", []) if not c["passed"]]
                print(f"{mode:10} scenario {s} {inv:9} -> {d.get('verdict') or d}  {fails}")


if __name__ == "__main__":
    main()
