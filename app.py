"""Web UI: prompt -> mandate (goal, budget) -> Groq agent drives the payments MCP server.

Run: uv run python app.py   then open http://127.0.0.1:8000
"""
import asyncio
import json
import os
import re
import sys
import time
from pathlib import Path

from dotenv import load_dotenv

HERE = Path(__file__).parent
load_dotenv(HERE / ".env")

import jaclang  # noqa: E402,F401  registers the .jac import hook
import httpx  # noqa: E402
import uvicorn  # noqa: E402
from mcp import ClientSession, StdioServerParameters  # noqa: E402
from mcp.client.stdio import stdio_client  # noqa: E402
from starlette.applications import Starlette  # noqa: E402
from starlette.responses import FileResponse, JSONResponse, StreamingResponse  # noqa: E402
from starlette.routing import Route  # noqa: E402

from vetting import extract_mandate, retrying  # noqa: E402

# Groq directly (OpenAI-compatible), so we get the agent's reasoning and its built-in browsing steps for the lens.
GROQ_URL = "https://api.groq.com/openai/v1/chat/completions"
AGENT_MODEL = os.getenv("AGENT_MODEL", "openai/gpt-oss-120b")  # browser_search needs a gpt-oss model
MAX_STEPS = 40
SYSTEM = """You are a purchasing agent working for the user. You can spend money only through the payments tools.
1. Call get_plan_instructions and follow it exactly.
2. Use browser_search to find a real product page for each item you plan to buy, and base the estimate on its listed price. Keep browsing short: one search per item, open at most one or two pages. Prefer retailers such as Walmart, Target or Party City. Don't look for images.
3. Call submit_plan. If it is rejected, fix every failed finding and resubmit. If you need information only the user has, ask the user and stop.
4. Once the plan is accepted, call purchase once per item node with the product page URL you found and its listed price.
5. If a purchase is rejected, fix what the findings say (a different page, or resubmit the plan if the price is above the estimate) and retry once. Otherwise report it.
Finish with a short summary for the user: what was bought, what was not, and why."""


async def complete(messages: list, tools: list) -> dict:
    """One agent step. Waits out rate limits (Groq says how long); retries malformed tool calls with the error as a hint."""
    hint: list = []
    async with httpx.AsyncClient(timeout=120) as client:
        for _ in range(10):
            r = await client.post(
                GROQ_URL,
                headers={"Authorization": f"Bearer {os.environ['GROQ_API_KEY']}"},
                json={"model": AGENT_MODEL, "messages": messages + hint, "tools": [{"type": "browser_search"}, *tools]},
            )
            if r.status_code == 429:
                await asyncio.sleep(float(r.headers.get("retry-after", 5)) + 0.5)
                continue
            body = r.json()
            err = body.get("error") or {}
            if err.get("code") == "tool_use_failed":
                hint = [{"role": "user", "content": f"Your last tool call was rejected: {err.get('message')}. Call the tool again with every required field."}]
                continue
            if r.status_code >= 400:
                raise RuntimeError(err.get("message") or r.text[:300])
            return body["choices"][0]["message"]
    raise RuntimeError("Groq kept rate-limiting or rejecting tool calls; try again in a minute.")


def browse_steps(executed: list) -> list[dict]:
    """Groq's server-side browsing steps -> {action, detail} for the lens."""
    steps = []
    for t in executed or []:
        kind = t.get("type") or ""
        try:
            args = json.loads(t.get("arguments") or "{}")
        except (json.JSONDecodeError, TypeError):
            args = {}
        if "search" in kind:
            steps.append({"action": "search", "detail": args.get("query", "")})
        elif "open" in kind:
            url = re.search(r"https?://\S+", t.get("output") or "")
            steps.append({"action": "open", "detail": url.group(0) if url else str(args.get("id", ""))})
        elif "find" in kind:
            steps.append({"action": "find", "detail": args.get("pattern", "")})
    return steps


def inline_refs(schema: dict) -> dict:
    """Groq models follow flat JSON schemas far better than $ref/$defs."""
    defs = schema.get("$defs", {})

    def walk(x):
        if isinstance(x, dict):
            if "$ref" in x:
                return walk(defs[x["$ref"].split("/")[-1]])
            return {k: walk(v) for k, v in x.items() if k != "$defs"}
        return [walk(v) for v in x] if isinstance(x, list) else x
    return walk(schema)


