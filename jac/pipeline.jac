"""request_payment pipeline.

FULL:       provenance walker -> history walker -> (LLM checks: Phase 3) -> decide
RULES_ONLY: cap + allowlist only -> decide
APPROVE -> gateway (mock until Phase 4) -> invoice marked paid.
"""
import os;
import from jac.auth { Role, authorize, fail, ok }
import from jac.graph {
    PaymentRequest, CheckResult, AuditEntry, Evidence, Verdict, Mode,
    CitesEvidence, AuthorizedBy, HasCheck,
    get_settings_node, find_request, find_instruction, find_invoice
}
import from jac.evidence { to_cents, now_iso }
import from jac.checks_det { provenance_check, history_check }
import from jac.decision { decide, rules_only_checks }


def check_view(c: CheckResult) -> dict[str, any] {
    return {
        "name": c.name,
        "passed": c.passed,
        "severity": c.severity,
        "detail": c.detail,
        "evidence_node_ids": c.evidence_node_ids
    };
}


def decision_view(pr: PaymentRequest) -> dict[str, any] {
    return {
        "request_id": pr.request_id,
        "verdict": pr.verdict,
        "checks": [check_view(c) for c in [pr ->:HasCheck:->][?:CheckResult]],
        "questions": [],
        "payment_ref": pr.payment_ref,
        "mode": pr.mode
    };
}


def _gateway(pr: PaymentRequest) -> str {
    # Phase 4: Stripe test mode when MOCK_GATEWAY is not "true".
    _ = os.getenv("MOCK_GATEWAY", "true");
    return f"mock_{pr.request_id}";
}


def _link_citations(pr: PaymentRequest) {
    ins = find_instruction(pr.instruction_id);
    if ins is not None {
        pr +>:AuthorizedBy():+> ins;
    }
    cited = set(pr.evidence_ids);
    for ev in [root -->][?:Evidence] {
        if ev.evidence_id in cited {
            pr +>:CitesEvidence():+> ev;
        }
    }
}


def _run_checks(pr: PaymentRequest) -> list[CheckResult] {
    s = get_settings_node();
    if pr.mode == Mode.RULES_ONLY.value {
        return rules_only_checks(pr, s);
    }
    prov = pr spawn provenance_check();
    hist = root spawn history_check(
        request=pr, settings=s,
        account_provenance=prov.classification.get("account_number", "")
    );
    return prov.results + hist.results;
}


"""Execute the gateway and mark the invoice paid only on success."""
def execute_payment(pr: PaymentRequest) {
    try {
        pr.payment_ref = _gateway(pr);
        pr.status = "EXECUTED";
        inv = find_invoice(pr.invoice_id);
        if inv is not None {
            inv.paid = True;
        }
    } except Exception as e {
        pr.payment_ref = None;
        pr.status = "GATEWAY_ERROR";
        err = CheckResult(
            name="gateway.execute", passed=False, severity="INFO",
            detail=f"Gateway call failed: {str(e)[:200]}"
        );
        pr +>:HasCheck():+> err;
    }
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
        return ok(decision_view(existing) | {"idempotent_replay": True});
    }
    cents = to_cents(req.get("amount"));
    if cents is None or cents <= 0 {
        return fail("BAD_REQUEST", "amount must be a positive number.");
    }
    justification = req.get("justification") or {};
    if not isinstance(justification, dict) {
        return fail("BAD_REQUEST", "justification must be an object.");
    }
    raw_ids = justification.get("evidence_ids") or [];
    evidence_ids = [str(x) for x in raw_ids] if isinstance(raw_ids, list) else [];

    pr = root ++> PaymentRequest(
        request_id=request_id,
        payee_name=str(req.get("payee_name", "")),
        account_number=str(req.get("account_number", "")),
        amount_cents=cents,
        currency=str(req.get("currency", "USD")),
        invoice_id=str(req.get("invoice_id", "")),
        instruction_id=str(justification.get("instruction_id", "")),
        evidence_ids=evidence_ids,
        reason_text=str(justification.get("reason_text", "")),
        mode=get_settings_node().mode,
        created_at=now_iso()
    );
    _link_citations(pr);
    for c in _run_checks(pr) {
        pr +>:HasCheck():+> c;
    }
    pr.verdict = decide([pr ->:HasCheck:->][?:CheckResult]);
    if pr.verdict == Verdict.APPROVE.value {
        execute_payment(pr);
    } elif pr.verdict == Verdict.DENY.value {
        pr.status = "BLOCKED";
    }
    root ++> AuditEntry(ts=now_iso(), event="DECISION", request_id=request_id, detail=pr.verdict);
    return ok(decision_view(pr) | {"idempotent_replay": False});
}
