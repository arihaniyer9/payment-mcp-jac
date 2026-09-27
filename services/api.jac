"""Endpoints for the human, the only party that can create a mandate or move it forward.

Every endpoint is `def:priv`: it needs a login token and runs on the caller's own root, so one
user's mandates, agents and evidence are invisible to everyone else. Agents get no endpoints and
no credentials at all; the harness calls their tools in-process.
"""
import time;
import from services.models { Mandate, MandateSummary, Event }
import from services.view { MandateView, AttemptView, BuyView, Decision, ChatItem, TraceRow, Check, CardView, PathView, build_view }
import from services.vetting { extract_mandate, retrying, MandateDraft, money }
import from services.harness { start, say, step }

"""A mandate id is only honoured if the mandate hangs off the caller's root (`jobj` alone never authorizes)."""
def _mine(mandate_id: str) -> Mandate {
    for m in [root -->[?:Mandate]] {
        if jid(m) == mandate_id {
            return m;
        }
    }
    raise ValueError("No such mandate.");
}

"""Read the goal and budget out of the human's own words, for them to confirm."""
def:priv read_mandate(prompt: str) -> MandateDraft {
    if not prompt.strip() {
        raise ValueError("Write what you want to get done, including a budget.");
    }
    return retrying(extract_mandate, prompt.strip()) as MandateDraft;
}

"""Create a mandate from the confirmed goal and budget and start its lead agent."""
def:priv start_mandate(prompt: str, goal: str, budget: float, rogue: bool) -> MandateView {
    if not prompt.strip() or not goal.strip() or not budget > 0 {
        raise ValueError("Goal and a budget above $0 are required.");
    }
    m = Mandate(goal=goal.strip(), budget=money(budget), request=prompt.strip(), rogue=rogue, created_at=time.time());
    root ++> m;
    start(m);
    return build_view(m);
}

"""Advance the agents by one step and return the new view; the UI calls this until `busy` is false."""
def:priv agent_step(mandate_id: str) -> MandateView {
    m = _mine(mandate_id);
    step(m);
    return build_view(m);
}

def:priv mandate_view(mandate_id: str) -> MandateView {
    return build_view(_mine(mandate_id));
}

"""The human replies to the lead agent."""
def:priv send_reply(mandate_id: str, text: str) -> MandateView {
    if not text.strip() {
        raise ValueError("Write a reply first.");
    }
    m = _mine(mandate_id);
    if not say(m, text.strip()) {
        raise ValueError("The agent is still working.");
    }
    return build_view(m);
}

def:priv list_mandates() -> list[MandateSummary] {
    out = [MandateSummary(id=jid(m), goal=m.goal, budget=m.budget, spent=m.spent, rogue=m.rogue, created_at=m.created_at) for m in [root -->[?:Mandate]]];
    return sorted(out, key=lambda s: MandateSummary : s.created_at, reverse=True);
}

"""The whole audit log of one mandate, oldest first. The UI rebuilds its view from it."""
def:priv mandate_log(mandate_id: str) -> list[dict] {
    m = _mine(mandate_id);
    return [e.to_dict() for e in sorted([m -->[?:Event]], key=lambda e: Event : e.seq)];
}
