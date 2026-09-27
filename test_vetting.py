"""Deterministic checks only (no LLM / network). Run: uv run python test_vetting.py"""
import copy

import jaclang  # noqa: F401  registers the .jac import hook
from vetting import build_and_validate, purchase_rule_failures

GOAL, BUDGET = "Host a birthday party", 100.0
PLAN = {
    "nodes": [
        {"id": "g", "kind": "goal", "name": GOAL, "price": 60},
        {"id": "food", "kind": "subgoal", "name": "Food", "price": 45},
        {"id": "cake", "kind": "item", "name": "Cake", "price": 37},
        {"id": "chips", "kind": "item", "name": "Chips", "price": 8},
        {"id": "deco", "kind": "subgoal", "name": "Decorations", "price": 15},
        {"id": "balloons", "kind": "item", "name": "Balloons", "price": 15},
    ],
    "edges": [
        {"child": "food", "parent": "g"}, {"child": "cake", "parent": "food"},
        {"child": "chips", "parent": "food"}, {"child": "deco", "parent": "g"},
        {"child": "balloons", "parent": "deco"},
    ],
}


def errors(mutate):
    p = copy.deepcopy(PLAN)
    mutate(p)
    return [e["rule"] + ": " + e["msg"] for e in build_and_validate(p, GOAL, BUDGET)["errors"]]


def node(p, id):
    return next(n for n in p["nodes"] if n["id"] == id)


assert errors(lambda p: None) == []
assert any(e.startswith("goal:") and "mandated goal" in e for e in errors(lambda p: node(p, "g").update(name="Something else")))
assert any(e.startswith("sums:") for e in errors(lambda p: node(p, "food").update(price=40))) and any("sum of children" in e for e in errors(lambda p: node(p, "food").update(price=40)))
assert any("illegal edge" in e for e in errors(lambda p: p["edges"].append({"child": "cake", "parent": "g"})))
assert any("exactly one parent" in e for e in errors(lambda p: p["edges"].pop()))
assert any("invalid price" in e for e in errors(lambda p: node(p, "cake").update(price=float("nan"))))
assert any("exactly one goal" in e for e in errors(lambda p: node(p, "deco").update(kind="goal")))


def over_budget(p):
    for id in ("g", "food", "cake"):
        node(p, id)["price"] += 50
assert any(e.startswith("budget:") and "exceeds budget" in e for e in errors(over_budget))


def cycle(p):  # food <-> deco loop, detached from goal
    p["edges"] = [e for e in p["edges"] if e["parent"] != "g"]
    p["edges"] += [{"child": "food", "parent": "deco"}, {"child": "deco", "parent": "food"}]
assert any(e.startswith("tree:") and "does not lead to the goal" in e for e in errors(cycle))

cake = {"name": "Cake", "price": 30.0}
ok = dict(item=cake, item_name="Cake", url="https://bakery.example.com/buy", price=29.99,
          spent=0.0, budget=BUDGET, blacklist=["evil.com"])
assert purchase_rule_failures(**ok) == []
assert [f["rule"] for f in purchase_rule_failures(**{**ok, "price": 31})] == ["price"]   # over estimate
assert [f["rule"] for f in purchase_rule_failures(**{**ok, "spent": 80})] == ["budget"]  # over budget
assert purchase_rule_failures(**{**ok, "item_name": "Pie"}) != []    # wrong item
assert purchase_rule_failures(**{**ok, "url": "http://bakery.example.com"}) != []
assert purchase_rule_failures(**{**ok, "url": "https://shop.evil.com/x"}) != []
assert purchase_rule_failures(**{**ok, "url": "https://notevil.com/x"}) == []
print("ok")
