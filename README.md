# Proof of Purpose — a supervision layer for agent payments (Jac core)

Any developer's AI agent can route its payments through Proof of Purpose. Every
payment field must trace back to ground truth that **the developer's own app**
registered, over a channel **the agent never touches**. The agent's own
explanation is stored for display and never used in a decision.

Status: **Phases 0–2 done (auth, thin path, evidence + deterministic checks,
RULES_ONLY). Context Registration API and end-user messages added. Phase 3
(LLM checks) in progress.**

## The trust boundary

```
Developer's app ──ADMIN_API_KEY──► register_vendor / register_invoice / register_instruction
                                                     │  (trusted ground truth)
AI agent ──MCP (AGENT_API_KEY)──► read_inbox / get_* / request_payment
                                                     │  (untrusted requests)
                                     Jac core checks every field against the ground truth
```

The developer's app feeds Proof of Purpose the **same** ground truth it already
gives its own agent (vendor master data, open invoices, the user's
instructions), but through a separate admin channel. The agent key cannot
reach that channel. That separation is the trust boundary the whole system
depends on: an agent that is tricked, for example by a fake "we changed banks"
email, cannot also forge the records its payment is checked against.

`reset_demo` seeds the Acme demo data through the same upserts as the
registration endpoints, so the demo path and the developer path are the same code.

## THE `ok`-FIELD CONTRACT (read this first — dashboard + MCP wrapper)

Every Jac endpoint returns HTTP **200** inside Jac's envelope, **including auth failures**.
Jac 0.34.20 has no supported request-level hook to return 401/403.

```json
{"ok": true, "data": {"result": { "ok": false, "error": {"code": "UNAUTHORIZED", "message": "..."} }}}
```

Rules every client MUST follow:

1. Read `data.result`. It is always an object with a boolean `ok`.
2. **`data.result.ok === true` is the only success.** HTTP 200 alone means nothing.
3. On `ok: false`, `error.code` is one of `UNAUTHORIZED`, `BAD_REQUEST`, `NOT_FOUND`, `CONFLICT`.
4. A response without a boolean `data.result.ok` is a contract violation: treat it as failure.
5. The outer envelope `ok` (transport) must also be `true`; `false` there is a server error.

## Authentication

The key goes in the **JSON body** as `api_key` (not a header), on every request.

| Key (env var) | Allowed endpoints |
|---|---|
| `AGENT_API_KEY` | `request_payment`, `answer_verification`, `read_inbox`, `get_instructions`, `get_vendors`, `agent_ping` |
| `ADMIN_API_KEY` | `register_vendor`, `register_invoice`, `register_instruction`, `resolve_escalation`, `set_mode`, `set_llm_checks`, `reset_demo`, `get_decision`, `get_settings`, `get_request_status`, `list_escalations` |

Keys are role-specific: the admin key is rejected on agent endpoints and vice versa.
Set both in JacHammer Settings → Environment (or `.env` locally), then restart.

## Endpoints available now

All are `POST {JAC_API_URL}/function/<name>` with a JSON body.

| Endpoint | Body (besides `api_key`) | Success result |
|---|---|---|
| `agent_ping` | — | `{ok, role: "agent"}` |
| `get_settings` | — | `{ok, settings: {mode, llm_checks_enabled, per_txn_cap_cents, allowlist}}` |
| `set_mode` | `mode: "FULL" \| "RULES_ONLY"` | `{ok, settings}` |
| `set_llm_checks` | `enabled: bool` | `{ok, settings}` |
| `list_escalations` | — | `{ok, escalations: [request]}` |
| `resolve_escalation` | `request_id`, `action: "APPROVE" \| "DENY"` | `{ok, request}` (gateway call wired in Phase 4) |
| `get_request_status` | `request_id` | `{ok, request}` |
| `reset_demo` | — | `{ok, reset: true}`: clears run data and non-seed context, restores the Acme seed |
| `get_decision` | `request_id` | `{ok, decision, request}` |
| `debug_create_escalation` | `request_id` | test fixture, removed once the pipeline exists |

### Context Registration (admin key)

