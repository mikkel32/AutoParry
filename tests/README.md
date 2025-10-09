# AutoParry Test Harness

This harness mirrors the Blade Ball runtime environment closely enough for CI
to execute `loader.lua` and bootstrap the AutoParry stack without touching the
live game.

## Rojo test place anatomy

The harness bundles a self-contained Roblox place, generated via Rojo, that
mirrors the subset of Blade Ball functionality AutoParry depends on. The
[`tests/fixtures/place.project.json`](../tests/fixtures/place.project.json)
project collects three major source buckets:

- `src/` — the current AutoParry runtime, imported via the generated
  [`tests/fixtures/AutoParrySourceMap.lua`](../tests/fixtures/AutoParrySourceMap.lua)
  so the harness always exercises the exact workspace version.
- `tests/shared/` — helper modules and service shims that replicate the Roblox
  environment (physics clock, heartbeat loop, and network latency stubs).
- [`tests/autoparry/harness.lua`](../tests/autoparry/harness.lua) — entrypoint
  glue that wires the loader into the fake Blade Ball services and exposes
  instrumentation hooks for the specs.

Because the project intentionally omits live-game services, keep new dependencies
behind feature flags or extend the harness fixtures first; otherwise the loader
may fail during CI.

## Building the place file

Run the helper script from the repository root to refresh the harness place and
source map, or let the new harness runner (documented below) rebuild it
automatically when sources change:

```bash
./tests/build-place.sh
```

The script regenerates `tests/fixtures/AutoParrySourceMap.lua` (using the
current workspace sources) and then calls `rojo build` on the project file. The
compiled place is written to `tests/AutoParryHarness.rbxl`.

Dependencies:

