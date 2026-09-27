"""Deterministic checks only (no LLM, no network). Run: jac test services/vetting.jac"""
import copy;

glob GOAL = "Host a birthday party";
glob BUDGET = 100.0;
glob PLAN: dict = {
    "nodes": [
        {"id": "g", "kind": "goal", "name": GOAL, "price": 60},
        {"id": "food", "kind": "subgoal", "name": "Food", "price": 45},
        {"id": "cake", "kind": "item", "name": "Cake", "price": 37},
        {"id": "chips", "kind": "item", "name": "Chips", "price": 8},
        {"id": "deco", "kind": "subgoal", "name": "Decorations", "price": 15},
        {"id": "balloons", "kind": "item", "name": "Balloons", "price": 15}
    ],
    "edges": [
        {"child": "food", "parent": "g"}, {"child": "cake", "parent": "food"},
        {"child": "chips", "parent": "food"}, {"child": "deco", "parent": "g"},
        {"child": "balloons", "parent": "deco"}
    ]
};

"""Rule errors ('rule: msg') for PLAN after `mutate`."""
def errors(mutate: Callable[[dict], None]) -> list[str] {
    p = copy.deepcopy(PLAN);
    mutate(p);
    return [e["rule"] + ": " + e["msg"] for e in build_and_validate(p, GOAL, BUDGET, PlanAttempt(v=0)).errors];
}

def node_of(p: dict, nid: str) -> dict {
    return [n for n in p["nodes"] if n["id"] == nid][0];
}

def has_err(errs: list[str], prefix: str, text: str) -> bool {
    return len([e for e in errs if e.startswith(prefix) and text in e]) > 0;
}

test "valid plan has no rule errors" {
    def same(p: dict) {}
    assert errors(same) == [];
}

test "plan rules catch each broken shape" {
    def rename_goal(p: dict) { node_of(p, "g")["name"] = "Something else"; }
    def bad_sum(p: dict) { node_of(p, "food")["price"] = 40; }
    def skip_level(p: dict) { p["edges"].append({"child": "cake", "parent": "g"}); }
    def orphan(p: dict) { p["edges"].pop(); }
    def nan_price(p: dict) { node_of(p, "cake")["price"] = float("nan"); }
    def two_goals(p: dict) { node_of(p, "deco")["kind"] = "goal"; }
    assert has_err(errors(rename_goal), "goal:", "mandated goal");
    assert has_err(errors(bad_sum), "sums:", "sum of children");
    assert has_err(errors(skip_level), "shape:", "illegal edge");
    assert has_err(errors(orphan), "tree:", "exactly one parent");
    assert has_err(errors(nan_price), "shape:", "invalid price");
    assert has_err(errors(two_goals), "shape:", "exactly one goal");
}

test "plan rules catch over budget and cycles" {
    def over(p: dict) {
        for nid in ["g", "food", "cake"] {
            node_of(p, nid)["price"] += 50;
        }
    }
    assert has_err(errors(over), "budget:", "exceeds budget");
    def cycle(p: dict) {
        p["edges"] = [e for e in p["edges"] if e["parent"] != "g"] + [{"child": "food", "parent": "deco"}, {"child": "deco", "parent": "food"}];
    }
    assert has_err(errors(cycle), "tree:", "does not lead to the goal");
}

test "a valid plan becomes Feeds edges in the graph" {
    attempt = PlanAttempt(v=1);
    _ = build_and_validate(copy.deepcopy(PLAN), GOAL, BUDGET, attempt);
    items = [n for n in [attempt -->[?:PlanNode]] if n.kind == "item"];
    assert len(items) == 3;
    cake = [n for n in items if n.id == "cake"][0];
    assert [p.id for p in [cake ->:Feeds:->]] == ["food"];
}

test "purchase rules" {
    cake = {"name": "Cake", "price": 30.0};
    def rules(name: str, url: str, price: float, spent: float) -> list[str] {
        return [f["rule"] for f in purchase_rule_failures(cake, name, url, price, spent, BUDGET, ["evil.com"])];
    }
    assert rules("Cake", "https://bakery.example.com/buy", 29.99, 0.0) == [];
    assert rules("Cake", "https://bakery.example.com/buy", 31.0, 0.0) == ["price"];
    assert rules("Cake", "https://bakery.example.com/buy", 29.99, 80.0) == ["budget"];
    assert rules("Pie", "https://bakery.example.com/buy", 29.99, 0.0) == ["item"];
    assert rules("Cake", "http://bakery.example.com", 29.99, 0.0) == ["url"];
    assert rules("Cake", "https://shop.evil.com/x", 29.99, 0.0) == ["url"];
    assert rules("Cake", "https://notevil.com/x", 29.99, 0.0) == [];
}

test "page_key ignores scheme, www, query and trailing slash" {
    assert page_key("https://www.walmart.com/ip/Dino/180?x=1#top") == page_key("http://walmart.com/ip/Dino/180/");
    assert page_key("https://walmart.com/ip/Dino/180") != page_key("https://walmart.com/ip/Dino/181");
}

test "listed prices read browser text, JSON-LD and meta tags" {
    assert 30.67 in listed_prices("Current price is USD$30.67");
    assert 1299.0 in listed_prices("Now $1,299 only");
    assert 12.5 in listed_prices("{\"@type\": \"Offer\", \"price\": \"12.50\"}");
    assert 8.99 in listed_prices("<meta property=\"product:price:amount\" content=\"8.99\">");
}

test "provenance: unopened page and unlisted price are both refused" {
    page = "Dino Balloon Set ... Current price is USD$30.67";
    assert source_failures("https://walmart.com/ip/1", 30.67, True, [page]) == [];
    assert [f["rule"] for f in source_failures("https://walmart.com/ip/1", 30.67, False, [])] == ["page", "listed"];
    assert [f["rule"] for f in source_failures("https://walmart.com/ip/1", 3.07, True, [page])] == ["listed"];
}
