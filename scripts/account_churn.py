"""Stale-account churn check: register a vendor's account A, B, A, B ... and
confirm stored node/edge counts do not drift.

Evidence is only created when get_vendors shows the account to the agent, so
each round also calls get_vendors (that is where the supersede path runs).
Usage: python scripts/account_churn.py [ROUNDS]
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


def call(endpoint: str, key: str, **p) -> dict:
    r = httpx.post(BASE + endpoint, json={"api_key": key, **p}, timeout=60).json()["data"]["result"]
    assert r["ok"] is True, r
    return r


def db() -> Counter:
    time.sleep(0.5)
    with sqlite3.connect(DB) as c:
        return Counter({a: n for a, n in c.execute(
            "select arch_type, count(*) from anchors group by arch_type")})


def trusted_accounts() -> list[str]:
    v = call("get_vendors", AGENT)["vendors"]
    acme = [x for x in v if x["name"] == "Acme Supplies"][0]
    return [e["raw_value"] for e in acme["evidence"] if e["kind"] == "ACCOUNT" and e["trusted"]]


def main() -> None:
    rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    call("reset_demo", ADMIN)
    snapshots = []
    for r in range(1, rounds + 1):
        for acct in ("US-ACME-000111", "US-ACME-999999", "US-ACME-000111"):
            call("register_vendor", ADMIN, name="Acme Supplies", known_account=acct)
            shown = trusted_accounts()
            assert shown == [acct], f"expected only {acct} trusted, got {shown}"
        snap = db()
        snapshots.append(snap)
        print(f"round {r}: Evidence={snap['Evidence']} Vendor={snap['Vendor']} "
              f"GenericEdge={snap['GenericEdge']} DerivedFrom={snap['DerivedFrom']} "
              f"total={sum(snap.values())}")
    stable = all(s == snapshots[0] for s in snapshots)
    print("IDENTICAL across rounds:", stable)
    sys.exit(0 if stable else 1)


if __name__ == "__main__":
    main()