- [`rojo` CLI](https://rojo.space/) (v7 or newer)
- Python 3.8+

If `rojo build` reports missing services, verify that the target service exists
in `tests/fixtures/place.project.json` or add a stub to
`tests/shared/services`. Remember to re-run `./tests/build-place.sh` after
adjusting fixtures.

## Roblox automation scripts

After building the place, validate the sandboxed bootstrap using the
[`run-in-roblox`](https://github.com/rojo-rbx/run-in-roblox) automation entry
points. The repository provides three primary scripts:

- [`tests/init.server.lua`](../tests/init.server.lua) — smoke test that mounts
  the loader and exits once AutoParry reports a healthy state.
- [`tests/spec.server.lua`](../tests/spec.server.lua) — executes the full
  spec suite, which fan out into modular specs such as
  [`tests/autoparry/heartbeat.spec.lua`](../tests/autoparry/heartbeat.spec.lua),
  [`tests/api/main.spec.lua`](../tests/api/main.spec.lua), and the loader
  integration specs in [`tests/loader`](../tests/loader).
- [`tests/perf/heartbeat_benchmark.server.lua`](../tests/perf/heartbeat_benchmark.server.lua)
  — drives the performance workload described below.

### Developer-friendly harness runner

To make day-to-day validation less error prone, the repository bundles a
Python-powered runner that orchestrates the entire workflow:

```bash
python tests/run_harness.py --suite all
```

Key capabilities:

- **Smart rebuilds** — the script tracks modification times across `src/`,
  `loader.lua`, and the critical fixtures so the Rojo place is rebuilt only
  when required. Pass `--force-build` to refresh manually or `--skip-build` to
  bypass the check entirely.
- **Quality gates** — `--suite all` now fronts Stylua, Selene, and
  `luau-analyze` before touching Roblox Studio. Missing tools are reported with
  install hints, and you can focus on just the static checks via
  `--suite static`.
- **Suite selection** — choose between the smoke, spec, performance, and
  accuracy harnesses using repeated `--suite <name>` flags. Groups such as
  `--suite roblox` and `--suite all` expand automatically, and `--list`
  surfaces the backing command for each suite.
- **Repeat & flaky detection** — pass `--repeat N` to run Roblox-backed suites
  multiple times. The summary rolls up pass/fail counts and shows per-run
  metrics so you can spot unstable specs quickly.
- **Artifact capture & insights** — `[ARTIFACT]`, `[PERF]`, and `[ACCURACY]`
  payloads emitted from Roblox are decoded automatically and written to
  `tests/artifacts/<suite>/`. Summary hooks compare performance numbers against
  the stored baseline and expand accuracy violations inline, while logs land in
  `tests/artifacts/logs/` for quick debugging.
- **Dry runs & overrides** — `--dry-run` prints the commands without executing
  them, `--run-in-roblox <path>` targets a non-default CLI install, and
  repeated `--env KEY=VALUE` flags forward custom environment variables.

The runner surfaces dependency gaps (missing `rojo`, `run-in-roblox`, Stylua,
Selene, or `luau-analyze`) with actionable remediation hints. When integrating
it into automated workflows you can inspect the JSON artifacts the same way CI
does, without manually copying console output.

### Luau spec runner

Studio access is no longer required to exercise the spec suite end-to-end. The
repository ships `tests/tools/run_specs.luau`, a Lune-compatible harness that:

- Bootstraps a DataModel with `game`, `workspace`, and Roblox globals wired to
  Lune's runtime while projecting `ReplicatedStorage.TestHarness.Specs` so the
  existing spec modules can be required verbatim.
- Provides focused API shims for UI-heavy code paths (Font families, text
  alignment enums, scrolling/layout modes, and common key codes) so
  `Enum.*` lookups match the values AutoParry expects when instantiating UI.
- Mirrors the remote wiring that the Roblox place exposes by parenting the
  harness folder into `ReplicatedStorage`, ensuring verification code can find
  the mocked remotes and success events.

When Lune is missing the harness will download a portable
[release](https://lune-org.github.io/docs/) automatically; you can also install it
manually if you prefer. Run the suite directly via:

```bash
python tests/run_harness.py --suite spec --spec-engine lune
```

You can focus on a subset of modules by setting `SPEC_FILTER` to a substring of the
spec module name:

```bash
SPEC_FILTER=parry python tests/run_harness.py --suite spec --spec-engine lune
```

The harness automatically regenerates the source map before execution and will
hint if `lune` is missing from your `PATH`.

You can still run the underlying automation scripts directly when needed:

```bash
run-in-roblox \
  --place tests/AutoParryHarness.rbxl \
  --script <script-path>
```

The automation commands use a headless Roblox Studio runner. If you encounter a
permission error, make sure Roblox Studio has been launched at least once on the
machine so the background runner is provisioned, and confirm the `run-in-roblox`
CLI is authenticated with the same Windows/macOS user.

## CI artifacts and review workflow

The harness writes JSON artifacts to `tests/artifacts/<suite>/` both locally and
in CI so reviewers can inspect results without re-running Studio:

- `perf/perf.json` — generated by the heartbeat benchmark, containing averaged
  frame timings per projectile batch alongside the sampled thresholds.
- `spec/ui_snapshot.json` — emitted by
  [`tests/ui/snapshot.spec.lua`](../tests/ui/snapshot.spec.lua) with `expected`
  and `observed` UI states.
- `spec/parry_timeline.json` — captured by the parry telemetry spec with the
  smart-press schedule snapshot, parry timestamp, and remote-call summary.
- `spec/loader.log` — produced by
  [`tests/loader/bootstrap.spec.lua`](../tests/loader/bootstrap.spec.lua)
  summarising network fetches and configuration overrides.
- `accuracy/parry-accuracy.json` — summarises deterministic benchmark totals,
  scenario-level violations, and the configured thresholds.

CI uploads these files as artifacts, and the GitHub Actions summary links back
to the most recent run. When validating a PR, review the artifacts for drift
before approving UI or performance-sensitive changes.

## Heartbeat performance benchmark

The harness also contains a synthetic workload that exercises the core
`AutoParry` heartbeat loop across increasing projectile counts. Execute the
benchmark locally with the automation command shown above, pointing to
`tests/perf/heartbeat_benchmark.server.lua`.

During the run the benchmark prints a `[PERF]` JSON blob and writes the same
payload to `tests/artifacts/perf/perf.json`. Key fields include:

- `summary.average` / `summary.p95` — frame time aggregates (seconds) captured
  across all samples. The harness summary converts them to milliseconds and
  reports the delta relative to the stored baseline.
- `summary.samples` — number of samples collected across all projectile
  populations.
- `thresholds` — snapshot of the configured performance budget loaded from
  [`tests/perf/config.lua`](../tests/perf/config.lua).

Interpretation guidelines:

- **Passing** — both `averageMs` ≤ 1.6 ms and `p95Ms` ≤ 3.5 ms (repository
  defaults). CI reports the current margin to each bound.
- **Regression** — if either metric exceeds the configured limit the script
  throws, causing the CI job to fail. Investigate recent changes in the
  heartbeat loop or benchmark fixtures.
- **Improvement** — when a change materially lowers the averages, update the
  baseline stored in [`tests/perf/baseline.json`](../tests/perf/baseline.json)
  so the dashboard reflects the new golden numbers.

If the benchmark exits early with service errors, confirm that the mock physics
services in [`tests/shared/physics`](../tests/shared/physics) export the same
APIs as the runtime modules you depend on. Missing API methods should be added
to the shim before landing gameplay changes.

## Parry accuracy benchmark

To validate that AutoParry continues to fire at the correct moments, the harness
ships a dedicated accuracy workload at `tests/perf/parry_accuracy.server.lua`.
The script drives the loader through a battery of deterministic scenarios that
exercise highlight gating, safe-radius snaps, cooldown spacing, and multi-target
selection.

Run the benchmark with the same automation entrypoint used for the heartbeat
workload:

```bash
run-in-roblox \
  --place tests/AutoParryHarness.rbxl \
  --script tests/perf/parry_accuracy.server.lua
```

The job prints a `[ACCURACY]` JSON payload summarising each scenario, total
parries, and any violations relative to the configured thresholds, and writes it
to `tests/artifacts/accuracy/parry-accuracy.json`. The harness summary expands
violations inline so you do not need to manually decode the JSON. You can
override the defaults by editing `tests/perf/parry_accuracy.config.lua` before
running the script.

If any scenario produces unexpected parries (false positives) or misses an
expected window, the script raises an error with a diagnostic string that lists
the failing thresholds. Review the JSON output to inspect which ball was
targeted and at which simulated frame the regression occurred.

## UI snapshot review workflow

Visual regressions in the AutoParry toggle UI are caught by
[`tests/ui/snapshot.spec.lua`](../tests/ui/snapshot.spec.lua). The spec compares
the mounted interface against the baseline stored in
[`tests/fixtures/ui_snapshot.json`](../tests/fixtures/ui_snapshot.json) and fails
when any properties drift.

Additional verification-focused specs complement the snapshot harness:

- [`tests/autoparry/verification_status.spec.lua`](../tests/autoparry/verification_status.spec.lua)
  runs the orchestrator through simulated failures (missing balls folder,
  absent success remotes, parry remote removal) and asserts the emitted status
  ladder plus the enable gating behaviour.
- [`tests/ui/verification_dashboard.spec.lua`](../tests/ui/verification_dashboard.spec.lua)
  mounts the verification dashboard and feeds synthetic status updates to verify
  the step cards reflect `AutoParry.onInitStatus` transitions, including warning
  tooltips when ball telemetry times out.

Include these specs in local runs whenever you touch bootstrap logic or the
loading overlay so CI stays green.

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
   `tests/artifacts/spec/ui_snapshot.json` and uploaded in CI) containing both the
   expected baseline and the newly observed state.

3. Manually review the artifact to confirm the layout, colors, and copy are
   correct. If the change is approved, update
   [`tests/fixtures/ui_snapshot.json`](../tests/fixtures/ui_snapshot.json) to
   match the new values and re-run the specs to ensure a clean pass.

4. Commit the refreshed baseline together with the intentional UI tweaks. This
   review gate prevents accidental UI regressions from landing unnoticed.

## Troubleshooting common harness failures

- **Missing service errors** — Extend `tests/fixtures/place.project.json` with
  the required service stub and add an implementation under
  `tests/shared/services`. Rebuild the place afterwards.
- **Permission denied from Roblox automation** — Ensure Roblox Studio has been
  opened interactively on the machine to grant filesystem and account access to
  the headless runner. Re-run the `run-in-roblox` command from the same user
  context.
- **Loader cannot fetch remote modules** — The harness runs fully offline; make
  sure new dependencies are added to `tests/shared` or proxied through
  `tests/fixtures/AutoParrySourceMap.lua` instead of relying on HTTP requests.

## Keeping docs in sync with tooling

Whenever a PR introduces new harness scripts, fixtures, or automation commands,
update this document (and any related READMEs) in the same branch. CI reviewers
rely on the documentation to discover freshly added entrypoints, so tooling
changes without docs will be requested for revision.
