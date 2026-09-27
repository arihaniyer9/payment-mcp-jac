"""Right column. Why: every check behind the latest decision (or a clicked card). Trace: everything the agent did."""
sv import from ..services.view { MandateView, Check, BuyView, CardView, AttemptView }
import from ..lib.fmt { usd, pct }

def:pub CheckRow(f: Check) -> JsxElement {
    judged = f.kind == "jev" and f.p >= 0;
    label = {"jev": "Jev", "source": "Source", "rule": "Rule"}[f.kind] or "Rule";
    return <details className={"check " + ("ok" if f.ok else "bad")}>
        <summary>
            <span className="mark">{"✓" if f.ok else "✗"}</span>
            <span className="title"><span className={"kind " + f.kind}>{label}</span> {f.check}
                {f.node_name and <small>{f.node_name}</small>}
                {not f.ok and f.kind != "jev" and <small>{f.detail}</small>}
            </span>
            {judged and <span className="num" style={{"fontWeight": "800"}}>{pct(f.p)}</span>}
        </summary>
        {judged and <div className="prob"><div className="fill" style={{"width": str(f.p * 100) + "%"}}></div><div className="tick" style={{"left": "calc(" + str(f.threshold * 100) + "% - 1px)"}}></div></div>}
        <div className="more">
            {if f.kind == "jev" {
                <span>Asked Jev: <q>{f.question}</q><br />{f.detail + " · " + (f.model or "jev") + " · " + str(f.ms) + " ms"}</span>
            } else {
                <span>{f.detail}</span>
            }}
        </div>
    </details>;
}

def:pub Group(title: str, checks: list[Check]) -> JsxElement {
    if len(checks) == 0 {
        return <span></span>;
    }
    passed = len([c for c in checks if c.ok]);
    ordered = [c for c in checks if not c.ok] + [c for c in checks if c.ok];
    return <div>
        <div className="group-title">{title + " · " + str(passed) + "/" + str(len(checks)) + " passed"}</div>
        {for (i, c) in enumerate(ordered) { <CheckRow key={str(i)} f={c} /> }}
    </div>;
}

def:pub Groups(checks: list[Check], prefix: str) -> JsxElement {
    return <div>
        <Group title={prefix + "Rules"} checks={[c for c in checks if c.kind == "rule"]} />
        <Group title={prefix + "Provenance"} checks={[c for c in checks if c.kind == "source"]} />
        <Group title={prefix + "Jev judgments"} checks={[c for c in checks if c.kind == "jev"]} />
    </div>;
}

def:pub Key() -> JsxElement {
    return <div className="key">
        <span className="kind rule">Rule</span> exact checks: sums, budget, blacklist. They can't be talked around.<br />
        <span className="kind source">Source</span> the page must be one the agent's browser opened, and the price must be listed on it.<br />
        <span className="kind jev">Jev</span> a typed AI judge. It returns a calibrated probability that the answer is yes; the check passes when it clears the black mark.
    </div>;
}

def:pub NodeLens(view: MandateView, nid: str, showKey: bool, onBack: Callable[[], None]) -> JsxElement {
    latest: AttemptView | None = view.attempts[len(view.attempts) - 1] if len(view.attempts) > 0 else None;
    cards = [c for c in (latest.cards if latest else []) if c.id == nid];
    buys = [b for b in view.buys if b.node_id == nid];
    b: BuyView | None = buys[0] if len(buys) > 0 else None;
    card: CardView | None = cards[0] if len(cards) > 0 else None;
    name = card.name if card else (b.name if b else nid);
    plan_checks = [c for c in (latest.checks if latest else []) if card and c.node_name == card.name];
    titles = {"bought": "Payment authorized", "blocked": "Purchase blocked", "checking": "Checking purchase…"};
    classes = {"bought": "ok", "blocked": "bad", "checking": "wait"};
    image = (b.image if b else "") or (card.image if card else "");
    return <div>
        {<Key /> if showKey else <button className="back" onClick={lambda e: MouseEvent { onBack(); }}>← Latest decision</button>}
        <div className="node-head">
            <span className="thumb">{<img src={image} alt={name} /> if image else name[0:1].upper()}</span>
            <div><h3>{name}</h3><div className="meta">{(card.kind if card else "item") + " · estimate " + usd(card.price if card else 0) + (" · part of " + card.parent_name if card and card.parent_name else "")}</div></div>
        </div>
        {if b {
            <div>
                <div className={"verdict " + classes[b.status]}>
                    <div className="src">{"Purchase check · by " + b.agent}</div>
                    <h3>{titles[b.status]}</h3>
                    <p>{("Stripe held " + usd(b.price) + " on the card (" + b.payment_intent + "). Nothing is captured until you confirm.") if b.status == "bought" else (b.error or ("At least one check failed. Details below." if b.status == "blocked" else ""))}</p>
                </div>
                <dl className="facts">
                    <dt>Price</dt><dd className="num">{usd(b.price) + " (estimate " + usd(card.price if card else 0) + ")"}</dd>
                    <dt>Page</dt><dd><a href={b.url} target="_blank" rel="noopener noreferrer">{b.url}</a></dd>
                </dl>
                <Groups checks={b.checks} prefix="Purchase " />
            </div>
        }}
        {len(plan_checks) > 0 and <div><div className="group-title">{"From plan review v" + str(latest.v if latest else 0)}</div>{for (i, c) in enumerate(plan_checks) { <CheckRow key={str(i)} f={c} /> }}</div>}
        {not b and len(plan_checks) == 0 and <p className="hint">No checks for this step yet.</p>}
    </div>;
}

