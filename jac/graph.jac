"""Graph model: nodes, enums. Grows each phase; fields follow section 6."""

enum Mode: str {
    FULL = "FULL",
    RULES_ONLY = "RULES_ONLY"
}

sem Mode.FULL = "All deterministic and LLM checks run.";
sem Mode.RULES_ONLY = "Baseline: only per-transaction cap and payee allowlist.";

enum Verdict: str {
    APPROVE = "APPROVE",
    ESCALATE = "ESCALATE",
    DENY = "DENY",
    NEEDS_ANSWERS = "NEEDS_ANSWERS"
}

sem Verdict.APPROVE = "Payment is fully justified by trusted evidence and executes.";
sem Verdict.ESCALATE = "Payment needs a human decision on the dashboard.";
sem Verdict.DENY = "Payment is blocked.";
sem Verdict.NEEDS_ANSWERS = "Agent must answer verification questions first.";

node Settings {
    has mode: str = "FULL",
        llm_checks_enabled: bool = True,
        per_txn_cap_cents: int = 500000,
        allowlist: list[str] = ["acme supplies"];
}

node PaymentRequest {
    has request_id: str,
        payee_name: str = "",
        account_number: str = "",
        amount_cents: int = 0,
        currency: str = "USD",
        invoice_id: str = "",
        instruction_id: str = "",
        reason_text: str = "",
        status: str = "PENDING",
        verdict: str = "",
        payment_ref: str | None = None,
        mode: str = "FULL",
        created_at: str = "";
}

node AuditEntry {
    has ts: str,
        event: str,
        request_id: str = "",
        detail: str = "";
}


def get_settings_node -> Settings {
    found = [root -->][?:Settings];
    if found {
        return found[0];
    }
    return root ++> Settings();
}


def find_request(request_id: str) -> PaymentRequest | None {
    for pr in [root -->][?:PaymentRequest] {
        if pr.request_id == request_id {
            return pr;
        }
    }
    return None;
}
