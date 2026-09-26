"""Evidence registry: normalization, deterministic extraction, registration.

No LLM is used here, so provenance stays deterministic.
"""
import re;
import from datetime { datetime, timezone }
import from jac.graph {
    Evidence, Email, Instruction, Vendor, Invoice, DerivedFrom,
    EvidenceKind, SourceType, get_settings_node
}

glob ACCOUNT_RE: str = r"\b[A-Z]{2}(?:[\s.\-]?[A-Z0-9]{2,}){2,}\b",
     AMOUNT_RE: str = r"\$\s?(\d{1,3}(?:,\d{3})*(?:\.\d{2})?|\d+(?:\.\d{2})?)",
     INVOICE_RE: str = r"\bINV-\d{3,}\b";


def now_iso -> str {
    return datetime.now(timezone.utc).isoformat();
}


# ---------- normalization ----------

def normalize_account(value: str) -> str {
    return re.sub(r"[\s.\-]", "", value).upper();
}


def normalize_name(value: str) -> str {
    return " ".join(value.casefold().split());
}


def to_cents(value: any) -> int | None {
    try {
        text = str(value).replace("$", "").replace(",", "").strip();
        return round(float(text) * 100);
    } except (TypeError, ValueError) {
        return None;
    }
}


def normalize_value(kind: str, value: str) -> str {
    if kind == EvidenceKind.ACCOUNT.value {
        return normalize_account(value);
    }
    if kind == EvidenceKind.AMOUNT.value {
        cents = to_cents(value);
        return str(cents) if cents is not None else "";
    }
    if kind == EvidenceKind.INVOICE_ID.value {
        return value.strip().upper();
    }
    return normalize_name(value);
}


# ---------- extraction ----------

def extract_accounts(text: str) -> list[str] {
    found: list[str] = [];
    for m in re.findall(ACCOUNT_RE, text) {
        has_digit = any([ch.isdigit() for ch in m]);
        if has_digit and not m.upper().startswith("INV") and m not in found {
            found.append(m);
        }
    }
    return found;
}


def extract_amounts(text: str) -> list[str] {
    return list(dict.fromkeys(re.findall(AMOUNT_RE, text)));
}


def extract_invoice_ids(text: str) -> list[str] {
    return list(dict.fromkeys(re.findall(INVOICE_RE, text)));
}


# ---------- registration ----------

def _next_evidence_id -> str {
    s = get_settings_node();
    s.evidence_seq += 1;
    return f"ev_{s.evidence_seq:03d}";
}


"""Register one value from one source. Idempotent per (source, kind, value):
calling read_inbox twice returns the same evidence ids."""
def register(
    source: Email | Instruction | Vendor | Invoice, source_type: str, source_id: str, kind: str,
    raw_value: str, trusted: bool
) -> Evidence {
    normalized = normalize_value(kind, raw_value);
    for ev in [source <-:DerivedFrom:<-][?:Evidence] {
        if ev.kind == kind and ev.normalized_value == normalized {
            return ev;
        }
    }
    ev = root ++> Evidence(
        evidence_id=_next_evidence_id(), raw_value=raw_value,
        normalized_value=normalized, kind=kind, source_type=source_type,
        source_id=source_id, trusted=trusted, first_seen=now_iso()
    );
    ev +>:DerivedFrom():+> source;
    return ev;
}


def register_email(em: Email) -> list[Evidence] {
    src = SourceType.EMAIL.value;
    evs: list[Evidence] = [
        register(em, src, em.email_id, EvidenceKind.OTHER.value, em.sender, False)
    ];
    text = em.subject + "\n" + em.body;
    for a in extract_accounts(text) {
        evs.append(register(em, src, em.email_id, EvidenceKind.ACCOUNT.value, a, False));
    }
    for amt in extract_amounts(text) {
        evs.append(register(em, src, em.email_id, EvidenceKind.AMOUNT.value, amt, False));
    }
    for inv in extract_invoice_ids(text) {
        evs.append(register(em, src, em.email_id, EvidenceKind.INVOICE_ID.value, inv, False));
    }
    for name in _names_in(text) {
        evs.append(register(em, src, em.email_id, EvidenceKind.NAME.value, name, False));
    }
    return evs;
}


"""Payee names in an email: any known vendor name it mentions, plus any name
after 'to'/'from' matching 'X Services|Supplies|Inc|LLC'. Deterministic."""
def _names_in(text: str) -> list[str] {
    names: list[str] = [];
    for v in [root -->][?:Vendor] {
        if normalize_name(v.name) in normalize_name(text) {
            names.append(v.name);
        }
    }
    for m in re.findall(r"\b([A-Z][a-z]+(?: [A-Z][a-z]+)* (?:Services|Supplies|Inc|LLC))\b", text) {
        if normalize_name(m) not in [normalize_name(n) for n in names] {
            names.append(m);
        }
    }
    return names;
}


def register_instruction(ins: Instruction) -> list[Evidence] {
    src = SourceType.INSTRUCTION.value;
    evs: list[Evidence] = [];
    for inv in extract_invoice_ids(ins.text) {
        evs.append(register(ins, src, ins.instruction_id, EvidenceKind.INVOICE_ID.value, inv, True));
    }
    for amt in extract_amounts(ins.text) {
        evs.append(register(ins, src, ins.instruction_id, EvidenceKind.AMOUNT.value, amt, True));
    }
    for name in _names_in(ins.text) {
        evs.append(register(ins, src, ins.instruction_id, EvidenceKind.NAME.value, name, True));
    }
    return evs;
}


def register_vendor(v: Vendor) -> list[Evidence] {
    src = SourceType.VENDOR_RECORD.value;
    return [
        register(v, src, v.name, EvidenceKind.NAME.value, v.name, True),
        register(v, src, v.name, EvidenceKind.ACCOUNT.value, v.known_account, True)
    ];
}


"""Invoices in the accounts-payable ledger are part of the trusted vendor
record (source_type VENDOR_RECORD, source_id = invoice id)."""
def register_invoice(inv: Invoice) -> list[Evidence] {
    src = SourceType.VENDOR_RECORD.value;
    return [
        register(inv, src, inv.invoice_id, EvidenceKind.INVOICE_ID.value, inv.invoice_id, True),
        register(inv, src, inv.invoice_id, EvidenceKind.AMOUNT.value,
            f"{inv.amount_cents / 100:.2f}", True)
    ];
}


def evidence_view(ev: Evidence) -> dict[str, any] {
    return {
        "evidence_id": ev.evidence_id,
        "kind": ev.kind,
        "raw_value": ev.raw_value,
        "source_type": ev.source_type,
        "source_id": ev.source_id,
        "trusted": ev.trusted
    };
}
