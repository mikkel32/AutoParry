#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/tests/fixtures/place.project.json"
OUTPUT_FILE="$ROOT_DIR/tests/AutoParryHarness.rbxl"
SOURCEMAP_FILE="$ROOT_DIR/tests/fixtures/AutoParrySourceMap.lua"

python3 - "$ROOT_DIR" "$SOURCEMAP_FILE" <<'PY'
from collections import OrderedDict
from pathlib import Path
import sys

root = Path(sys.argv[1])
outfile = Path(sys.argv[2])

entries = OrderedDict()

src_root = root / "src"
for path in sorted(src_root.rglob("*.lua")):
    relative = path.relative_to(root).as_posix()
    entries[relative] = path

for relative, path in [
    ("loader.lua", root / "loader.lua"),
    ("tests/perf/config.lua", root / "tests" / "perf" / "config.lua"),
    ("tests/fixtures/ui_snapshot.json", root / "tests" / "fixtures" / "ui_snapshot.json"),
]:
    entries[relative] = path

with outfile.open("w", encoding="utf-8") as handle:
    handle.write("-- Auto-generated source map for AutoParry tests\n")
    handle.write("return {\n")
    for key, path in entries.items():
        with path.open("r", encoding="utf-8") as source:
            handle.write(f"    ['{key}'] = [===[\n{source.read()}\n]===],\n")
    handle.write("}\n")
PY

if ! command -v rojo >/dev/null 2>&1; then
    echo "[build-place] rojo CLI is required. Install from https://rojo.space/docs/v7/getting-started/" >&2
    exit 1
fi

rojo build "$PROJECT_FILE" --output "$OUTPUT_FILE"

echo "[build-place] Wrote $OUTPUT_FILE"
