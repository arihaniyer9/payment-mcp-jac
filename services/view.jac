"""What the UI shows, as typed objects built from the mandate's audit log.

The client receives these hydrated (Jac generates the wire types), so it only renders. Rebuilding
from the log means a reload, or opening an old mandate, shows exactly what happened.
"""
import json;
import from services.models { Mandate, AgentRun, Event, Shot }
import from services.vetting { num }
import from services.harness { active_agent }

obj Check {
    has kind: str,
        check: str,
        node_name: str,
        ok: bool,
        detail: str;
    has p: float = -1.0,
        threshold: float = 0.0,
        question: str = "",
        model: str = "",
        ms: int = 0;
}

obj CardView {
    has id: str,
        kind: str,
        name: str,
        price: float,
        x: float,
        y: float,
        w: float,
        h: float;
    has status: str = "",
        image: str = "",
        flagged: bool = False,
        got: int = 0,
        total: int = 0,
        parent_name: str = "";
}

obj PathView {
    has key: str,
        d: str,
        cls: str;
}

obj AttemptView {
    has v: int,
        status: str;
    has summary: str = "",
        checks: list[Check] = [],
        goal_price: float = 0.0,
        width: float = 0.0,
        height: float = 0.0,
        cards: list[CardView] = [],
        paths: list[PathView] = [];
}

obj BuyView {
    has node_id: str,
        name: str,
        price: float,
        url: str,
        agent: str,
        status: str;
    has image: str = "",
        payment_intent: str = "",
        error: str = "",
        checks: list[Check] = [];
}

obj Decision {
    has kind: str;
    has attempt: int = -1,
        node_id: str = "";
}

obj ChatItem {
    has k: str;
    has agent: str = "lead",
        who: str = "",
        text: str = "",
        cls: str = "",
        pre: str = "",
        bold: str = "",
        post: str = "",
        decision: int = -1,
        searches: int = 0,
        pages: int = 0;
}

obj TraceRow {
    has when: str,
        cls: str,
        label: str,
        agent: str,
        summary: str;
    has detail: str = "",
        link: str = "";
}

"""One browser action, without its image (the client fetches that separately)."""
obj ShotView {
    has n: int,
        agent: str,
        action: str,
        detail: str,
        url: str,
        title: str,
        x: float,
        y: float,
        when: str;
}

obj MandateView {
    has id: str,
        goal: str,
        budget: float,
        spent: float,
        rogue: bool,
        busy: bool;
    has attempts: list[AttemptView] = [],
        buys: list[BuyView] = [],
        decisions: list[Decision] = [],
        chat: list[ChatItem] = [],
        trace: list[TraceRow] = [],
        shots: list[ShotView] = [];
}

def plural(n: int, word: str) -> str {
    return f"{n} {word}" + ("" if n == 1 else "s");
}

"""Agent-written numbers may be junk; show 0 rather than crash the view."""
def safe_num(x: object) -> float {
    try {
        return num(x);
    } except Exception {
        return 0.0;
    }
}

def usd(x: float) -> str {
    return f"${x:,.2f}";
}

def step_item(cls: str, pre: str, bold: str, post: str, agent: str, decision: int = -1) -> ChatItem {
    return ChatItem(k="step", cls=cls, pre=pre, bold=bold, post=post, agent=agent, decision=decision);
}

"""Findings (dicts written by vetting.jac) -> typed checks, labelled with node names."""
def checks_of(findings: list, names: dict[str, str]) -> list[Check] {
    out: list[Check] = [];
    for f in findings {
        nid = str(f.get("node") or "");
        p = f.get("p");
        out.append(Check(
            kind=str(f["kind"]), check=str(f["check"]), node_name=names.get(nid, nid), ok=bool(f["ok"]), detail=str(f["detail"]),
            p=num(p) if p is not None else -1.0, threshold=num(f.get("threshold") or 0), question=str(f.get("question") or ""),
            model=str(f.get("model") or ""), ms=int(num(f.get("ms") or 0))
        ));
    }
    return out;
}

def names_of(plan: dict) -> dict[str, str] {
    return {str(n.get("id")): str(n.get("name")) for n in (plan.get("nodes") or []) if isinstance(n, dict)};
}

