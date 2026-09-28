#!/usr/bin/env python3
"""Collect ${VAR} placeholders from template files for envsubst."""
from __future__ import annotations

import re
import sys
from pathlib import Path

VAR_RE = re.compile(r"\$\{([A-Z][A-Z0-9_]*)\}")


def vars_in(path: Path) -> set[str]:
    return set(VAR_RE.findall(path.read_text(encoding="utf-8")))


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: collect-envsubst-vars.py <template> ...", file=sys.stderr)
        return 1
    all_vars: set[str] = set()
    for arg in sys.argv[1:]:
        all_vars |= vars_in(Path(arg))
    # envsubst expects a single string: '$VAR1 $VAR2' with braces
    print(" ".join(f"${{{v}}}" for v in sorted(all_vars)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
