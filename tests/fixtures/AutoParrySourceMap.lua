-- Auto-generated source map for AutoParry tests
return {
    ['loader.lua'] = [===[
-- mikkel32/AutoParry : loader.lua  (Lua / Luau)
-- Remote bootstrapper that fetches repository modules, exposes a cached
-- global require, and hands execution to the entrypoint module.

local RAW_HOST = "https://raw.githubusercontent.com"
local DEFAULT_REPO = "mikkel32/AutoParry"
local DEFAULT_BRANCH = "main"
local DEFAULT_ENTRY = "src/main.lua"

local globalSourceCache = {}

local function buildUrl(repo, branch, path)
    return ("%s/%s/%s/%s"):format(RAW_HOST, repo, branch, path)
end

local function fetch(repo, branch, path, refresh)
    local url = buildUrl(repo, branch, path)
    if not refresh and globalSourceCache[url] then
        return globalSourceCache[url]
    end

    local ok, res = pcall(game.HttpGet, game, url, true)
    if not ok then
        error(("AutoParry loader: failed to fetch %s\nReason: %s"):format(url, tostring(res)), 0)
    end

    if not refresh then
        globalSourceCache[url] = res
    end

    return res
end

local function createContext(options)
    local context = {
        repo = options.repo or DEFAULT_REPO,
        branch = options.branch or DEFAULT_BRANCH,
        entrypoint = options.entrypoint or DEFAULT_ENTRY,
        refresh = options.refresh == true,
        cache = {},
    }

    local function remoteRequire(path)
        local cacheKey = path
        if not context.refresh and context.cache[cacheKey] ~= nil then
            return context.cache[cacheKey]
        end

        local source = fetch(context.repo, context.branch, path, context.refresh)
        local chunk, err = loadstring(source, "=" .. path)
        if not chunk then
            error(("AutoParry loader: compile error in %s\n%s"):format(path, tostring(err)), 0)
        end

        local previousRequire = rawget(_G, "ARequire")
        rawset(_G, "ARequire", remoteRequire)

        local ok, result = pcall(chunk)

        rawset(_G, "ARequire", previousRequire)

        if not ok then
            error(("AutoParry loader: runtime error in %s\n%s"):format(path, tostring(result)), 0)
        end

        context.cache[cacheKey] = result
        return result
    end

    context.require = remoteRequire
    return context
end

local function bootstrap(options)
    options = options or {}
    local context = createContext(options)

    local previousRequire = rawget(_G, "ARequire")
    local previousLoader = rawget(_G, "AutoParryLoader")

    local function run()
        rawset(_G, "ARequire", context.require)
        rawset(_G, "AutoParryLoader", {
            require = context.require,
            context = context,
        })

        local mainModule = context.require(context.entrypoint)
        if typeof(mainModule) == "function" then
            return mainModule(options, context)
        end

        return mainModule
    end

    local ok, result = pcall(run)
    if not ok then
        if previousRequire == nil then
            rawset(_G, "ARequire", nil)
        else
            rawset(_G, "ARequire", previousRequire)
        end

        if previousLoader == nil then
            rawset(_G, "AutoParryLoader", nil)
        else
            rawset(_G, "AutoParryLoader", previousLoader)
        end

        error(result, 0)
    end

    return result
end

return bootstrap(...)

]===],
    ['src/main.lua'] = [===[
-- mikkel32/AutoParry : src/main.lua
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
        onToggle = function(enabled, context)
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

]===],
    ['src/core/autoparry.lua'] = [===[
-- mikkel32/AutoParry : src/core/autoparry.lua
-- Frame-driven parry engine with developer-friendly configuration hooks.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Replicated = game:GetService("ReplicatedStorage")
local Stats = game:GetService("Stats")

local Require = rawget(_G, "ARequire")
local Util = Require("src/shared/util.lua")

local function resolveLocalPlayer()
    local player = Players.LocalPlayer
    if player then
        return player
    end

    local start = os.clock()
    while not player do
        task.wait()
        player = Players.LocalPlayer
        if player or os.clock() - start > 10 then
            break
        end
    end

    assert(player, "AutoParry: LocalPlayer unavailable")
    return player
end

local function resolveParryRemote()
    local remotes = Replicated:FindFirstChild("Remotes")
    if not remotes then
        remotes = Replicated:WaitForChild("Remotes", 10)
    end

    assert(remotes, "AutoParry: ReplicatedStorage.Remotes missing")

    local remote = remotes:FindFirstChild("ParryButtonPress")
    if not remote then
        remote = remotes:WaitForChild("ParryButtonPress", 10)
    end

    assert(remote, "AutoParry: ParryButtonPress remote missing")
    return remote
end

local LocalPlayer = resolveLocalPlayer()
local ParryRemote = resolveParryRemote()

local DEFAULT_CONFIG = {
    cooldown = 0.10,
    minSpeed = 10,
    pingOffset = 0.05,
    minTTI = 0.12,
    maxTTI = 0.55,
    safeRadius = 10,
    targetHighlightName = "Highlight",
    ballsFolderName = "Balls",
}

local AutoParry = {}
local config = Util.deepCopy(DEFAULT_CONFIG)
local state = {
    enabled = false,
    connection = nil,
    lastParry = 0,
}

local stateChanged = Util.Signal.new()
local parryEvent = Util.Signal.new()
local logger = nil

local function log(...)
    if logger then
        logger(...)
    end
end

local function ballsFolder()
    return workspace:FindFirstChild(config.ballsFolderName)
end

local function characterIsTargeted(character)
    if not character then
        return false
    end

    if not config.targetHighlightName then
        return true
    end

    return character:FindFirstChild(config.targetHighlightName) ~= nil
end

local function distance(a, b)
    return (a - b).Magnitude
end

local function currentPing()
    local ok, stat = pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]
    end)
    if not ok or not stat then
        return 0
    end

    local success, value = pcall(stat.GetValue, stat)
    if not success or not value then
        return 0
    end

    return value / 1000
end

local function emitState()
    stateChanged:fire(state.enabled)
end

local function tryParry(ball)
    local now = os.clock()
    if now - state.lastParry < config.cooldown then
        return false
    end

    state.lastParry = now
    ParryRemote:FireServer()
    parryEvent:fire(ball, now)
    log("AutoParry: fired parry for", ball)
    return true
end

local function evaluateBall(ball, rootPos, ping)
    if not ball:IsA("BasePart") then
        return nil
    end

    if ball:GetAttribute("realBall") ~= true then
        return nil
    end

    local velocity = ball.AssemblyLinearVelocity
    local speed = velocity.Magnitude
    if speed < config.minSpeed then
        return nil
    end

    local toPlayer = (rootPos - ball.Position)
    if toPlayer.Magnitude == 0 then
        return 0
    end

    local toward = velocity:Dot(toPlayer.Unit)
    if toward <= 0 then
        return nil
    end

    local distanceToPlayer = distance(ball.Position, rootPos)
    if distanceToPlayer <= config.safeRadius then
        return 0
    end

    local tti = distanceToPlayer / toward
    tti = tti - (ping + config.pingOffset)

    if tti < config.minTTI or tti > config.maxTTI then
        return nil
    end

    return tti
end

local function step()
    local character = LocalPlayer and LocalPlayer.Character
    if not character or not character.PrimaryPart then
        return
    end

    if not characterIsTargeted(character) then
        return
    end

    local folder = ballsFolder()
    if not folder then
        return
    end

    local rootPos = character.PrimaryPart.Position
    local bestBall, bestTti
    local ping = currentPing()

    for _, ball in ipairs(folder:GetChildren()) do
        local tti = evaluateBall(ball, rootPos, ping)
        if tti == 0 then
            if tryParry(ball) then
                return
            end
        elseif tti and (not bestTti or tti < bestTti) then
            bestTti = tti
            bestBall = ball
        end
    end

    if bestBall then
        tryParry(bestBall)
    end
end

function AutoParry.enable()
    if state.enabled then
        return
    end

    state.enabled = true
    if not state.connection then
        state.connection = RunService.Heartbeat:Connect(step)
    end

    emitState()
end

function AutoParry.disable()
    if not state.enabled then
        return
    end

    state.enabled = false
    if state.connection then
        state.connection:Disconnect()
        state.connection = nil
    end

    emitState()
end

function AutoParry.setEnabled(enabled)
    if enabled then
        AutoParry.enable()
    else
        AutoParry.disable()
    end
end

function AutoParry.toggle()
    AutoParry.setEnabled(not state.enabled)
    return state.enabled
end

function AutoParry.isEnabled()
    return state.enabled
end

local validators = {
    cooldown = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    minSpeed = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    pingOffset = function(value)
        return typeof(value) == "number"
    end,
    minTTI = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    maxTTI = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    safeRadius = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    targetHighlightName = function(value)
        return value == nil or (typeof(value) == "string" and value ~= "")
    end,
    ballsFolderName = function(value)
        return typeof(value) == "string" and value ~= ""
    end,
}

local function applyConfigOverride(key, value)
    local validator = validators[key]
    if not validator then
        error(("AutoParry.configure: unknown option '%s'"):format(tostring(key)), 0)
    end
    if not validator(value) then
        error(("AutoParry.configure: invalid value for '%s'"):format(tostring(key)), 0)
    end

    config[key] = value
end

function AutoParry.configure(opts)
    assert(typeof(opts) == "table", "AutoParry.configure expects a table")
    for key, value in pairs(opts) do
        applyConfigOverride(key, value)
    end
    log("AutoParry: applied config", config)
    return AutoParry.getConfig()
end

function AutoParry.getConfig()
    return Util.deepCopy(config)
end

function AutoParry.resetConfig()
    config = Util.deepCopy(DEFAULT_CONFIG)
    log("AutoParry: reset config to defaults")
    return AutoParry.getConfig()
end

function AutoParry.getLastParryTime()
    return state.lastParry
end

function AutoParry.onStateChanged(callback)
    assert(typeof(callback) == "function", "AutoParry.onStateChanged expects a function")
    return stateChanged:connect(callback)
end

function AutoParry.onParry(callback)
    assert(typeof(callback) == "function", "AutoParry.onParry expects a function")
    return parryEvent:connect(callback)
end

function AutoParry.setLogger(fn)
    if fn ~= nil then
        assert(typeof(fn) == "function", "AutoParry.setLogger expects a function or nil")
    end
    logger = fn
end

function AutoParry.destroy()
    AutoParry.disable()
    stateChanged:destroy()
    parryEvent:destroy()
    stateChanged = Util.Signal.new()
    parryEvent = Util.Signal.new()
    logger = nil
    state.lastParry = 0
    AutoParry.resetConfig()
end

return AutoParry

]===],
    ['src/ui/init.lua'] = [===[
-- mikkel32/AutoParry : src/ui/init.lua
-- Lightweight, developer-friendly UI controller with toggle button + hotkey support.

local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")

local Require = rawget(_G, "ARequire")
local Util = Require("src/shared/util.lua")

local UI = {}

local Controller = {}
Controller.__index = Controller

local function ensureGuiRoot(name)
    local existing = CoreGui:FindFirstChild(name)
    if existing then
        existing:Destroy()
    end

    local sg = Instance.new("ScreenGui")
    sg.Name = name
    sg.ResetOnSpawn = false
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    sg.Parent = CoreGui
    return sg
end

local function makeFrame(parent)
    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(0, 200, 0, 64)
    frame.Position = UDim2.new(0, 32, 0, 180)
    frame.BackgroundColor3 = Color3.fromRGB(24, 24, 24)
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Draggable = true
    frame.Parent = parent
    return frame
end

local function makeTitle(frame, title)
    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, -80, 1, -8)
    label.Position = UDim2.new(0, 12, 0, 4)
    label.BackgroundTransparency = 1
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Top
    label.Text = tostring(title or "AutoParry")
    label.Font = Enum.Font.GothamBold
    label.TextSize = 18
    label.TextColor3 = Color3.fromRGB(235, 235, 235)
    label.Parent = frame
    return label
end

local function makeButton(frame)
    local button = Instance.new("TextButton")
    button.Name = "ToggleButton"
    button.Size = UDim2.new(0, 72, 0, 30)
    button.Position = UDim2.new(1, -88, 0.5, -15)
    button.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
    button.AutoButtonColor = true
    button.Text = "OFF"
    button.Font = Enum.Font.GothamBold
    button.TextSize = 16
    button.TextColor3 = Color3.fromRGB(255, 255, 255)
    button.Parent = frame
    return button
end

local function makeHotkeyLabel(frame, hotkeyText)
    if not hotkeyText or hotkeyText == "" then
        return nil
    end

    local label = Instance.new("TextLabel")
    label.Name = "HotkeyLabel"
    label.Size = UDim2.new(1, -24, 0, 16)
    label.Position = UDim2.new(0, 12, 1, -20)
    label.BackgroundTransparency = 1
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = hotkeyText
    label.Font = Enum.Font.Gotham
    label.TextSize = 12
    label.TextColor3 = Color3.fromRGB(200, 200, 200)
    label.Parent = frame
    return label
end

local function makeTooltip(frame, text)
    if not text or text == "" then
        return nil
    end

    local label = Instance.new("TextLabel")
    label.Name = "Tooltip"
    label.Size = UDim2.new(1, -24, 0, 16)
    label.Position = UDim2.new(0, 12, 1, -4)
    label.BackgroundTransparency = 1
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Bottom
    label.Text = text
    label.Font = Enum.Font.Gotham
    label.TextSize = 12
    label.TextColor3 = Color3.fromRGB(160, 160, 160)
    label.Parent = frame
    return label
end

local function formatHotkeyDisplay(hotkey)
    if typeof(hotkey) == "EnumItem" then
        return hotkey.Name
    end

    if typeof(hotkey) == "table" then
        local parts = {}
        if hotkey.modifiers then
            for _, mod in ipairs(hotkey.modifiers) do
                table.insert(parts, mod.Name)
            end
        end
        if hotkey.key then
            table.insert(parts, hotkey.key.Name)
        end
        if #parts > 0 then
            return table.concat(parts, " + ")
        end
    end

    if typeof(hotkey) == "string" and hotkey ~= "" then
        return hotkey
    end

    return nil
end

local function parseHotkey(hotkey)
    if not hotkey then
        return nil
    end

    if typeof(hotkey) == "EnumItem" then
        return { key = hotkey, modifiers = {} }
    end

    if typeof(hotkey) == "table" then
        local key = hotkey.key or hotkey.Key
        if typeof(key) == "EnumItem" then
            local modifiers = hotkey.modifiers or hotkey.Modifiers or {}
            return {
                key = key,
                modifiers = modifiers,
                allowGameProcessed = hotkey.allowGameProcessed == true,
            }
        end
    end

    if typeof(hotkey) == "string" then
        local upper = hotkey:upper()
        local enumValue = Enum.KeyCode[upper]
        if enumValue then
            return { key = enumValue, modifiers = {} }
        end
    end

    return nil
end

local function matchesHotkey(input, descriptor)
    if not descriptor then
        return false
    end

    if input.KeyCode ~= descriptor.key then
        return false
    end

    if descriptor.modifiers then
        for _, modifier in ipairs(descriptor.modifiers) do
            if not UserInputService:IsKeyDown(modifier) then
                return false
            end
        end
    end

    return true
end

function Controller:setEnabled(enabled, context)
    if self._destroyed then
        return self._enabled
    end

    enabled = not not enabled
    context = context or {}

    if self._enabled == enabled then
        return self._enabled
    end

    self._enabled = enabled
    self.button.Text = enabled and "ON" or "OFF"
    self.button.BackgroundColor3 = enabled and Color3.fromRGB(0, 160, 80) or Color3.fromRGB(60, 60, 60)

    if not context.silent and typeof(self._onToggle) == "function" then
        task.spawn(self._onToggle, enabled, context)
    end

    if self._changed then
        self._changed:fire(enabled, context)
    end

    return self._enabled
end

function Controller:toggle()
    return self:setEnabled(not self._enabled)
end

function Controller:isEnabled()
    return self._enabled
end

function Controller:getGui()
    return self.gui
end

function Controller:onChanged(callback)
    assert(typeof(callback) == "function", "UI.onChanged expects a function")
    return self._changed:connect(callback)
end

function Controller:destroy()
    if self._destroyed then
        return
    end

    self._destroyed = true
    for _, connection in ipairs(self._connections) do
        connection:Disconnect()
    end
    self._connections = {}
    if self._hotkeyConnection then
        self._hotkeyConnection:Disconnect()
        self._hotkeyConnection = nil
    end
    if self.gui then
        self.gui:Destroy()
        self.gui = nil
    end
    if self._changed then
        self._changed:destroy()
        self._changed = nil
    end
    self.button = nil
end

function UI.mount(options)
    options = options or {}
    local gui = ensureGuiRoot("AutoParryUI")
    local frame = makeFrame(gui)
    makeTitle(frame, options.title or "AutoParry")
    local button = makeButton(frame)

    local controller = setmetatable({
        gui = gui,
        button = button,
        _enabled = false,
        _onToggle = options.onToggle,
        _connections = {},
        _changed = Util.Signal.new(),
    }, Controller)

    local hotkeyDescriptor = parseHotkey(options.hotkey)
    local hotkeyDisplay = formatHotkeyDisplay(hotkeyDescriptor and hotkeyDescriptor.key and hotkeyDescriptor or options.hotkey)
    makeHotkeyLabel(frame, hotkeyDisplay and ("Hotkey: %s"):format(hotkeyDisplay) or nil)
    makeTooltip(frame, options.tooltip)

    table.insert(controller._connections, button.MouseButton1Click:Connect(function()
        controller:toggle()
    end))

    if hotkeyDescriptor then
        controller._hotkeyConnection = UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
            if gameProcessedEvent and hotkeyDescriptor.allowGameProcessed ~= true then
                return
            end
            if matchesHotkey(input, hotkeyDescriptor) then
                controller:toggle()
            end
        end)
        table.insert(controller._connections, controller._hotkeyConnection)
    end

    controller:setEnabled(options.initialState == true, { silent = true })

    return controller
