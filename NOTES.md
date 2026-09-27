# Proof of Purpose - Engineering Notes

> **KNOWN GAP (fix after hackathon):** auth failures return HTTP 200 with `{"ok": false}` instead of real 401/403, because Jac 0.34.20 exposes no request-level hook. Clients must check `ok`.

## Toolchain (verified 2026-09-26)

| Item | Value |
|---|---|
| Jac | `jac 0.34.20`, single self-contained binary (embedded Python 3.14.6, byLLM, server) |
| `pip show jaclang byllm` | N/A: byLLM is `jaclang.byllm` inside the binary |
| Jac runtime packages | `httpx`, `requests`, `stripe 15.6.1` (via `jac install stripe`); no `mcp` |
| Python side | separate `.venv` from `requirements.txt` (mcp, httpx, pytest) |
| cloc | not installed; Jac % will be counted with a small script |

## Serving

- `jac start main.jac` (the JacHammer preview manages it here: app :8000, API :8001).
- `def:pub f(...)` -> `POST /function/f`; `walker:pub W` -> `POST /walker/W`.
- Envelope: `{ok, type, data: {result, reports}, error, meta}`. Function payload is `data.result`.
- CORS on by default. Graph persists across restarts (SQLite in `.jac/data/`).
- Every endpoint must be named in `main.jac`'s import, or it 404/405s.
- Entry module uses absolute imports (`import from jac.api {...}`); `import from .x` fails there.

## LLM (Groq)

- `jac.toml`: `default_model = "${LLM_MODEL:-groq/openai/gpt-oss-120b}"`, `api_key = "${GROQ_API_KEY:-}"`, `temperature = 0.0`.
- `llama-3.3-70b-versatile` was deprecated for the free/dev tier (model_not_found).
- Smoke test passed on `openai/gpt-oss-120b`: `by llm()` enum returned `HAPPY` for positive text and `SAD` for negative text.

## Auth

- Tried: endpoint param `request: fastapi.Request` -> Pydantic schema error, route 404. No supported request hook.
- Adopted: `api_key` in JSON body, checked in `jac/auth.jac` (`hmac.compare_digest`) as the first statement of every endpoint.
- Roles: `AGENT_API_KEY` vs `ADMIN_API_KEY`; each key is rejected on the other role's endpoints.
- Contract: every result has top-level `ok`; failures add `error: {code, message}`.
- `tests/test_auth.py`: 35/35 pass live, including "action never executes" checks.

## ENGINE QUIRK: delete + create of the same node type in one request

> **Watch for this pattern anywhere in the codebase.** Before writing any code
> path, check: does one request delete nodes of type X and also create a node of
> type X? If so, restructure it.

- **Symptom:** nodes created after a delete of the same archetype in the same
  request can be lost (not persisted). Observed with the original wipe-and-reseed
  `reset_demo` (graph empty on every other reset) and with `AuditEntry` (reset
  deleted all audit entries, then wrote one; stored rows grew irregularly).
- **Not the cause:** `[root -->]` is a plain list evaluated eagerly (probe
  verified), so iterating it while mutating edges is safe.
- **Fix pattern:** update existing nodes in place; only create when none
  exists; never create a type you just deleted in the same request.
- **Applied in:** `jac/seed.jac` (reset), `jac/context.jac` (upserts never delete),
  evidence supersede (marks old Evidence untrusted instead of deleting it;
  Evidence is only created at read time, never in the reset/registration path).
- **Check next:** Phase 3 `Question` cleanup in the interrogator and Phase 4
  `resolve_escalation`.
- Verified stable: 5x `reset_demo` and 4 rounds of A/B/A account re-registration
  give identical stored anchor counts (`scripts/reset_stability.py`,
  `scripts/account_churn.py`).

## Deliberate limitations

- `reset_demo` writes **no** AuditEntry (it deletes all audit entries; writing
  one in the same request hits the quirk above).
- Verify Services stays on the RULES_ONLY allowlist on purpose, so the
  side-by-side scenario 4 comparison (RULES_ONLY approves, FULL denies) works.
- `.jac/data/` holds ~340 orphan rows from early delete/disconnect resets. Stable,
  not growing. Do **not** wipe until the team schedules it with time to verify
  the graph reseeds right after.
- Trusted Evidence is created lazily, when `get_vendors`/`get_instructions` shows
  the value to the agent, not at registration. Evidence = "the system showed the
  agent this value from this source".

## Deviations from the build prompt

1. No `pip show` (single binary).
2. Auth key in body, not `X-API-Key` header; 200 + `ok:false` instead of 401/403.
3. Module layout: `jac/` package imported as `jac.api`, `jac.graph`, `jac.auth` from the root `main.jac`.
4. `debug_create_escalation` is an admin-only test fixture until the pipeline creates escalations.
