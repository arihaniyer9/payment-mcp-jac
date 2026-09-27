# Create a plan graph

Plan how to achieve this goal: **{{Goal}}**

Stay under the budget: **${{Budget}}** (USD).

Break the goal into subgoals, and subgoals into smaller subgoals, down to the individual items you need to buy.
Submit the result with `submit_plan`:

- Exactly one node has kind `goal`, and its name is exactly `{{Goal}}` (copy it character for character).
- Nodes of kind `item` are single purchasable products. Give each a realistic estimated `price`.
- Nodes of kind `subgoal` group related steps.
- Every edge points from child to parent: `item -> subgoal`, `subgoal -> subgoal`, or `subgoal -> goal`.
- Every node except the goal has exactly one parent, and every node leads to the goal.
- The price of every subgoal and of the goal is exactly the sum of its children's prices. The goal's price must not exceed the budget.
- Every child must genuinely contribute to its parent.

Example shape (a different goal):

```json
{
  "nodes": [
    {"id": "goal", "kind": "goal", "name": "Paint the bedroom", "price": 72},
    {"id": "supplies", "kind": "subgoal", "name": "Painting supplies", "price": 72},
    {"id": "paint", "kind": "item", "name": "1 gallon interior eggshell paint", "price": 45},
    {"id": "roller", "kind": "item", "name": "9 inch roller kit", "price": 27}
  ],
  "edges": [
    {"child": "supplies", "parent": "goal"},
    {"child": "paint", "parent": "supplies"},
    {"child": "roller", "parent": "supplies"}
  ]
}
```

If you are missing information needed to plan (sizes, preferences, dates, quantities), ask the user before submitting.
Do not guess.

When the plan is accepted, buy each item with `purchase`. If an item costs more than its estimate,
update the estimate (and the sums above it), resubmit the plan, then buy it.