"""Replay the audit log into the typed view."""
def build_view(m: Mandate) -> MandateView {
    events = sorted([m -->[?:Event]], key=lambda e: Event : e.seq);
    view = MandateView(id=jid(m), goal=m.goal, budget=m.budget, spent=m.spent, rogue=m.rogue, busy=active_agent(m) is not None);
    plans: list[dict] = [];
    raw: list[dict] = [];
    buys: dict[str, BuyView] = {};
    pending: dict[str, dict] = {};
    browse_at = -1;
    for e in events {
        d = e.data;
        a = e.agent;
        view.trace = view.trace + [trace_row(e, m.created_at)] if e.kind != "turn_end" else view.trace;
        if e.kind not in ["browse", "thinking"] {
            browse_at = -1;
        }
        if e.kind == "say" {
            view.chat.append(ChatItem(k="msg", who="user", text=str(d["text"]), agent=a));
        } elif e.kind == "assistant" {
            view.chat.append(ChatItem(k="msg", who="agent", text=str(d["text"]), agent=a));
        } elif e.kind == "rogue" {
            view.chat.append(ChatItem(k="rogue", text=str(d["text"]), agent=a));
        } elif e.kind == "browse" {
            if browse_at < 0 {
                view.chat.append(ChatItem(k="browse", agent=a));
                browse_at = len(view.chat) - 1;
            }
            if d["action"] == "search" {
                view.chat[browse_at].searches += 1;
            } else {
                view.chat[browse_at].pages += 1;
            }
        } elif e.kind == "error" {
            view.chat.append(step_item("bad", "", "Stopped:", " " + str(d["text"])[:300], a));
        } elif e.kind == "spawn" {
            view.chat.append(step_item("ok", "Started ", str(d["helper"]), " · " + str(d["task"])[:90], a));
        } elif e.kind == "tool_call" {
            on_call(view, plans, buys, pending, d, a);
        } elif e.kind == "tool_result" and str(d.get("id")) in pending {
            on_result(view, plans, raw, buys, pending.pop(str(d["id"])), d, a);
        }
    }
    view.attempts = [attempt_view(i + 1, plans[i], raw[i] if i < len(raw) else {}, buys) for i in range(len(plans))];
    view.buys = list(buys.values());
    view.shots = [
        ShotView(n=s.n, agent=s.agent, action=s.action, detail=s.detail, url=s.url, title=s.title, x=s.x, y=s.y, when=f"+{max(0.0, s.t - m.created_at):.1f}s")
        for s in sorted([m -->[?:Shot]], key=lambda s: Shot : s.n)
    ];
    return view;
}

def on_call(view: MandateView, plans: list[dict], buys: dict[str, BuyView], pending: dict[str, dict], d: dict, a: str) {
    name = str(d["name"]);
    args = (d.get("args") or {}) as dict;
    cid = str(d["id"]);
    if name == "get_plan_instructions" {
        view.chat.append(step_item("wait", "Reading the planning rules", "", "", a));
        pending[cid] = {"i": len(view.chat) - 1, "name": name};
    } elif name == "submit_plan" {
        plans.append(args);
        items = len([n for n in (args.get("nodes") or []) if isinstance(n, dict) and n.get("kind") == "item"]);
        view.chat.append(step_item("wait", "Submitted ", f"plan v{len(plans)}", " · " + plural(items, "item"), a));
        pending[cid] = {"i": len(view.chat) - 1, "name": name, "attempt": len(plans) - 1};
    } elif name == "purchase" {
        nid = str(args.get("node_id", ""));
        old = buys.get(nid);
        buys[nid] = BuyView(
            node_id=nid, name=str(args.get("item_name", "")), price=safe_num(args.get("price")), url=str(args.get("payment_url", "")),
            agent=a, status="checking", image=old.image if old is not None else ""
        );
        view.chat.append(step_item("wait", "Buying ", str(args.get("item_name", "")), " · " + usd(safe_num(args.get("price"))), a));
        pending[cid] = {"i": len(view.chat) - 1, "name": name, "node": nid};
    } elif name == "spawn_agent" {
        view.chat.append(step_item("wait", "Asking for ", "a helper agent", "", a));
        pending[cid] = {"i": len(view.chat) - 1, "name": name};
    } else {
        view.chat.append(step_item("wait", f"Calling {name}", "", "", a));
        pending[cid] = {"i": len(view.chat) - 1, "name": name};
    }
}