end

return UI

]===],
    ['src/shared/util.lua'] = [===[
-- mikkel32/AutoParry : src/shared/util.lua
-- Shared helpers for table utilities and lightweight signals.

local Util = {}

local Signal = {}
Signal.__index = Signal

function Signal.new()
    return setmetatable({ _connections = {}, _nextId = 0 }, Signal)
end

function Signal:connect(handler)
    assert(typeof(handler) == "function", "Signal:connect expects a function")
    if not self._connections then
        local stub = { Disconnect = function() end }
        stub.disconnect = stub.Disconnect
        return stub
    end

    self._nextId = self._nextId + 1
    local id = self._nextId
    self._connections[id] = handler

    local connection = { _signal = self, _id = id }

    function connection:Disconnect()
        local signal = rawget(self, "_signal")
        if signal and signal._connections then
            signal._connections[self._id] = nil
        end
        self._signal = nil
    end

    connection.disconnect = connection.Disconnect

    return connection
end

function Signal:fire(...)
    if not self._connections then
        return
    end

    for _, handler in pairs(self._connections) do
        task.spawn(handler, ...)
    end
end

function Signal:destroy()
    self._connections = nil
end

Util.Signal = Signal

function Util.deepCopy(value)
    if typeof(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, val in pairs(value) do
        copy[Util.deepCopy(key)] = Util.deepCopy(val)
    end
    return copy
end

function Util.merge(into, from)
    assert(typeof(into) == "table", "Util.merge: into must be a table")
    if typeof(from) ~= "table" then
        return into
    end

    for key, value in pairs(from) do
        into[key] = value
    end

    return into
end

return Util

]===],
    ['tests/fixtures/ui_snapshot.json'] = [===[
{
  "screenGui": {
    "name": "AutoParryUI",
    "resetOnSpawn": false,
    "zIndexBehavior": "Sibling",
    "frame": {
      "size": {
        "x": { "scale": 0, "offset": 200 },
        "y": { "scale": 0, "offset": 64 }
      },
      "position": {
        "x": { "scale": 0, "offset": 32 },
        "y": { "scale": 0, "offset": 180 }
      },
      "backgroundColor3": { "r": 24, "g": 24, "b": 24 },
      "borderSizePixel": 0,
      "active": true,
      "draggable": true,
      "title": {
        "text": "Snapshot Title",
        "font": "GothamBold",
        "textSize": 18,
        "textColor3": { "r": 235, "g": 235, "b": 235 },
        "size": {
          "x": { "scale": 1, "offset": -80 },
          "y": { "scale": 1, "offset": -8 }
        },
        "position": {
          "x": { "scale": 0, "offset": 12 },
          "y": { "scale": 0, "offset": 4 }
        },
        "textXAlignment": "Left",
        "textYAlignment": "Top",
        "backgroundTransparency": 1
      },
      "button": {
        "name": "ToggleButton",
        "text": "OFF",
        "font": "GothamBold",
        "textSize": 16,
        "textColor3": { "r": 255, "g": 255, "b": 255 },
        "size": {
          "x": { "scale": 0, "offset": 72 },
          "y": { "scale": 0, "offset": 30 }
        },
        "position": {
          "x": { "scale": 1, "offset": -88 },
          "y": { "scale": 0.5, "offset": -15 }
        },
        "backgroundColor3": { "r": 60, "g": 60, "b": 60 },
        "autoButtonColor": true
      },
      "hotkeyLabel": {
        "text": "Hotkey: G",
        "font": "Gotham",
        "textSize": 12,
        "textColor3": { "r": 200, "g": 200, "b": 200 },
        "size": {
          "x": { "scale": 1, "offset": -24 },
          "y": { "scale": 0, "offset": 16 }
        },
        "position": {
          "x": { "scale": 0, "offset": 12 },
          "y": { "scale": 1, "offset": -20 }
        },
        "textXAlignment": "Left",
        "textYAlignment": "Center",
        "backgroundTransparency": 1
      },
      "tooltip": {
        "text": "Tap to toggle",
        "font": "Gotham",
        "textSize": 12,
        "textColor3": { "r": 160, "g": 160, "b": 160 },
        "size": {
          "x": { "scale": 1, "offset": -24 },
          "y": { "scale": 0, "offset": 16 }
        },
        "position": {
          "x": { "scale": 0, "offset": 12 },
          "y": { "scale": 1, "offset": -4 }
        },
        "textXAlignment": "Left",
        "textYAlignment": "Bottom",
        "backgroundTransparency": 1
      }
    }
  }
}

]===],
    ['tests/perf/config.lua'] = [===[
return {
    -- Number of frames to run before samples are collected.
    warmupFrames = 8,

    -- Number of samples collected for each ball population target.
    samplesPerBatch = 120,

    -- Simulated frame duration passed to the heartbeat step.
    frameDuration = 1 / 120,

    -- Populations of synthetic balls to evaluate during the benchmark.
    ballPopulations = { 0, 16, 32, 64, 96, 128 },

    -- Ball spawn tuning for the synthetic workload.
    ballSpawn = {
        baseDistance = 28,
        distanceJitter = 7,
        speedBase = 120,
        speedJitter = 24,
    },

    -- Regression thresholds in seconds. If either metric exceeds the value the
    -- benchmark fails the current run.
    thresholds = {
        average = 0.0016,
        p95 = 0.0035,
    },
}
]===],
}
