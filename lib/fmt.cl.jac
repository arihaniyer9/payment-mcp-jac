"""Formatting helpers shared by the UI sections."""

glob NL: str = chr(10);

def:pub usd(x: float) -> str {
    return "$" + f"{x:.2f}";
}

def:pub pct(p: float) -> str {
    return str(Math.round(p * 100)) + "%";
}

def:pub plural(n: int, word: str) -> str {
    return str(n) + " " + word + ("" if n == 1 else "s");
}

def:pub px(x: float) -> str {
    return str(x) + "px";
}
