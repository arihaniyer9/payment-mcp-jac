"""request_payment pipeline.

FULL:       provenance walker -> history walker -> (LLM checks: Phase 3) -> decide
RULES_ONLY: cap + allowlist only -> decide
APPROVE -> gateway (mock until Phase 4) -> invoice marked paid.
"""
import os;
import from jac.auth { Role, authorize, fail, ok }
import from jac.graph {
    PaymentRequest, CheckResult, AuditEntry, Evidence, Question, Verdict, Mode,
    Severity, AnswerMatch, CitesEvidence, AuthorizedBy, HasCheck, HasQuestion,
    get_settings_node, find_request, find_instruction, find_invoice
}
import from jac.evidence { to_cents, now_iso }
import from jac.checks_det { provenance_check, history_check }
import from jac.checks_llm {
    intent_check, should_interrogate, create_questions, judge, verification_check,
    VERIFIABLE_CHECKS
}
import from jac.decision { decide, rules_only_checks }
import jac.messages as msg;
import from jac.gateway { charge }


def check_view(c: CheckResult) -> dict[str, any] {
    return {
        "name": c.name,
        "passed": c.passed,
        "severity": c.severity,
        "detail": c.detail,
        "evidence_node_ids": c.evidence_node_ids,
        "user_message": c.user_message
    };
}


"""Questions shown to the agent: id + text only. f"expected" never leaves the server."""
def question_view(q: Question) -> dict[str, any] {
    return {"question_id": q.question_id, "text": q.text};
}


def decision_view(pr: PaymentRequest) -> dict[str, any] {
    pending = [q for q in [pr ->:HasQuestion:->][?:Question] if q.answer is None];
    return {
        "request_id": pr.request_id,
        "verdict": pr.verdict,
        "summary": pr.summary,
        "checks": [check_view(c) for c in [pr ->:HasCheck:->][?:CheckResult]],
        "questions": [question_view(q) for q in pending]
            if pr.verdict == Verdict.NEEDS_ANSWERS.value else [],
        "payment_ref": pr.payment_ref,
        "mode": pr.mode
    };
}


"""Active checks for the decision: all CheckResults except SOFT failures that a
consistent verification round has cleared (they stay visible, marked resolved)."""
def active_checks(pr: PaymentRequest) -> list[CheckResult] {
    # getattr: CheckResults persisted before f"resolved_by" existed load without it.
    return [c for c in [pr ->:HasCheck:->][?:CheckResult] if getattr(c, "resolved_by", "") == ""];
}


"""Decide, then act on the verdict. Shared by request_payment and
answer_verification so both paths execute identically."""
def finalize(pr: PaymentRequest) {
    pending = len([q for q in [pr ->:HasQuestion:->][?:Question] if q.answer is None]);
    pr.verdict = decide(active_checks(pr), pending);
    if pr.verdict == Verdict.APPROVE.value {
        execute_payment(pr);
    } elif pr.verdict == Verdict.DENY.value {
        pr.status = "BLOCKED";
    } elif pr.verdict == Verdict.ESCALATE.value {
        pr.status = "PENDING";
    } else {
        pr.status = "AWAITING_ANSWERS";
    }
    pr.summary = msg.summarize(pr, active_checks(pr));
    root ++> AuditEntry(ts=now_iso(), event="DECISION", request_id=pr.request_id, detail=pr.verdict);
}


def _gateway(pr: PaymentRequest) -> str {
    return charge(pr.request_id, pr.amount_cents, pr.currency, pr.invoice_id, pr.payee_name);
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
    pr.provenance = dict(prov.classification);
    hist = root spawn history_check(
        request=pr, settings=s,
        account_provenance=prov.classification.get("account_number", "")
    );
    results = prov.results + hist.results;
    if s.llm_checks_enabled {
        intent = intent_check(pr);
        if intent is not None {
            results.append(intent);
        }
    }
    return results;
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
            detail=f"Gateway call failed: {str(e)[:200]}",
            user_message=msg.msg_gateway_error()
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
    checks = _run_checks(pr);
    for c in checks {
        pr +>:HasCheck():+> c;
    }
    if pr.mode == Mode.FULL.value and should_interrogate(pr, checks) {
        create_questions(pr);
    }
    finalize(pr);
    return ok(decision_view(pr) | {"idempotent_replay": False});
}


"""Answer NEEDS_ANSWERS questions. answers = [{question_id, answer}, ...].
All pending questions must be answered in one call. Re-runs the decision."""
def:pub answer_verification(
    api_key: str = "", request_id: str = "", answers: list[dict[str, any]] = []
) -> dict[str, any] {
    denied = authorize(api_key, Role.AGENT);
    if denied is not None {
        return denied;
    }
    pr = find_request(request_id);
    if pr is None {
        return fail("NOT_FOUND", f"No payment request {request_id}.");
    }
    if pr.verdict != Verdict.NEEDS_ANSWERS.value {
        return fail("CONFLICT", f"Request {request_id} is not waiting for answers.");
    }
    given: dict[str, str] = {};
    for a in answers {
        if isinstance(a, dict) {
            given[str(a.get("question_id", ""))] = str(a.get("answer", ""))[:500];
        }
    }
    pending = [q for q in [pr ->:HasQuestion:->][?:Question] if q.answer is None];
    missing = [q.question_id for q in pending if q.question_id not in given];
    if missing {
        return fail("BAD_REQUEST", f"Answer every question: missing {', '.join(missing)}.");
    }
    llm_on = get_settings_node().llm_checks_enabled;
    for q in pending {
        q.answer = given[q.question_id];
        q.result = judge(q, q.answer, llm_on);
        pr +>:HasCheck():+> verification_check(q);
    }
    if all([q.result == AnswerMatch.CONSISTENT.value for q in pending]) {
        for c in [pr ->:HasCheck:->][?:CheckResult] {
            if not c.passed and c.severity == Severity.SOFT.value and c.name in VERIFIABLE_CHECKS {
                c.resolved_by = "verification";
            }
        }
    }
    finalize(pr);
    return ok(decision_view(pr) | {"idempotent_replay": False});
}
