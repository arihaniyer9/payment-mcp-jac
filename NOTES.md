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

- **Known residual risk:** `clear_non_seed_context` deletes developer-registered
  Vendor/Invoice/Instruction nodes that are not part of the seed, and the upserts
  that follow only create a node of those types if a *seed* node is missing
  (fresh database). On an existing database reset never creates a type it just
  deleted. On a fresh database there is nothing to delete, so no conflict.

## Demo host performance (measured 2026-09-27)

- The preview sandbox pod (`JAC_SANDBOX_ID=warm-pool`) is capped at **1 vCPU**
  (`cpu.max = 100000 100000`) on a node whose load average is ~31 on 32 cores.
  About **20% of CPU periods are throttled** (`nr_throttled 16993 / 85259`).
- The server itself runs `jac start --dev` (HMR file watcher + Vite/bun), using
  ~80% of that one core under test load; idle it uses ~4%.
- Measured: `agent_ping` 0.04 s, `get_settings` 0.1 s, but `reset_demo` ~9 s,
  `read_inbox` 3-13 s, a full scenario (reads + payment via MCP) ~30 s.
  `tests/test_scenarios.py` alone takes ~9.5 min.
- **Not verified:** whether a JacHammer deployment gets more CPU or runs without
  `--dev`. Nothing in this sandbox exposes a host-size setting. Treat the live
  demo as at risk and keep a **pre-recorded run** as backup.
- Likely code-side contributors (not yet optimized): every read endpoint and the
  provenance walker scan all Evidence under root; `request_payment` scans all
  PaymentRequests for idempotency. Fine at demo scale, O(n) per request.

## Phase 3 status (2026-09-27, in progress)

- Wired: `intent_check` (by llm, instruction read from graph by id), interrogator
  (templated questions, expected answers server-side only), judge (deterministic
  for invoice id/amount, LLM only for free-text period), `answer_verification`
  endpoint + MCP tool, scenario 5 in the replay agent, `tests/test_phase3.py`,
  `scripts/reliability.py`.
- Regression hit and fixed: adding `CheckResult.resolved_by` made old persisted
  CheckResults fail with `'CheckResult' object has no attribute 'resolved_by'`
  (schema migration did not backfill the default on those loaded objects).
  Fixed with `getattr(c, "resolved_by", "")`. Lesson: when adding a field that is
  read across existing nodes, read it defensively.
- Reliability so far (LLM checks ON, gpt-oss-120b, temp 0):
  - Scenario 4: **10/10** DENY with intent UNRELATED.
  - Scenario 3: **2/4**. Failure mode: INV-4471 (the authorized March invoice)
    also classified EXCEEDS_SCOPE, so it ESCALATEs instead of APPROVE. INV-4502
    was correctly EXCEEDS_SCOPE in 4/4. Not yet fixed: next step is tightening
    the MATCHES/EXCEEDS_SCOPE sem strings, then a stronger model via LLM_MODEL.
- Not yet run: `tests/test_phase3.py`, scenario 5 end to end.

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
