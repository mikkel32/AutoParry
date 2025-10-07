# AutoParry

AutoParry is a plug-and-play Blade Ball helper that you can bootstrap straight
from GitHub with a single `loadstring`. The loader exposes a small developer
API so you can tweak timings, wire your own UI, or integrate the parry engine
into a larger hub.

## Quick start

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/mikkel32/AutoParry/main/loader.lua", true))()
```

Calling the loader will mount the built-in draggable toggle UI and keep the
parry loop idle until you flip it on. Everything required (loader, UI, core)
is fetched automatically, so the UI is visible and ready the moment the
loadstring returns.

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
| `targetHighlightName` | `string?` | `"Highlight"` | Character child required to parry (set to `nil` to skip the check) |
| `ballsFolderName` | `string` | `"Balls"` | Workspace folder that holds the Blade Ball projectiles |

Call `resetConfig()` to restore defaults at runtime.

## Reliability safeguards

- The core waits for the local player and the `ParryButtonPress` remote with a
  sensible timeout before starting the heartbeat loop, raising a clear error if
  Blade Ball is not ready yet.
- Config overrides are validated to prevent invalid values from breaking the
  parry window.
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
