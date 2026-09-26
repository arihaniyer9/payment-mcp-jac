"""Scripted agent that drives the MCP server over stdio, like a real client.

Phase 1: one payment (scenario 1 shape) -> expects APPROVE + mock payment ref.
Usage: python agent/replay_agent.py [--request-id ID]
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


async def call_tool(session: ClientSession, name: str, args: dict) -> dict:
    result = await session.call_tool(name, args)
    text = "".join(c.text for c in result.content if getattr(c, "type", "") == "text")
    if result.isError:
        return {"tool_error": text}
    return json.loads(text)


async def run(request_id: str) -> dict:
    params = StdioServerParameters(
        command=sys.executable, args=[str(SERVER)], env=dict(os.environ)
    )
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            return await call_tool(session, "request_payment", {
                "request_id": request_id,
                "payee_name": "Acme Supplies",
                "account_number": "US-ACME-000111",
                "amount": 4200.00,
                "currency": "USD",
                "invoice_id": "INV-4471",
                "instruction_id": "ins_001",
                "evidence_ids": [],
                "reason_text": "Paying March invoice per instruction ins_001.",
            })


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--request-id", default=f"req_{uuid.uuid4().hex[:10]}")
    args = parser.parse_args()
    print(json.dumps(asyncio.run(run(args.request_id)), indent=2))


if __name__ == "__main__":
    main()
