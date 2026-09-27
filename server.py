"""Plan-graph payment MCP server.

Ground truth (GOAL, BUDGET, optional REQUEST) comes from the human via env, never from the agent.
Run: GOAL="..." BUDGET=100 uv run python server.py
"""
import os
import threading
from pathlib import Path
from typing import Literal

from dotenv import load_dotenv

HERE = Path(__file__).parent
load_dotenv(HERE / ".env")

import jaclang  # noqa: E402,F401  registers the .jac import hook
import stripe  # noqa: E402
from mcp.server.mcpserver import MCPServer  # noqa: E402
from pydantic import BaseModel, Field  # noqa: E402

from vetting import vet_plan, vet_purchase  # noqa: E402

GOAL = os.environ["GOAL"]
BUDGET = float(os.environ["BUDGET"])
REQUEST = os.getenv("REQUEST", GOAL)  # the human's original wording, context for the judges
BLACKLIST = [
    line.strip().lower()
    for line in (HERE / "blacklist.txt").read_text().splitlines()
    if line.strip() and not line.startswith("#")
]

mcp = MCPServer("plan-graph-payments")

# ponytail: in-memory state, one mandate per server process. Persist if purchases must survive restarts.
lock = threading.Lock()
plan_items: dict[str, dict] = {}  # accepted plan: item node id -> {name, price}
purchased: dict[str, str] = {}  # item node id -> Stripe PaymentIntent id
spent = 0.0


class Node(BaseModel):
    id: str
    kind: Literal["item", "subgoal", "goal"]
    name: str = Field(description="For the goal node, exactly the mandated goal. For items, the exact product name.")
    price: float = Field(description="USD. Items: estimated price. Subgoal/goal: exactly the sum of children.")


class Edge(BaseModel):
    child: str = Field(description="Node id. Allowed: item->subgoal, subgoal->subgoal, subgoal->goal.")
    parent: str


@mcp.tool()
def get_plan_instructions() -> str:
    """Step 1. Get the instructions for building the plan graph for the user's goal and budget."""
    text = (HERE / "prompts" / "CreatePlanGraph.md").read_text()
    return text.replace("{{Goal}}", GOAL).replace("{{Budget}}", f"{BUDGET:.2f}")


@mcp.tool()
def submit_plan(nodes: list[Node], edges: list[Edge]) -> dict:
    """Step 2. Submit the plan graph for vetting. On rejection, fix the findings and resubmit.
    Resubmitting also replaces an accepted plan, e.g. when an item price was underestimated."""
    global plan_items
    plan = {"nodes": [n.model_dump() for n in nodes], "edges": [e.model_dump() for e in edges]}
    result = vet_plan(plan, GOAL, BUDGET, REQUEST)
    with lock:
        if result["accepted"]:
            plan_items = result.pop("items")
        else:
            result.pop("items", None)
    return result


@mcp.tool()
def purchase(node_id: str, item_name: str, payment_url: str, price: float) -> dict:
    """Step 3. Request payment for one item node of the accepted plan. price is the actual USD price at payment_url."""
    global spent
    with lock:  # ponytail: global lock also serializes the judges; fine for one agent
        item = plan_items.get(node_id)
        if item is None:
            return {"approved": False, "error": f"'{node_id}' is not an item in the accepted plan"}
        if node_id in purchased:
            return {"approved": False, "error": f"'{node_id}' already purchased ({purchased[node_id]})"}
        result = vet_purchase(item, item_name, payment_url, price, spent, BUDGET, BLACKLIST)
        if not result["approved"]:
            return result
        try:
            intent = authorize(node_id, item_name, payment_url, price)
        except Exception as e:
            return {"approved": False, "findings": result["findings"], "error": f"payment authorization failed: {e}"}
        purchased[node_id] = intent.id
        spent += price
        return {**result, "payment_intent": intent.id, "status": intent.status, "spent": spent, "remaining": BUDGET - spent}


def authorize(node_id: str, item_name: str, url: str, price: float):
    """Authorize (not capture) a card payment in Stripe test mode."""
    key = os.environ.get("STRIPE_SECRET_KEY", "")
    if not key.startswith("sk_test_"):
        raise RuntimeError("STRIPE_SECRET_KEY must be a Stripe test-mode key (sk_test_...)")
    return stripe.StripeClient(key).v1.payment_intents.create(params={
        "amount": round(price * 100),
        "currency": "usd",
        "capture_method": "manual",
        "confirm": True,
        "payment_method": "pm_card_visa",
        "payment_method_types": ["card"],
        "description": item_name,
        "metadata": {"node_id": node_id, "payment_url": url},
    })


if __name__ == "__main__":
    mcp.run()