def:pub DecisionLens(view: MandateView, focus: int, onBack: Callable[[], None]) -> JsxElement {
    n = len(view.decisions);
    if n == 0 {
        return <div><Key /><div className="empty" style={{"margin": "30px auto"}}><b>Nothing decided yet</b>Every plan review and purchase check shows up here with the reasons behind it. Click a card in the graph to see one item.</div></div>;
    }
    d = view.decisions[focus if focus >= 0 and focus < n else n - 1];
    if d.kind == "purchase" {
        return <NodeLens view={view} nid={d.node_id} showKey={True} onBack={onBack} />;
    }
    a = view.attempts[d.attempt];
    return <div>
        <Key />
        <div className={"verdict " + ("ok" if a.status == "accepted" else "bad")}>
            <div className="src">{"Plan review · attempt " + str(a.v) + " of " + str(len(view.attempts))}</div>
            <h3>{"Plan accepted" if a.status == "accepted" else "Plan rejected"}</h3>
            <p>{a.summary}</p>
        </div>
        <Groups checks={a.checks} prefix="" />
    </div>;
}

def:pub Trace(view: MandateView) -> JsxElement {
    if len(view.trace) == 0 {
        return <div className="empty" style={{"margin": "30px auto"}}><b>No activity yet</b>Every step the agent takes shows up here.</div>;
    }
    return <div>
        {for (i, r) in enumerate(view.trace) {
            <div key={str(i)} className="trace-row">
                <span className="when">{r.when}</span>
                <span className={"what " + r.cls}>{r.label}</span>
                <div className="body">
                    {r.agent != "lead" and r.agent != "you" and <span className="who">{r.agent}</span>}
                    {if r.link {
                        <a href={r.link} target="_blank" rel="noopener noreferrer">{r.link}</a>
                    } elif r.detail {
                        <details><summary>{r.summary}</summary><pre>{r.detail}</pre></details>
                    } else {
                        <span>{r.summary}</span>
                    }}
                </div>
            </div>
        }}
    </div>;
}

def:pub Lens(view: MandateView, tab: str, selected: str, focus: int, onTab: Callable[[str], None], onBack: Callable[[], None]) -> JsxElement {
    return <section className="panel" id="lens" aria-label="Lens">
        <div className="panel-head">
            <h2>Lens</h2>
            <div className="tabs" role="tablist">
                <button role="tab" aria-selected={tab == "why"} onClick={lambda e: MouseEvent { onTab("why"); }}>Why</button>
                <button role="tab" aria-selected={tab == "trace"} onClick={lambda e: MouseEvent { onTab("trace"); }}>Trace</button>
            </div>
        </div>
        <div className="scroll"><div id="lens-body">
            {if tab == "trace" {
                <Trace view={view} />
            } elif selected {
                <NodeLens view={view} nid={selected} showKey={False} onBack={onBack} />
            } else {
                <DecisionLens view={view} focus={focus} onBack={onBack} />
            }}
        </div></div>
    </section>;
}
