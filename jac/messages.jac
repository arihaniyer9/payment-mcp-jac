"""End-user-facing wording, kept in one place so tone can be reviewed.

Rules: plain language a developer's agent can repeat verbatim to its end user.
No internal IDs (ev_..., em_..., ins_...), no "provenance", "evidence node",
"HARD/SOFT", or check names. Money is formatted as $1,234.56.
"""
import from jac.graph { PaymentRequest, CheckResult, Verdict }


def money(cents: int) -> str {
    return f"${cents / 100:,.2f}";
}


def _payee(pr: PaymentRequest) -> str {
    return pr.payee_name or "this payee";
}


# ---------- per-check user messages ----------

def msg_account_trusted(pr: PaymentRequest) -> str {
    return f"The account number matches the one we have on file for {_payee(pr)}.";
}

def msg_account_email_only(pr: PaymentRequest) -> str {
    return "The account number for this payment only appeared in an email. We don't have it "
        + f"on file for {_payee(pr)}, and emails can be faked.";
}

def msg_field_email_only(field_label: str) -> str {
    return f"The {field_label} for this payment only appeared in an email and isn't confirmed "
        + "by your own records.";
}

def msg_field_unsourced(field_label: str) -> str {
    return f"The {field_label} for this payment doesn't appear anywhere in your records or "
        + "your inbox.";
}

def msg_field_trusted(field_label: str) -> str {
    return f"The {field_label} matches your own records.";
}

def msg_instruction_missing -> str {
    return "This payment doesn't point to any instruction you gave, so there's no record "
        + "that you asked for it.";
}

def msg_instruction_ok -> str {
    return "This payment is linked to one of your instructions.";
}

def msg_duplicate(invoice_id: str) -> str {
    return f"Invoice {invoice_id} has already been paid. Paying it again would be a duplicate payment.";
}

def msg_invoice_unpaid(invoice_id: str) -> str {
    return f"Invoice {invoice_id} hasn't been paid yet.";
}

def msg_amount_mismatch(pr: PaymentRequest, invoice_id: str, invoice_cents: int) -> str {
    return f"The amount ({money(pr.amount_cents)}) doesn't match invoice {invoice_id}, "
        + f"which is for {money(invoice_cents)}.";
}

def msg_amount_matches(invoice_id: str) -> str {
    return f"The amount matches invoice {invoice_id}.";
}

def msg_new_payee(pr: PaymentRequest) -> str {
    return f"{_payee(pr)} isn't one of your known vendors.";
}

def msg_payee_mismatch(pr: PaymentRequest, vendor_name: str) -> str {
    return f"The invoice belongs to {vendor_name}, but the payment is addressed to {_payee(pr)}.";
}

def msg_payee_known(vendor_name: str) -> str {
    return f"{vendor_name} is one of your known vendors.";
}

def msg_account_changed(pr: PaymentRequest, vendor_name: str, email_only: bool) -> str {
    base = f"This isn't the bank account we have on file for {vendor_name}.";
    if email_only {
        return base + " The new account only came from an email, which is a common sign of "
            + "invoice fraud.";
    }
    return base + " A change of bank details should be confirmed with the vendor directly.";
}

def msg_account_unchanged(vendor_name: str) -> str {
    return f"The bank account matches the one on file for {vendor_name}.";
}

def msg_over_cap(pr: PaymentRequest, cap_cents: int) -> str {
    return f"This payment ({money(pr.amount_cents)}) is above your per-payment limit of "
        + f"{money(cap_cents)}.";
}

def msg_rules_cap(pr: PaymentRequest, cap_cents: int, ok: bool) -> str {
    if ok {
        return f"The amount is within your per-payment limit of {money(cap_cents)}.";
    }
    return msg_over_cap(pr, cap_cents);
}

def msg_rules_allowlist(pr: PaymentRequest, ok: bool) -> str {
    if ok {
        return f"{_payee(pr)} is on your list of approved payees.";
    }
    return f"{_payee(pr)} isn't on your list of approved payees.";
}

def msg_gateway_error -> str {
    return "The payment was approved, but the payment provider couldn't complete it. "
        + "Nothing was charged.";
}

# Phase 3 (intent + verification)

def msg_intent_matches -> str {
    return "This payment is what your instruction asked for.";
}

def msg_intent_exceeds(pr: PaymentRequest) -> str {
    return f"Your instruction covers a payment to {_payee(pr)}, but not this one: it's for a "
        + "different invoice or period than the one you asked to pay.";
}

def msg_intent_unrelated(pr: PaymentRequest) -> str {
    return f"Your instruction doesn't mention {_payee(pr)} at all, so there's no sign you "
        + "asked for this payment.";
}

def msg_intent_unavailable -> str {
    return "We couldn't automatically confirm this payment matches your instruction, so a "
        + "person should check it.";
}

def msg_answer_consistent -> str {
    return "The answers to our verification questions matched your records.";
}

def msg_answer_inconsistent -> str {
    return "An answer to one of our verification questions contradicted your records.";
}

def msg_answer_evasive -> str {
    return "One of our verification questions wasn't answered clearly, so a person should check this payment.";
}


# ---------- overall summary ----------

def _first_failures(checks: list[CheckResult], severity: str) -> list[str] {
    msgs: list[str] = [];
    for c in checks {
        if not c.passed and c.severity == severity and c.user_message and c.user_message not in msgs {
            msgs.append(c.user_message);
        }
    }
    return msgs;
}


"""One or two sentences covering the verdict as a whole."""
def summarize(pr: PaymentRequest, checks: list[CheckResult]) -> str {
    what = f"the {money(pr.amount_cents)} payment to {_payee(pr)}";
    if pr.verdict == Verdict.APPROVE.value {
        if pr.mode == "RULES_ONLY" {
            return f"Approved {what}. Only the basic limit and approved-payee rules were checked.";
        }
        if pr.payment_ref is None and pr.status == "GATEWAY_ERROR" {
            return f"Approved {what}, but the payment provider couldn't complete it. Nothing was charged.";
        }
        return f"Approved {what}. Every detail matches your own records and your instructions.";
    }
    if pr.verdict == Verdict.DENY.value {
        reasons = _first_failures(checks, "HARD");
        return f"Blocked {what}. " + (reasons[0] if reasons else "It failed a required safety check.");
    }
    if pr.verdict == Verdict.NEEDS_ANSWERS.value {
        reasons = _first_failures(checks, "SOFT");
        return f"Before paying {what}, we need a few quick answers to confirm the details. "
            + (reasons[0] if reasons else "").strip();
    }
    reasons = _first_failures(checks, "SOFT");
    return f"Held {what} for a person to review. " + (reasons[0] if reasons else "")
        .strip();
}
