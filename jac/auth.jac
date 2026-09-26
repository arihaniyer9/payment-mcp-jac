"""API-key authorization for every Proof of Purpose endpoint.

Contract: every endpoint returns a dict with a top-level f"ok" bool.
On failure: {"ok": False, "error": {"code": str, "message": str}}.
Callers MUST check f"ok" - the HTTP status is 200 even on auth failure
(Jac 0.34.20 offers no supported request-level hook to return 401/403).
"""
import os;
import hmac;

enum Role {
    AGENT,
    ADMIN
}


def _key_matches(provided: str, env_name: str) -> bool {
    configured = os.getenv(env_name) or "";
    if configured == "" or provided == "" {
        return False;
    }
    return hmac.compare_digest(provided.encode(), configured.encode());
}


"""Return None when authorized, or the failure response to return as-is."""
def authorize(api_key: str, role: Role) -> dict[str, any] | None {
    env_name = "ADMIN_API_KEY" if role == Role.ADMIN else "AGENT_API_KEY";
    if not _key_matches(api_key, env_name) {
        return fail("UNAUTHORIZED", f"A valid {role.name.lower()} API key is required.");
    }
    return None;
}


def fail(code: str, message: str) -> dict[str, any] {
    return {"ok": False, "error": {"code": code, "message": message}};
}


def ok(data: dict[str, any]) -> dict[str, any] {
    return {"ok": True, "error": None} | data;
}
