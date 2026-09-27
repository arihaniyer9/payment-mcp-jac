"""HTTP endpoints. Every endpoint takes f"api_key" in the JSON body and
returns a dict with a top-level f"ok". Auth runs BEFORE any graph read/write."""
import from datetime { datetime, timezone }
import from jac.auth { Role, authorize, fail, ok }
import from jac.graph {
    Settings, PaymentRequest, AuditEntry, Email, Instruction, Vendor, Invoice,
    PaysTo, Mode, Verdict, get_settings_node, find_request
}
import from jac.evidence {
    register_email, evidence_view, normalize_account, to_cents
}
import jac.evidence as ev_registry;
import from jac.context {
    upsert_vendor, upsert_invoice, upsert_instruction,
    vendor_view, invoice_view, instruction_view
}
import from jac.seed { reset_seed_data }
import from jac.pipeline { decision_view }


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
    # No audit entry here: reset wipes AuditEntry, and deleting + creating the
    # same node type in one request left orphaned rows in storage.
    reset_seed_data();
    return ok({"reset": True});
}


def:pub get_decision(api_key: str = "", request_id: str = "") -> dict[str, any] {
    denied = authorize(api_key, Role.ADMIN);
    if denied is not None {
        return denied;
    }
    pr = find_request(request_id);
    if pr is None {
        return fail("NOT_FOUND", f"No payment request {request_id}.");
    }
    return ok({"decision": decision_view(pr), "request": _request_view(pr)});
}


# ---------- Context Registration API (admin key) ----------
# The developer's app registers the same ground truth it gives its own agent,
# over a channel the agent never touches. reset_demo uses these same upserts.

def:pub register_vendor(
    api_key: str = "", name: str = "", known_account: str = ""
) -> dict[str, any] {
    denied = authorize(api_key, Role.ADMIN);
    if denied is not None {
        return denied;
    }
    if name.strip() == "" or normalize_account(known_account) == "" {
        return fail("BAD_REQUEST", "name and known_account are required.");
    }
    return ok({"vendor": vendor_view(upsert_vendor(name.strip(), known_account.strip()))});
}


def:pub register_invoice(
    api_key: str = "", invoice_id: str = "", vendor_name: str = "",
    amount: any = None, period: str = ""
) -> dict[str, any] {
    denied = authorize(api_key, Role.ADMIN);
    if denied is not None {
        return denied;
    }
    cents = to_cents(amount);
    if invoice_id.strip() == "" or cents is None or cents <= 0 {
        return fail("BAD_REQUEST", "invoice_id and a positive amount are required.");
    }
    inv = upsert_invoice(invoice_id, vendor_name, cents, period.strip());
    if inv is None {
        return fail("NOT_FOUND", f"Vendor '{vendor_name}' is not registered. Call register_vendor first.");
    }
    return ok({"invoice": invoice_view(inv)});
}


def:pub register_instruction(
    api_key: str = "", text: str = "", instruction_id: str = ""
) -> dict[str, any] {
    denied = authorize(api_key, Role.ADMIN);
    if denied is not None {
        return denied;
    }
    if text.strip() == "" {
        return fail("BAD_REQUEST", "text is required.");
    }
    return ok({"instruction": instruction_view(upsert_instruction(text.strip(), instruction_id.strip()))});
}


# ---------- agent read tools: every value handed out is recorded as Evidence ----------

def:pub read_inbox(api_key: str = "") -> dict[str, any] {
    denied = authorize(api_key, Role.AGENT);
    if denied is not None {
        return denied;
    }
    emails: list[dict[str, any]] = [];
    for em in [root -->][?:Email] {
        evs = register_email(em);
        emails.append({
            "email_id": em.email_id, "sender": em.sender, "subject": em.subject,
            "body": em.body, "received_at": em.received_at,
            "trusted": False,
            "evidence": [evidence_view(e) for e in evs]
        });
    }
    return ok({"emails": emails});
}


def:pub get_instructions(api_key: str = "") -> dict[str, any] {
    denied = authorize(api_key, Role.AGENT);
    if denied is not None {
        return denied;
    }
    items: list[dict[str, any]] = [];
    for ins in [root -->][?:Instruction] {
        evs = ev_registry.register_instruction(ins);
        items.append({
            "instruction_id": ins.instruction_id, "text": ins.text,
            "created_at": ins.created_at, "trusted": True,
            "evidence": [evidence_view(e) for e in evs]
        });
    }
    return ok({"instructions": items});
}


def:pub get_vendors(api_key: str = "") -> dict[str, any] {
    denied = authorize(api_key, Role.AGENT);
    if denied is not None {
        return denied;
    }
    items: list[dict[str, any]] = [];
    for v in [root -->][?:Vendor] {
        evs = ev_registry.register_vendor(v);
        invoices: list[dict[str, any]] = [];
        for inv in [v <-:PaysTo:<-][?:Invoice] {
            inv_evs = ev_registry.register_invoice(inv);
            invoices.append({
                "invoice_id": inv.invoice_id, "period": inv.period,
                "amount": inv.amount_cents / 100, "paid": inv.paid,
                "evidence": [evidence_view(e) for e in inv_evs]
            });
        }
        items.append({
            "name": v.name, "known_account": v.known_account, "trusted": True,
            "evidence": [evidence_view(e) for e in evs],
            "open_invoices": invoices
        });
    }
    return ok({"vendors": items});
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
