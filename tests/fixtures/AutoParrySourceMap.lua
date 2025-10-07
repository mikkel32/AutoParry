-- Auto-generated source map for AutoParry tests
return {
    ['src/core/autoparry.lua'] = [===[
-- mikkel32/AutoParry : src/core/autoparry.lua
-- selene: allow(global_usage)
-- Frame-driven parry engine with developer-friendly configuration hooks.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Replicated = game:GetService("ReplicatedStorage")
local Stats = game:GetService("Stats")

local Require = rawget(_G, "ARequire")
local Util = Require("src/shared/util.lua")

local function clone(tbl)
    return Util.deepCopy(tbl)
end

local initStatus = Util.Signal.new()
local initProgress = { stage = "waiting-player" }

local function updateInitProgress(stage, details)
    for key in pairs(initProgress) do
        initProgress[key] = nil
    end

    initProgress.stage = stage

    if details then
        for key, value in pairs(details) do
            initProgress[key] = value
        end
    end

    initStatus:fire(clone(initProgress))
end

local function resolveLocalPlayer(report)
    report("waiting-player", { elapsed = 0 })

    local player = Players.LocalPlayer
    if player then
        return player
    end

    local start = os.clock()

    while not player do
        local elapsed = os.clock() - start
        if elapsed >= 10 then
            report("timeout", {
                stage = "waiting-player",
                elapsed = elapsed,
                reason = "local-player",
            })
            break
        end

        report("waiting-player", { elapsed = elapsed })
        task.wait()
        player = Players.LocalPlayer
    end

    assert(player, "AutoParry: LocalPlayer unavailable")
    return player
end

local function resolveParryRemote(report)
    report("waiting-remotes", { target = "folder", elapsed = 0 })

    local remotes = Replicated:FindFirstChild("Remotes")
    if not remotes then
        local start = os.clock()
        while not remotes do
            local elapsed = os.clock() - start
            if elapsed >= 10 then
                report("timeout", {
                    stage = "waiting-remotes",
                    target = "folder",
                    elapsed = elapsed,
                    reason = "remotes-folder",
                })
                break
            end

            report("waiting-remotes", {
                target = "folder",
                elapsed = elapsed,
            })
            task.wait()
            remotes = Replicated:FindFirstChild("Remotes")
        end
    end

    assert(remotes, "AutoParry: ReplicatedStorage.Remotes missing")

    report("waiting-remotes", { target = "remote", elapsed = 0 })

    local remote = remotes:FindFirstChild("ParryButtonPress")
    if not remote then
        local start = os.clock()
        while not remote do
            local elapsed = os.clock() - start
            if elapsed >= 10 then
                report("timeout", {
                    stage = "waiting-remotes",
                    target = "remote",
                    elapsed = elapsed,
                    reason = "parry-remote",
                })
                break
            end

            report("waiting-remotes", {
                target = "remote",
                elapsed = elapsed,
            })
            task.wait()
            remote = remotes:FindFirstChild("ParryButtonPress")
        end
    end

    assert(remote, "AutoParry: ParryButtonPress remote missing")
    return remote
end

local LocalPlayer = nil
local ParryRemote = nil

local initialization = {
    started = false,
    completed = false,
    error = nil,
    token = 0,
}

local function beginInitialization()
    initialization.token += 1
    local token = initialization.token
    initialization.started = true
    initialization.completed = false
    initialization.error = nil

    updateInitProgress("waiting-player", { elapsed = 0 })

    local initStart = os.clock()

    task.spawn(function()
        local function report(stage, details)
            if initialization.token ~= token then
                return
            end

            updateInitProgress(stage, details)
        end

        local ok, player, remoteOrError = pcall(function()
            local player = resolveLocalPlayer(report)
            if initialization.token ~= token then
                return nil, nil
            end

            local remote = resolveParryRemote(report)
            return player, remote
        end)

        if initialization.token ~= token then
            return
        end

        if ok then
            if not player or not remoteOrError then
                return
            end

            LocalPlayer = player
            ParryRemote = remoteOrError
            initialization.completed = true
            report("ready", { elapsed = os.clock() - initStart })
        else
            initialization.error = player
        end
    end)
end

local function ensureInitialization()
    if initialization.started then
        return
    end

    beginInitialization()
end

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

local function waitForReady()
    ensureInitialization()

    if initialization.completed then
        return true
    end

    if initialization.error then
        error(initialization.error, 0)
    end

    while true do
        task.wait()

        if initialization.completed then
            return true
        end

        if initialization.error then
            error(initialization.error, 0)
        end
    end
end

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

    waitForReady()

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

function AutoParry.onInitStatus(callback)
    assert(typeof(callback) == "function", "AutoParry.onInitStatus expects a function")

    ensureInitialization()

    local connection = initStatus:connect(callback)
    callback(clone(initProgress))
    return connection
end

function AutoParry.getInitProgress()
    ensureInitialization()
    return clone(initProgress)
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
    initStatus:destroy()

    stateChanged = Util.Signal.new()
    parryEvent = Util.Signal.new()
    initStatus = Util.Signal.new()
    logger = nil
    state.lastParry = 0
    AutoParry.resetConfig()

    LocalPlayer = nil
    ParryRemote = nil

    for key in pairs(initProgress) do
        initProgress[key] = nil
    end
    initProgress.stage = "waiting-player"

    initialization.started = false
    initialization.completed = false
    initialization.error = nil

    beginInitialization()
end

ensureInitialization()

return AutoParry

]===],
    ['src/main.lua'] = [===[
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

    function connection.Disconnect(conn)
        local signal = rawget(conn, "_signal")
        if signal and signal._connections then
            signal._connections[conn._id] = nil
        end
        conn._signal = nil
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
    ['src/ui/init.lua'] = [===[
-- mikkel32/AutoParry : src/ui/init.lua
-- selene: allow(global_usage)
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

local lowerKeyCodeLookup

local function resolveKeyCodeFromString(name)
    if typeof(name) ~= "string" then
        return nil
    end

    local trimmed = name:match("^%s*(.-)%s*$")
    if trimmed == "" then
        return nil
    end

    local enumValue = Enum.KeyCode[trimmed]
    if enumValue then
        return enumValue
    end

    if not lowerKeyCodeLookup then
        lowerKeyCodeLookup = {}
        for _, item in ipairs(Enum.KeyCode:GetEnumItems()) do
            lowerKeyCodeLookup[item.Name:lower()] = item
        end
    end

    return lowerKeyCodeLookup[trimmed:lower()]
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
        if typeof(key) ~= "EnumItem" then
            key = resolveKeyCodeFromString(key)
        end

        if typeof(key) == "EnumItem" then
            local parsedModifiers = {}
            local modifiers = hotkey.modifiers or hotkey.Modifiers or {}

            if typeof(modifiers) == "table" then
                for _, modifier in ipairs(modifiers) do
                    if typeof(modifier) == "EnumItem" then
                        table.insert(parsedModifiers, modifier)
                    else
                        local resolvedModifier = resolveKeyCodeFromString(modifier)
                        if typeof(resolvedModifier) == "EnumItem" then
                            table.insert(parsedModifiers, resolvedModifier)
                        end
                    end
                end
            end

            return {
                key = key,
                modifiers = parsedModifiers,
                allowGameProcessed = hotkey.allowGameProcessed == true,
            }
        end
    end

    if typeof(hotkey) == "string" then
        local enumValue = resolveKeyCodeFromString(hotkey)

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
    ['loader.lua'] = [===[
-- mikkel32/AutoParry : loader.lua  (Lua / Luau)
-- selene: allow(global_usage)
-- Remote bootstrapper that fetches repository modules, exposes a cached
-- global require, and hands execution to the entrypoint module.

local RAW_HOST = "https://raw.githubusercontent.com"
local DEFAULT_REPO = "mikkel32/AutoParry"
local DEFAULT_BRANCH = "main"
local DEFAULT_ENTRY = "src/main.lua"

local globalSourceCache = {}

local function newSignal()
    local listeners = {}

    local signal = {}

    function signal:Connect(callback)
        assert(type(callback) == "function", "Signal connection requires a callback")

        local connection = {
            Connected = true,
        }

        listeners[connection] = callback

        function connection:Disconnect()
            if not self.Connected then
                return
            end

            self.Connected = false
            listeners[self] = nil
        end

        return connection
    end

    function signal:Fire(...)
        local snapshot = {}
        local count = 0

        for connection, callback in pairs(listeners) do
            if connection.Connected then
                count = count + 1
                snapshot[count] = callback
            end
        end

        for i = 1, count do
            local callback = snapshot[i]
            callback(...)
        end
    end

    return signal
end

local function copyTable(source)
    local target = {}
    for key, value in pairs(source) do
        target[key] = value
    end
    return target
end

local function emit(signal, basePayload, overrides)
    if not signal then
        return
    end

    local payload = copyTable(basePayload)

    if overrides then
        for key, value in pairs(overrides) do
            payload[key] = value
        end
    end

    signal:Fire(payload)
end

local function updateAllComplete(context)
    if context.progress.started == context.progress.finished + context.progress.failed then
        context.signals.onAllComplete:Fire(context.progress)
    end
end

local function buildUrl(repo, branch, path)
    return ("%s/%s/%s/%s"):format(RAW_HOST, repo, branch, path)
end

local function fetch(repo, branch, path, refresh)
    local url = buildUrl(repo, branch, path)
    if not refresh and globalSourceCache[url] then
        return globalSourceCache[url], true
    end

    local ok, res = pcall(game.HttpGet, game, url, true)
    if not ok then
        error(("AutoParry loader: failed to fetch %s\nReason: %s"):format(url, tostring(res)), 0)
    end

    if not refresh then
        globalSourceCache[url] = res
    end

    return res, false
end

local function createContext(options)
    local context = {
        repo = options.repo or DEFAULT_REPO,
        branch = options.branch or DEFAULT_BRANCH,
        entrypoint = options.entrypoint or DEFAULT_ENTRY,
        refresh = options.refresh == true,
        cache = {},
    }

    context.progress = {
        started = 0,
        finished = 0,
        failed = 0,
    }

    context.signals = {
        onFetchStarted = newSignal(),
        onFetchCompleted = newSignal(),
        onFetchFailed = newSignal(),
        onAllComplete = newSignal(),
    }

    local function remoteRequire(path)
        local cacheKey = path
        local url = buildUrl(context.repo, context.branch, path)
        local baseEvent = {
            path = path,
            url = url,
            refresh = context.refresh,
        }

        local function start(overrides)
            context.progress.started = context.progress.started + 1
            emit(context.signals.onFetchStarted, baseEvent, overrides)
        end

        local function succeed(overrides)
            context.progress.finished = context.progress.finished + 1
            emit(context.signals.onFetchCompleted, baseEvent, overrides)
            updateAllComplete(context)
        end

        local function fail(message, overrides)
            context.progress.failed = context.progress.failed + 1
            emit(context.signals.onFetchFailed, baseEvent, overrides)
            updateAllComplete(context)
            error(message, 0)
        end

        if not context.refresh and context.cache[cacheKey] ~= nil then
            local cachedResult = context.cache[cacheKey]
            start({
                status = "started",
                fromCache = true,
                cache = "context",
            })
            succeed({
                status = "completed",
                fromCache = true,
                cache = "context",
                result = cachedResult,
            })
            return cachedResult
        end

        local willUseGlobalCache = not context.refresh and globalSourceCache[url] ~= nil

        start({
            status = "started",
            fromCache = willUseGlobalCache,
            cache = willUseGlobalCache and "global" or nil,
        })

        local fetchOk, fetchResult, fetchFromCache = pcall(fetch, context.repo, context.branch, path, context.refresh)
        if not fetchOk then
            local message = fetchResult
            fail(message, {
                status = "failed",
                fromCache = willUseGlobalCache,
                cache = willUseGlobalCache and "global" or nil,
                error = message,
            })
        end

        local source = fetchResult
        local chunk, err = loadstring(source, "=" .. path)
        if not chunk then
            local message = ("AutoParry loader: compile error in %s\n%s"):format(path, tostring(err))
            fail(message, {
                status = "failed",
                fromCache = fetchFromCache or false,
                cache = fetchFromCache and "global" or nil,
                error = message,
            })
        end

        local previousRequire = rawget(_G, "ARequire")
        rawset(_G, "ARequire", remoteRequire)

        local ok, result = pcall(chunk)

        rawset(_G, "ARequire", previousRequire)

        if not ok then
            local message = ("AutoParry loader: runtime error in %s\n%s"):format(path, tostring(result))
            fail(message, {
                status = "failed",
                fromCache = fetchFromCache or false,
                cache = fetchFromCache and "global" or nil,
                error = message,
            })
        end

        context.cache[cacheKey] = result

        succeed({
            status = "completed",
            fromCache = fetchFromCache or false,
            cache = fetchFromCache and "global" or nil,
            result = result,
        })

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
            signals = context.signals,
            progress = context.progress,
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
}
