"""Count non-blank, non-comment lines of our own .jac vs .py code.

Excludes the JacHammer frontend template (frontend.cl.jac, components/ui, lib/)
and generated/vendored dirs.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKIP_DIRS = {".jac", ".venv", "node_modules", ".git", "dist", "components", "lib"}
SKIP_FILES = {"frontend.cl.jac"}


def count(path: Path) -> int:
    n = 0
    for line in path.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if s and not s.startswith("#"):
            n += 1
    return n


def main() -> None:
    totals = {".jac": 0, ".py": 0}
    for p in ROOT.rglob("*"):
        if not p.is_file() or p.suffix not in totals or p.name in SKIP_FILES:
            continue
        if SKIP_DIRS & set(p.relative_to(ROOT).parts):
            continue
        totals[p.suffix] += count(p)
    total = sum(totals.values()) or 1
    print(f"jac lines: {totals['.jac']}  py lines: {totals['.py']}  "
          f"jac share: {100 * totals['.jac'] / total:.1f}%")


if __name__ == "__main__":
    main()
