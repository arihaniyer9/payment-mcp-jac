"""Deterministic checks: provenance walker + history walker.

These must catch scenario 2 (fake bank-change email) with LLM checks disabled.
"""
import from jac.graph {
    PaymentRequest, Evidence, Vendor, Invoice, Settings, CheckResult,
    MatchedTo, PaysTo, EvidenceKind, Severity, find_instruction, find_invoice
}
import from jac.evidence { normalize_value, normalize_name }

glob FIELD_KINDS: dict[str, str] = {
    "account_number": "ACCOUNT",
    "payee_name": "NAME",
    "amount": "AMOUNT",
    "invoice_id": "INVOICE_ID"
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
                    evidence_node_ids=[e.evidence_id for e in trusted]
                ));
            } elif matches {
                self.classification[field] = UNTRUSTED_ONLY;
                sev = Severity.HARD.value if field == "account_number" else Severity.SOFT.value;
                self.results.append(CheckResult(
                    name=f"provenance.{field}", passed=False, severity=sev,
                    detail=f"{field} '{shown}' appears ONLY in untrusted sources: "
                        + f"{_describe(matches)}. No trusted record confirms it.",
                    evidence_node_ids=[e.evidence_id for e in matches]
                ));
            } else {
                self.classification[field] = UNSOURCED;
                self.results.append(CheckResult(
                    name=f"provenance.{field}", passed=False, severity=Severity.SOFT.value,
                    detail=f"{field} '{shown}' was never shown to the agent by any source.",
                    evidence_node_ids=[]
                ));
            }
        }
        if find_instruction(here.instruction_id) is None {
            self.results.append(CheckResult(
                name="provenance.instruction_id", passed=False, severity=Severity.HARD.value,
                detail=f"Cited instruction '{here.instruction_id}' does not exist.",
                evidence_node_ids=[]
            ));
        } else {
            self.results.append(CheckResult(
                name="provenance.instruction_id", passed=True, severity=Severity.INFO.value,
                detail=f"Instruction '{here.instruction_id}' exists.", evidence_node_ids=[]
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
                f"Invoice {here.invoice_id} is already paid. This would be a duplicate payment.");
        } else {
            self._add("history.duplicate_payment", True, Severity.INFO.value,
                f"Invoice {here.invoice_id} is unpaid.");
        }
        if pr.amount_cents != here.amount_cents {
            self._add("history.amount_matches_invoice", False, Severity.SOFT.value,
                f"Amount ${pr.amount_cents / 100:,.2f} differs from invoice {here.invoice_id} "
                + f"amount ${here.amount_cents / 100:,.2f}.");
        } else {
            self._add("history.amount_matches_invoice", True, Severity.INFO.value,
                f"Amount matches invoice {here.invoice_id}.");
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
            f"Payee '{self.request.payee_name}' is not in vendor records (new payee).");
    }

    def _compare_vendor(v: Vendor) {
        pr = self.request;
        if normalize_name(v.name) != normalize_name(pr.payee_name) {
            self._add("history.known_payee", False, Severity.SOFT.value,
                f"Payee '{pr.payee_name}' does not match the invoice's vendor '{v.name}'.");
        } else {
            self._add("history.known_payee", True, Severity.INFO.value,
                f"Payee matches vendor record '{v.name}'.");
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
                ));
        } else {
            self._add("history.account_matches_vendor", True, Severity.INFO.value,
                f"Account matches {v.name}'s account on file.");
        }
    }

    def _check_cap {
        cap = self.settings.per_txn_cap_cents;
        if self.request.amount_cents > cap {
            self._add("history.per_txn_cap", False, Severity.SOFT.value,
                f"Amount ${self.request.amount_cents / 100:,.2f} exceeds the per-transaction "
                + f"cap ${cap / 100:,.2f}.");
        }
    }

    def _add(name: str, passed: bool, severity: str, detail: str) {
        self.results.append(CheckResult(
            name=name, passed=passed, severity=severity, detail=detail, evidence_node_ids=[]
        ));
    }
}
