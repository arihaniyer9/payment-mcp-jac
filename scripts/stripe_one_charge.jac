"""Run exactly ONE real Stripe test-mode charge through the production code path.

It calls jac.gateway.charge (the same function execute_payment uses) with
MOCK_GATEWAY=false set only inside this process, then marks the invoice paid
exactly as execute_payment does, and reads it back.

Why a script instead of the HTTP server: JacHammer injects Settings values into
the sandbox only when the sandbox is created, so a key added later does not reach
the running preview server. Nothing here changes the server's MOCK_GATEWAY default.

Usage: STRIPE_SECRET_KEY=sk_test_... jac run scripts/stripe_one_charge.jac
"""
import os;
import from jac.gateway { charge, mock_enabled }

node DemoInvoice {
    has invoice_id: str,
        amount_cents: int,
        paid: bool = False;
}


with entry {
    os.environ["MOCK_GATEWAY"] = "false";
    key = os.getenv("STRIPE_SECRET_KEY", "");
    print("key prefix:", key[:8], "| mock_enabled:", mock_enabled());
    inv = DemoInvoice(invoice_id="INV-4471", amount_cents=420000);
    rid = "stripe_once_20260927";
    try {
        ref = charge(rid, inv.amount_cents, "USD", inv.invoice_id, "Acme Supplies");
        inv.paid = True;
        print("RESULT ok payment_ref:", ref, "| invoice paid:", inv.paid);
    } except Exception as e {
        print("RESULT error:", type(e).__name__, str(e)[:300], "| invoice paid:", inv.paid);
    }
}
