# Engine Observability Artifacts

The telemetry exporter consolidates AutoParry runtime state, smart tuning
snapshots, diagnostics, and per-step physics traces into two deterministic
artifacts:

- **`*-observability.json`** – normalised telemetry payload.
- **`*-trace.json`** – compressed replay trace.

Both files are emitted by [`engine/telemetry/exporter.lua`](../../engine/telemetry/exporter.lua)
via `Exporter.writeArtifacts`.

## Telemetry payload schema

The payload is a JSON object with the following top-level structure:

| Field | Type | Description |
| ----- | ---- | ----------- |
| `version` | number | Export format version (`1`). |
| `generatedAt` | number | Wall-clock timestamp used for diffing runs. |
| `metadata` | object | Caller-provided run metadata (e.g. scenario id). |
| `telemetry` | object | Snapshot from `AutoParry.getTelemetrySnapshot()`, including the event history and adaptive state. |
| `smartTuning` | object | Smart-tuning state (falls back to the telemetry snapshot if a separate payload is not supplied). |
| `diagnostics` | object | Diagnostics report produced by `AutoParry.getDiagnosticsReport()`. |
| `parryLog` | array | List of `{ timestamp, ball }` entries derived from the simulation harness. |
| `events` | array | Telemetry event stream rendered as an array for convenience (defaults to `telemetry.history` when omitted). |

### Normalisation rules

The exporter sanitises values using the same rules enforced by the spec suite:

- `Vector3` → `{ "x": number, "y": number, "z": number }`
- `Vector2` → `{ "x": number, "y": number }`
- `CFrame` → `{ "cframe": [ number × 12 ] }`
- `Color3` → `{ "r": number, "g": number, "b": number }`
- `EnumItem` → string representation.
- `Instance` → `{ "className": string, "name": string }`
- Tables are cloned recursively with array/dictionary shape preserved.
- Functions, threads, and userdata are stringified.

Smart tuning payloads and diagnostics reuse this sanitisation, which ensures
that hashes stay stable across runs and the test harness can diff payloads
reliably.

### Parry log entries

When the harness captures a `ball` instance, the exporter records a compact
object containing the instance name, position, and velocity. If the `ball`
value is already serialisable (e.g. a string id) it is propagated verbatim.

## Trace file schema

The trace file stores per-step simulation snapshots in a compressed layout that
favours tooling ingest:

```json
{
  "version": 1,
  "metadata": { "frequency": 240 },
  "agents": [ "player", … ],
  "projectiles": [ "BaselineThreat", … ],
  "rules": [ "highlight-gate", "cooldown-guard", … ],
  "steps": [
    [
      <time seconds>,
      [ [ <agentIndex>, px, py, pz, vx, vy, vz ], … ],
      [ [ <projectileIndex>, px, py, pz, vx, vy, vz, contactFlag ], … ],
      [ [ <ruleIndex>, <sanitisedState> ], … ]
    ],
    …
  ]
}
```

Key points:

- Names are deduplicated into the `agents`, `projectiles`, and `rules` arrays
  to minimise repetition; step entries reference them by index.
- Positions and velocities are encoded as raw numbers (no nested objects).
- `contactFlag` is `1` when the projectile is armed for contact, otherwise `0`.
- Rule states accept booleans, numbers, or sanitised tables depending on the
  source payload.

Downstream tooling can replay a simulation by resolving entity ids to their
names, then iterating the ordered `steps` array. The compact array-based layout
keeps file sizes low while remaining JSON compatible.

## Baseline validation

`tests/engine/telemetry_exporter.spec.lua` exercises the exporter with a
representative scenario and compares the emitted payloads against the golden
baseline stored in
[`tests/artifacts/engine/baselines/telemetry_exporter.json`](../../tests/artifacts/engine/baselines/telemetry_exporter.json).
Any drift in the payload or trace structure will fail the spec and surface a
reviewable artifact under `tests/artifacts/spec/`.

When intentionally updating the schema:

1. Regenerate the baseline by running the spec harness with the exporter
   scenario.
2. Review the differences captured in `tests/artifacts/spec/telemetry_exporter.json`.
3. Update the baseline JSON (and this document if fields change) before
   committing.
