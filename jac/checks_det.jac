"""Deterministic checks: provenance walker + history walker.

These must catch scenario 2 (fake bank-change email) with LLM checks disabled.
Each CheckResult carries f"detail" (operator/dashboard wording, names evidence)
and f"user_message" (plain language, see jac/messages.jac).
"""
import from jac.graph {
    PaymentRequest, Evidence, Vendor, Invoice, Settings, CheckResult,
    MatchedTo, PaysTo, EvidenceKind, Severity, find_instruction, find_invoice
}
import from jac.evidence { normalize_value, normalize_name }
import jac.messages as msg;

glob FIELD_KINDS: dict[str, str] = {
    "account_number": "ACCOUNT",
    "payee_name": "NAME",
    "amount": "AMOUNT",
    "invoice_id": "INVOICE_ID"
};

glob FIELD_LABELS: dict[str, str] = {
    "account_number": "account number",
    "payee_name": "payee name",
    "amount": "amount",
    "invoice_id": "invoice number"
};

glob TRUSTED: str = "TRUSTED",
     UNTRUSTED_ONLY: str = "UNTRUSTED_ONLY",
     UNSOURCED: str = "UNSOURCED";


def field_value(pr: PaymentRequest, field: str) -> str {
    if field == "account_number" { return pr.account_number; }
    if field == "payee_name" { return pr.payee_name; }
    if field == "amount" { return str(pr.amount_cents / 100); }
    return pr.invoice_id;
}


def _describe(evs: list[Evidence]) -> str {
    parts = [f"{e.evidence_id} ({e.source_type.lower()} {e.source_id})" for e in evs];
    return ", ".join(parts);
}


def _field_message(pr: PaymentRequest, field: str, status: str) -> str {
    label = FIELD_LABELS[field];
    if status == TRUSTED {
        return msg.msg_account_trusted(pr) if field == "account_number" else msg.msg_field_trusted(label);
    }
    if status == UNTRUSTED_ONLY {
        return msg.msg_account_email_only(pr) if field == "account_number" else msg.msg_field_email_only(label);
    }
    return msg.msg_field_unsourced(label);
}


"""Walks from the PaymentRequest to every Evidence node with the same kind +
normalized value, links it with MatchedTo(field), and classifies each field."""
walker provenance_check {
    has classification: dict[str, str] = {},
        results: list[CheckResult] = [];

    can run with PaymentRequest entry {
        all_evidence = [root -->][?:Evidence];
        for (field, kind) in FIELD_KINDS.items() {
            normalized = normalize_value(kind, field_value(here, field));
            matches = [
                e for e in all_evidence
                if e.kind == kind and e.normalized_value == normalized and normalized != ""
            ];
            for e in matches {
                here +>:MatchedTo(field=field):+> e;
            }
            trusted = [e for e in matches if e.trusted];
            shown = field_value(here, field);
            if trusted {
                self.classification[field] = TRUSTED;
                self.results.append(CheckResult(
                    name=f"provenance.{field}", passed=True, severity=Severity.INFO.value,
                    detail=f"{field} '{shown}' matches trusted evidence {_describe(trusted)}.",
                    evidence_node_ids=[e.evidence_id for e in trusted],
                    user_message=_field_message(here, field, TRUSTED)
                ));
            } elif matches {
                self.classification[field] = UNTRUSTED_ONLY;
                sev = Severity.HARD.value if field == "account_number" else Severity.SOFT.value;
                self.results.append(CheckResult(
                    name=f"provenance.{field}", passed=False, severity=sev,
                    detail=f"{field} '{shown}' appears ONLY in untrusted sources: "
                        + f"{_describe(matches)}. No trusted record confirms it.",
                    evidence_node_ids=[e.evidence_id for e in matches],
                    user_message=_field_message(here, field, UNTRUSTED_ONLY)
                ));
            } else {
                self.classification[field] = UNSOURCED;
                self.results.append(CheckResult(
                    name=f"provenance.{field}", passed=False, severity=Severity.SOFT.value,
                    detail=f"{field} '{shown}' was never shown to the agent by any source.",
                    evidence_node_ids=[],
                    user_message=_field_message(here, field, UNSOURCED)
                ));
            }
        }
        if find_instruction(here.instruction_id) is None {
            self.results.append(CheckResult(
                name="provenance.instruction_id", passed=False, severity=Severity.HARD.value,
                detail=f"Cited instruction '{here.instruction_id}' does not exist.",
                evidence_node_ids=[], user_message=msg.msg_instruction_missing()
            ));
        } else {
            self.results.append(CheckResult(
                name="provenance.instruction_id", passed=True, severity=Severity.INFO.value,
                detail=f"Instruction '{here.instruction_id}' exists.", evidence_node_ids=[],
                user_message=msg.msg_instruction_ok()
            ));
        }
    }
}


