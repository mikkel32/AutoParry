#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/tests/fixtures/place.project.json"
OUTPUT_FILE="$ROOT_DIR/tests/AutoParryHarness.rbxl"
SOURCEMAP_FILE="$ROOT_DIR/tests/fixtures/AutoParrySourceMap.lua"

if ! command -v rojo >/dev/null 2>&1; then
    echo "[build-place] rojo CLI is required. Install from https://rojo.space/docs/v7/getting-started/" >&2
    exit 1
fi

python3 - "$ROOT_DIR" "$SOURCEMAP_FILE" <<'PY'
import os
import sys

root = sys.argv[1]
outfile = sys.argv[2]
files = [
    ('loader.lua', os.path.join(root, 'loader.lua')),
    ('src/main.lua', os.path.join(root, 'src', 'main.lua')),
    ('src/core/autoparry.lua', os.path.join(root, 'src', 'core', 'autoparry.lua')),
    ('src/ui/init.lua', os.path.join(root, 'src', 'ui', 'init.lua')),
    ('src/shared/util.lua', os.path.join(root, 'src', 'shared', 'util.lua')),
    ('tests/fixtures/ui_snapshot.json', os.path.join(root, 'tests', 'fixtures', 'ui_snapshot.json')),
]

contents = {}
for key, path in files:
    with open(path, 'r', encoding='utf-8') as handle:
        contents[key] = handle.read()

with open(outfile, 'w', encoding='utf-8') as handle:
    handle.write('-- Auto-generated source map for AutoParry tests\n')
    handle.write('return {\n')
    for key, source in contents.items():
        handle.write(f"    ['{key}'] = [===[\n{source}\n]===],\n")
    handle.write('}\n')
PY

rojo build "$PROJECT_FILE" --output "$OUTPUT_FILE"

echo "[build-place] Wrote $OUTPUT_FILE"
