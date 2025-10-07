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

## UI snapshot review workflow

Visual regressions in the AutoParry toggle UI are caught by
`tests/ui/snapshot.spec.lua`. The spec compares the mounted interface against
the baseline stored in `tests/fixtures/ui_snapshot.json` and fails when any
properties drift.

When a legitimate UI change is made:

1. Rebuild the harness place so the updated sources and fixture file are packed
   into the test environment:

   ```bash
   ./tests/build-place.sh
   ```

2. Execute the spec suite locally or allow CI to run it:

   ```bash
   run-in-roblox --place tests/AutoParryHarness.rbxl --script tests/spec.server.lua
   ```

   The snapshot spec emits a `ui-snapshot` artifact (written locally to
   `tests/artifacts/ui_snapshot.json` and uploaded in CI) containing both the
   expected baseline and the newly observed state.

3. Manually review the artifact to confirm the layout, colors, and copy are
   correct. If the change is approved, update `tests/fixtures/ui_snapshot.json`
   to match the new values and re-run the specs to ensure a clean pass.

4. Commit the refreshed baseline together with the intentional UI tweaks. This
   review gate prevents accidental UI regressions from landing unnoticed.
