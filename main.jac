import from .frontend { app as ClientApp }
import from smoke { smoke_seed, smoke_walk, smoke_llm }
import from auth_proof { agent_auth_proof, admin_auth_proof }
import from auth_proof { agent_auth_proof, admin_auth_proof }

def:pub app() -> JsxElement {
    return <ClientApp />;
}
