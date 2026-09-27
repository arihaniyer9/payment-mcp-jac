# Proof of Purpose - Engineering Notes

How the system works today, and what to watch for. The README covers the API
contract; this file covers internals, operations and known limitations.

## Toolchain

| Item | Value |
|---|---|
| Jac | `jac 0.34.20`: one binary with an embedded Python 3.14, byLLM and the HTTP server |
| LLM | Groq via byLLM. `jac.toml [byllm.model]`: `default_model = "${LLM_MODEL:-groq/openai/gpt-oss-120b}"`, `api_key = "${GROQ_API_KEY}"`, temperature 0 |
| Jac-side packages | `stripe` (declared in `jac.toml [dependencies]`) |
| Python side | `mcp_server/`, `agent/`, `tests/`, `scripts/` use a separate venv from `requirements.txt` (`mcp<2`, `httpx`, `pytest`). `mcp` 2.x renamed FastMCP, hence the pin |

### Where Jac puts installed packages
`jac install` installs PyPI dependencies into the **runtime's own site-packages**
(`~/.cache/jac/rt/<hash>/python/lib/python3.14/site-packages`), not into
`.jac/venv/lib/.../site-packages` (which stays empty; it is a
`--system-site-packages` venv over the runtime). The server's `sys.path`
includes that runtime directory, so an installed package is importable by the
server. A fresh sandbox re-runs `jac install` from `jac.toml` before starting
the server (see `.jac-deps-ready`), so **the dependency must be declared in the
IDE copy of `jac.toml`**; editing it only inside the sandbox is lost on the
next sync.

## Serving

