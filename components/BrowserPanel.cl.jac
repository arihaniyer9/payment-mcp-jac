"""Middle column, browser mode: the agent's real Chrome tab, one screenshot per action, with the cursor."""
sv import from ..services.api { browser_shot }
sv import from ..services.view { MandateView, ShotView }

glob ICONS: dict[str, str] = {"search": "⌕", "open": "↗", "click": "●", "type": "⌨", "scroll": "↕"};

def:pub ModeTabs(mode: str, onMode: Callable[[str], None]) -> JsxElement {
    return <div className="tabs" role="tablist">
        <button role="tab" aria-selected={mode == "browser"} onClick={lambda e: MouseEvent { onMode("browser"); }}>Live browser</button>
        <button role="tab" aria-selected={mode == "graph"} onClick={lambda e: MouseEvent { onMode("graph"); }}>Plan graph</button>
    </div>;
}

def:pub BrowserPanel(view: MandateView, onMode: Callable[[str], None]) -> JsxElement {
    has picked: int = -1,
        img: str = "",
        img_n: int = 0;

    total = len(view.shots);
    n = picked if picked > 0 and picked <= total else total;
    s: ShotView | None = view.shots[n - 1] if n > 0 else None;
    live = picked <= 0;

    async can with [n] entry {
        if n > 0 and n != img_n {
            got = await browser_shot(view.id, n);
            img = got;
            img_n = n;
        }
    }

    return <section className="panel" id="graph-panel" aria-label="Live browser">
        <div className="panel-head"><h2>Browser</h2><ModeTabs mode="browser" onMode={onMode} /></div>
        {if s is None {
            <div className="empty"><b>The browser hasn't opened yet</b>When the agent searches or opens a page, you'll see its Chrome tab here, with the cursor on every click.</div>
        } else {
            <div className="browser">
                <div className="chrome-bar">
                    <span className="dots"><i></i><i></i><i></i></span>
                    <span className="url" title={s.url}>{s.url}</span>
                    <span className={"live-pill" + (" on" if live else "")}>{"Live" if live else "Step " + str(n) + " of " + str(total)}</span>
                </div>
                <div className="screen">
                    {img and <img src={img} alt={"Screenshot: " + s.title} />}
                    {s.x >= 0 and <div className={"cursor " + s.action} style={{"left": str(s.x / 12.8) + "%", "top": str(s.y / 7.2) + "%"}}>
                        <span className="ripple"></span>
                        <svg width="22" height="22" viewBox="0 0 24 24"><path d="M4 2l16 9-7 2-3 7z" fill="#1C2230" stroke="#fff" strokeWidth="1.5" /></svg>
                    </div>}
                    <div className="caption"><span className="who">{s.agent}</span>{ICONS[s.action] or "·"} {s.action + " · " + s.detail}</div>
                </div>
                <div className="film">
                    {if not live {
                        <button className="ghost" onClick={lambda e: MouseEvent { picked = -1; }}>Follow live</button>
                    }}
                    {for (i, x) in enumerate(view.shots) {
                        <button key={str(x.n)} className={"frame" + (" on" if x.n == n else "")} title={x.url} onClick={lambda e: MouseEvent { picked = x.n; }}>
                            <b>{ICONS[x.action] or "·"}</b> {x.detail}<small>{x.when + " · " + x.agent}</small>
                        </button>
                    }}
                </div>
            </div>
        }}
    </section>;
}
