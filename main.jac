import from .frontend { app as ClientApp }
import from smoke { smoke_seed, smoke_walk, smoke_llm }

def:pub app() -> JsxElement {
    return <ClientApp />;
}
