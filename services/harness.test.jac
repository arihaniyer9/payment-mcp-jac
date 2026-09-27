"""Harness state machine and evidence recording. No model calls. Run: jac test services/harness.jac"""

def fresh(rogue: bool = False) -> Mandate {
    m = Mandate(goal="Host a birthday party", budget=100.0, request="party for 10 kids, $100", rogue=rogue);
    root ++> m;
    start(m);
    return m;
}

def queue_spawn(m: Mandate, a: AgentRun, cid: str) {
    a.pending = [{"id": cid, "type": "function", "function": {"name": "spawn_agent", "arguments": "{\"task\": \"buy the cake\"}"}}];
    run_tool(m, a);
}

test "start queues the lead and logs the request; rogue text reaches only the agent" {
    m = fresh(True);
    lead = lead_of(m);
    assert lead is not None and active_agent(m) == lead;
    assert "rogue agent" in lead.messages[1]["content"];
    kinds = [e.kind for e in [m -->[?:Event]]];
    assert "say" in kinds and "rogue" in kinds;
    assert m.request == "party for 10 kids, $100";
}

test "a helper takes over the turn, then hands its summary back" {
    m = fresh();
    lead = lead_of(m);
    queue_spawn(m, lead, "c1");
    helper = [lead ->:Spawned:->][0];
    assert lead.status == "waiting" and active_agent(m) == helper;
    finish(m, helper, "bought the cake");
    assert active_agent(m) == lead and helper.status == "done";
    assert "bought the cake" in lead.messages[-1]["content"];
    assert lead.messages[-1]["tool_call_id"] == "c1";
}

test "spawn limits: two helpers per mandate, helpers can't spawn" {
    m = fresh();
    lead = lead_of(m);
    queue_spawn(m, lead, "c1");
    helper = [lead ->:Spawned:->][0];
    queue_spawn(m, helper, "h1");
    assert "can't start more agents" in helper.messages[-1]["content"];
    finish(m, helper, "done");
    queue_spawn(m, lead, "c2");
    finish(m, [h for h in [lead ->:Spawned:->] if h.status == "running"][0], "done");
    queue_spawn(m, lead, "c3");
    assert "limit of 2 helpers" in lead.messages[-1]["content"];
    assert m.helpers == 2;
    assert len([e for e in [m -->[?:Event]] if e.kind == "spawn_refused"]) == 2;
}

test "helpers only get the purchase tool" {
    m = fresh();
    lead = lead_of(m);
    queue_spawn(m, lead, "c1");
    helper = [lead ->:Spawned:->][0];
    r = dispatch(m, helper, "submit_plan", {"nodes": [], "edges": []});
    assert "not available" in r["error"];
}

test "browser output becomes evidence; search results don't" {
    m = fresh();
    executed = [
        {"type": "browser_search", "arguments": "{\"query\": \"dino balloons\"}", "output": "L4: * 【0†Dino Balloon Set†www.walmart.com】"},
        {"type": "browser.open", "arguments": "{\"cursor\": 0, \"id\": 0}", "output": "L1: URL:\nL2: https://www.walmart.com/ip/Dino-Balloon-Set/18020857092\nL9: # Dino Balloon Set"},
        {"type": "browser.find", "arguments": "{\"cursor\": 1, \"pattern\": \"price\"}", "output": "Current price is USD$30.67"}
    ];
    steps = record_browsing(m, "lead", executed);
    assert [s["action"] for s in steps] == ["search", "open", "find"];
    ev = [e for e in [m -->[?:Evidence]]];
    assert len(ev) == 2;
    assert ev[0].url == "https://www.walmart.com/ip/Dino-Balloon-Set/18020857092";
    assert "USD$30.67" in ev[1].text and ev[1].url == ev[0].url;
}

test "the human can only reply between turns" {
    m = fresh();
    assert not say(m, "hurry up");
    finish(m, lead_of(m), "Here is my plan.");
    assert say(m, "go ahead");
    assert active_agent(m) == lead_of(m);
}
