"""Decision engine (deterministic) and the RULES_ONLY baseline."""
import from jac.graph { PaymentRequest, Settings, CheckResult, Verdict, Severity }
import from jac.evidence { normalize_name }


"""Precedence: HARD fail -> DENY; pending questions -> NEEDS_ANSWERS;
SOFT fail -> ESCALATE; otherwise APPROVE."""
def decide(checks: list[CheckResult], pending_questions: int = 0) -> str {
    failed = [c for c in checks if not c.passed];
    if any([c.severity == Severity.HARD.value for c in failed]) {
        return Verdict.DENY.value;
    }
    if pending_questions > 0 {
        return Verdict.NEEDS_ANSWERS.value;
    }
    if any([c.severity == Severity.SOFT.value for c in failed]) {
        return Verdict.ESCALATE.value;
    }
    return Verdict.APPROVE.value;
}


"""Baseline guard: only the per-transaction cap and payee allowlist.
Exists to show on stage that rule-based guards approve the attacks."""
def rules_only_checks(pr: PaymentRequest, s: Settings) -> list[CheckResult] {
    under_cap = pr.amount_cents <= s.per_txn_cap_cents;
    allowed = normalize_name(pr.payee_name) in [normalize_name(a) for a in s.allowlist];
    return [
        CheckResult(
            name="rules.per_txn_cap", passed=under_cap,
            severity=Severity.HARD.value,
            detail=(f"Amount ${pr.amount_cents / 100:,.2f} is within" if under_cap
                    else f"Amount ${pr.amount_cents / 100:,.2f} exceeds")
                + f" the cap ${s.per_txn_cap_cents / 100:,.2f}."
        ),
        CheckResult(
            name="rules.allowlist", passed=allowed, severity=Severity.HARD.value,
            detail=f"Payee '{pr.payee_name}' is " + ("" if allowed else "not ")
                + "on the allowlist."
        )
    ];
}
