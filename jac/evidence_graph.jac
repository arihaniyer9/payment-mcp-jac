"""Evidence subgraph for the dashboard (build prompt section 10).

A walker starts at the PaymentRequest and traverses:
  PaymentRequest -MatchedTo(field)-> Evidence -DerivedFrom-> Email|Instruction|Vendor|Invoice
  PaymentRequest -AuthorizedBy-> Instruction
  (invoice by id) -PaysTo-> Vendor
Nodes: {id, type, label, trusted, failed}. Edges: {from, to, type, field}.
f"failed" = the node is implicated in a failed check (its evidence id is cited
by a failed CheckResult, or the request itself was not approved).
"""
import from jac.graph {
    PaymentRequest, Evidence, Email, Instruction, Vendor, Invoice, CheckResult,
    MatchedTo, DerivedFrom, AuthorizedBy, PaysTo, HasCheck, Verdict, find_invoice
}


walker evidence_subgraph {
    has failed_evidence: list[str] = [],
        nodes: dict[str, dict[str, any]] = {},
        edges: list[dict[str, any]] = [];

    def add_node(nid: str, kind: str, label: str, trusted: bool | None, failed: bool) {
        if nid not in self.nodes {
            self.nodes[nid] = {
                "id": nid, "type": kind, "label": label, "trusted": trusted, "failed": failed
            };
        }
    }

    def add_edge(src: str, dst: str, kind: str, field: str = "") {
        self.edges.append({"from": src, "to": dst, "type": kind, "field": field});
    }

    def source_node(src: Email | Instruction | Vendor | Invoice) -> str {
        if isinstance(src, Email) {
            self.add_node(src.email_id, "Email", f"{src.sender}: {src.subject}", False, False);
            return src.email_id;
        }
        if isinstance(src, Instruction) {
            self.add_node(src.instruction_id, "Instruction", src.text, True, False);
            return src.instruction_id;
        }
        if isinstance(src, Vendor) {
            nid = f"vendor:{src.name}";
            self.add_node(nid, "Vendor", f"{src.name} (account on file {src.known_account})", True, False);
            return nid;
        }
        nid = f"invoice:{src.invoice_id}";
        self.add_node(nid, "Invoice",
            f"{src.invoice_id} {src.period} ${src.amount_cents / 100:,.2f}"
                + (" (paid)" if src.paid else ""), True, False);
        return nid;
    }

    can on_request with PaymentRequest entry {
        pr = here;
        for c in [pr ->:HasCheck:->][?:CheckResult] {
            if not c.passed {
                self.failed_evidence.extend(c.evidence_node_ids);
            }
        }
        rid = f"request:{pr.request_id}";
        self.add_node(rid, "PaymentRequest",
            f"{pr.payee_name} ${pr.amount_cents / 100:,.2f} to {pr.account_number} ({pr.verdict})",
            None, pr.verdict != Verdict.APPROVE.value);

        # Walk each matched evidence node, then read the MatchedTo edge(s) that
        # connect pr to it to recover the field name(s).
        for ev in [pr ->:MatchedTo:->][?:Evidence] {
            self.add_node(ev.evidence_id, "Evidence", f"{ev.kind}: {ev.raw_value}", ev.trusted,
                ev.evidence_id in self.failed_evidence);
            for e in [edge pr ->:MatchedTo:-> ev] {
                self.add_edge(rid, ev.evidence_id, "MatchedTo", e.field);
            }
        }
        for ins in [pr ->:AuthorizedBy:->][?:Instruction] {
            self.add_edge(rid, self.source_node(ins), "AuthorizedBy");
        }
        inv = find_invoice(pr.invoice_id);
        if inv is not None {
            inv_id = self.source_node(inv);
            self.add_edge(rid, inv_id, "ForInvoice");
            for v in [inv ->:PaysTo:->][?:Vendor] {
                self.add_edge(inv_id, self.source_node(v), "PaysTo");
            }
        }
        visit [pr ->:MatchedTo:->][?:Evidence];
    }

    can on_evidence with Evidence entry {
        for src in [here ->:DerivedFrom:->] {
            if isinstance(src, (Email, Instruction, Vendor, Invoice)) {
                self.add_edge(here.evidence_id, self.source_node(src), "DerivedFrom");
            }
        }
    }
}


def build_evidence_graph(pr: PaymentRequest) -> dict[str, any] {
    w = pr spawn evidence_subgraph();
    return {"request_id": pr.request_id, "nodes": list(w.nodes.values()), "edges": w.edges};
}
