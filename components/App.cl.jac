"""The whole app: login, then intake, then the three-panel workspace. Owns all page state."""
import from "@jac/runtime" { jacLogin, jacSignup, jacLogout, jacIsLoggedIn }
sv import from ..services.api { read_mandate, start_mandate, agent_step, mandate_view, send_reply, list_mandates }
sv import from ..services.view { MandateView }
sv import from ..services.models { MandateSummary }
sv import from ..services.vetting { MandateDraft }
import from .Intake { Intake }
import from .AgentPanel { AgentPanel }
import from .GraphPanel { GraphPanel }
import from .BrowserPanel { BrowserPanel }
import from .Lens { Lens }
import from ..lib.fmt { usd }

def:pub App() -> JsxElement {
    has logged: bool = jacIsLoggedIn(),
        user: str = "",
        password: str = "",
        signup: bool = False,
        prompt: str = "",
        goal: str = "",
        budget: str = "",
        rogue: bool = False,
        drafted: bool = False,
        reading: bool = False,
        error: str = "",
        history: list[MandateSummary] = [],
        view: MandateView | None = None,
        busy: bool = False,
        reply: str = "",
        tab: str = "why",
        selected: str = "",
        focus: int = -1,
        shown: int = -1,
        middle: str = "browser";

    async can with [logged] entry {
        if logged {
            try {
                history = (await list_mandates()) or [];
            } except Exception {
                history = [];
            }
        }
    }

    async def authenticate -> None {
        error = "";
        ok: bool = False;
        made: dict | None = None;
        try {
            if signup {
                made = await jacSignup(user, password);
                if not made["success"] {
                    error = "Couldn't sign up. That username may be taken.";
                    return;
                }
            }
            ok = await jacLogin(user, password);
        } except Exception as e {
            error = str(e);
        }
        if ok {
            logged = True;
        } elif not error {
            error = "Wrong username or password.";
        }
    }

    def logout(e: MouseEvent) {
        jacLogout();
        logged = False;
        view = None;
    }

    async def readGoal -> None {
        error = "";
        if not prompt.strip() {
            error = "Write what you want done, with a budget.";
            return;
        }
        reading = True;
        d: MandateDraft | None = None;
        try {
            d = await read_mandate(prompt);
            goal = d.goal;
            budget = str(d.budget_usd) if d.budget_usd > 0 else "";
            drafted = True;
            if d.budget_usd <= 0 {
                error = "No budget found in your request. Enter one below.";
            }
        } except Exception as e {
            error = "Couldn't read the goal and budget: " + str(e);
        }
        reading = False;
    }

    async def runAgent(mid: str) -> None {
        busy = True;
        v: MandateView | None = None;
        seen = len(view.decisions) if view else 0;
        going = True;
        try {
            while going {
                v = await agent_step(mid);
                view = v;
                if len(v.decisions) != seen {
                    seen = len(v.decisions);
                    focus = -1;
                    selected = "";
                    shown = -1;
                }
                going = v.busy;
            }
        } except Exception as e {
            error = str(e);
        }
        busy = False;
    }

    async def startAgent -> None {
        error = "";
        amount = parseFloat(budget.replace("$", "").replace(",", ""));
        if not goal.strip() or not (amount > 0) {
            error = "Enter a goal and a budget above $0.";
            return;
        }
        v: MandateView | None = None;
        try {
            v = await start_mandate(prompt, goal, amount, rogue);
            view = v;
            runAgent(v.id);
        } except Exception as e {
            error = str(e);
        }
    }

    async def openMandate(mid: str) -> None {
        v: MandateView | None = None;
        try {
            v = await mandate_view(mid);
            view = v;
            if v.busy {
                runAgent(mid);
            }
        } except Exception as e {
            error = str(e);
        }
    }

    async def sendReply -> None {
        text = reply.strip();
        if not text or busy or not view {
            return;
        }
        reply = "";
        v: MandateView | None = None;
        try {
            v = await send_reply(view.id, text);
            view = v;
            runAgent(v.id);
        } except Exception as e {
            error = str(e);
        }
    }

    def newMandate(e: MouseEvent) {
        view = None;
        drafted = False;
        prompt = "";
        goal = "";
        budget = "";
        rogue = False;
        error = "";
        tab = "why";
        selected = "";
        focus = -1;
        shown = -1;
    }

    if not logged {
        return <main className="auth">
            <h1>Spending mandate</h1>
            <p>An agent spends money for you. Every plan and every purchase is checked first.</p>
            <form onSubmit={lambda e: FormEvent { e.preventDefault(); authenticate(); }}>
                <label>Username <input value={user} onChange={lambda e: ChangeEvent { user = e.target.value; }} autoComplete="username" /></label>
                <label>Password <input type="password" value={password} onChange={lambda e: ChangeEvent { password = e.target.value; }} autoComplete="current-password" /></label>
                <div className="row">
                    <button className="btn" type="submit">{"Sign up" if signup else "Log in"}</button>
                    <button className="linkish" type="button" onClick={lambda e: MouseEvent { signup = not signup; }}>{"I have an account" if signup else "Create an account"}</button>
                </div>
                {error and <p className="err" role="alert">{error}</p>}
            </form>
        </main>;
    }

    latest = view.attempts[len(view.attempts) - 1] if view and len(view.attempts) > 0 else None;
    planned = Math.max(0, (latest.goal_price if latest else 0) - (view.spent if view else 0));
    b = view.budget if view else 1;
    spent_w = str(Math.min(100, (view.spent if view else 0) / b * 100)) + "%";
    planned_w = str(Math.min(100, Math.min(planned, b - (view.spent if view else 0)) / b * 100)) + "%";

    return <div>
        <header>
            <div className="brand">Spending mandate<small>Agent spends · every step checked</small></div>
            {if view {
                <div id="mandate">
                    <div id="mandate-goal"><span>Goal</span><div>{view.goal}</div></div>
                    {view.rogue and <span className="badge-rogue">Rogue agent test</span>}
                    <div className="meter-wrap">
                        <div className="meter-top"><span className="num">{usd(view.spent) + " bought · " + usd(view.budget - view.spent) + " left"}</span><span>budget <b className="num">{usd(view.budget)}</b></span></div>
                        <div className="meter"><div className="spent" style={{"width": spent_w}}></div><div className="planned" style={{"width": planned_w}}></div></div>
                    </div>
                    <button className="ghost" onClick={newMandate}>New mandate</button>
                </div>
            } else {
                <div style={{"flex": "1"}}></div>
            }}
            <button className="ghost" onClick={logout}>Log out</button>
        </header>
        {if view {
            <div id="workspace">
                <AgentPanel view={view} busy={busy} reply={reply} error={error}
                    onReply={lambda v: str { reply = v; }}
                    onSend={sendReply}
                    onDecision={lambda i: int { focus = i; selected = ""; tab = "why"; middle = "graph"; }}
                    onBrowser={lambda { middle = "browser"; }} />
                {if middle == "browser" {
                    <BrowserPanel view={view} onMode={lambda m: str { middle = m; }} />
                } else {
                    <GraphPanel view={view} shown={shown} selected={selected}
                        onShow={lambda i: int { shown = i; selected = ""; }}
                        onSelect={lambda nid: str { selected = nid; tab = "why"; }}
                        onMode={lambda m: str { middle = m; }} />
                }}
                <Lens view={view} tab={tab} selected={selected} focus={focus}
                    onTab={lambda t: str { tab = t; }}
                    onBack={lambda { selected = ""; }} />
            </div>
        } else {
            <Intake prompt={prompt} goal={goal} budget={budget} rogue={rogue} drafted={drafted} reading={reading} error={error} history={history}
                onPrompt={lambda v: str { prompt = v; }}
                onGoal={lambda v: str { goal = v; }}
                onBudget={lambda v: str { budget = v; }}
                onRogue={lambda v: bool { rogue = v; }}
                onRead={readGoal}
                onStart={startAgent}
                onOpen={lambda mid: str { openMandate(mid); }} />
        }}
    </div>;
}
