# Proof of Purpose — a supervision layer for agent payments (Jac core)

Any developer's AI agent can route its payments through Proof of Purpose. Every
payment field must trace back to ground truth that **the developer's own app**
registered, over a channel **the agent never touches**. The agent's own
explanation is stored for display and never used in a decision.

Internals, module map and known limitations: see [NOTES.md](NOTES.md).

## Status (last updated 2026-09-27)

Code share: **63.0% Jac** (1,949 Jac lines vs 1,147 Python, `scripts/jac_percent.py`).

Legend: **Verified** = run live against the preview server and passed.
**Built, not tested** = code exists and passes `jac check`, never run.
**Not done** = does not exist.

### Verified

| Area | Evidence |
|---|---|
| Auth: agent/admin keys, `ok`-field contract, rejected actions never execute | `tests/test_auth.py` 35/35 (before Phase 3–4 changes) |
| Replay agent → MCP (stdio) → Jac, idempotent retry, bad key surfaces as tool error | `tests/test_phase1.py` 3/3 (after Phase 3 changes) |
| Scenario 1 (legit invoice) APPROVE; scenario 2 (fake bank-change email) DENY **with LLM checks off**; RULES_ONLY approves both; duplicate payment DENY | `tests/test_scenarios.py` 8/8 (before Phase 3–4 changes) |
| Context Registration API, re-registered account revokes old trust, reset restores seed, plain-language `user_message`/`summary` | `tests/test_context.py` 14/14 (before Phase 3–4 changes) |
| Scenario 3: INV-4471 APPROVE, INV-4502 ESCALATE (EXCEEDS_SCOPE) | 10/10 fresh runs (`scripts/reliability.py 3`) |
| Scenario 4: $49 to Verify Services DENY with UNRELATED as a second reason | 10/10 fresh runs (`scripts/reliability.py 4`) |
| Scenario 5: NEEDS_ANSWERS round trip over MCP; truthful answers → APPROVE, contradicting answer → DENY; expected answers never sent | `scripts/scenario5.py`, and `tests/test_phase3.py` 8/8 |
| `reset_demo` is stable | 5 resets in a row, identical node/edge counts (`scripts/reset_stability.py`) |
| Groq LLM path | `openai/gpt-oss-120b` returns typed enums |

**How scenario 3 reached 10/10 (be aware):** the LLM alone got 2/4. The final
scenario 3 run used an LLM-plus-override version that has since been replaced:
the instruction-scope decision is now fully deterministic whenever the
instruction names an invoice number (`instruction_scope_check`), and the LLM
only judges instructions that name none. **Scenario 3 has not been re-run on
this final version.** The scenario 3 test in `test_phase3.py` passed on the
earlier version.

### Built, not tested

| Item | Where | Notes |
|---|---|---|
| `list_decisions` | `jac/api.jac` | Newest first: verdict, payee, amount, timestamp, mode, summary, payment_ref |
| `get_evidence_graph` | `jac/api.jac`, `jac/evidence_graph.jac` (walker) | `{nodes: [{id, type, label, trusted, failed}], edges: [{from, to, type, field}]}` |
| `resolve_escalation(APPROVE)` charges through the gateway | `jac/api.jac` | Same `execute_payment` as `request_payment`; marks the invoice paid only on success; refuses an already-paid invoice |
| Deterministic instruction-scope check | `jac/checks_llm.jac` `instruction_scope_check` | Replaces the earlier LLM-plus-override logic |
| Stripe test-mode gateway | `jac/gateway.jac` | Refuses non-`sk_test_` keys at startup; idempotency key = `request_id` |
| One-shot Stripe charge script | `scripts/stripe_one_charge.jac` | Runs a single real test-mode charge through `jac.gateway.charge` |
| Phase 4 tests | `tests/test_phase4.py` (5 tests) | Never run |
| Real escalation fixture in auth tests | `tests/test_auth.py` `new_escalation()` | Creates escalations via `request_payment` (over the cap); the old debug endpoint is gone |
| MCP admin tools (`--admin-tools`) | `mcp_server/server.py` | Tests exist in `test_context.py`; those three tests have not been run since they were added |

### Not done

1. **No real Stripe test-mode charge has ever been run.** Every payment so far
   used the mock. Blocked on: an `sk_test_` key (none in Settings), and
   confirming the server process can import `stripe` (it is declared in
   `jac.toml`; the gateway imports it lazily so the mock path never needs it).
2. **Full suite not re-run after the Phase 3 and Phase 4 changes.** Only
   `test_phase1.py` and `test_phase3.py` were run on the Phase 3 code;
   `test_auth.py`, `test_scenarios.py`, `test_context.py` last passed before
   those changes; `test_phase4.py` never ran.
3. **No deployment.** Performance on a real JacHammer deployment is unmeasured.
   The preview sandbox is slow (1 vCPU, heavily shared): `request_payment` with
   the LLM check took ~18 s there.
4. **Dashboard UI** is out of scope for this repo (a teammate builds it); the
   frontend template files are left in place.

