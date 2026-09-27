"""The payment tools an agent can call. Each works on one Mandate subgraph.

Nothing here lets an agent change the goal, the budget or the record of what it browsed:
those are written only by the human's endpoints (api.jac) and by the harness (harness.jac).
"""
import os;
import re;
import time;
import ipaddress;
import httpx;
import from stripe { StripeClient, PaymentIntent }
import from pathlib { Path }
import from urllib.parse { urljoin, urlparse }
import from dotenv { load_dotenv }
import from services.models { Mandate, PlanAttempt, PlanNode, Purchase }
import from services.vetting { vet_plan, vet_purchase, money }

glob ROOT_DIR: Path = Path(__file__ or ".").resolve().parent.parent;
with entry {
    load_dotenv(str(ROOT_DIR / ".env"));
}

glob BLACKLIST: list[str] = [
    line.strip().lower()
    for line in (ROOT_DIR / "blacklist.txt").read_text().splitlines()
    if line.strip() and not line.startswith("#")
];

glob BROWSER_HEADERS: dict[str, str] = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
    "Accept": "text/html",
    "Accept-Language": "en-US,en;q=0.9"
};
glob OG_IMAGE = re.compile(
    r"""<meta[^>]+(?:property|name)=["'](?:og:image|twitter:image)["'][^>]+content=["']([^"']+)"""
    r"""|<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["'](?:og:image|twitter:image)["']"""
);

def plan_instructions(m: Mandate) -> str {
    text = (ROOT_DIR / "prompts" / "CreatePlanGraph.md").read_text();
    return text.replace("{{Goal}}", m.goal).replace("{{Budget}}", f"{m.budget:.2f}");
}

"""Vet a plan graph. The attempt and its nodes stay in the graph whether or not it passes."""
def submit_plan(m: Mandate, nodes: list[dict], edges: list[dict]) -> dict {
    attempt = PlanAttempt(v=len([m -->[?:PlanAttempt]]) + 1);
    m ++> attempt;
    return vet_plan({"nodes": nodes, "edges": edges}, m.goal, m.budget, m.request, attempt);
}

"""Items of the newest accepted plan: node id -> {name, price}. Rejected resubmissions don't replace it."""
def accepted_items(m: Mandate) -> dict[str, dict] {
    accepted = [a for a in [m -->[?:PlanAttempt]] if a.accepted];
    if not accepted {
        return {};
    }
    latest = max(accepted, key=lambda a: PlanAttempt : a.v);
    return {n.id: {"name": n.name, "price": n.price} for n in [latest -->[?:PlanNode]] if n.kind == "item"};
}

"""Vet one purchase, then authorize (not capture) it in Stripe test mode."""
def purchase(m: Mandate, agent: str, node_id: str, item_name: str, payment_url: str, price: float) -> dict {
    item = accepted_items(m).get(node_id);
    if item is None {
        return {"approved": False, "error": f"'{node_id}' is not an item in the accepted plan"};
    }
    done = [p for p in [m -->[?:Purchase]] if p.approved and p.node_id == node_id];
    if done {
        return {"approved": False, "error": f"'{node_id}' already purchased ({done[0].payment_intent}) by {done[0].agent}"};
    }
    # ponytail: public https hosts only (see public_host); DNS rebinding not handled
    html: str = fetch_page(payment_url) or "";
    opened = html != "";
    pages = [html] if html else [];
    verdict = vet_purchase(node_id, item, item_name, payment_url, price, m.spent, m.budget, BLACKLIST, opened, pages);
    record = Purchase(node_id=node_id, item_name=item_name, url=payment_url, price=price, agent=agent, findings=verdict.findings, t=time.time());
    m ++> record;
    result = {"approved": verdict.approved, "findings": verdict.findings};
    if not verdict.approved {
        return result;
    }
    record.image = og_image(html, payment_url) if html else "";
    try {
        intent = authorize(f"{jid(m)}:{node_id}", node_id, item_name, payment_url, price);
    } except Exception as e {
        return {**result, "approved": False, "error": f"payment authorization failed: {e}"};
    }
    record.approved = True;
    record.payment_intent = intent.id;
    m.spent = money(m.spent + price);
    return {**result, "payment_intent": intent.id, "status": intent.status, "spent": m.spent, "remaining": money(m.budget - m.spent), "image": record.image or None};
}

"""Public https hosts only: no raw IPs, localhost or internal names."""
def public_host(url: str) -> bool {
    u = urlparse(url);
    host = (u.hostname or "").lower();
    if u.scheme != "https" or not host or host == "localhost" or host.endswith(".local") or host.endswith(".internal") {
        return False;
    }
    try {
        _ = ipaddress.ip_address(host);
        return False;
    } except ValueError {
        return True;
    }
}

"""The product page as the server sees it. Best effort: Amazon and eBay block this."""
def fetch_page(url: str) -> str | None {
    if not public_host(url) {
        return None;
    }
    try {
        r = httpx.get(url, headers=BROWSER_HEADERS, follow_redirects=True, timeout=8);
        return r.text if r.status_code < 400 else None;
    } except httpx.HTTPError {
        return None;
    }
}

"""The page's preview image, if it has one."""
def og_image(html: str, url: str) -> str {
    m = OG_IMAGE.search(html);
    return urljoin(url, m.group(1) or m.group(2)) if m else "";
}

"""Authorize (not capture) a card payment in Stripe test mode. The idempotency key makes a retried step charge once."""
def authorize(idem: str, node_id: str, item_name: str, url: str, price: float) -> PaymentIntent {
    key = os.environ.get("STRIPE_SECRET_KEY", "");
    if not key.startswith("sk_test_") {
        raise RuntimeError("STRIPE_SECRET_KEY must be a Stripe test-mode key (sk_test_...)");
    }
    return StripeClient(key).v1.payment_intents.create(
        params={
            "amount": round(price * 100),
            "currency": "usd",
            "capture_method": "manual",
            "confirm": True,
            "payment_method": "pm_card_visa",
            "payment_method_types": ["card"],
            "description": item_name,
            "metadata": {"node_id": node_id, "payment_url": url}
        },
        options={"idempotency_key": idem}
    );
}