class Session:
    """One mandate = one MCP server process + one agent conversation."""

    def __init__(self, prompt: str, goal: str, budget: float):
        self.prompt, self.goal, self.budget = prompt, goal, budget
        self.inbox: asyncio.Queue = asyncio.Queue()
        self.events: asyncio.Queue = asyncio.Queue()
        self.messages = [{"role": "system", "content": SYSTEM}]
        self.inbox.put_nowait(prompt)
        self.task = asyncio.create_task(self.run())

    async def emit(self, type: str, **data):
        await self.events.put({"type": type, "t": time.time(), **data})

    async def run(self):
        # ponytail: judges see only the first request, not later chat replies
        env = {**os.environ, "GOAL": self.goal, "BUDGET": str(self.budget), "REQUEST": self.prompt}
        params = StdioServerParameters(command=sys.executable, args=[str(HERE / "server.py")], cwd=str(HERE), env=env)
        try:
            async with stdio_client(params) as (r, w), ClientSession(r, w) as mcp:
                await mcp.initialize()
                tools = [
                    {"type": "function", "function": {"name": t.name, "description": t.description or "", "parameters": inline_refs(t.input_schema)}}
                    for t in (await mcp.list_tools()).tools
                ]
                while True:
                    self.messages.append({"role": "user", "content": await self.inbox.get()})
                    try:
                        await self.turn(mcp, tools)
                    except Exception as e:
                        await self.emit("error", text=f"{type(e).__name__}: {e}")
                    await self.emit("done")
        except Exception as e:
            await self.emit("error", text=f"Payments server stopped: {type(e).__name__}: {e}")
            await self.emit("done")

    async def turn(self, mcp: ClientSession, tools: list):
        for _ in range(MAX_STEPS):
            msg = await complete(self.messages, tools)
            calls = [c for c in msg.get("tool_calls") or [] if c.get("type") == "function"]
            self.messages.append({"role": "assistant", "content": msg.get("content") or "", **({"tool_calls": calls} if calls else {})})
            if msg.get("reasoning"):
                await self.emit("thinking", text=msg["reasoning"])
            for step in browse_steps(msg.get("executed_tools")):
                await self.emit("browse", **step)
            if msg.get("content"):
                await self.emit("assistant", text=msg["content"])
            if not calls:
                return
            for c in calls:
                name = c["function"]["name"]
                try:
                    args = json.loads(c["function"].get("arguments") or "{}")
                except json.JSONDecodeError as e:
                    text = f"Invalid JSON arguments: {e}"
                else:
                    await self.emit("tool_call", id=c["id"], name=name, args=args)
                    t0 = time.time()
                    res = await mcp.call_tool(name, args)
                    text = "".join(getattr(part, "text", "") for part in res.content)
                    try:
                        result = json.loads(text)
                    except json.JSONDecodeError:
                        result = text
                    await self.emit("tool_result", id=c["id"], name=name, result=result, is_error=bool(res.is_error), ms=round((time.time() - t0) * 1000))
                self.messages.append({"role": "tool", "tool_call_id": c["id"], "content": text})
        await self.emit("error", text=f"Stopped after {MAX_STEPS} agent steps.")


session: Session | None = None  # ponytail: one session per app, local single-user tool


def stream(s: Session) -> StreamingResponse:
    async def lines():
        while True:
            ev = await s.events.get()
            yield json.dumps(ev) + "\n"
            if ev["type"] == "done":
                return
    return StreamingResponse(lines(), media_type="application/x-ndjson")


async def index(request):
    return FileResponse(HERE / "ui.html")


async def mandate(request):
    prompt = (await request.json()).get("prompt", "").strip()
    if not prompt:
        return JSONResponse({"error": "Write what you want to get done, including a budget."}, 400)
    try:
        m = await asyncio.to_thread(retrying, extract_mandate, prompt)
    except Exception as e:
        return JSONResponse({"error": f"Couldn't read the goal and budget: {type(e).__name__}"}, 502)
    return JSONResponse({"goal": m.goal, "budget": m.budget_usd if m.budget_usd > 0 else None})


async def start(request):
    global session
    body = await request.json()
    prompt, goal = str(body.get("prompt", "")).strip(), str(body.get("goal", "")).strip()
    try:
        budget = float(body.get("budget"))
    except (TypeError, ValueError):
        budget = 0.0
    if not prompt or not goal or not budget > 0:
        return JSONResponse({"error": "Goal and a budget above $0 are required."}, 400)
    if session:
        session.task.cancel()
    session = Session(prompt, goal, round(budget, 2))
    return stream(session)


async def say(request):
    text = str((await request.json()).get("text", "")).strip()
    if not session or session.task.done():
        return JSONResponse({"error": "No active mandate. Start a new one."}, 409)
    if not text:
        return JSONResponse({"error": "Write a reply first."}, 400)
    session.inbox.put_nowait(text)
    return stream(session)


app = Starlette(routes=[
    Route("/", index),
    Route("/mandate", mandate, methods=["POST"]),
    Route("/start", start, methods=["POST"]),
    Route("/say", say, methods=["POST"]),
])

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=int(os.getenv("PORT", "8000")))
