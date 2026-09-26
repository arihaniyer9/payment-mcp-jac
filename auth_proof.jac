import os;


def _check_key(provided: str, configured: str | None) -> bool {
    if configured is None or configured == "" {
        return False;
    }
    return provided == configured;
}


def:pub agent_auth_proof(api_key: str = "") -> dict {
    if _check_key(api_key, os.getenv("AGENT_API_KEY")) {
        return {"ok": True, "role": "agent"};
    }
    return {"ok": False, "status": 401, "error": "Unauthorized"};
}


def:pub admin_auth_proof(api_key: str = "", action: str = "") -> dict {
    if not _check_key(api_key, os.getenv("ADMIN_API_KEY")) {
        return {"ok": False, "status": 401, "error": "Unauthorized"};
    }
    allowed_actions: list[str] = [
        "resolve_escalation", "set_mode", "set_llm_checks", "reset_demo"
    ];
    if action not in allowed_actions {
        return {"ok": False, "status": 400, "error": "Unknown admin action"};
    }
    return {"ok": True, "role": "admin", "action": action};
}