def on_result(view: MandateView, plans: list[dict], raw: list[dict], buys: dict[str, BuyView], p: dict, d: dict, a: str) {
    r = (d.get("result") or {}) as dict;
    i = int(p["i"]);
    name = str(p["name"]);
    findings = (r.get("findings") or []) as list;
    failed = len([f for f in findings if not f.get("ok")]);
    fails = " · " + plural(failed, "check") + " failed" if failed else "";
    if name == "submit_plan" {
        while len(raw) < len(plans) {
            raw.append({});
        }
        raw[int(p["attempt"])] = r;
        ok = bool(r.get("accepted"));
        view.decisions.append(Decision(kind="plan", attempt=int(p["attempt"])));
        label = f"Plan v{int(p['attempt']) + 1} " + ("accepted" if ok else "rejected");
        view.chat[i] = step_item("ok" if ok else "bad", "", label, "" if ok else fails, a, len(view.decisions) - 1);
    } elif name == "purchase" {
        b = buys[str(p["node"])];
        ok = bool(r.get("approved"));
        b.status = "bought" if ok else "blocked";
        b.image = str(r.get("image") or b.image or "");
        b.payment_intent = str(r.get("payment_intent") or "");
        b.error = str(r.get("error") or "");
        b.checks = checks_of(findings, names_of(plans[-1] if plans else {}));
        view.decisions.append(Decision(kind="purchase", node_id=b.node_id));
        if ok {
            view.chat[i] = step_item("ok", "", f"Bought {b.name}", " · " + usd(b.price), a, len(view.decisions) - 1);
        } else {
            view.chat[i] = step_item("bad", "", f"Blocked {b.name}", fails or (" · " + b.error), a, len(view.decisions) - 1);
        }
    } elif name == "spawn_agent" {
        if r.get("helper") {
            view.chat[i] = step_item("ok", "", f"{r['helper']} finished", "", a);
        } else {
            view.chat[i] = step_item("bad", "", "Helper refused", " · " + str(r.get("error") or ""), a);
        }
    } elif name == "get_plan_instructions" {
        view.chat[i] = step_item("ok", "Read the planning rules", "", "", a);
    } else {
        view.chat[i] = step_item("bad" if d.get("is_error") else "ok", f"{name} done", "", "", a);
    }
}

def trace_row(e: Event, t0: float) -> TraceRow {
    d = e.data;
    when = f"+{max(0.0, e.t - t0):.1f}s";
    k = e.kind;
    if k == "thinking" {
        text = str(d["text"]);
        return TraceRow(when=when, cls="think", label="Thinks", agent=e.agent, summary=text[:110] + ("…" if len(text) > 110 else ""), detail=text);
    }
    if k == "browse" {
        act = str(d["action"]);
        detail = str(d["detail"]);
        label = {"search": "Search", "open": "Opens", "click": "Clicks", "type": "Types", "scroll": "Scrolls"}.get(act, act);
        url = str(d.get("url") or "");
        return TraceRow(when=when, cls="open" if act != "search" else "search", label=label, agent=e.agent, summary=f"“{detail}”" + (f" → {url}" if url and act != "open" else ""), link=url if act == "open" else "");
    }
    if k == "tool_call" {
        return TraceRow(when=when, cls="call", label="Calls", agent=e.agent, summary=str(d["name"]), detail=json.dumps(d.get("args"), indent=2));
    }
    if k == "tool_result" {
        r = d.get("result") or {};
        verdict = "returned";
        if "accepted" in r {
            verdict = "accepted" if r["accepted"] else "rejected";
        } elif "approved" in r {
            verdict = "approved" if r["approved"] else "blocked";
        }
        return TraceRow(when=when, cls="result", label="Result", agent=e.agent, summary=f"{d['name']} {verdict} · {d.get('ms', 0)} ms", detail=json.dumps(r, indent=2));
    }
    if k == "assistant" {
        text = str(d["text"]);
        return TraceRow(when=when, cls="say", label="Replies", agent=e.agent, summary=text[:160] + ("…" if len(text) > 160 else ""));
    }
    if k == "say" {
        return TraceRow(when=when, cls="say", label="You", agent=e.agent, summary=str(d["text"]));
    }
    if k == "rogue" {
        return TraceRow(when=when, cls="error", label="Rogue", agent=e.agent, summary="Hidden instructions injected into the agent's prompt", detail=str(d["text"]));
    }
    if k == "spawn" {
        return TraceRow(when=when, cls="call", label="Spawns", agent=e.agent, summary=f"{d['helper']}: {d['task']}");
    }
    if k == "spawn_refused" {
        return TraceRow(when=when, cls="error", label="Refused", agent=e.agent, summary=f"spawn_agent: {d['reason']}");
    }
    return TraceRow(when=when, cls="error", label="Error", agent=e.agent, summary=str(d.get("text") or k));
}

