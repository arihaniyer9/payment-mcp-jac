"""Print the user-facing summary + failed-check user_message for scenarios 1-4
in FULL (LLM checks off) and RULES_ONLY, for tone review."""
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
    for mode in ("FULL", "RULES_ONLY"):
        for s in ("1", "2", "3", "4"):
            admin("reset_demo")
            admin("set_mode", mode=mode)
            admin("set_llm_checks", enabled=False)
            for d in asyncio.run(replay_agent.run_scenarios([s], uuid.uuid4().hex[:6]))[s]:
                print(f"\n[{mode} scenario {s}] {d['verdict']}")
                print(f"  summary: {d['summary']}")
                for c in d["checks"]:
                    if not c["passed"]:
                        print(f"   - {c['user_message']}")


if __name__ == "__main__":
    main()
