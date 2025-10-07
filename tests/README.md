# AutoParry Test Harness

This harness mirrors the Blade Ball runtime environment closely enough for CI
to execute `loader.lua` and bootstrap the AutoParry stack without touching the
live game.

## Building the place file

Run the helper script from the repository root:

```bash
./tests/build-place.sh
```

The script regenerates `tests/fixtures/AutoParrySourceMap.lua` (using the
current workspace sources) and then calls `rojo build` on
`tests/fixtures/place.project.json`. The compiled place is written to
`tests/AutoParryHarness.rbxl`.

Dependencies:

- [`rojo` CLI](https://rojo.space/) (v7 or newer)
- Python 3.8+

## Executing the harness

After building the place, validate the sandboxed bootstrap using
[`run-in-roblox`](https://github.com/rojo-rbx/run-in-roblox):

```bash
run-in-roblox \
  --place tests/AutoParryHarness.rbxl \
  --script tests/init.server.lua
```

The script stubs networking, heartbeat timing, and stats latency so the loader
can run deterministically in CI. A successful run prints a confirmation message
and exits with code zero.
