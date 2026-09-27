"""Call reset_demo N times and print node/edge counts after each call.

Two views per reset:
  api:  what the agent can reach (vendors, invoices, emails, instructions, escalations)
  db:   every anchor in the SQLite store by type, INCLUDING orphans that no
        query can reach. Identical rows across resets = no accumulation.

Usage: python scripts/reset_stability.py [N]   (env: JAC_API_URL, AGENT_API_KEY, ADMIN_API_KEY)
"""
import os
import sqlite3
import sys
import time
from collections import Counter
from pathlib import Path

import httpx

BASE = os.getenv("JAC_API_URL", "http://localhost:8001").rstrip("/") + "/function/"
AGENT = os.environ["AGENT_API_KEY"]
ADMIN = os.environ["ADMIN_API_KEY"]
DB = Path(__file__).resolve().parent.parent / ".jac" / "data" / "anchor_store.db"


def call(name: str, key: str, **payload) -> dict:
    r = httpx.post(BASE + name, json={"api_key": key, **payload}, timeout=60).json()
    result = r["data"]["result"]
    assert result["ok"] is True, result
    return result


def api_counts() -> dict:
    vendors = call("get_vendors", AGENT)["vendors"]
    return {
        "vendors": len(vendors),
        "invoices": sum(len(v["open_invoices"]) for v in vendors),
        "unpaid": sum(1 for v in vendors for i in v["open_invoices"] if not i["paid"]),
        "emails": len(call("read_inbox", AGENT)["emails"]),
        "instructions": len(call("get_instructions", AGENT)["instructions"]),
    }


def db_counts() -> Counter:
    time.sleep(0.5)  # let the server flush its write-ahead log
    with sqlite3.connect(DB) as c:
        return Counter({f"{t}:{a}": n for t, a, n in c.execute(
            "select type, arch_type, count(*) from anchors group by type, arch_type")})


def main() -> None:
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 5
    seen = []
    for i in range(1, n + 1):
        call("reset_demo", ADMIN)
        db = db_counts()        # read before get_* calls add Evidence
        api = api_counts()
        seen.append((api, db))
        print(f"reset {i}: api={api}")
        print(f"         db={dict(sorted(db.items()))}  total={sum(db.values())}")
    identical = all(s == seen[0] for s in seen)
    print("IDENTICAL across resets:", identical)
    sys.exit(0 if identical else 1)


if __name__ == "__main__":
    main()
