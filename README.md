# AutoParry

AutoParry is a plug-and-play Blade Ball helper that you can bootstrap straight
from GitHub with a single `loadstring`. The loader exposes a small developer
API so you can tweak timings, wire your own UI, or integrate the parry engine
into a larger hub.

## Quick start

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/mikkel32/AutoParry/main/loader.lua", true))()
```

Calling the loader will spin up a full-screen loading overlay, stream the
required modules, and fade in the draggable toggle UI once the parry engine is
ready. Everything required (loader, UI, core) is fetched automatically and the
overlay keeps users informed while AutoParry warms up.

## Customising the bootstrap

You can pass an options table to the loader call for finer control:

```lua
local autoparry = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/mikkel32/AutoParry/main/loader.lua",
    true
))({
    autoStart = true, -- enable immediately
    title = "My Hub / AutoParry",
    hotkey = { key = Enum.KeyCode.P, modifiers = { Enum.KeyCode.LeftControl } },
    tooltip = "Ctrl+P to toggle",
    parry = {
        minSpeed = 12,
        maxTTI = 0.60,
    },
})
```

The `loadingOverlay` option accepts `false` to opt out entirely, or a
configuration table (documented below) to customise the status text, styling,
and retry behaviour of the bootstrap overlay.

### Rich error reporting

When something goes wrong during bootstrap or verification the overlay expands
into a dedicated error panel. The formatter described below now returns both a
status string and a detail payload, so the overlay can render stack traces,
module paths, remediation tips, and timeline metadata inline.

- **Inspector entries** — contextual lines (such as module paths or HTTP
  errors) appear inside the panel alongside copy-friendly buttons. Players can
  tap **Copy error** to put the entire report on their clipboard when reaching
  out for support.
- **Documentation shortcut** — the **Open docs** button jumps directly to the
  troubleshooting guide referenced in the error detail (overridable via
  `docsLink`).
- **Structured timeline** — verification stages that failed are highlighted in
  the dashboard and error panel at the same time, making it obvious which step
  needs attention.
- **Responsive layout** — the panel automatically adapts its size and styling to
  the active theme, keeps action buttons aligned with retry/cancel controls, and
  clamps scroll regions to ensure long logs stay readable.

Custom formatters can piggyback on the same pipeline by returning a table of
the shape `{ text = "status string", detail = buildErrorDetail(state) }`. Any
custom `overlay:setErrorDetails` calls you make will reuse the same UI pieces,
so your bespoke bootstrap flow inherits the copy/docs affordances automatically.

### Loader-level options

| option       | type      | default            | description |
| ------------ | --------- | ------------------ | ----------- |
| `repo`       | `string`  | `"mikkel32/AutoParry"` | Override the GitHub repo to fetch from |
| `branch`     | `string`  | `"main"`          | Remote branch/tag/commit |
| `entrypoint` | `string`  | `"src/main.lua"`  | Alternate entrypoint path |
| `refresh`    | `boolean` | `false`            | Skip loader/module caching |

The same table is forwarded to the main module, so you can keep your custom
parry settings alongside loader overrides.

Behind the scenes the loader protects any existing global state and only
publishes the `AutoParryLoader` helper after the bootstrap succeeds, so failed
fetches or compile errors will not leak partial state into the environment.

### Loader monitoring hooks

When the bootstrap succeeds, a global `AutoParryLoader` table is exposed with
helpers for manual module access and instrumentation:

```lua
local loader = AutoParryLoader
loader.signals.onFetchCompleted:Connect(function(event)
    print("Loaded", event.path, "from", event.cache or "network")
end)
```

| field | description |
| ----- | ----------- |
| `require` | Re-exports the loader-aware `require` implementation |
| `context` | Active loader context (repo, branch, caches, etc.) |
| `signals` | Signal table described below |
| `progress` | Mutable counters `{ started, finished, failed }` |

`signals` contains four connections (`onFetchStarted`, `onFetchCompleted`,
`onFetchFailed`, `onAllComplete`). Listeners receive a payload table containing:

| key | description |
| --- | ----------- |
| `path` | Module path relative to the repository root |
| `url` | Resolved raw GitHub URL |
| `refresh` | Boolean indicating whether refresh mode is active |
| `status` | One of `"started"`, `"completed"`, or `"failed"` |
| `fromCache` | `true` when the module came from context/global caches |
| `cache` | Either `"context"`, `"global"`, or `nil` |
| `result` | Module return value (completed events only) |
| `error` | Error message (failed events only) |

Signals fire for every loader request, including cache hits, and `onAllComplete`
emits whenever `progress.started == progress.finished + progress.failed`.

### Loading overlay options

The bootstrap overlay subscribes to both `AutoParryLoader.context.signals` and
`AutoParry.onInitStatus`, so it can surface download progress, retry failures,
and the moment the parry engine reports `"ready"`. Supplying a table to
`options.loadingOverlay` lets you tailor that experience:

| key | type | default | description |
| --- | ---- | ------- | ----------- |
| `enabled` | `boolean` | `true` | Toggle the overlay without removing other configuration |
| `parent` / `name` / `tips` / `theme` | passthrough | `nil` | Forwarded to `LoadingOverlay.create` for layout/theming tweaks |
| `statusFormatter(state)` | `function` | built-in formatter | Return the status string given loader/parry state |
| `progressFormatter(state)` | `function` | built-in formatter | Return a `0-1` progress value for the overlay bar |
| `actions` | `table` or `function` | `nil` | Custom action buttons or a factory called when the state changes |
| `retryLabel` / `cancelLabel` | `string` | `"Retry"` / `"Cancel"` | Override the default button text |
| `onRetry(ctx)` | `function` | re-runs loader with `refresh = true` | Called when the retry action is pressed |
| `onCancel(ctx)` | `function` | `nil` | Invoked when the cancel action is pressed |
| `onOverlayCreated(overlay)` | `function` | `nil` | Inspect or mutate the overlay instance after creation (`customizeOverlay` is an alias) |
| `fadeDuration` / `progressDuration` | `number?` | `nil` | Override the tween timings passed to `overlay:complete` |

The formatter `state` includes `state.loader` (with `started`, `finished`,
`failed`, `completed`, and the last loader payload), `state.parry` (a copy of
`AutoParry.getInitProgress()`), and `state.error` when a loader or init timeout
occurs. When `actions` is a function it receives the same `(state,
overlayOptions, options)` tuple as the formatters and should return the button
spec array expected by `LoadingOverlay:setActions`. The default retry behaviour
clears caches and re-invokes the loader with `refresh = true`, but you can
supply your own handler to integrate with a custom boot flow.

## Verification timeline

![Verification dashboard showing the staged status ladder](docs/verification-dashboard.png)

While the loader streams modules, AutoParry's orchestrator emits granular
updates through `AutoParry.onInitStatus`. The loading overlay renders those
events with the neon verification dashboard above so players can follow each
stage:

- **Player Sync** — waits for `Players.LocalPlayer` and the character rig.
- **Parry Input** — prepares the local `F` key via `VirtualInputManager` so
  AutoParry can trigger parries without relying on replicated remotes.
- **Success Events** — wires listeners for `ParrySuccess` / `ParrySuccessAll`
  so the core can reset cooldowns as soon as Blade Ball confirms a parry.
- **Ball Telemetry** — verifies the configured workspace folder (defaults to
  `workspace.Balls`) before enabling the heartbeat loop.

Every stage reports a status ladder (`pending`/`waiting`, `ok`, `warning`, or
`failed`). If any resource disappears after AutoParry is ready (for example, the
virtual F-key bridge is disrupted or the balls folder is deleted) the
orchestrator emits a `restarting` update, tears down listeners, and re-runs the
verification flow before allowing parries again.

### Verification configuration

The runtime exposes several tuning knobs via `configure` (or the `parry`
sub-table passed to the loader):

| key | type | default | description |
| --- | ---- | ------- | ----------- |
| `playerTimeout` | `number` | `10` | Seconds to wait for `Players.LocalPlayer` |
| `remotesTimeout` | `number` | `10` | Seconds to wait for `ReplicatedStorage.Remotes` |
| `ballsFolderTimeout` | `number` | `5` | Seconds to wait for the configured balls folder (`nil` disables the wait) |
| `verificationRetryInterval` | `number` | `0` | Delay between verification retries (set >0 to pace polling) |
| `ballsFolderName` | `string` | `"Balls"` | Workspace folder searched during ball telemetry verification |

These options sit alongside the parry timing controls listed below. Most users
can keep the defaults, but hub authors can stretch the timeouts for slower
setups or point `ballsFolderName` at custom projectile folders.

### Troubleshooting verification issues

- **Timeout** — if a stage reports `timeout` the dashboard and loader emit a
  blocking error with the offending resource (`local-player`, `remotes-folder`,
  `parry-input`, or `balls-folder`). Ensure Roblox is focused so VirtualInputManager
  can deliver the F key, or increase the corresponding timeout.
- **Warning on Ball Telemetry** — a `warning` status means AutoParry could not
  locate the balls folder before the timeout. AutoParry will keep running but
  cannot pre-emptively analyse projectiles; verify the folder name or increase
  the timeout.
- **Restarting** — if the dashboard flashes `restarting` mid-match, the F-key
  bridge or balls folder went missing. AutoParry will automatically rescan and
  re-arm the virtual input once the resource returns.

## Runtime API

The loader returns the AutoParry API table:

```lua
local api = loadstring(game:HttpGet(URL, true))()
print(api.getVersion())
```

| method | description |
| ------ | ----------- |
| `getVersion()` | Returns the AutoParry build identifier |
| `isEnabled()` | `true` if the parry loop is running |
| `setEnabled(flag)` | Enables or disables the loop and syncs the UI |
| `toggle()` | Flips the enabled state |
| `configure(config)` | Applies config overrides (see below) |
| `getConfig()` | Returns a copy of the active configuration |
| `resetConfig()` | Restores factory settings |
| `setLogger(fn)` | Injects a custom logger callback |
| `getLastParryTime()` | Unix timestamp of the most recent parry |
| `onStateChanged(callback)` | Subscribe to enable/disable changes |
| `onParry(callback)` | Subscribe to successful parry events |
| `getUiController()` | Access the UI controller (set/toggle/destroy) |
| `destroy()` | Shuts down the loop and removes the UI |

## Parry configuration

`configure` (and the `parry` table passed to the loader) understands:

| key | type | default | description |
| --- | ---- | ------- | ----------- |
| `cooldown` | `number` | `0.10` | Minimum seconds between parry attempts |
| `minSpeed` | `number` | `10` | Ignore balls slower than this (studs/s) |
| `pingOffset` | `number` | `0.05` | Extra latency padding (seconds) |
| `minTTI` | `number` | `0.12` | Minimum time-to-impact accepted |
| `maxTTI` | `number` | `0.55` | Maximum time-to-impact window |
| `safeRadius` | `number` | `10` | Instant parry radius around the player |
| `curvatureLeadScale` | `number` | `0.12` | Extra seconds injected into the response window when curvature/jerk spike (scaled by severity) |
| `curvatureHoldBoost` | `number` | `0.5` | Portion of the curve-derived lead distance preserved for the hold radius |
| `targetHighlightName` | `string?` | `"Highlight"` | Character child required to parry (set to `nil` to skip the check) |
| `ballsFolderName` | `string` | `"Balls"` | Workspace folder that holds the Blade Ball projectiles |
| `playerTimeout` | `number` | `10` | Upper bound for LocalPlayer discovery |
| `remotesTimeout` | `number` | `10` | Upper bound for locating `ReplicatedStorage.Remotes` |
| `parryRemoteTimeout` | `number` | `10` | Upper bound for finding the parry remote |
| `ballsFolderTimeout` | `number` | `5` | Upper bound for finding the balls folder |
| `verificationRetryInterval` | `number` | `0` | Delay between verification polls |

**Anti-curve tuning.** AutoParry watches the filtered curvature (`κ`), curvature rate, radial acceleration, and jerk overflow reported by Blade Ball projectiles. When those values approach the configured physics limits AutoParry injects more lead time and expands the hold radius. Tweak `curvatureLeadScale` to control the maximum extra response time (set it to `0` to disable the behaviour) and adjust `curvatureHoldBoost` to decide how much of that extra distance should remain available while holding the parry key.

Call `resetConfig()` to restore defaults at runtime.

## Reliability safeguards

- The core waits for the local player and the `ParryButtonPress.parryButtonPress`
  bindable with a
  sensible timeout before starting the heartbeat loop, raising a clear error if
  Blade Ball is not ready yet.
- Config overrides are validated to prevent invalid values from breaking the
  parry window.
- Verification watchers monitor the remotes folder, success events, and the
  balls folder; if any disappear AutoParry emits a `restarting` status and
  re-runs the verification ladder before attempting another parry.
- `destroy()` tears down events, detaches the UI, resets the configuration to
  defaults, and leaves the environment clean for subsequent reloads.

## UI controller helpers

The UI mount returns a controller with:

- `setEnabled(flag, context?)`
- `toggle()`
- `isEnabled()`
- `getGui()`
- `onChanged(callback)`
- `destroy()`

You can also provide a hotkey descriptor when mounting:

```lua
local controller = autoparry.getUiController()
controller:onChanged(function(enabled)
    print("UI toggled", enabled)
end)
```

## Notes

- Instances are created under `CoreGui` and cleaned up when `destroy()` is
  called.
- The loader exposes `AutoParryLoader` globally with the active context so you
  can fetch sibling modules manually if needed.
- No external dependencies are required; everything is pure Luau.

## Development workflow

AutoParry's repository is wired to mirror Roblox's environment as closely as
possible so syntax or runtime issues surface during local development instead of
in-game. To iterate confidently:

1. **Install tooling** — ensure the [Rojo CLI](https://rojo.space/),
   [`run-in-roblox`](https://github.com/rojo-rbx/run-in-roblox), Python 3.8+, and
   a recent Rust toolchain (for the Selene linter) are available on your PATH.
2. **Lint with Selene** — run `selene .` from the repository root to verify Luau
   syntax and Roblox-specific globals using the stricter configuration provided
   in `selene.toml`. The repository vendors the `lua51.yml` and `luau.yml`
   standard library descriptions so Selene works offline.
3. **Refresh the harness place** — execute `./tests/build-place.sh` to regenerate
   `tests/fixtures/AutoParrySourceMap.lua` (pulling every module from `src/`) and
   rebuild the automated Blade Ball test place.
4. **Drive automation** — use `run-in-roblox --place tests/AutoParryHarness.rbxl
   --script tests/spec.server.lua` to run the full spec suite, or switch the
   script path for smoke/performance scenarios.

The CI workflow mirrors this process by running Selene before spinning up the
Roblox automation harness, so local runs stay aligned with the gated checks.
