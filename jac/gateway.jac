"""Payment gateway: Stripe test mode, or a mock with no network calls.

- MOCK_GATEWAY is "true" unless explicitly set to "false" (default: mock).
- A STRIPE_SECRET_KEY that does not start with "sk_test_" is refused: this
  system never moves real money. The same check runs at import (startup), so a
  live key makes the server fail loudly instead of silently mocking.
- The Stripe idempotency key is the request_id, so a retried request can never
  create a second charge.
"""
import os;
import importlib;


def mock_enabled -> bool {
    return os.getenv("MOCK_GATEWAY", "true").strip().lower() != "false";
}


def _secret_key -> str {
    key = os.getenv("STRIPE_SECRET_KEY", "").strip();
    if key != "" and not key.startswith("sk_test_") {
        raise RuntimeError("STRIPE_SECRET_KEY is not a test key (sk_test_...). Refusing to run.");
    }
    return key;
}


"""Charge the payment. Returns the payment reference; raises on failure so the
caller records a gateway error and leaves the invoice unpaid."""
def charge(
    request_id: str, amount_cents: int, currency: str, invoice_id: str, payee_name: str
) -> str {
    if mock_enabled() {
        return f"mock_{request_id}";
    }
    key = _secret_key();
    if key == "" {
        raise RuntimeError("MOCK_GATEWAY=false but STRIPE_SECRET_KEY is not set.");
    }
    # Imported lazily: the mock path (the default) must work without the package.
    stripe = importlib.import_module("stripe");
    stripe.api_key = key;
    intent = stripe.PaymentIntent.create(
        amount=amount_cents,
        currency=currency.lower(),
        payment_method="pm_card_visa",
        payment_method_types=["card"],
        confirm=True,
        metadata={"request_id": request_id, "invoice_id": invoice_id, "payee_name": payee_name},
        idempotency_key=request_id
    );
    if intent.status != "succeeded" {
        raise RuntimeError(f"PaymentIntent {intent.id} status {intent.status}");
    }
    return str(intent.id);
}


# Startup guard: refuse a live key at import time.
glob _STARTUP_KEY_CHECK: str = _secret_key();
