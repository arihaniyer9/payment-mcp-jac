"""Plan-graph payment MCP server.

Ground truth (GOAL, BUDGET, optional REQUEST) comes from the human via env, never from the agent.
Run: GOAL="..." BUDGET=100 uv run python server.py
"""
import os
import re
import threading
from pathlib import Path
from typing import Literal
from urllib.parse import urljoin

from dotenv import load_dotenv

HERE = Path(__file__).parent
load_dotenv(HERE / ".env")

import jaclang  # noqa: E402,F401  registers the .jac import hook
import httpx  # noqa: E402
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
        result = vet_purchase(node_id, item, item_name, payment_url, price, spent, BUDGET, BLACKLIST)
        if not result["approved"]:
            return result
        result["image"] = product_image(payment_url)  # only fetched once every check passed
        try:
            intent = authorize(node_id, item_name, payment_url, price)
        except Exception as e:
            return {**result, "approved": False, "error": f"payment authorization failed: {e}"}
        purchased[node_id] = intent.id
        spent += price
        return {**result, "payment_intent": intent.id, "status": intent.status, "spent": spent, "remaining": BUDGET - spent}


BROWSER_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
    "Accept": "text/html",
    "Accept-Language": "en-US,en;q=0.9",
}
OG_IMAGE = re.compile(
    r"""<meta[^>]+(?:property|name)=["'](?:og:image|twitter:image)["'][^>]+content=["']([^"']+)"""
    r"""|<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["'](?:og:image|twitter:image)["']"""
)


def product_image(url: str) -> str | None:
    """The product page's preview image, if it exposes one. Best effort: Amazon and eBay block this."""
    try:
        html = httpx.get(url, headers=BROWSER_HEADERS, follow_redirects=True, timeout=8).text
    except httpx.HTTPError:
        return None
    m = OG_IMAGE.search(html)
    return urljoin(url, m.group(1) or m.group(2)) if m else None


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
