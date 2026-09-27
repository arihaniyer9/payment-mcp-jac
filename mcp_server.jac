"""MCP server for any MCP client (Claude Code, Cursor, ...): the same vetting as the web app.

The goal and budget come from the user's prompt, which the agent passes to get_plan_instructions once per session.
Both are fixed for the session after that first call.
As in the web app, a purchase page must load when the server fetches it, and the price must be listed on it.

Run: jac run mcp_server.jac
"""
import os;
import time;
import from mcp.server.mcpserver { MCPServer, Context }
import from services.models { Mandate, Purchase }
import from services.tools { accepted_items, plan_instructions, submit_plan as vet_submitted_plan, purchase as vet_and_buy }
import from services.vetting { money, extract_mandate, retrying }

glob mcp = MCPServer(
    "plan-graph-payments",
    instructions="These tools are for an autonomous purchasing agent. Once the user has given a goal and budget, plan and buy without asking the user for confirmation or more details: choose sensible defaults for anything unstated. The server vets every plan and purchase against the user's mandate, so that is the safety check, not the user. Only a missing budget needs the user.",
);
# ponytail: one mandate per client session, in memory; a restart forgets every session.
glob mandates: dict[str, Mandate] = {};
# A client can reuse its session across conversations, so a mandate ends once every item is bought or after this long.
glob MANDATE_TTL_S = 6 * 3600;
glob NO_GOAL = {"ok": False, "error": "No goal yet. Call get_plan_instructions with the user's request first."};

"""The client's MCP session id over HTTP; stdio has one client, so one key."""
def key(ctx: Context) -> str {
    return (ctx.headers or {}).get("mcp-session-id") or "stdio";
}

"""This session's mandate, once get_plan_instructions has set its goal. Kept in the graph as an audit trail."""
def current(ctx: Context) -> Mandate | None {
    m = mandates.get(key(ctx));
    if m is not None and (time.time() - m.created_at > MANDATE_TTL_S or finished(m)) {
        del mandates[key(ctx)];
        return None;
    }
    return m;
}

"""True once every item of the accepted plan has an approved purchase."""
def finished(m: Mandate) -> bool {
    items = accepted_items(m);
    bought = {p.node_id for p in [m -->[?:Purchase]] if p.approved};
    return bool(items) and set(items) <= bought;
}

def logged(m: Mandate, name: str, args: dict, result: dict) -> dict {
    m.log("tool_result", "mcp", {"name": name, "args": args, "result": result});
    return result;
}

"""Step 1. Pass the user's request verbatim (their own words: what they want and why). Returns the instructions for
building the plan graph for their goal and budget. The request must state a budget. Goal and budget are fixed for the session after the first call.
Then carry out the instructions autonomously, without asking the user to confirm."""
@mcp.tool()
def get_plan_instructions(request: str, ctx: Context) -> str {
    m = current(ctx);
    header = "";
    if m is not None and request != m.request {
        header = "This session already has a mandate; its goal and budget are fixed until every item is bought, so the new request was not applied.\n";
    }
    if m is None {
        draft = retrying(extract_mandate, request);
        if draft.budget_usd <= 0 {
            return "No budget found in the request. Ask the user for their total budget in USD, then call again with it included.";
        }
        m = Mandate(goal=draft.goal, budget=money(draft.budget_usd), request=request, created_at=time.time());
        root ++> m;
        mandates[key(ctx)] = m;
    }
    return f"{header}Mandate: {m.goal}, budget ${m.budget:.2f} (USD). Tell the user this budget.\n\n{plan_instructions(m)}";
}

"""Step 2. Submit the plan graph for vetting. nodes: [{id, kind: item|subgoal|goal, name, price}], edges: [{child, parent}].
On rejection, fix the findings and resubmit, without asking the user. Resubmitting also replaces an accepted plan, e.g. when an item price was underestimated."""
@mcp.tool()
def submit_plan(nodes: list[dict], edges: list[dict], ctx: Context) -> dict {
    m = current(ctx);
    if m is None {
        return NO_GOAL;
    }
    return logged(m, "submit_plan", {"nodes": nodes, "edges": edges}, vet_submitted_plan(m, nodes, edges));
}

"""Step 3. Request payment for one item node of the accepted plan. price is the USD price listed at payment_url.
Buy every item without asking the user to confirm: the server vets each purchase."""
@mcp.tool()
def purchase(node_id: str, item_name: str, payment_url: str, price: float, ctx: Context) -> dict {
    m = current(ctx);
    if m is None {
        return NO_GOAL;
    }
    args = {"node_id": node_id, "item_name": item_name, "payment_url": payment_url, "price": price};
    return logged(m, "purchase", args, vet_and_buy(m, "mcp", node_id, item_name, payment_url, price));
}

with entry:__main__ {
    # Hosts like Render set PORT: serve streamable HTTP at /mcp. Otherwise stdio for local clients.
    if os.getenv("PORT") {
        mcp.run(transport="streamable-http", host="0.0.0.0", port=int(os.environ["PORT"]));
    } else {
        mcp.run();
    }
}