### Known limitations

- Auth failures return HTTP 200 with `{"ok": false}`, not real 401/403.
- Jac engine quirk: deleting and creating a node of the same type in one
  request can lose the new node. All write paths avoid it.
- `reset_demo` writes no audit entry (it deletes all audit entries).
- ~340 orphan rows from early resets remain in `.jac/data/` (stable).

## The trust boundary

```
Developer's app ──ADMIN_API_KEY──► register_vendor / register_invoice / register_instruction
                                                     │  (trusted ground truth)
AI agent ──MCP (AGENT_API_KEY)──► read_inbox / get_* / request_payment / answer_verification
                                                     │  (untrusted requests)
                                     Jac core checks every field against the ground truth
```

The developer's app feeds Proof of Purpose the **same** ground truth it already
gives its own agent (vendor master data, open invoices, the user's
instructions), but through a separate admin channel the agent key cannot reach.
That separation is the trust boundary the whole system depends on: an agent
that is tricked, for example by a fake "we changed banks" email, cannot also
forge the records its payment is checked against.

`reset_demo` seeds the Acme demo data through the same upserts as the
registration endpoints, so the demo path and the developer path are the same code.

## How a payment is decided

1. **Provenance** (deterministic walker): each field (account, payee, amount,
   invoice id) is matched to the values the system itself showed the agent.
   A value seen only in email is UNTRUSTED_ONLY; never seen is UNSOURCED.
2. **History** (deterministic walker): invoice → vendor. Already paid, amount
   mismatch, unknown payee, account differs from the one on file, over the cap.
3. **Instruction scope** (deterministic, when the instruction names an invoice
   number): same payee + same invoice → MATCHES; same payee, other invoice →
   EXCEEDS_SCOPE; other payee, other invoice → UNRELATED.
4. **LLM intent match** (only when the instruction names no invoice, and LLM
   checks are on). The instruction text is read from the graph by id, never
   from the agent's request.
5. **Verification questions** when the only problem is a small underpayment
   (≤10% below a real unpaid invoice): three templated questions, answers
   judged deterministically where possible.
6. **Decision:** any HARD → DENY; open questions → NEEDS_ANSWERS; any SOFT →
   ESCALATE; else APPROVE and charge.

RULES_ONLY mode skips 1–5 and applies only the per-transaction cap and payee
allowlist. It exists to show that rule-based guards approve the attacks.

## THE `ok`-FIELD CONTRACT (dashboard + MCP wrapper must follow)

Every Jac endpoint returns HTTP **200** inside Jac's envelope, **including auth failures**.

```json
{"ok": true, "data": {"result": { "ok": false, "error": {"code": "UNAUTHORIZED", "message": "..."} }}}
```

1. Read `data.result`. It is always an object with a boolean `ok`.
2. **`data.result.ok === true` is the only success.** HTTP 200 alone means nothing.
3. On `ok: false`, `error.code` is one of `UNAUTHORIZED`, `BAD_REQUEST`, `NOT_FOUND`, `CONFLICT`, `LLM_ERROR`.
4. A response without a boolean `data.result.ok` is a contract violation: treat it as failure.
5. The outer envelope `ok` (transport) must also be `true`; `false` there is a server error.

## Authentication

The key goes in the **JSON body** as `api_key` (not a header), on every request.

| Key (env var) | Allowed endpoints |
|---|---|
| `AGENT_API_KEY` | `request_payment`, `answer_verification`, `read_inbox`, `get_instructions`, `get_vendors`, `agent_ping` |
| `ADMIN_API_KEY` | everything else below |

Keys are role-specific: the admin key is rejected on agent endpoints and vice versa.
Set both in JacHammer Settings → Environment (or `.env` locally), then restart.

## Endpoints

All are `POST {JAC_API_URL}/function/<name>` with a JSON body that includes `api_key`.

### Agent endpoints (agent key)

| Endpoint | Body | Result |
|---|---|---|
| `read_inbox` | — | `{ok, emails: [{email_id, sender, subject, body, received_at, trusted: false, evidence: [...]}]}` |
| `get_instructions` | — | `{ok, instructions: [{instruction_id, text, created_at, trusted: true, evidence}]}` |
| `get_vendors` | — | `{ok, vendors: [{name, known_account, trusted: true, evidence, open_invoices: [...]}]}` |
| `request_payment` | `req`: the PaymentRequest contract | `{ok, ...Decision}` |
| `answer_verification` | `request_id`, `answers: [{question_id, answer}]` (all at once) | `{ok, ...Decision}` |
| `agent_ping` | — | `{ok, role: "agent"}` |

### Dashboard and admin endpoints (admin key)

