"""Scripted agent that drives the MCP server over stdio, like a real client.

Each scenario reads the sources through MCP first (so evidence is recorded),
then submits payments citing the evidence ids it was given.

Usage: python agent/replay_agent.py [scenario ...]   (default: 1 2)
"""
import argparse
import asyncio
import json
import os
import sys
import uuid
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

SERVER = Path(__file__).resolve().parent.parent / "mcp_server" / "server.py"

# Scenario -> list of payments. Values come straight from the seed data.
SCENARIOS: dict[str, list[dict]] = {
    "1": [{"payee_name": "Acme Supplies", "account_number": "US-ACME-000111",
           "amount": 4200.00, "invoice_id": "INV-4471"}],
    "2": [{"payee_name": "Acme Supplies", "account_number": "US-XFER-998877",
           "amount": 4200.00, "invoice_id": "INV-4471"}],
    "3": [{"payee_name": "Acme Supplies", "account_number": "US-ACME-000111",
           "amount": 4200.00, "invoice_id": "INV-4471"},
          {"payee_name": "Acme Supplies", "account_number": "US-ACME-000111",
           "amount": 4350.00, "invoice_id": "INV-4502"}],
    "4": [{"payee_name": "Verify Services", "account_number": "US-VRFY-424242",
           "amount": 49.00, "invoice_id": ""}],
}


def _text(result) -> str:
    return "".join(c.text for c in result.content if getattr(c, "type", "") == "text")


async def call_tool(session: ClientSession, name: str, args: dict | None = None) -> dict:
    result = await session.call_tool(name, args or {})
    if result.isError:
        return {"tool_error": _text(result)}
    return json.loads(_text(result))


def collect_evidence(*sources: dict) -> dict[tuple[str, str], list[str]]:
    """Map (kind, raw_value) -> evidence ids seen in tool results."""
    index: dict[tuple[str, str], list[str]] = {}

    def walk(obj):
        if isinstance(obj, dict):
            if "evidence_id" in obj and "kind" in obj:
                index.setdefault((obj["kind"], str(obj["raw_value"])), []).append(obj["evidence_id"])
            for v in obj.values():
                walk(v)
        elif isinstance(obj, list):
            for v in obj:
                walk(v)

    for s in sources:
        walk(s)
    return index


def cite(index: dict, payment: dict) -> list[str]:
    """The evidence ids whose raw value equals one of the payment fields."""
    wanted = {str(payment["payee_name"]), str(payment["account_number"]),
              str(payment["invoice_id"]), f"{payment['amount']:.2f}",
              f"{payment['amount']:,.2f}"}
    return sorted({eid for (_, raw), ids in index.items() if raw in wanted for eid in ids})


async def run_scenario(session: ClientSession, scenario: str, prefix: str) -> list[dict]:
    inbox = await call_tool(session, "read_inbox")
    instructions = await call_tool(session, "get_instructions")
    vendors = await call_tool(session, "get_vendors")
    index = collect_evidence(inbox, instructions, vendors)
    decisions = []
    for i, payment in enumerate(SCENARIOS[scenario]):
        decisions.append(await call_tool(session, "request_payment", {
            "request_id": f"{prefix}_s{scenario}_{i}",
            "currency": "USD",
            "instruction_id": "ins_001",
            "evidence_ids": cite(index, payment),
            "reason_text": "Paying per instruction ins_001.",
            **payment,
        }))
    return decisions


async def session_run(fn):
    params = StdioServerParameters(command=sys.executable, args=[str(SERVER)], env=dict(os.environ))
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            return await fn(session)


async def run(request_id: str) -> dict:
    """Phase 1 compatibility: one scenario-1 payment with a given request id."""
    async def fn(session):
        return await call_tool(session, "request_payment", {
            "request_id": request_id, "currency": "USD", "instruction_id": "ins_001",
            "evidence_ids": [], "reason_text": "Paying March invoice.",
            **SCENARIOS["1"][0],
        })
    return await session_run(fn)


async def run_scenarios(scenarios: list[str], prefix: str) -> dict[str, list[dict]]:
    async def fn(session):
        return {s: await run_scenario(session, s, prefix) for s in scenarios}
    return await session_run(fn)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("scenarios", nargs="*", default=["1", "2"])
    args = parser.parse_args()
    out = asyncio.run(run_scenarios(args.scenarios, uuid.uuid4().hex[:6]))
    for s, decisions in out.items():
        for d in decisions:
            print(f"scenario {s}: {d.get('verdict') or d}  ref={d.get('payment_ref')}")
            for c in d.get("checks", []):
                if not c["passed"]:
                    print(f"    {c['severity']:4} {c['name']}: {c['detail']}")


if __name__ == "__main__":
    main()
