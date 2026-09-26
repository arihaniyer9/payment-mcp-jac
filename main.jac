import from .frontend { app as ClientApp }
import from jac.api {
    set_mode, set_llm_checks, get_settings, list_escalations,
    resolve_escalation, reset_demo, debug_create_escalation,
    get_request_status, agent_ping
}
import from jac.pipeline { request_payment }

def:pub app() -> JsxElement {
    return <ClientApp />;
}
