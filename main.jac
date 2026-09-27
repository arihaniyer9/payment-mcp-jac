"""Spending mandate: an agent spends money only after its plan and every purchase pass the checks.

Server code lives in services/ (endpoints in services/api.jac); the UI in components/.
Run: jac start --dev main.jac
"""
cl {
    import "./styles/global.css";
    import from .components.App { App }

    def:pub app() -> JsxElement {
        return <App />;
    }
}
