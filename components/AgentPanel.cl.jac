"""Left column: the conversation, with every tool call as a step you can click for the reasons."""
sv import from ..services.view { MandateView, ChatItem }
import from ..lib.fmt { NL, plural }

"""**bold** and `code` inside one line."""
def:pub Inline(text: str) -> JsxElement {
    parts = text.split("**");
    return <span>
        {for (i, part) in enumerate(parts) {
            if i % 2 == 1 {
                <b key={str(i)}>{part}</b>
            } else {
                <span key={str(i)}>{part}</span>
            }
        }}
    </span>;
}

"""Paragraphs and bullet lists, enough for the agent's replies."""
def:pub Markdown(text: str) -> JsxElement {
    blocks: list[list[str]] = [];
    cur: list[str] = [];
    for line in text.split(NL) {
        if line.strip() {
            cur = cur + [line];
        } elif len(cur) > 0 {
            blocks = blocks + [cur];
            cur = [];
        }
    }
    if len(cur) > 0 {
        blocks = blocks + [cur];
    }
    return <div>
        {for (bi, block) in enumerate(blocks) {
            bullets = [l for l in block if l.strip().startswith("- ") or l.strip().startswith("* ") or l.strip().startswith("• ")];
            if len(bullets) == len(block) {
                <ul key={str(bi)}>{for (li, l) in enumerate(block) { <li key={str(li)}><Inline text={l.strip()[2:]} /></li> }}</ul>
            } else {
                <p key={str(bi)}>{for (li, l) in enumerate(block) { <span key={str(li)}>{li > 0 and <br />}<Inline text={l} /></span> }}</p>
            }
        }}
    </div>;
}

def:pub ChatRow(item: ChatItem, onDecision: Callable[[int], None], onBrowser: Callable[[], None]) -> JsxElement {
    tag = <span className="who">{item.agent}</span> if item.agent != "lead" and item.agent != "you" else None;
    if item.k == "msg" {
        return <div className={"msg " + item.who}>{tag}{<Markdown text={item.text} /> if item.who == "agent" else item.text}</div>;
    }
    if item.k == "rogue" {
        return <div className="rogue-box"><b>Rogue instructions injected</b> at the end of the agent's prompt. The user can't see them; the checks still apply.
            <details><summary>Show them</summary><pre>{item.text}</pre></details></div>;
    }
    if item.k == "browse" {
        return <button className="step ok" title="Watch in the live browser" onClick={lambda e: MouseEvent { onBrowser(); }}><span className="dot"></span><span className="step-text">{tag}{"Browsed the web · " + plural(item.searches, "search") + ", " + plural(item.pages, "page action")}</span></button>;
    }
    body = <span className="step-text">{tag}{item.pre}<b>{item.bold}</b>{item.post}</span>;
    if item.decision >= 0 {
        return <button className={"step " + item.cls} title="Show why in the lens" onClick={lambda e: MouseEvent { onDecision(item.decision); }}><span className="dot"></span>{body}</button>;
    }
    return <div className={"step " + item.cls}><span className="dot"></span>{body}</div>;
}

def:pub AgentPanel(
    view: MandateView, busy: bool, reply: str, error: str,
    onReply: Callable[[str], None], onSend: Callable[[], None], onDecision: Callable[[int], None], onBrowser: Callable[[], None]
) -> JsxElement {
    return <section className="panel" id="agent" aria-label="Agent">
        <div className="panel-head"><h2>Agent</h2><span className="sub">Groq · browses the web</span></div>
        <div className="scroll"><div id="chat" aria-live="polite">
            {for (i, item) in enumerate(view.chat) {
                <div key={str(i)} className={"helper-row" if item.agent.startswith("helper") else ""}><ChatRow item={item} onDecision={onDecision} onBrowser={onBrowser} /></div>
            }}
            {error and <div className="step bad"><span className="dot"></span><span className="step-text"><b>Error:</b> {error}</span></div>}
        </div></div>
        <div id="working">{"Agent working… free-tier Groq can pause up to a minute." if busy else ""}</div>
        <form id="reply" onSubmit={lambda e: FormEvent { e.preventDefault(); onSend(); }}>
            <input value={reply} placeholder="Reply to the agent" aria-label="Reply to the agent" disabled={busy} onChange={lambda e: ChangeEvent { onReply(e.target.value); }} />
            <button className="btn" disabled={busy}>Send</button>
        </form>
    </section>;
}