| Endpoint | Body | Result | Status |
|---|---|---|---|
| `list_decisions` | optional `limit` (1–1000, default 100) | `{ok, decisions: [{request_id, verdict, status, payee_name, amount, currency, invoice_id, timestamp, mode, summary, payment_ref}]}` newest first | Built, not tested |
| `get_decision` | `request_id` | `{ok, decision, request}` | Verified |
| `get_evidence_graph` | `request_id` | `{ok, request_id, nodes, edges}` (see below) | Built, not tested |
| `list_escalations` | — | `{ok, escalations: [request]}` | Verified |
| `resolve_escalation` | `request_id`, `action: "APPROVE" \| "DENY"` | `{ok, request, decision}`. APPROVE charges via the gateway and marks the invoice paid; `CONFLICT` if not a pending escalation or already paid | DENY path and auth verified; APPROVE charging built, not tested |
| `get_request_status` | `request_id` | `{ok, request}` | Verified |
| `set_mode` | `mode: "FULL" \| "RULES_ONLY"` | `{ok, settings}` | Verified |
| `set_llm_checks` | `enabled: bool` | `{ok, settings}` | Verified |
| `get_settings` | — | `{ok, settings}` | Verified |
| `reset_demo` | — | `{ok, reset: true}` | Verified |

`get_evidence_graph` nodes: `{id, type, label, trusted, failed}` where `type` is
`PaymentRequest | Evidence | Email | Instruction | Vendor | Invoice` and `failed`
means the node is implicated in a failed check. Edges: `{from, to, type, field}`
with `type` in `MatchedTo` (field = payment field), `DerivedFrom`, `AuthorizedBy`,
`ForInvoice`, `PaysTo`.

### Context Registration (admin key)

| Endpoint | Body | Result |
|---|---|---|
| `register_vendor` | `name`, `known_account` | `{ok, vendor: {name, known_account, first_seen}}` |
| `register_invoice` | `invoice_id`, `vendor_name`, `amount` (dollars), `period` | `{ok, invoice}`; `NOT_FOUND` if the vendor isn't registered |
| `register_instruction` | `text`, optional `instruction_id` | `{ok, instruction: {instruction_id, text, created_at}}` |

All three are upserts. Re-registering a vendor with a new account makes the old
account stop counting as trusted.

### Decision shape

```json
{"ok": true, "request_id": "...", "verdict": "APPROVE|ESCALATE|DENY|NEEDS_ANSWERS",
 "summary": "One or two plain-language sentences for the end user.",
 "checks": [{"name": "...", "passed": false, "severity": "HARD|SOFT|INFO",
             "detail": "Operator detail naming evidence ids",
             "evidence_node_ids": ["ev_007"],
             "user_message": "Plain-language reason an agent can repeat to its user."}],
 "questions": [{"question_id": "q1", "text": "..."}],
 "payment_ref": "mock_... | pi_... | null", "mode": "FULL|RULES_ONLY",
 "idempotent_replay": false}
```

`summary` and `user_message` never contain internal ids or jargon. `questions`
is non-empty only for NEEDS_ANSWERS and never includes the expected answer.

## MCP server

- Default (agent-facing): `python mcp_server/server.py` (stdio) or
  `python mcp_server/server.py --http --port 8765`. Tools: `read_inbox`,
  `get_instructions`, `get_vendors`, `request_payment`, `answer_verification`,
  authenticated with `AGENT_API_KEY`. Any `ok: false` becomes an MCP tool error.
- `--admin-tools` additionally exposes `register_vendor`, `register_invoice`,
  `register_instruction` with `ADMIN_API_KEY`. For the developer's own admin
  client only, never the agent.
- Registering in a client (e.g. Claude Desktop): command `python`, args
  `["mcp_server/server.py"]`, env `JAC_API_URL`, `AGENT_API_KEY`.

## Configuration

| Variable | Purpose |
|---|---|
| `GROQ_API_KEY` | byLLM provider key |
| `LLM_MODEL` | defaults to `groq/openai/gpt-oss-120b`; swap without code changes |
| `AGENT_API_KEY`, `ADMIN_API_KEY` | role keys |
| `MOCK_GATEWAY` | mock unless set to exactly `false` |
| `STRIPE_SECRET_KEY` | must start with `sk_test_`; a live key stops the server at startup |
| `JAC_API_URL` | used by the MCP server, agent, tests and scripts |

## Running the tests and scripts

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
# keys are read from .env. On the slow preview sandbox, run one test at a time:
bash scripts/run_each.sh tests/test_phase4.py
bash scripts/run_tests.sh tests/test_auth.py
```

| Script | Purpose |
|---|---|
| `scripts/reliability.py 3 10` / `4 10` | Scenario 3 / 4 reliability runs |
| `scripts/scenario5.py` | Scenario 5 round trip (truthful and lying answers) |
| `scripts/residual_intent.py` | LLM intent path for an instruction that names no invoice |
| `scripts/reset_stability.py` | 5 resets, identical node/edge counts |
| `scripts/message_review.py` | Prints live user-facing text per scenario |
| `scripts/stripe_one_charge.jac` | One real Stripe test charge (`STRIPE_SECRET_KEY=sk_test_... jac run ...`) |
| `scripts/jac_percent.py` | Jac vs Python line share |
