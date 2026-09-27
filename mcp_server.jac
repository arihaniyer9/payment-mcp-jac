"""MCP server for any MCP client (Claude Code, Cursor, ...): the same vetting as the web app.

Ground truth (GOAL, BUDGET, optional REQUEST) comes from the human's client config, never from the agent.
There is no harness here to watch the agent browse, so a purchase page counts as seen when the server
itself can fetch it, and the price must still be listed on it.

Run: GOAL="..." BUDGET=100 jac run mcp_server.jac
"""
import os;
import time;
import from mcp.server.mcpserver { MCPServer }
import from services.models { Mandate }
import from services.tools { plan_instructions, submit_plan as vet_submitted_plan, purchase as vet_and_buy }
import from services.vetting { money, num }

glob mcp = MCPServer("plan-graph-payments");
glob mandate: Mandate | None = None;

"""This process's mandate. Created once from the environment and kept in the graph as an audit trail."""
def current() -> Mandate {
    global mandate;
    if mandate is None {
        goal = os.environ["GOAL"];
        m = Mandate(goal=goal, budget=money(num(os.environ["BUDGET"])), request=os.getenv("REQUEST", goal), strict_sources=False, created_at=time.time());
        root ++> m;
        mandate = m;
    }
    return mandate;
}

def logged(name: str, args: dict, result: dict) -> dict {
    m = current();
    m.log("tool_result", "mcp", {"name": name, "args": args, "result": result});
    return result;
}

"""Step 1. Get the instructions for building the plan graph for the user's goal and budget."""
@mcp.tool()
def get_plan_instructions() -> str {
    return plan_instructions(current());
}

"""Step 2. Submit the plan graph for vetting. nodes: [{id, kind: item|subgoal|goal, name, price}], edges: [{child, parent}].
On rejection, fix the findings and resubmit. Resubmitting also replaces an accepted plan, e.g. when an item price was underestimated."""
@mcp.tool()
def submit_plan(nodes: list[dict], edges: list[dict]) -> dict {
    return logged("submit_plan", {"nodes": nodes, "edges": edges}, vet_submitted_plan(current(), nodes, edges));
}

"""Step 3. Request payment for one item node of the accepted plan. price is the USD price listed at payment_url."""
@mcp.tool()
def purchase(node_id: str, item_name: str, payment_url: str, price: float) -> dict {
    args = {"node_id": node_id, "item_name": item_name, "payment_url": payment_url, "price": price};
    return logged("purchase", args, vet_and_buy(current(), "mcp", node_id, item_name, payment_url, price));
}

with entry:__main__ {
    _ = current();
    mcp.run();
}
