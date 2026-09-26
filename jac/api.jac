"""HTTP endpoints. Every endpoint takes f"api_key" in the JSON body and
returns a dict with a top-level f"ok". Auth runs BEFORE any graph read/write."""
import from datetime { datetime, timezone }
import from jac.auth { Role, authorize, fail, ok }
import from jac.graph {
    Settings, PaymentRequest, AuditEntry, Mode, Verdict,
    get_settings_node, find_request
}


def _now -> str {
    return datetime.now(timezone.utc).isoformat();
}


def _audit(event: str, request_id: str, detail: str) {
    root ++> AuditEntry(ts=_now(), event=event, request_id=request_id, detail=detail);
}


def _settings_view(s: Settings) -> dict[str, any] {
    return {
        "mode": s.mode,
        "llm_checks_enabled": s.llm_checks_enabled,
        "per_txn_cap_cents": s.per_txn_cap_cents,
        "allowlist": s.allowlist
    };
}


def _request_view(pr: PaymentRequest) -> dict[str, any] {
    return {
        "request_id": pr.request_id,
        "payee_name": pr.payee_name,
        "amount_cents": pr.amount_cents,
        "currency": pr.currency,
        "invoice_id": pr.invoice_id,
        "status": pr.status,
        "verdict": pr.verdict,
        "payment_ref": pr.payment_ref,
        "mode": pr.mode,
        "created_at": pr.created_at
    };
}


# ---------- admin endpoints ----------

def:pub set_mode(api_key: str = "", mode: str = "") -> dict[str, any] {
    denied = authorize(api_key, Role.ADMIN);
    if denied is not None {
        return denied;
    }
    if mode not in [m.value for m in Mode] {
        return fail("BAD_REQUEST", "mode must be FULL or RULES_ONLY.");
    }
    s = get_settings_node();
    s.mode = mode;
    _audit("SET_MODE", "", mode);
    return ok({"settings": _settings_view(s)});
}


def:pub set_llm_checks(api_key: str = "", enabled: bool = True) -> dict[str, any] {
    denied = authorize(api_key, Role.ADMIN);
    if denied is not None {
        return denied;
    }
    s = get_settings_node();
    s.llm_checks_enabled = enabled;
    _audit("SET_LLM_CHECKS", "", str(enabled));
    return ok({"settings": _settings_view(s)});
}


def:pub get_settings(api_key: str = "") -> dict[str, any] {
    denied = authorize(api_key, Role.ADMIN);
    if denied is not None {
        return denied;
    }
    return ok({"settings": _settings_view(get_settings_node())});
}


def:pub list_escalations(api_key: str = "") -> dict[str, any] {
    denied = authorize(api_key, Role.ADMIN);
    if denied is not None {
        return denied;
    }
    items = [
        _request_view(pr)
        for pr in [root -->][?:PaymentRequest]
        if pr.verdict == Verdict.ESCALATE.value and pr.status == "PENDING"
    ];
    return ok({"escalations": items});
}


def:pub resolve_escalation(
    api_key: str = "", request_id: str = "", action: str = ""
) -> dict[str, any] {
    denied = authorize(api_key, Role.ADMIN);
    if denied is not None {
        return denied;
    }
    if action not in ["APPROVE", "DENY"] {
        return fail("BAD_REQUEST", "action must be APPROVE or DENY.");
    }
    pr = find_request(request_id);
    if pr is None {
        return fail("NOT_FOUND", f"No payment request {request_id}.");
    }
    if pr.verdict != Verdict.ESCALATE.value or pr.status != "PENDING" {
        return fail("CONFLICT", f"Request {request_id} is not a pending escalation.");
    }
    # Phase 4 wires the gateway here; until then APPROVE marks it resolved only.
    pr.status = "RESOLVED_" + action;
    _audit("RESOLVE_ESCALATION", request_id, action);
    return ok({"request": _request_view(pr)});
}


def:pub reset_demo(api_key: str = "") -> dict[str, any] {
    denied = authorize(api_key, Role.ADMIN);
    if denied is not None {
        return denied;
    }
    for n in [root -->] {
        del n;
    }
    root ++> Settings();
    _audit("RESET_DEMO", "", "graph wiped and reseeded");
    return ok({"reset": True});
}


# ---------- test fixture (admin-only) ----------
# Creates a pending escalation so the auth test can prove the action never
# executes. Replaced by the real pipeline in Phase 2/3.
def:pub debug_create_escalation(api_key: str = "", request_id: str = "") -> dict[str, any] {
    denied = authorize(api_key, Role.ADMIN);
    if denied is not None {
        return denied;
    }
    if request_id == "" or find_request(request_id) is not None {
        return fail("BAD_REQUEST", "request_id must be new and non-empty.");
    }
    pr = root ++> PaymentRequest(
        request_id=request_id, payee_name="Test Payee", amount_cents=100,
        verdict=Verdict.ESCALATE.value, status="PENDING", created_at=_now()
    );
    return ok({"request": _request_view(pr)});
}


def:pub get_request_status(api_key: str = "", request_id: str = "") -> dict[str, any] {
    denied = authorize(api_key, Role.ADMIN);
    if denied is not None {
        return denied;
    }
    pr = find_request(request_id);
    if pr is None {
        return fail("NOT_FOUND", f"No payment request {request_id}.");
    }
    return ok({"request": _request_view(pr)});
}


# ---------- agent endpoint (stub for Phase 1) ----------

def:pub agent_ping(api_key: str = "") -> dict[str, any] {
    denied = authorize(api_key, Role.AGENT);
    if denied is not None {
        return denied;
    }
    return ok({"role": "agent"});
}
