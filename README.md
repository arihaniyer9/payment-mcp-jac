# Proof of Purpose — MCP Payment Firewall (Jac core)

Status: **Phase 0 complete, auth layer done and tested. Phase 1 next.**

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
| `ADMIN_API_KEY` | `resolve_escalation`, `set_mode`, `set_llm_checks`, `reset_demo`, `list_*`, `get_*` |

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
| `reset_demo` | — | `{ok, reset: true}` (seed data added in Phase 2) |
| `debug_create_escalation` | `request_id` | test fixture, removed once the pipeline exists |

`request` = `{request_id, payee_name, amount_cents, currency, invoice_id, status, verdict, payment_ref, mode, created_at}`.
The full section-10 list (decisions, evidence graph) will be documented here as each phase lands.

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
export JAC_API_URL=http://localhost:8001 AGENT_API_KEY=... ADMIN_API_KEY=...
.venv/bin/python -m pytest tests/ -v
```

`tests/test_auth.py` checks the `ok` contract on every response. It also checks that rejected
admin actions **never execute**: escalation still `PENDING`, settings unchanged, and data survives an agent-key `reset_demo`.

## Known gap

Auth failures are not real HTTP 401/403 responses (see NOTES.md). If a future Jac version exposes request middleware,
move the check there and keep the `ok` field for compatibility.