glob COL = 290.0;
glob ROW = 90.0;
glob CARD: dict[str, list[float]] = {"item": [236.0, 76.0], "subgoal": [200.0, 62.0], "goal": [210.0, 74.0]};

"""One plan attempt: items on the left, rolling up column by column into the goal on the right."""
def attempt_view(v: int, plan: dict, result: dict, buys: dict[str, BuyView]) -> AttemptView {
    status = "checking" if not result else ("accepted" if result.get("accepted") else "rejected");
    nodes: list[dict] = [n for n in (plan.get("nodes") or []) if isinstance(n, dict) and "id" in n];
    names = names_of(plan);
    av = AttemptView(v=v, status=status, summary=str(result.get("summary") or ""), checks=checks_of((result.get("findings") or []) as list, names));
    if not nodes {
        return av;
    }
    by_id: dict[str, dict] = {str(n["id"]): n for n in nodes};
    kids: dict[str, list[str]] = {};
    parent: dict[str, str] = {};
    for e in (plan.get("edges") or []) {
        c = str(e.get("child"));
        p = str(e.get("parent"));
        if c in by_id and p in by_id {
            kids[p] = kids.get(p, []) + [c];
            parent.setdefault(c, p);
        }
    }
    flagged = {str(f.get("node")) for f in (result.get("findings") or []) if not f.get("ok") and f.get("node")};
    height: dict[str, int] = {};
    def h(nid: str, seen: set[str]) -> int {
        if nid in height {
            return height[nid];
        }
        if nid in seen {
            return 0;
        }
        seen.add(nid);
        height[nid] = max([1 + h(c, seen) for c in kids.get(nid, [])] or [0]);
        return height[nid];
    }
    max_h = max([h(nid, set()) for nid in by_id]);
    pos: dict[str, list[float]] = {};
    cursor = [0.0];
    def place(nid: str) -> float {
        if nid in pos {
            return pos[nid][1];
        }
        pos[nid] = [0.0, 0.0];
        ch = [c for c in kids.get(nid, []) if c not in pos];
        cy = 0.0;
        if ch {
            ys = [place(c) for c in ch];
            cy = (ys[0] + ys[-1]) / 2;
        } else {
            cy = cursor[0] + ROW / 2;
            cursor[0] += ROW;
        }
        col = max_h if by_id[nid].get("kind") == "goal" else height.get(nid, 0);
        pos[nid] = [col * COL, cy];
        return cy;
    }
    for nid in [k for k in by_id if by_id[k].get("kind") == "goal"] + list(by_id.keys()) {
        place(nid);
    }
    def state_of(nid: str) -> str {
        if by_id[nid].get("kind") == "item" {
            return buys[nid].status if nid in buys else "planned";
        }
        sts = [state_of(c) for c in kids.get(nid, [])];
        if sts and all([s == "bought" for s in sts]) {
            return "bought";
        }
        return "checking" if "checking" in sts else "planned";
    }
    def items_under(nid: str) -> list[str] {
        out: list[str] = [];
        for c in kids.get(nid, []) {
            out = out + ([c] if by_id[c].get("kind") == "item" else items_under(c));
        }
        return out;
    }
    for (nid, n) in by_id.items() {
        kind = str(n.get("kind"));
        size = CARD.get(kind, CARD["item"]);
        (x, cy) = (pos[nid][0], pos[nid][1]);
        items = items_under(nid);
        b = buys.get(nid) if kind == "item" else None;
        price = safe_num(n.get("price"));
        if kind == "goal" {
            av.goal_price = price;
        }
        av.cards.append(CardView(
            id=nid, kind=kind, name=str(n.get("name") or nid), price=price, x=x, y=cy - size[1] / 2, w=size[0], h=size[1],
            status=b.status if b is not None else "", image=b.image if b is not None else "", flagged=nid in flagged,
            got=len([i for i in items if i in buys and buys[i].status == "bought"]), total=len(items),
            parent_name=names.get(parent.get(nid, ""), "")
        ));
        if nid in parent {
            (px, py) = (pos[parent[nid]][0], pos[parent[nid]][1]);
            x1 = x + size[0];
            mx = (x1 + px) / 2;
            av.paths.append(PathView(key=nid, d=f"M{x1} {cy} C{mx} {cy}, {mx} {py}, {px - 2} {py}", cls=state_of(nid)));
        }
    }
    av.width = (max_h + 1) * COL - (COL - 236.0);
    av.height = max(cursor[0], ROW);
    return av;
}
