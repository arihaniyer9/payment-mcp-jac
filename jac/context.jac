"""Context Registration: how a developer's app registers ground truth.

These upserts are the ONLY write path for trusted context (vendors, invoices,
instructions). reset_demo uses them too, so the demo seed and a developer's
own data go through provably the same code.

Evidence is NOT created here. It is created, with the same normalization and
trusted=True labeling, at the moment a value is handed to the agent
(get_vendors / get_instructions), because Evidence means "the system showed
the agent this value from this source". This also keeps reset_demo safe from
the engine quirk in NOTES.md: reset deletes Evidence, and creating Evidence in
the same request would risk losing it.

Engine quirk: deleting and creating nodes of the same type in one request can
lose the new nodes. Every upsert updates an existing node in place and only
creates one when none exists; nothing here deletes a node.
"""
import from jac.graph { Vendor, Invoice, Instruction, PaysTo }
import from jac.evidence { normalize_name, now_iso }


def find_vendor(name: str) -> Vendor | None {
    for v in [root -->][?:Vendor] {
        if normalize_name(v.name) == normalize_name(name) {
            return v;
        }
    }
    return None;
}


def upsert_vendor(name: str, known_account: str, first_seen: str = "") -> Vendor {
    existing = find_vendor(name);
    v: Vendor = existing if existing is not None else (
        root ++> Vendor(name=name, known_account=known_account)
    );
    v.name = name;
    v.known_account = known_account;
    v.first_seen = first_seen or v.first_seen or now_iso()[:10];
    return v;
}


"""Upsert an invoice and its PaysTo edge. Returns None if the vendor is unknown."""
def upsert_invoice(
    invoice_id: str, vendor_name: str, amount_cents: int, period: str, paid: bool = False
) -> Invoice | None {
    vendor = find_vendor(vendor_name);
    if vendor is None {
        return None;
    }
    key = invoice_id.strip().upper();
    found = [i for i in [root -->][?:Invoice] if i.invoice_id.upper() == key];
    inv: Invoice = found[0] if found else (root ++> Invoice(
        invoice_id=key, vendor_name=vendor.name, amount_cents=amount_cents, period=period
    ));
    inv.vendor_name = vendor.name;
    inv.amount_cents = amount_cents;
    inv.period = period;
    inv.paid = paid;
    linked = [inv ->:PaysTo:->][?:Vendor];
    if len(linked) != 1 or linked[0] != vendor {
        for e in [edge inv ->:PaysTo:->] {
            del e;
        }
        inv +>:PaysTo():+> vendor;
    }
    return inv;
}


def _next_instruction_id -> str {
    existing = [i.instruction_id for i in [root -->][?:Instruction]];
    n = len(existing) + 1;
    while f"ins_{n:03d}" in existing {
        n += 1;
    }
    return f"ins_{n:03d}";
}


"""Upsert an instruction. With no instruction_id, a new ins_NNN id is issued."""
def upsert_instruction(
    text: str, instruction_id: str = "", created_at: str = ""
) -> Instruction {
    found: list[Instruction] = [];
    if instruction_id != "" {
        found = [i for i in [root -->][?:Instruction] if i.instruction_id == instruction_id];
    }
    ins: Instruction = found[0] if found else (root ++> Instruction(
        instruction_id=instruction_id or _next_instruction_id(), text=text,
        created_at=created_at or now_iso()
    ));
    ins.text = text;
    ins.created_at = created_at or ins.created_at;
    return ins;
}


def vendor_view(v: Vendor) -> dict[str, any] {
    return {"name": v.name, "known_account": v.known_account, "first_seen": v.first_seen};
}


def invoice_view(inv: Invoice) -> dict[str, any] {
    return {
        "invoice_id": inv.invoice_id, "vendor_name": inv.vendor_name,
        "amount": inv.amount_cents / 100, "period": inv.period, "paid": inv.paid
    };
}


def instruction_view(ins: Instruction) -> dict[str, any] {
    return {
        "instruction_id": ins.instruction_id, "text": ins.text, "created_at": ins.created_at
    };
}
