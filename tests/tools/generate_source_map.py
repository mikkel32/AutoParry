#!/usr/bin/env python3
"""Generate the AutoParry test source map used by the harness suites."""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
from typing import Iterable, Tuple

ROOT_RELATIVE_PATHS: Tuple[Tuple[str, str], ...] = (
    ("loader.lua", "loader.lua"),
    ("tests/perf/config.lua", "tests/perf/config.lua"),
    ("tests/fixtures/ui_snapshot.json", "tests/fixtures/ui_snapshot.json"),
)


def iter_source_entries(root: Path) -> Iterable[Tuple[str, Path]]:
    src_root = root / "src"
    for path in sorted(src_root.rglob("*.lua")):
        relative = path.relative_to(root).as_posix()
        yield relative, path

    for relative, path_str in ROOT_RELATIVE_PATHS:
        yield relative, root / path_str


def compute_digest(contents: str) -> str:
    return hashlib.sha1(contents.encode("utf-8")).hexdigest()


def render_source_map(root: Path, output: Path) -> bool:
    entries = list(iter_source_entries(root))
    lines = ["-- Auto-generated source map for AutoParry tests", "return {"]

    for relative, path in entries:
        with path.open("r", encoding="utf-8") as handle:
            source = handle.read()
        digest = compute_digest(source)
        header = f"-- {relative} (sha1: {digest})"
        lines.append(f"    ['{relative}'] = [===[\n{header}\n{source}\n]===],")

    lines.append("}")
    rendered = "\n".join(lines) + "\n"

    try:
        existing = output.read_text(encoding="utf-8")
    except FileNotFoundError:
        existing = None

    if existing == rendered:
        return False

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(rendered, encoding="utf-8")
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path, help="Repository root containing src/")
    parser.add_argument("output", type=Path, help="Destination AutoParrySourceMap.lua path")
    args = parser.parse_args()

    changed = render_source_map(args.root.resolve(), args.output.resolve())
    if changed:
        print(f"[generate-source-map] Wrote {args.output}")
    else:
        print(f"[generate-source-map] Up to date: {args.output}")


if __name__ == "__main__":
    main()
