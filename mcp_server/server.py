"""Proof of Purpose MCP server: thin routing layer over the Jac core.

No business logic lives here. Each tool forwards to a Jac endpoint and returns
its result. A Jac result with "ok": false is raised as a tool error so the
agent can never mistake a rejected call for success.

Run:
  stdio (Claude Desktop / Claude Code):  python mcp_server/server.py
  HTTP  (hosted demo):                   python mcp_server/server.py --http --port 8765
"""
import argparse
import os
from typing import Any

import httpx
from mcp.server.fastmcp import FastMCP

JAC_API_URL = os.getenv("JAC_API_URL", "http://localhost:8001").rstrip("/")
AGENT_API_KEY = os.getenv("AGENT_API_KEY", "")

mcp = FastMCP("proof-of-purpose")


class JacError(RuntimeError):
    pass


def call_jac(endpoint: str, **payload: Any) -> dict:
    """POST to a Jac function endpoint and enforce the ok-field contract."""
    resp = httpx.post(
        f"{JAC_API_URL}/function/{endpoint}",
        json={"api_key": AGENT_API_KEY, **payload},
        timeout=60,
    )
    resp.raise_for_status()
    envelope = resp.json()
    if envelope.get("ok") is not True:
        raise JacError(f"Jac transport error: {envelope.get('error')}")
    result = envelope.get("data", {}).get("result")
    if not isinstance(result, dict) or not isinstance(result.get("ok"), bool):
        raise JacError(f"Jac response broke the ok-field contract: {result!r}")
    if result["ok"] is False:
        err = result.get("error") or {}
        raise JacError(f"{err.get('code', 'ERROR')}: {err.get('message', '')}")
    return result


@mcp.tool()
def request_payment(
    request_id: str,
    payee_name: str,
    account_number: str,
    amount: float,
    currency: str,
    invoice_id: str,
    instruction_id: str,
    evidence_ids: list[str],
    reason_text: str = "",
) -> dict:
    """Request a payment. The only way to move money; you never hold gateway keys.

    You MUST justify every field with evidence the system recorded:
    - instruction_id: the id from get_instructions() that authorizes this payment.
    - evidence_ids: the evidence ids returned by read_inbox(), get_instructions()
      and get_vendors() for the payee, account number, amount and invoice.
    - reason_text is shown to humans only and is NEVER used in the decision.

    request_id is your idempotency key: retrying with the same id returns the
    original decision and never charges twice.

    Returns a Decision with verdict APPROVE, ESCALATE, DENY or NEEDS_ANSWERS.
    On NEEDS_ANSWERS you must call answer_verification(request_id, answers).
    """
    return call_jac(
        "request_payment",
        req={
            "request_id": request_id,
            "payee_name": payee_name,
            "account_number": account_number,
            "amount": amount,
            "currency": currency,
            "invoice_id": invoice_id,
            "justification": {
                "instruction_id": instruction_id,
                "evidence_ids": evidence_ids,
                "reason_text": reason_text,
            },
        },
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--http", action="store_true", help="serve over streamable HTTP")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    if not AGENT_API_KEY:
        raise SystemExit("AGENT_API_KEY must be set")
    if args.http:
        mcp.settings.port = args.port
        mcp.run(transport="streamable-http")
    else:
        mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
