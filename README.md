# payment-mcp-jac

An MCP server that lets an agent spend money only after two levels of vetting:

1. **Vet the plan.** The agent breaks the user's goal into a graph (item → subgoal → goal, with a price on each node). Fixed rules and AI judges review the graph. If they reject it, the agent gets feedback and tries again.
2. **Vet each purchase.** Every payment request against an accepted item runs through independent checks. The card is authorized (not captured) in Stripe test mode only if every check passes.

Checks that are arithmetic are deterministic: the goal and budget match the mandate, each node's price equals the sum of its children, the total is within budget, the price is at most the estimate, cumulative spend stays within budget, the domain isn't blacklisted, and the URL uses https. Yes/no checks that need judgment go to [Jev](https://typesafe.ai) (TypeSafe), a typed model that returns a calibrated P(yes) for each question in one ~150 ms call: whether the plan as a whole achieves the goal, whether each price is realistic, whether each step serves its parent, whether the URL is a legit merchant, and whether it sells the item. A check passes when P(yes) clears its threshold (70% for "legit merchant", 50% otherwise). A judgment that errors counts as a fail. Text work (the review summary, reading the goal and budget from your request) uses a Groq model through [byLLM](https://github.com/jaseci-labs/jac).

## Files

| File | What |
|---|---|
| `vetting.jac` | Plan graph (Jac nodes/edges), rules, Jev judgments, byLLM text |
| `server.py` | MCP tools, state, Stripe authorization |
| `app.py`, `ui.html` | Web app: your prompt → browsing Groq agent driving the MCP server |
| `prompts/CreatePlanGraph.md` | Planning instructions sent to the agent |
| `blacklist.txt` | Blocked domains (subdomains included) |
| `test_vetting.py` | Deterministic checks, no network |

## Run the web app

```
uv run python app.py
```

Open http://127.0.0.1:8000, describe what you want with a budget, confirm the goal and budget it reads out, and press **Start agent**. A Groq agent then starts its own copy of the MCP server with that mandate. It searches the web for real products, plans, gets rejected and revises, and buys items.

- **Agent** (left): the conversation. If the agent asks you something, reply at the bottom.
- **Purchase graph** (middle): items on the left roll up through steps into the goal. Cards show price, status, and the product photo once bought. Money flows along the edges of bought items. Switch between plan attempts at the top.
- **Lens** (right): *Why* explains the latest decision, or any card you click: every rule and every Jev probability against its threshold, plus the exact question Jev was asked. *Trace* is the timeline: the agent's reasoning, searches, pages opened, tool calls and results.

## Setup

`.env`:

```
GROQ_API_KEY=...
JEV_API_KEY=...                 # TypeSafe Jev, for the yes/no judgments
STRIPE_SECRET_KEY=sk_test_...   # test-mode keys only; live keys are refused
# AGENT_MODEL=openai/gpt-oss-120b   # Groq model for the web app agent; web browsing needs a gpt-oss model
# TEXT_MODEL=groq/openai/gpt-oss-20b # summaries and reading the mandate (any LiteLLM model string)
# JEV_MODEL=jev-latest              # pin a version (e.g. jev-1.13.0) to keep thresholds stable
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
- `purchase(node_id, item_name, payment_url, price)`: vets the purchase, then authorizes it in Stripe. Returns the PaymentIntent id (`requires_capture`), `spent`, `remaining`, and the product page's photo (`image`) when it has one.

## Test

```
uv run python test_vetting.py
```

## Limits

- State is in memory, one mandate per server process.
- The URL judgments see only the URL, not the page.
- Agent-written text only goes into Jev's state, never into the questions, but a crafted item name could still sway a judgment. The rules (price, budget, blacklist) don't depend on any model.
- Product photos come from the page's preview image. Amazon and eBay block this, so those items show a letter instead.
- On free-tier Groq (8k tokens/min), the agent's browsing makes a full run take a few minutes.
- The web app runs one mandate at a time. The judges see your first message, not later replies.
