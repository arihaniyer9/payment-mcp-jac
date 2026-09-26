# Proof of Purpose — authentication proof checkpoint

This workspace currently contains the Jac Phase 0 smoke test and an **unintegrated API-key proof**, not the payment firewall. The hosted Jac API listens on port 8001; the JacHammer preview owns the server lifecycle.

## Current proof endpoints

Keys are provided in the JSON body for this approved fallback (the original `X-API-Key` header proof could not be implemented through the endpoint signature). Configure `AGENT_API_KEY` and `ADMIN_API_KEY` in JacHammer Settings → Environment, then restart the preview.

| Endpoint | JSON body | Expected data result |
|---|---|---|
| `POST /function/agent_auth_proof` | `{"api_key":"<agent key>"}` | `{"ok":true,"role":"agent"}` for the matching agent key; otherwise `{ "ok":false,"status":401,"error":"Unauthorized" }` |
| `POST /function/admin_auth_proof` | `{"api_key":"<admin key>","action":"set_mode"}` | success for the matching admin key and an allowed action; otherwise unauthorized |

Allowed proof actions: `resolve_escalation`, `set_mode`, `set_llm_checks`, `reset_demo`. These are labels for the proof only; the endpoint does not perform admin operations.

**Important limitation:** Jac's REST response envelope remains HTTP 200 for unauthorized proof results; the `status: 401` value is inside `data.result`. This is not true HTTP access control and is not sufficient to protect real payment/admin endpoints. The check compares keys inside the endpoint. Do not wire it into real operations until an actual HTTP-level protection mechanism is proven. The body-key fallback also changes the API contract and request bodies may be logged.

The original undocumented FastAPI request-object approach was tried and failed at endpoint schema generation (`PydanticSchemaGenerationError` for `starlette.requests.Request`, route returned 404). If a supported server-level auth hook is established, prefer that; otherwise a real ASGI middleware is needed to return HTTP 401 before dispatch.

## Proof status — incomplete; not safe for real endpoints

The FastAPI `Request` endpoint parameter failed Jac's endpoint schema generation (`PydanticSchemaGenerationError`). The approved JSON-body fallback allows Jac to compare strings, but it **does not enforce HTTP-level access control**: an unauthorized result is returned inside a normal HTTP 200 envelope. The current preview also lacks `AGENT_API_KEY` and `ADMIN_API_KEY`, so matching-key calls cannot be demonstrated there. Do not use these proof functions to protect real operations.

Direct, local Jac logic check with test-only process environment values passed: correct agent key succeeds; missing/wrong agent key rejected; correct admin key/action succeeds; agent key denied for all four admin labels. This is only a pure logic test—not an HTTP test. There is no committed API integration test until a server-level hook capable of returning actual 401/403 is established. An ASGI middleware or supported authentication extension is required before Phase 1.

## Groq smoke status

`jac.toml` uses `GROQ_API_KEY`, model `${LLM_MODEL:-groq/llama-3.3-70b-versatile}`, and temperature 0. The key now reaches Groq, but both smoke calls fail with `model_not_found` for `llama-3.3-70b-versatile`. Select a model accessible to the Groq account via `LLM_MODEL` in Settings → Environment, restart, and re-run before relying on any LLM checks.

See [NOTES.md](NOTES.md) for Phase 0 syntax/HTTP findings and outstanding decisions. **Phase 1 has not started.**
