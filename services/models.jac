"""The graph schema. One Mandate per human request; everything agents do hangs off it.

    Mandate --> AgentRun (lead) ->:Spawned:-> AgentRun (helpers)
            --> PlanAttempt --> PlanNode ->:Feeds:-> PlanNode (child -> parent)
            --> Purchase
            --> Evidence   (what the harness saw the agent browse: the provenance record)
            --> Event      (append-only audit log the UI replays)

The goal and budget live only on the Mandate, which only the human's endpoints can create.
"""
import time;

node Mandate {
    has goal: str,
        budget: float,
        request: str;
    has rogue: bool = False,
        strict_sources: bool = True,
        created_at: float = 0.0,
        spent: float = 0.0,
        seq: int = 0,
        helpers: int = 0;

    """Append one audit event. Everything the UI shows is replayed from these."""
    def log(kind: str, agent: str, data: dict[str, any]) -> Event {
        self.seq += 1;
        ev = Event(seq=self.seq, t=time.time(), kind=kind, agent=agent, data=data);
        self ++> ev;
        return ev;
    }
}

node AgentRun {
    has name: str;
    has role: str = "lead",
        messages: list[dict] = [],
        pending: list[dict] = [],
        status: str = "idle",
        steps: int = 0,
        result: str = "",
        task_call: str = "";
}

edge Spawned: AgentRun --> AgentRun {}

node PlanAttempt {
    has v: int;
    has accepted: bool = False,
        summary: str = "",
        findings: list[dict] = [];
}

node PlanNode {
    has id: str,
        kind: str,
        name: str,
        price: float;
}

"""Money rolls up along these: item -> subgoal -> goal."""
edge Feeds: PlanNode --> PlanNode {}

node Purchase {
    has node_id: str,
        item_name: str,
        url: str,
        price: float,
        agent: str;
    has approved: bool = False,
        findings: list[dict] = [],
        payment_intent: str = "",
        image: str = "",
        t: float = 0.0;
}

"""A page the harness's own browser rendered. Agent-written text never lands here."""
node Evidence {
    has url: str,
        kind: str,
        text: str,
        agent: str;
    has image: str = "";
}

"""One browser action: a screenshot and where the cursor went (x/y in page pixels, -1 when none)."""
node Shot {
    has n: int,
        agent: str,
        action: str,
        detail: str,
        url: str,
        title: str,
        x: float,
        y: float,
        data: str,
        t: float;
}

node Event {
    has seq: int,
        t: float,
        kind: str,
        agent: str,
        data: dict[str, any];

    def to_dict -> dict[str, any] {
        return {**self.data, "seq": self.seq, "t": self.t, "type": self.kind, "agent": self.agent};
    }
}

obj MandateSummary {
    has id: str,
        goal: str,
        budget: float,
        spent: float,
        rogue: bool,
        created_at: float;
}