"""Walks Invoice -> PaysTo -> Vendor and compares the request with history."""
walker history_check {
    has request: PaymentRequest,
        settings: Settings,
        account_provenance: str = "",
        results: list[CheckResult] = [];

    can start with Root entry {
        inv = find_invoice(self.request.invoice_id);
        if inv is None {
            self._check_vendor_by_name();
            self._check_cap();
            return;
        }
        visit inv;
    }

    can on_invoice with Invoice entry {
        pr = self.request;
        if here.paid {
            self._add("history.duplicate_payment", False, Severity.HARD.value,
                f"Invoice {here.invoice_id} is already paid. This would be a duplicate payment.",
                msg.msg_duplicate(here.invoice_id));
        } else {
            self._add("history.duplicate_payment", True, Severity.INFO.value,
                f"Invoice {here.invoice_id} is unpaid.", msg.msg_invoice_unpaid(here.invoice_id));
        }
        if pr.amount_cents != here.amount_cents {
            self._add("history.amount_matches_invoice", False, Severity.SOFT.value,
                f"Amount ${pr.amount_cents / 100:,.2f} differs from invoice {here.invoice_id} "
                + f"amount ${here.amount_cents / 100:,.2f}.",
                msg.msg_amount_mismatch(pr, here.invoice_id, here.amount_cents));
        } else {
            self._add("history.amount_matches_invoice", True, Severity.INFO.value,
                f"Amount matches invoice {here.invoice_id}.", msg.msg_amount_matches(here.invoice_id));
        }
        self._check_cap();
        visit [here ->:PaysTo:->];
    }

    can on_vendor with Vendor entry {
        self._compare_vendor(here);
    }

    def _check_vendor_by_name {
        for v in [root -->][?:Vendor] {
            if normalize_name(v.name) == normalize_name(self.request.payee_name) {
                self._compare_vendor(v);
                return;
            }
        }
        self._add("history.known_payee", False, Severity.SOFT.value,
            f"Payee '{self.request.payee_name}' is not in vendor records (new payee).",
            msg.msg_new_payee(self.request));
    }

    def _compare_vendor(v: Vendor) {
        pr = self.request;
        if normalize_name(v.name) != normalize_name(pr.payee_name) {
            self._add("history.known_payee", False, Severity.SOFT.value,
                f"Payee '{pr.payee_name}' does not match the invoice's vendor '{v.name}'.",
                msg.msg_payee_mismatch(pr, v.name));
        } else {
            self._add("history.known_payee", True, Severity.INFO.value,
                f"Payee matches vendor record '{v.name}'.", msg.msg_payee_known(v.name));
        }
        req_acct = normalize_value(EvidenceKind.ACCOUNT.value, pr.account_number);
        known = normalize_value(EvidenceKind.ACCOUNT.value, v.known_account);
        if req_acct != known {
            hard = self.account_provenance == UNTRUSTED_ONLY;
            self._add("history.account_matches_vendor", False,
                Severity.HARD.value if hard else Severity.SOFT.value,
                f"Account {pr.account_number} differs from {v.name}'s account on file "
                + f"{v.known_account}" + (
                    "; the new account only appears in untrusted email." if hard else "."
                ),
                msg.msg_account_changed(pr, v.name, hard));
        } else {
            self._add("history.account_matches_vendor", True, Severity.INFO.value,
                f"Account matches {v.name}'s account on file.", msg.msg_account_unchanged(v.name));
        }
    }

    def _check_cap {
        cap = self.settings.per_txn_cap_cents;
        if self.request.amount_cents > cap {
            self._add("history.per_txn_cap", False, Severity.SOFT.value,
                f"Amount ${self.request.amount_cents / 100:,.2f} exceeds the per-transaction "
                + f"cap ${cap / 100:,.2f}.", msg.msg_over_cap(self.request, cap));
        }
    }

    def _add(name: str, passed: bool, severity: str, detail: str, user_message: str) {
        self.results.append(CheckResult(
            name=name, passed=passed, severity=severity, detail=detail,
            evidence_node_ids=[], user_message=user_message
        ));
    }
}
