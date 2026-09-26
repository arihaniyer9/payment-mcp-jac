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

## Deviations from the build prompt

1. No `pip show` (single binary).
2. Auth key in body, not `X-API-Key` header; 200 + `ok:false` instead of 401/403.
3. Module layout: `jac/` package imported as `jac.api`, `jac.graph`, `jac.auth` from the root `main.jac`.
4. `debug_create_escalation` is an admin-only test fixture until the pipeline creates escalations.
