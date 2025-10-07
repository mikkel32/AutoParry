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
