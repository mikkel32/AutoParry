# Engine Scenario Workflow

The engine harness now treats scenario bundles as first-class build inputs so you can iterate on runtime behaviour without leaving the command line. This document explains how to compile scenario manifests, run the new engine suites, and diagnose common issues.

## Quick start

```bash
# Run the full engine workflow (simulation, replay, metrics)
python tests/run_harness.py --suite engine

# Rebuild scenarios and place even if timestamps are stale
python tests/run_harness.py --suite engine-sim --force-build

# Inspect replay logs only
python tests/run_harness.py --suite engine-replay --keep-artifacts
```

The harness automatically rebuilds the scenario modules and regenerates the test place whenever manifests or engine runtime files change. Artifacts are written to `tests/artifacts/engine/*` and scenario modules are emitted under `tests/artifacts/scenarios/`.

## Suites

| Suite | Description | Key artifacts |
| --- | --- | --- |
| `engine-sim` | Runs every compiled scenario bundle through the runtime, capturing parry/remote logs and telemetry snapshots. | `engine_simulation.json` |
| `engine-replay` | Emits replay-ready payloads for downstream tools and quick manual inspection. | `engine_replay.json` |
| `engine-metrics` | Aggregates metrics (parries, remote traffic, warnings) across all scenarios. | `engine_metrics.json` |
| `engine-perf` | Executes the high-load perf scenarios (5k threats, hitch gauntlet, flicker storms) and captures scheduler/GC telemetry for regressions. | `engine_perf_metrics.json` |

All suites rely on the compiled scenario modules and the generated Rojo place. Use `--skip-build` if you are iterating on the Lua launchers only and already have fresh artifacts.

### Player timeline helpers

Scenario timelines can invoke rich player actions in addition to rule toggles. The runner now surfaces targeting-safe instrumentation alongside the existing configuration helpers:

| Action | Description |
| --- | --- |
| `configure` | Apply relative configuration overrides resolved against the current AutoParry config. |
| `configure-invalid` | Attempt to apply invalid overrides and expect the call to fail without mutating the config. |
| `reset-config` | Restore defaults via `AutoParry.resetConfig()`. |
| `inject-hitch` | Advance the simulation clock by the provided duration to mimic frame hitches. |
| `observe-telemetry` | Run the simulation forward for a fixed duration (at `1/240` step granularity) without injecting new events. |
| `snapshot-targeting-safe` | Capture a sanitised snapshot of the targeting safe-state guard and attach it to the event log. |
| `clear-targeting-safe` | Clear the targeting safe-state guard (optionally with a reason string) and record the resulting snapshot. |

## Autoparry telemetry snapshots

Every scenario run now exposes an `autoparry` payload alongside the existing
physics telemetry. The runner calls the public AutoParry inspection APIs after
each plan completes and stores the sanitised results under:

- `scenario.autoparry` – full snapshot containing the current config, smart
  press state, smart tuning payloads, telemetry history, diagnostics report,
  adaptive state, and auto-tuning status.
- `scenario.metrics.autoparry` – condensed overview with severity, key metrics,
  sample counts, counters, adaptive bias, and any outstanding recommendations
  or adjustments.

These fields make the exported `engine_*` artifacts self-contained: you can
inspect precise telemetry history, replay adjustments, or diff smart tuning
decisions without needing to re-run the harness.

## Scenario compilation

Scenario manifests live in `tests/scenarios/`. They are compiled to Luau modules via `tests/tools/compile_scenarios.lua`. The harness will invoke this compiler automatically, but you can run it manually:

```bash
lune run tests/tools/compile_scenarios.lua --root . --verbose
```

Artifacts are written to `tests/artifacts/scenarios/` and mirrored into the place under `ReplicatedStorage/TestHarness/Scenarios`.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `engine.scenario.runner: scenario artifact folder … is missing` | Run `python tests/run_harness.py --suite engine --force-build` to regenerate the scenario modules and rebuild the place. |
| `Failed to prepare Lune for scenario compilation` | The harness could not find or download `lune`. Verify your network connection or install Lune manually and re-run with `--lune /path/to/lune`. |
| Engine suites exit immediately without artifacts | Ensure `run-in-roblox` is installed and on `PATH`. The suites require a valid Rojo build with up-to-date scenario modules. |
| Replay artifacts contain no remote events | Confirm the manifest’s timeline toggles the parry remote on. Use `engine-sim` to verify rule ordering and highlight warnings in the logs. |

### Tips

* Use `--keep-artifacts` when comparing runs; the engine artifacts live under `tests/artifacts/engine/…`.
* Combine suites: `python tests/run_harness.py --suite static --suite engine` will run linting followed by the engine workflow.
* Pass `--env ENGINE_TRACE=1` (or similar custom flags) if your launchers honour environment toggles.

## Extending scenarios

1. Edit or add manifests in `tests/scenarios/`.
2. Run any engine suite (or `lune run tests/tools/compile_scenarios.lua`) to regenerate compiled modules.
3. Inspect artifacts under `tests/artifacts/engine/` to confirm behaviour.

Remember to check the generated `.roblox.lua` modules into version control only via the harness; they are treated as build products.

## Performance regression gating

Run `python tests/run_harness.py --suite engine-perf` locally or in CI to guard against throughput regressions. The suite filters
for scenarios tagged `engine-perf`, emits `tests/artifacts/engine-perf/engine_perf_metrics.json`, and fails when the workload
contracts (e.g. fewer than 5 000 threats) or when hitch injections disappear. Wire this command into your merge gate so new
commits cannot land if scheduler utilisation, GC drift, or workload coverage falls outside the target envelopes captured in
`goal.md`.

The runtime scheduler now maintains a priority queue and records aggregate lateness metrics so you can spot when callbacks
slip behind simulated time. Inspect `profiler.scheduler.lateness` inside the perf artifact to verify the average and maximum
delays stay well under the 10 ms P99 budget.
