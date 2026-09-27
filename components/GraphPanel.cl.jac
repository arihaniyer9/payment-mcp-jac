"""Middle column: the plan graph. Items on the left roll up into the goal; money flows along bought edges."""
sv import from ..services.view { MandateView, AttemptView, CardView }
import from ..lib.fmt { usd, px }

def:pub Card(c: CardView, budget: float, selected: bool, onSelect: Callable[[str], None]) -> JsxElement {
    cls = "card " + c.kind + " " + c.status + (" flagged" if c.flagged else "") + (" sel" if selected else "");
    style = {"left": px(c.x), "top": px(c.y), "width": px(c.w), "height": px(c.h)};
    pill = <span className={"pill " + c.status}>{c.status}</span> if c.status else (<span className="pill flag">flagged</span> if c.flagged else None);
    if c.kind == "item" {
        return <button className={cls} style={style} aria-label={c.kind + " " + c.name} onClick={lambda e: MouseEvent { onSelect(c.id); }}>
            <span className="thumb">{<img src={c.image} alt="" /> if c.image else c.name[0:1].upper()}</span>
            <span style={{"minWidth": "0"}}><span className="name">{c.name}</span><span className="meta"><span className="price num">{usd(c.price)}</span>{pill}</span></span>
        </button>;
    }
    return <button className={cls} style={style} aria-label={c.kind + " " + c.name} onClick={lambda e: MouseEvent { onSelect(c.id); }}>
        <span style={{"minWidth": "0"}}><span className="name">{c.name}</span><span className="meta"><span className="price num">{usd(c.price)}</span>
            <span>{("of " + usd(budget) + " · " if c.kind == "goal" else "") + str(c.got) + "/" + str(c.total) + " bought"}</span>{c.flagged and <span className="pill flag">flagged</span>}</span></span>
    </button>;
}

def:pub GraphPanel(view: MandateView, shown: int, selected: str, onShow: Callable[[int], None], onSelect: Callable[[str], None]) -> JsxElement {
    n = len(view.attempts);
    idx = shown if shown >= 0 and shown < n else n - 1;
    a: AttemptView | None = view.attempts[idx] if n > 0 else None;
    marks = {"accepted": " ✓", "rejected": " ✗", "checking": " …"};
    return <section className="panel" id="graph-panel" aria-label="Purchase graph">
        <div className="panel-head"><h2>Purchase graph</h2>
            <div id="attempts">
                {for (i, x) in enumerate(view.attempts) {
                    <button key={str(i)} className={"attempt " + x.status + (" on" if i == idx else "")} title={"Show plan v" + str(x.v)} onClick={lambda e: MouseEvent { onShow(-1 if i == n - 1 else i); }}>{"v" + str(x.v) + marks[x.status]}</button>
                }}
            </div>
        </div>
        <div className="legend">
            <span><i style={{"background": "var(--item)"}}></i>Planned</span>
            <span><i style={{"background": "var(--wait)"}}></i>Checking</span>
            <span><i style={{"background": "var(--pass)"}}></i>Bought</span>
            <span><i style={{"background": "var(--fail)"}}></i>Blocked or flagged</span>
        </div>
        <div id="canvas-wrap">
            {if a is None or len(a.cards) == 0 {
                <div className="empty"><b>No plan yet</b>The graph appears when the agent submits its first plan. Items sit on the left and roll up into the goal.</div>
            } else {
                <div id="canvas" style={{"width": px(a.width), "height": px(a.height)}}>
                    <svg id="edges" viewBox={"0 0 " + str(a.width) + " " + str(a.height)} width={a.width} height={a.height}>
                        {for p in a.paths { <path key={p.key} className={p.cls} d={p.d} /> }}
                    </svg>
                    {for c in a.cards { <Card key={c.id} c={c} budget={view.budget} selected={c.id == selected} onSelect={onSelect} /> }}
                </div>
            }}
        </div>
    </section>;
}
