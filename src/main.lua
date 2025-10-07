-- mikkel32/AutoParry : src/main.lua
-- selene: allow(global_usage)
-- Bootstraps the AutoParry experience, wiring together the UI and core logic
-- and returning a friendly developer API.

local Require = rawget(_G, "ARequire")
assert(Require, "AutoParry: ARequire missing (loader.lua not executed)")

local UI = Require("src/ui/init.lua")
local Parry = Require("src/core/autoparry.lua")
local Util = Require("src/shared/util.lua")

local VERSION = "1.1.0"

local function normalizeOptions(options)
    options = options or {}
    local defaults = {
        title = "AutoParry",
        autoStart = false,
        defaultEnabled = false,
        hotkey = nil,
        tooltip = nil,
        parry = nil,
    }

    return Util.merge(Util.deepCopy(defaults), options)
end

return function(options)
    local opts = normalizeOptions(options)

    if typeof(opts.parry) == "table" then
        Parry.configure(opts.parry)
    end

    local controller = UI.mount({
        title = opts.title,
        initialState = opts.autoStart or opts.defaultEnabled,
        hotkey = opts.hotkey,
        tooltip = opts.tooltip,
        onToggle = function(enabled, _context)
            Parry.setEnabled(enabled)
        end,
    })

    local parryConn = Parry.onStateChanged(function(enabled)
        controller.setEnabled(enabled, { silent = true, source = "parry" })
    end)

    if opts.autoStart or opts.defaultEnabled then
        Parry.enable()
    else
        controller.setEnabled(Parry.isEnabled(), { silent = true })
    end

    local api = {}

    function api.getVersion()
        return VERSION
    end

    function api.isEnabled()
        return Parry.isEnabled()
    end

    function api.setEnabled(enabled)
        controller.setEnabled(enabled)
        return Parry.isEnabled()
    end

    function api.toggle()
        controller.toggle()
        return Parry.isEnabled()
    end

    function api.configure(config)
        Parry.configure(config)
        return Parry.getConfig()
    end

    function api.getConfig()
        return Parry.getConfig()
    end

    function api.resetConfig()
        return Parry.resetConfig()
    end

    function api.setLogger(fn)
        Parry.setLogger(fn)
    end

    function api.getLastParryTime()
        return Parry.getLastParryTime()
    end

    function api.onStateChanged(callback)
        return Parry.onStateChanged(callback)
    end

    function api.onParry(callback)
        return Parry.onParry(callback)
    end

    function api.getUiController()
        return controller
    end

    function api.destroy()
        Parry.destroy()
        if parryConn then
            parryConn:Disconnect()
            parryConn = nil
        end
        controller.destroy()
    end

    return api
end
