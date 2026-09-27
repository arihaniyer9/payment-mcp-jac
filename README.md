# payment-mcp-jac

An MCP server that lets an agent spend money only after two levels of vetting:

1. **Vet the plan.** The agent breaks the user's goal into a graph (item → subgoal → goal, with a price on each node). Deterministic checks and LLM judges review the graph. If they reject it, the agent gets feedback and tries again.
2. **Vet each purchase.** Every payment request against an accepted item runs through independent checks. The card is authorized (not captured) in Stripe test mode only if every check passes.

Checks that are arithmetic are deterministic: the goal and budget match the mandate, each node's price equals the sum of its children, the total is within budget, the price is at most the estimate, cumulative spend stays within budget, the domain isn't blacklisted, and the URL uses https. Checks that need judgment go to LLM judges via [byLLM](https://github.com/jaseci-labs/jac): whether the connections are reasonable, whether prices are reasonable, whether each child relates to its parent, whether the URL is legit or a scam, and whether the URL sells the item. A judge that errors counts as a fail.

## Files

| File | What |
|---|---|
| `vetting.jac` | Plan graph (Jac nodes/edges), deterministic checks, byLLM judges |
| `server.py` | MCP tools, state, Stripe authorization |
| `app.py`, `ui.html` | Web app: your prompt → Groq agent driving the MCP server |
| `prompts/CreatePlanGraph.md` | Planning instructions sent to the agent |
| `blacklist.txt` | Blocked domains (subdomains included) |
| `test_vetting.py` | Deterministic checks, no network |

## Run the web app

```
uv run python app.py
```

Open http://127.0.0.1:8000, describe what you want with a budget, confirm the goal and budget it reads out, and press **Start agent**. A Groq agent then starts its own copy of the MCP server with that mandate. It plans, gets rejected and revises, and buys items. The page shows each step, the plan with its prices, and a budget meter. If the agent asks you something, reply in the box at the bottom.

## Setup

`.env`:

```
GROQ_API_KEY=...
STRIPE_SECRET_KEY=sk_test_...   # test-mode keys only; live keys are refused
# AGENT_MODEL=groq/openai/gpt-oss-120b   # the agent in the web app (any LiteLLM model string)
# JUDGE_MODEL=groq/openai/gpt-oss-20b    # judges; a different model than the agent means a separate Groq rate limit
# JUDGE_WORKERS=3                        # parallel judges; raise on a paid Groq tier
```

To use the MCP server from another client (Claude Code, Cursor, …), set the goal and budget in its config. The agent can't change them. `REQUEST` (optional) is your original wording, which the judges use as context:

```json
{
  "mcpServers": {
    "payments": {
      "command": "uv",
      "args": ["run", "--directory", "/path/to/payment-mcp-jac", "python", "server.py"],
      "env": { "GOAL": "Host a birthday party", "BUDGET": "100", "REQUEST": "Host a birthday party for 10 kids, pizza is handled" }
    }
  }
}
```

## Tools

- `get_plan_instructions()`: the planning prompt, filled in with the goal and budget.
- `submit_plan(nodes, edges)`: vets the plan. Returns `accepted`, a `summary`, and per-check `findings`. Resubmitting replaces the accepted plan (for example, when an item's price was underestimated).
- `purchase(node_id, item_name, payment_url, price)`: vets the purchase, then authorizes it in Stripe. Returns the PaymentIntent id (`requires_capture`), `spent` and `remaining`.

## Test

```
uv run python test_vetting.py
```

## Limits

- State is in memory, one mandate per server process.
- The URL judges see only the URL. They don't fetch the page.
- Judge prompts tell the model to treat agent text as data, but prompt injection through item names or URLs is still possible. The deterministic checks (price, budget, blacklist) don't depend on the LLM.
- On free-tier Groq (8k tokens/min per model), a full run takes a few minutes because calls back off on rate limits.
- The web app runs one mandate at a time. The judges see your first message, not later replies.
