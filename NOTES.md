# Proof of Purpose - Engineering Notes

## Phase 0 toolchain (verified 2026-09-26)

| Item | Value |
|---|---|
| Jac | `jac 0.34.20` (Linux x86_64), single self-contained binary |
| Jac runtime Python | 3.14.6 |
| System Python | 3.12.14 |
| `pip show jaclang byllm` | Not applicable: Jac/byLLM ship inside the single binary |
| In Jac runtime | `httpx`, `requests`; Stripe 15.6.1 installed with `jac install stripe`; `mcp` missing |
| `cloc` | Not installed |
| git | Initialized in a prior step; prior tool session's sandbox cwd differed from the IDE workspace so git status/commit could not be verified this turn |

## Verified Jac + HTTP behavior

- `jac start main.jac` is the documented command; this hosted preview is platform-managed (app :8000, API :8001).
- `walker:pub X` is `POST /walker/X`; `def:pub f(...)` is `POST /function/f`.
- Response envelope is `{ok, type, data: {result, reports}, error, meta}`.
- CORS is already enabled by the hosted server.
- Nodes attached under `root` persisted through a preview restart.
- Server-module endpoints must be explicitly named in the entry module import list.
- Use `import from smoke {...}` in the server entry; `import from .smoke` fails without a package parent.

## Groq

- `jac.toml` configures `default_model = "${LLM_MODEL:-groq/llama-3.3-70b-versatile}"`, `api_key = "${GROQ_API_KEY:-}"`, `temperature = 0.0`.
- A key is now reaching Groq: the error changed from `invalid_api_key` to `model_not_found`.
- Two live LLM smoke calls (positive and negative text) **both failed**: Groq returned `The model llama-3.3-70b-versatile does not exist or you do not have access to it.` No classification is claimed. Set `LLM_MODEL` in Settings to a model enabled on the provided Groq account, then restart and re-test.
- `api.groq.com` and `api.stripe.com` are reachable from the sandbox (401 without credentials).

## API key proof and decision

- Tried a Jac endpoint parameter `request: fastapi.Request` to read `X-API-Key`. Jac's endpoint schema generation fails with Pydantic `PydanticSchemaGenerationError`; route returns 404. No runtime hook for app code was established.
- Per user approval, fallback is a public Jac function receiving `api_key` in JSON request body. `auth_proof.jac` exports `agent_auth_proof` and `admin_auth_proof`; credentials are compared in Jac against `AGENT_API_KEY` and `ADMIN_API_KEY`.
- **Security/contract caveats:** body key is a deviation from the original header contract and can be logged with request bodies. This proof does not create real admin actions; its `action` parameter only validates role separation. Do not integrate secrets or production behavior until env keys and tests are verified.
- Expected routes are `POST /function/agent_auth_proof` with `{"api_key":"..."}` and `POST /function/admin_auth_proof` with `{"api_key":"...","action":"set_mode"}`. Admin action allowlist is `resolve_escalation`, `set_mode`, `set_llm_checks`, `reset_demo`.
- Jac REST transport wraps the body result with HTTP 200; proof rejection is represented as `{ok:false,status:401,error:"Unauthorized"}` inside `data.result`. It is **not an actual HTTP 401**. This is a serious gap from the requested proof; do not claim real HTTP access control.
- Actual preview environment does not expose `AGENT_API_KEY` or `ADMIN_API_KEY`; endpoint calls with purported correct values were rejected. Preview cases: missing agent key = unauthorized payload; wrong agent key = unauthorized payload; correct agent candidate = unauthorized payload; admin candidate = unauthorized payload. These are not valid credential checks because server-side secrets are absent.
- Direct Jac logic test (`auth_logic_check.jac`, then deleted) set process-local keys and called the functions directly. Results: correct agent key PASS; missing agent key rejected PASS; wrong agent key rejected PASS; correct admin key/action PASS; agent key rejected for each of `resolve_escalation`, `set_mode`, `set_llm_checks`, `reset_demo` PASS (4/4). This does NOT test HTTP routing or status codes.
- `tests/test_auth.py` is an integration test with key-presence skips. Requires pytest/httpx in teammate Python env, and actual keys in both test and server processes. The preview denial payload is not actual HTTP 401.

## Required next verification

1. Configure `AGENT_API_KEY`, `ADMIN_API_KEY` and a valid `LLM_MODEL` in JacHammer Settings Environment; restart the preview.
2. Verify success for each correct key, rejection for missing and wrong keys, and admin action denial under agent key. If body-result denial is not sufficient, stop and implement server-level actual HTTP status/auth middleware before real endpoints.
3. Re-test both Groq smoke classifications with an account-accessible model.
4. Do not start Phase 1 until these outcomes are actually verified.

## Deviation requiring team agreement

The user approved JSON-body key fallback if the FastAPI request-hook option fails. The Jac credential comparison logic passes a direct local test, but it fails the required HTTP-level rejection criterion: Jac serializes unauthorized results with HTTP 200. Do not wire this into real endpoints. The requested HTTP auth proof is **not complete**; use a proven ASGI middleware or another supported server-level mechanism before proceeding. Dashboard clients must send the key in each JSON body if retaining this prototype.
