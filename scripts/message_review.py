"""Print the live user-facing summary + every check's user_message for a
chosen set of runs, for tone review. LLM checks off.

Usage: python scripts/message_review.py [MODE:SCENARIO ...]
       default: FULL:1 FULL:2 FULL:4 RULES_ONLY:2
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


def main() -> None:
    runs = sys.argv[1:] or ["FULL:1", "FULL:2", "FULL:4", "RULES_ONLY:2"]
    for run in runs:
        mode, s = run.split(":")
        admin("reset_demo")
        admin("set_mode", mode=mode)
        admin("set_llm_checks", enabled=False)
        for d in asyncio.run(replay_agent.run_scenarios([s], uuid.uuid4().hex[:6]))[s]:
            print(f"\n[{mode} scenario {s}] {d['verdict']}")
            print(f"  summary: {d['summary']}")
            for c in d["checks"]:
                mark = "PASS" if c["passed"] else "FAIL"
                print(f"   {mark} {c['user_message']}")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
