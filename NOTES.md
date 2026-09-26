# Proof of Purpose - Engineering Notes

## Phase 0: toolchain (verified 2026-09-26)

| Item | Value |
|---|---|
| Jac | `jac 0.34.20` (Linux x86_64), **single self-contained binary** at `/usr/local/bin/jac` |
| Jac's embedded Python | 3.14.6 (byLLM, server (jac-scale/FastAPI/uvicorn) all bundled) |
| System Python | 3.12.14 - no packages installed (`mcp`, `httpx`, `pytest` absent) |
| `pip show jaclang byllm` | **Not applicable** - no pip packages exist; byLLM is `jaclang.byllm` inside the binary |
| In Jac runtime | `httpx`, `requests` available; `stripe`, `mcp` NOT installed |
| `cloc` | not installed |
| git | installed, but project is **not a git repo** yet |

## Serving

- Command: `jac start main.jac` (API only: `jac start main.jac --no-client`). Needs `jac.toml` in cwd.
  In JacHammer the preview server is platform-managed (App :8000, API :8001).
- `walker:pub X` -> `POST /walker/X`, JSON body maps onto `has` fields.
- `def:pub f(a: T)` -> `POST /function/f`, JSON body maps onto params.
- `@restspec(method=HTTPMethod.GET, path="/x/{id}")` for custom routes.
- Envelope: `{"ok", "type", "data": {"result", "reports": [...]}, "error": {code,message}|null, "meta"}`.
  Walker payload = `data.reports[0]`; function payload = `data.result`.
- `:pub` = no auth, runs on shared guest graph. Plain/`:priv` = JWT required, per-user root.
- CORS: enabled by default (preflight echoes Origin, allows credentials). Verified with curl.
- Swagger at `/docs`.

## Verified syntax (see smoke.jac)

```jac
enum Mood { HAPPY, SAD }
sem Mood.HAPPY = "...";                       # enum member sem
node SmokeItem { has name: str; has seq: int = 0; }
edge SmokeLink { has label: str = ""; }
a = (root ++> SmokeItem(name="x")) as SmokeItem;   # connect to root, returns node
a +>: SmokeLink(label="child") :+> b;             # typed edge with attrs
[root -->][?:SmokeItem]                            # filter by type
visit [->:SmokeLink:->];                           # traverse typed edge
can collect with SmokeItem entry { here.name; }    # ability; `here` = current node
can done with Root exit { report {...}; }
def classify_mood(text: str) -> Mood by llm();     # by llm, enum return
sem classify_mood.text = "...";                    # param sem
```

- Persistence: nodes reachable from `root` survived a full server restart (SQLite `.jac/data/anchor_store.db`).
- byLLM: call path works; it failed only because `OPENAI_API_KEY` is unset. Model is configured in `jac.toml [byllm.model]`.

## Deviations from the build prompt

1. **Entry module cannot use relative imports** (`import from .smoke` -> ImportError). Use absolute `import from smoke {...}`.
2. **`pip show jaclang byllm` is not applicable**: Jac ships as one binary.
3. Every endpoint must be **named in the entry module's import**, or it returns 405.
4. `jac.toml` must sit where `jac start` runs, so `jac.toml` + `main.jac` belong at repo root (proposed layout pending approval).