- `def:pub f(...)` is `POST /function/f`; the JSON body maps to parameters. Payload is `data.result`.
- Every endpoint must be named in `main.jac`'s import list or it returns 404/405.
- The entry module uses absolute imports (`import from jac.api {...}`).
- The graph persists in SQLite under `.jac/data/`. CORS is on by default.
- Server-module edits need a server restart (the preview's hot reload only covers client code).

## Module map (`jac/`)

| Module | Responsibility |
|---|---|
| `graph.jac` | Nodes, edges, enums with `sem` strings, lookups |
| `auth.jac` | `authorize(api_key, role)`, `ok()` / `fail()` response helpers |
| `context.jac` | Context Registration upserts (vendor, invoice, instruction). Never deletes |
| `seed.jac` | Demo seed values and `reset_seed_data` (update in place) |
| `evidence.jac` | Normalization, deterministic regex extraction, Evidence registration |
| `checks_det.jac` | `provenance_check` and `history_check` walkers |
| `checks_llm.jac` | Deterministic instruction-scope check, LLM intent match (residual case), interrogator, judge |
| `decision.jac` | Verdict precedence and RULES_ONLY checks |
| `pipeline.jac` | `request_payment`, `answer_verification`, `finalize`, `execute_payment` |
| `gateway.jac` | Stripe test mode or mock |
| `messages.jac` | All end-user wording (`user_message`, `summary`) |
| `evidence_graph.jac` | Walker that builds the dashboard evidence subgraph |
| `api.jac` | Admin, registration, read and dashboard endpoints |

## Graph model

Nodes, all reachable from `root`:
- `Settings {mode, llm_checks_enabled, per_txn_cap_cents, allowlist, evidence_seq}`
- `Vendor {name, known_account, first_seen}`
- `Invoice {invoice_id, vendor_name, amount_cents, period, paid}`
- `Email {email_id, sender, subject, body, received_at}`
- `Instruction {instruction_id, text, created_at}`
- `Evidence {evidence_id, raw_value, normalized_value, kind, source_type, source_id, trusted, first_seen}`
- `PaymentRequest {request_id, payee_name, account_number, amount_cents, currency, invoice_id, instruction_id, evidence_ids, reason_text, status, verdict, payment_ref, mode, created_at, summary, provenance, intent_verdict}`
- `CheckResult {name, passed, severity, detail, evidence_node_ids, user_message, resolved_by}`
- `Question {question_id, kind, topic, text, expected, answer, result}` (`expected` never leaves the server)
- `AuditEntry {ts, event, request_id, detail}`

Edges: `DerivedFrom` (Evidence to its source), `PaysTo` (Invoice to Vendor),
`AuthorizedBy` (request to Instruction), `CitesEvidence` (request to cited
Evidence), `MatchedTo {field}` (request to every Evidence matching a field),
`HasCheck`, `HasQuestion`.

Enums: `Mode`, `Verdict`, `Severity`, `EvidenceKind`, `SourceType`,
`IntentVerdict {MATCHES, EXCEEDS_SCOPE, UNRELATED}`,
`AnswerMatch {CONSISTENT, INCONSISTENT, EVASIVE}`.

## Evidence

- Evidence means "the system showed the agent this value from this source".
  It is created when a value is handed to the agent: `read_inbox` (untrusted),
  `get_instructions` and `get_vendors` (trusted). Registration alone does not
  create Evidence.
- Normalization: accounts strip spaces, dashes and dots and are uppercased;
  amounts become integer cents; names are case-folded with collapsed whitespace;
  invoice ids are uppercased.
- Extraction from email text is regex only (accounts, `$` amounts, `INV-nnnn`,
  known vendor names, `X Services|Supplies|Inc|LLC`). No LLM.
- Registration is idempotent per (source, kind, value). For single-valued facts
  (a vendor's account on file, an invoice's amount) a new value marks the old
  Evidence untrusted (`_SUPERSEDED`), so a stale account cannot vouch for a payment.

## Pipeline (`request_payment`)

1. `authorize` with the agent key.
2. Validate shape; replay the stored decision if `request_id` exists (idempotency).
3. Create the `PaymentRequest`, link `AuthorizedBy` and `CitesEvidence`.
4. **RULES_ONLY:** only `rules.per_txn_cap` and `rules.allowlist` (both HARD). Go to step 9.
5. **Provenance walker** (deterministic): for account, payee, amount and invoice id,
   find all Evidence with the same kind and normalized value, add `MatchedTo`
   edges, classify TRUSTED / UNTRUSTED_ONLY / UNSOURCED. UNTRUSTED_ONLY on the
   account is HARD, other fields SOFT; UNSOURCED is SOFT. A missing instruction is HARD.
6. **History walker** (deterministic): Invoice, then over `PaysTo` to Vendor.
   Already paid: HARD. Amount differs from invoice: SOFT. Payee differs from
   vendor or unknown: SOFT. Account differs from the account on file: SOFT, or
   HARD when the account provenance is UNTRUSTED_ONLY. Over the cap: SOFT.
7. **Instruction scope** (deterministic, always in FULL mode, before any LLM):
   when the instruction names at least one `INV-nnnn`:
   - this invoice named and the payee's name appears in the instruction: MATCHES (passes)
   - this invoice named, payee not in it: EXCEEDS_SCOPE (SOFT)
   - another invoice named, payee in it: EXCEEDS_SCOPE (SOFT)
   - another invoice named, payee not in it: UNRELATED (HARD)

   The amount is not compared here (the amount checks own that).
8. **LLM intent match**, only if step 7 did not decide (instruction names no
   invoice) and `llm_checks_enabled`. Inputs: instruction text read from the
   graph by id, plus typed payment fields. `reason_text` is never sent to an LLM.
   EXCEEDS_SCOPE is SOFT, UNRELATED is HARD. An LLM error becomes SOFT (escalate).
9. **Interrogator:** only when there is no HARD failure, every SOFT failure is
   an amount check, and the amount is at most 10% below a real unpaid invoice.
   Creates three templated questions (invoice number, invoice amount, period).
10. **Decision** (`finalize`): any HARD, DENY; pending questions, NEEDS_ANSWERS;
    any SOFT, ESCALATE; otherwise APPROVE, then `execute_payment`.
11. Write `summary`, an `AuditEntry`, return the Decision.

`answer_verification`: all pending questions must be answered in one call.
Invoice id and amount are judged deterministically; the period by month name,
with the LLM judge only if no month is found. INCONSISTENT is HARD, EVASIVE is
SOFT. If all are CONSISTENT, the amount SOFT failures are marked
`resolved_by = "verification"` (still shown, no longer counted). Then `finalize`.

`resolve_escalation(APPROVE)` calls the same `execute_payment` (gateway, then
invoice marked paid only on success). It refuses a request whose invoice is
already paid.

## Gateway

- `MOCK_GATEWAY` is true unless set to exactly `false`. Mock returns `mock_<request_id>`.
- Real path: Stripe PaymentIntent in test mode, `pm_card_visa`, confirmed,
  metadata `{request_id, invoice_id, payee_name}`, idempotency key = `request_id`.
- A `STRIPE_SECRET_KEY` that is not `sk_test_...` raises at import, so the
  server refuses to start with a live key.
- On gateway error: verdict stays APPROVE, `payment_ref = null`, status
  `GATEWAY_ERROR`, a `gateway.execute` check is attached, invoice not marked paid.

## Reset

`reset_demo` deletes run artifacts (PaymentRequest, CheckResult, Question,
Evidence, AuditEntry) and non-seed registered context, then writes the Acme
seed through the same upserts as the registration API. Seed nodes are never
deleted, only updated. Verified: node and edge counts identical across 5 resets.

## Known limitations

- **No real 401/403.** Auth failures return HTTP 200 with `{"ok": false,
  "error": {...}}`; Jac 0.34.20 has no supported request hook. Clients must
  check `ok`. Fix after the hackathon if a request middleware becomes available.
- **Engine quirk: delete and create of the same node type in one request can
  lose the new nodes.** Observed with the original reset and with AuditEntry.
  Watch for this anywhere: every write path here updates in place and never
  creates a type it deleted in the same request. `resolve_escalation` and the
  interrogator only create or update.
- **`reset_demo` writes no AuditEntry** (it deletes all audit entries; writing
  one in the same request hits the quirk above).
- **New fields on existing node types** are missing on previously stored nodes
  at runtime; read such fields with `getattr(node, "field", default)`.
- Verify Services is on the RULES_ONLY allowlist on purpose, so RULES_ONLY
  approves scenario 4 in the side-by-side demo.
- `.jac/data/` holds ~340 orphan rows from early resets. Stable, not growing.
  Do not wipe until the team schedules it with time to verify the reseed.
- Reads and provenance scan all Evidence under root, and idempotency scans all
  requests. Fine at demo scale.
- The preview sandbox is slow (1 vCPU, heavily shared, `--dev` server). Run
  tests one function at a time there.

## Deviations from the build prompt

1. Auth key is in the JSON body (`api_key`), not an `X-API-Key` header.
2. Endpoints are functions (`/function/<name>`); walkers are used internally
   for traversal (provenance, history, evidence graph).
3. Layout: `jac.toml` and `main.jac` at the repo root, modules in `jac/`.
4. Instruction scope is decided deterministically when the instruction names an
   invoice; the LLM intent match only covers instructions that name none.
