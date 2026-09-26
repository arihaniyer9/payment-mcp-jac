"""Payment pipeline. Phase 1: validate shape, idempotency, always APPROVE,
mock gateway. Later phases insert evidence/provenance/history/LLM checks
between validation and the decision."""
import os;
import from datetime { datetime, timezone }
import from jac.auth { Role, authorize, fail, ok }
import from jac.graph { PaymentRequest, AuditEntry, Verdict, get_settings_node, find_request }


def _now -> str {
    return datetime.now(timezone.utc).isoformat();
}


def _to_cents(amount: any) -> int | None {
    try {
        return round(float(amount) * 100);
    } except (TypeError, ValueError) {
        return None;
    }
}


def _decision(pr: PaymentRequest) -> dict[str, any] {
    return {
        "request_id": pr.request_id,
        "verdict": pr.verdict,
        "checks": [],
        "questions": [],
        "payment_ref": pr.payment_ref,
        "mode": pr.mode
    };
}


def _mock_gateway(pr: PaymentRequest) -> str {
    # Phase 4 adds Stripe test mode when MOCK_GATEWAY != "true".
    _ = os.getenv("MOCK_GATEWAY", "true");
    return f"mock_{pr.request_id}";
}


def:pub request_payment(api_key: str = "", req: dict[str, any] = {}) -> dict[str, any] {
    denied = authorize(api_key, Role.AGENT);
    if denied is not None {
        return denied;
    }
    request_id = str(req.get("request_id", "")).strip();
    if request_id == "" {
        return fail("BAD_REQUEST", "request_id is required.");
    }
    existing = find_request(request_id);
    if existing is not None {
        return ok(_decision(existing) | {"idempotent_replay": True});
    }
    cents = _to_cents(req.get("amount"));
    if cents is None or cents <= 0 {
        return fail("BAD_REQUEST", "amount must be a positive number.");
    }
    justification = req.get("justification") or {};
    if not isinstance(justification, dict) {
        return fail("BAD_REQUEST", "justification must be an object.");
    }
    settings = get_settings_node();
    pr = root ++> PaymentRequest(
        request_id=request_id,
        payee_name=str(req.get("payee_name", "")),
        account_number=str(req.get("account_number", "")),
        amount_cents=cents,
        currency=str(req.get("currency", "USD")),
        invoice_id=str(req.get("invoice_id", "")),
        instruction_id=str(justification.get("instruction_id", "")),
        reason_text=str(justification.get("reason_text", "")),
        mode=settings.mode,
        created_at=_now()
    );
    # Phase 1: no checks yet -> APPROVE.
    pr.verdict = Verdict.APPROVE.value;
    pr.payment_ref = _mock_gateway(pr);
    pr.status = "EXECUTED";
    root ++> AuditEntry(ts=_now(), event="DECISION", request_id=request_id, detail=pr.verdict);
    return ok(_decision(pr) | {"idempotent_replay": False});
}
