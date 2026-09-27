"""A real Chrome the agent drives, one isolated profile per mandate, through Jac's built-in CDP
browser engine (the one behind `jac browse`).

Every action leaves a screenshot and where the cursor went, so the human can watch. Every page the
agent lands on is recorded as Evidence from the rendered page itself, which is what the provenance
checks compare purchases against.
"""
import time;
import json;
import from urllib.parse { quote_plus }
import jaclang.cli.browser_engine as be;
import from jaclang.cli.browser_engine { CDP }
import from services.models { Mandate, Evidence, Shot }

glob WIDTH = 1280;
glob HEIGHT = 720;
glob UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";

# ponytail: one live CDP connection per mandate in this process; the user-agent override lives on it.
glob _pages: dict[str, CDP] = {};

"""Tag visible links, buttons and inputs with data-ref numbers and list them for the model."""
glob ELEMENTS_JS = """(() => {
  document.querySelectorAll('[data-ref]').forEach(e => e.removeAttribute('data-ref'));
  const out = []; const seen = new Set(); let i = 0;
  document.querySelectorAll('a[href], button, input, select, textarea, [role=button]').forEach(el => {
    const r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2 || r.bottom < 0 || r.top > innerHeight * 2) return;
    const tag = el.tagName.toLowerCase();
    const text = (el.innerText || el.value || el.placeholder || el.getAttribute('aria-label') || el.title || '').trim().replace(/\\s+/g, ' ').slice(0, 70);
    if (!text && tag !== 'input' && tag !== 'textarea') return;
    const key = tag + text + (el.href || '');
    if (seen.has(key)) return; seen.add(key);
    i += 1; el.setAttribute('data-ref', String(i));
    let href = el.href || '';
    const u = href.match(/[?&]uddg=([^&]+)/); if (u) href = decodeURIComponent(u[1]);
    out.push('[' + i + '] ' + tag + (href ? ' ' + href.slice(0, 110) : '') + (text ? ' "' + text + '"' : ''));
  });
  return out.slice(0, 45).join('\\n');
})()""";

glob PAGE_TEXT_JS = """(() => {
  const ld = Array.from(document.querySelectorAll('script[type="application/ld+json"]')).map(s => s.textContent).join('\\n');
  const og = document.querySelector('meta[property="og:image"], meta[name="twitter:image"]');
  return JSON.stringify({url: location.href, title: document.title, text: (document.body ? document.body.innerText : '').slice(0, 20000), ld: ld.slice(0, 8000), image: og ? og.content : ''});
})()""";

def session_of(m: Mandate) -> str {
    return "mandate-" + str(jid(m)).replace("-", "")[:16];
}

"""The mandate's browser tab, launching Chrome on first use."""
def page_of(m: Mandate) -> CDP {
    s = session_of(m);
    st = be.load_state(s);
    if s in _pages and st is not None and be._pid_alive(int(st["pid"])) {
        return _pages[s];
    }
    if st is None or not be._pid_alive(int(st["pid"])) {
        be.cmd_open(s, "about:blank", f"{WIDTH}x{HEIGHT}");
    }
    cdp = be.connect(s);
    cdp.call("Network.enable");
    cdp.call("Network.setUserAgentOverride", {"userAgent": UA, "acceptLanguage": "en-US,en;q=0.9", "platform": "MacIntel"});
    cdp.call("Page.enable");
    cdp.call("Page.addScriptToEvaluateOnNewDocument", {"source": "Object.defineProperty(navigator, 'webdriver', {get: () => undefined});"});
    _pages[s] = cdp;
    return cdp;
}

def settle(cdp: CDP) {
    deadline = time.time() + 8;
    time.sleep(0.6);
    while time.time() < deadline and str(be._eval(cdp, "document.readyState")) != "complete" {
        time.sleep(0.25);
    }
    time.sleep(0.5);
}

"""Screenshot + page record + what the model sees next. `x`/`y` is where the cursor acted (-1: nowhere)."""
def observe(m: Mandate, agent: str, action: str, detail: str, x: float = -1.0, y: float = -1.0) -> dict {
    cdp = page_of(m);
    info = json.loads(str(be._eval(cdp, PAGE_TEXT_JS)));
    elements = str(be._eval(cdp, ELEMENTS_JS) or "");
    shot = cdp.call("Page.captureScreenshot", {"format": "jpeg", "quality": 55});
    n = len([m -->[?:Shot]]) + 1;
    m ++> Shot(n=n, agent=agent, action=action, detail=detail, url=str(info["url"]), title=str(info["title"]), x=x, y=y, data=str(shot.get("data", "")), t=time.time());
    url = str(info["url"]);
    if url.startswith("http") {
        m ++> Evidence(url=url, kind="page", text=str(info["text"]) + "\n" + str(info["ld"]), agent=agent, image=str(info["image"] or ""));
    }
    text = str(info["text"]);
    prices = [l.strip() for l in text.splitlines() if "$" in l and len(l.strip()) < 120][:15];
    m.log("browse", agent, {"action": action, "detail": detail, "url": url, "shot": n});
    return {
        "url": url, "title": info["title"],
        "text": text[:1500], "price_lines": prices,
        "elements": elements,
        "hint": "Use click/type_text with an element number. Buy only from a product page you opened, at a price shown on it."
    };
}

"""Where element `ref` sits on screen, once it's visible and clickable."""
def spot(cdp: CDP, m: Mandate, ref: int) -> list[float] {
    pt = be._locate(cdp, session_of(m), f"[data-ref=\"{ref}\"]", 5.0);
    return [float(str(pt[0])), float(str(pt[1]))];
}

def web_search(m: Mandate, agent: str, query: str) -> dict {
    cdp = page_of(m);
    cdp.call("Page.navigate", {"url": "https://html.duckduckgo.com/html/?q=" + quote_plus(query)});
    settle(cdp);
    return observe(m, agent, "search", query);
}

def open_page(m: Mandate, agent: str, url: str) -> dict {
    if not url.startswith("http") {
        return {"error": "open_page needs a full http(s) URL"};
    }
    cdp = page_of(m);
    cdp.call("Page.navigate", {"url": url});
    settle(cdp);
    return observe(m, agent, "open", url);
}

def click(m: Mandate, agent: str, ref: int) -> dict {
    cdp = page_of(m);
    (x, y) = spot(cdp, m, ref);
    label = str(be._eval(cdp, f"(document.querySelector('[data-ref=\"{ref}\"]')?.innerText || '').trim().slice(0, 60)") or f"#{ref}");
    be._real_click(cdp, x, y);
    settle(cdp);
    return observe(m, agent, "click", label, x, y);
}

def type_text(m: Mandate, agent: str, ref: int, text: str, submit: bool) -> dict {
    cdp = page_of(m);
    (x, y) = spot(cdp, m, ref);
    be._real_click(cdp, x, y);
    be._press(cdp, "a", modifiers=4);
    be._press(cdp, "Delete");
    be._insert_text(cdp, text);
    if submit {
        be._press(cdp, "Enter");
    }
    settle(cdp);
    return observe(m, agent, "type", text, x, y);
}

def scroll(m: Mandate, agent: str, direction: str) -> dict {
    cdp = page_of(m);
    dy = -600 if direction == "up" else 600;
    _ = be._eval(cdp, f"window.scrollBy(0, {dy})");
    time.sleep(0.5);
    return observe(m, agent, "scroll", direction, float(WIDTH / 2), float(HEIGHT / 2));
}

def close_browser(m: Mandate) {
    s = session_of(m);
    if s in _pages {
        try {
            _pages[s].close();
        } except Exception {}
        del _pages[s];
    }
}
