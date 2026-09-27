"""Scenario 5 end to end over MCP: pay -> NEEDS_ANSWERS -> answer_verification
-> final decision. Runs the truthful and/or lying answer set.

Usage: python scripts/scenario5.py [truthful|lying ...]   (default: truthful lying)
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
    httpx.post(BASE + name, json={"api_key": ADMIN, **p}, timeout=120)


def show(label: str, d: dict | None) -> None:
    if d is None:
        print(f"  {label}: (not reached)")
        return
    print(f"  {label}: {d.get('verdict') or d}  ref={d.get('payment_ref')}")
    print(f"    summary: {d.get('summary')}")
    for q in d.get("questions", []):
        print(f"    question {q['question_id']}: {q['text']}  keys={sorted(q)}")
    for c in d.get("checks", []):
        if not c["passed"] or c["name"].startswith("verification"):
            print(f"    {'PASS' if c['passed'] else 'FAIL'} {c['severity']:4} {c['name']}: {c['user_message']}")


def main() -> None:
    for answer_set in sys.argv[1:] or ["truthful", "lying"]:
        admin("reset_demo")
        admin("set_mode", mode="FULL")
        admin("set_llm_checks", enabled=True)
        r = asyncio.run(replay_agent.run_needs_answers(uuid.uuid4().hex[:6], answer_set))
        print(f"\n== scenario 5, {answer_set} answers")
        show("first", r["first"])
        print(f"  answers sent: {r['answers']}")
        show("final", r["final"])
        sys.stdout.flush()


if __name__ == "__main__":
    main()