| Endpoint | Body (besides `api_key`) | Success result |
|---|---|---|
| `register_vendor` | `name`, `known_account` | `{ok, vendor: {name, known_account, first_seen}}` |
| `register_invoice` | `invoice_id`, `vendor_name`, `amount` (dollars), `period` | `{ok, invoice: {invoice_id, vendor_name, amount, period, paid}}`; `NOT_FOUND` if the vendor isn't registered |
| `register_instruction` | `text`, optional `instruction_id` | `{ok, instruction: {instruction_id, text, created_at}}` |

All three are upserts: calling again updates the record in place. Re-registering
a vendor with a new account makes the old account stop counting as trusted.

### Agent endpoints (agent key)

| Endpoint | Body (besides `api_key`) | Success result |
|---|---|---|
| `read_inbox` | — | `{ok, emails: [{email_id, sender, subject, body, received_at, trusted: false, evidence: [...]}]}` |
| `get_instructions` | — | `{ok, instructions: [{instruction_id, text, created_at, trusted: true, evidence}]}` |
| `get_vendors` | — | `{ok, vendors: [{name, known_account, trusted: true, evidence, open_invoices: [...]}]}` |
| `request_payment` | `req`: the PaymentRequest contract (section 5) | `{ok, ...Decision}` |

### Decision shape

```json
{"ok": true, "request_id": "...", "verdict": "APPROVE|ESCALATE|DENY|NEEDS_ANSWERS",
 "summary": "One or two plain-language sentences for the end user.",
 "checks": [{"name": "...", "passed": false, "severity": "HARD|SOFT|INFO",
             "detail": "Operator detail naming evidence ids",
             "evidence_node_ids": ["ev_007"],
             "user_message": "Plain-language reason an agent can repeat to its user."}],
 "questions": [], "payment_ref": "mock_... or null", "mode": "FULL|RULES_ONLY",
 "idempotent_replay": false}
```

`summary` and `user_message` never contain internal ids or jargon; `detail` and
`evidence_node_ids` are for the dashboard and are unchanged.

`request` = `{request_id, payee_name, amount_cents, currency, invoice_id, status, verdict, payment_ref, mode, created_at}`.

## MCP server

- Default (agent-facing): `python mcp_server/server.py` exposes `read_inbox`,
  `get_instructions`, `get_vendors`, `request_payment` with `AGENT_API_KEY`.
- `--admin-tools` additionally exposes `register_vendor`, `register_invoice`,
  `register_instruction`, authenticated with `ADMIN_API_KEY`. Use this only for
  the developer's own admin client, never for the agent. Tests confirm the
  default server lists no register tools and that the agent key is rejected.

## Configuration

| Variable | Purpose |
|---|---|
| `GROQ_API_KEY` | byLLM provider key |
| `LLM_MODEL` | defaults to `groq/openai/gpt-oss-120b`; swap without code changes |
| `AGENT_API_KEY`, `ADMIN_API_KEY` | role keys (above) |
| `MOCK_GATEWAY` | `true` by default: no Stripe network calls |
| `JAC_API_URL` | used by the Python MCP server, agent and tests |

## Running the tests

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
# reads keys from .env; runs one file at a time in the foreground
bash scripts/run_tests.sh tests/test_auth.py
bash scripts/run_tests.sh tests/test_phase1.py
bash scripts/run_tests.sh tests/test_scenarios.py
bash scripts/run_tests.sh tests/test_context.py
```

On the JacHammer preview sandbox (1 vCPU, heavily shared) the scenario and
context files each take several minutes; run them separately. Last full run
(2026-09-27): auth 35/35, phase1 3/3, scenarios 8/8, context 14/14.

Other scripts: `scripts/reset_stability.py` (5x reset, identical node/edge
counts), `scripts/message_review.py` (prints live user-facing text per
scenario), `scripts/scenario_matrix.py` (verdict table), `scripts/jac_percent.py`.

`tests/test_auth.py` checks the `ok` contract on every response. It also checks that rejected
admin actions **never execute**: escalation still `PENDING`, settings unchanged, and data survives an agent-key `reset_demo`.

## Known gap

Auth failures are not real HTTP 401/403 responses (see NOTES.md). If a future Jac version exposes request middleware,
move the check there and keep the `ok` field for compatibility.
