-- Auto-generated source map for AutoParry tests
return {
    ['src/core/autoparry.lua'] = [===[
-- mikkel32/AutoParry : src/core/autoparry.lua
-- selene: allow(global_usage)
-- Auto-parry implementation that mirrors the "Auto-Parry (F-Key Proximity)" logic
-- shared by the user: it presses the local "F" key via VirtualInputManager when a
-- tracked projectile is about to reach the player. The module keeps the public
-- AutoParry API that the rest of the experience relies on (configure, signals,
-- destroy, etc.) while swapping the internal behaviour for the requested
-- proximity/TTI based approach.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Stats = game:FindService("Stats")
local VirtualInputManager = game:GetService("VirtualInputManager")

local Require = rawget(_G, "ARequire")
local Util = Require and Require("src/shared/util.lua") or require(script.Parent.Parent.shared.util)

local Signal = Util.Signal

local DEFAULT_CONFIG = {
    -- legacy configuration keys kept for compatibility with the public API
    cooldown = 0.10,
    minSpeed = 10,
    pingOffset = 0,
    minTTI = 0.12,
    maxTTI = 0.55,
    safeRadius = 10,
    targetHighlightName = "Highlight",
    ballsFolderName = "Balls",
    playerTimeout = 10,
    remotesTimeout = 10,
    parryRemoteTimeout = 10,
    ballsFolderTimeout = 5,
    verificationRetryInterval = 0,

    -- new configuration exposed by the requested logic
    proximityStuds = 5,
    useTTIWindow = true,
    staticTTIWindow = 0.50,
    dynamicWindow = true,
    ballSpeedCheck = true,
    pingBased = true,
    pingBasedOffset = 0,
    fHoldTime = 0.06,
}

local TARGET_WINDOW_BANDS = {
    { threshold = 160, window = 0.22 },
    { threshold = 120, window = 0.28 },
    { threshold = 90, window = 0.35 },
    { threshold = 60, window = 0.45 },
    { threshold = 0, window = 0.58 },
}

local function getGlobalTable()
    local ok, env = pcall(function()
        if typeof(getgenv) == "function" then
            return getgenv()
        end
        return nil
    end)

    if ok and typeof(env) == "table" then
        return env
    end

    _G.__AUTO_PARRY_GLOBAL = _G.__AUTO_PARRY_GLOBAL or {}
    return _G.__AUTO_PARRY_GLOBAL
end

local GlobalEnv = getGlobalTable()
GlobalEnv.Paws = GlobalEnv.Paws or {}

local config = Util.deepCopy(DEFAULT_CONFIG)
local state = {
    enabled = false,
    connection = nil,
    lastParry = 0,
    lastSuccess = 0,
    lastBroadcast = 0,
}

local initialization = {
    started = false,
    completed = false,
    destroyed = false,
    error = nil,
}

local initStatus = Signal.new()
local initProgress = { stage = "waiting-player" }
local stateChanged = Signal.new()
local parryEvent = Signal.new()
local parrySuccessSignal = Signal.new()
local parryBroadcastSignal = Signal.new()

local LocalPlayer: Player?
local Character: Model?
local RootPart: BasePart?
local Humanoid: Humanoid?
local BallsFolder: Instance?

local UiRoot: ScreenGui?
local ToggleButton: TextButton?
local RemoveButton: TextButton?
local StatusLabel: TextLabel?
local BallHighlight: Highlight?
local BallBillboard: BillboardGui?
local BallStatsLabel: TextLabel?

local loopConnection: RBXScriptConnection?
local humanoidDiedConnection: RBXScriptConnection?
local characterAddedConnection: RBXScriptConnection?
local characterRemovingConnection: RBXScriptConnection?

local lastFiredTime = 0
local trackedBall: BasePart?

local AutoParry

local function cloneTable(tbl)
    return Util.deepCopy(tbl)
end

local function applyInitStatus(update)
    for key in pairs(initProgress) do
        if update[key] == nil and key ~= "stage" then
            initProgress[key] = initProgress[key]
        end
    end

    for key, value in pairs(update) do
        initProgress[key] = value
    end

    initStatus:fire(cloneTable(initProgress))
end

local function setStage(stage, extra)
    local payload = { stage = stage }
    if typeof(extra) == "table" then
        for key, value in pairs(extra) do
            payload[key] = value
        end
    end
    applyInitStatus(payload)
end

local function formatToggleText(enabled)
    return enabled and "Auto-Parry: ON" or "Auto-Parry: OFF"
end

local function formatToggleColor(enabled)
    if enabled then
        return Color3.fromRGB(0, 120, 0)
    end
    return Color3.fromRGB(40, 40, 40)
end

local function syncGlobalSettings()
    local settings = GlobalEnv.Paws
    if typeof(settings) ~= "table" then
        settings = {}
        GlobalEnv.Paws = settings
    end

    settings.AutoParry = state.enabled
    settings.ProximityStuds = config.proximityStuds
    settings.UseTTIWindow = config.useTTIWindow
    settings.StaticTTIWindow = config.staticTTIWindow
    settings.DynamicWindow = config.dynamicWindow
    settings.BallSpeedCheck = config.ballSpeedCheck
    settings.PingBased = config.pingBased
    settings.PingBasedOffset = config.pingBasedOffset
    settings.FHoldTime = config.fHoldTime
    settings.AntiSpam = config.cooldown
end

local function updateToggleButton()
    if not ToggleButton then
        return
    end

    ToggleButton.Text = formatToggleText(state.enabled)
    ToggleButton.BackgroundColor3 = formatToggleColor(state.enabled)
end

local function updateStatusLabel(lines)
    if not StatusLabel then
        return
    end

    if typeof(lines) == "table" then
        StatusLabel.Text = table.concat(lines, "\n")
    else
        StatusLabel.Text = tostring(lines)
    end
end

local function clearBallVisuals()
    if BallHighlight then
        BallHighlight.Enabled = false
        BallHighlight.Adornee = nil
    end
    if BallBillboard then
        BallBillboard.Enabled = false
        BallBillboard.Adornee = nil
    end
    trackedBall = nil
end

local function ensureUi()
    if UiRoot or not LocalPlayer then
        return
    end

    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not playerGui then
        playerGui = LocalPlayer:WaitForChild("PlayerGui", 5)
    end

    if not playerGui then
        return
    end

    local gui = Instance.new("ScreenGui")
    gui.Name = "AutoParryF_UI"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.Parent = playerGui

    local toggleBtn = Instance.new("TextButton")
    toggleBtn.Size = UDim2.fromOffset(180, 40)
    toggleBtn.Position = UDim2.fromOffset(10, 10)
    toggleBtn.BackgroundColor3 = formatToggleColor(state.enabled)
    toggleBtn.TextColor3 = Color3.new(1, 1, 1)
    toggleBtn.Font = Enum.Font.GothamBold
    toggleBtn.TextSize = 20
    toggleBtn.BorderSizePixel = 0
    toggleBtn.Text = formatToggleText(state.enabled)
    toggleBtn.Parent = gui
    toggleBtn.MouseButton1Click:Connect(function()
        AutoParry.toggle()
    end)

    local removeBtn = Instance.new("TextButton")
    removeBtn.Size = UDim2.fromOffset(180, 30)
    removeBtn.Position = UDim2.fromOffset(10, 54)
    removeBtn.BackgroundColor3 = Color3.fromRGB(120, 0, 0)
    removeBtn.TextColor3 = Color3.new(1, 1, 1)
    removeBtn.Font = Enum.Font.GothamBold
    removeBtn.TextSize = 18
    removeBtn.BorderSizePixel = 0
    removeBtn.Text = "REMOVE Auto-Parry"
    removeBtn.Parent = gui
    removeBtn.MouseButton1Click:Connect(function()
        AutoParry.destroy()
        GlobalEnv.Paws = nil
    end)

    local status = Instance.new("TextLabel")
    status.Size = UDim2.fromOffset(320, 80)
    status.Position = UDim2.fromOffset(10, 90)
    status.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
    status.BackgroundTransparency = 0.25
    status.TextColor3 = Color3.new(1, 1, 1)
    status.TextXAlignment = Enum.TextXAlignment.Left
    status.TextYAlignment = Enum.TextYAlignment.Top
    status.Font = Enum.Font.Gotham
    status.TextSize = 14
    status.BorderSizePixel = 0
    status.Text = "Auto-Parry F loaded."
    status.Parent = gui

    local highlight = Instance.new("Highlight")
    highlight.Name = "BallHighlight"
    highlight.FillColor = Color3.fromRGB(0, 255, 0)
    highlight.OutlineColor = Color3.fromRGB(0, 255, 0)
    highlight.FillTransparency = 0.6
    highlight.OutlineTransparency = 0
    highlight.Enabled = false
    highlight.Parent = gui

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "BallStats"
    billboard.Size = UDim2.new(0, 220, 0, 60)
    billboard.StudsOffset = Vector3.new(0, 3.5, 0)
    billboard.AlwaysOnTop = true
    billboard.Enabled = false
    billboard.Parent = gui

    local statsLabel = Instance.new("TextLabel")
    statsLabel.Size = UDim2.fromScale(1, 1)
    statsLabel.BackgroundTransparency = 0.25
    statsLabel.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    statsLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    statsLabel.TextStrokeTransparency = 0.2
    statsLabel.Font = Enum.Font.GothamBold
    statsLabel.TextSize = 16
    statsLabel.Text = ""
    statsLabel.Parent = billboard

    UiRoot = gui
    ToggleButton = toggleBtn
    RemoveButton = removeBtn
    StatusLabel = status
    BallHighlight = highlight
    BallBillboard = billboard
    BallStatsLabel = statsLabel

    updateToggleButton()
    updateStatusLabel({ "Auto-Parry F", "Status: initializing" })
end

local function destroyUi()
    clearBallVisuals()
    if UiRoot then
        UiRoot:Destroy()
    end
    UiRoot = nil
    ToggleButton = nil
    RemoveButton = nil
    StatusLabel = nil
    BallHighlight = nil
    BallBillboard = nil
    BallStatsLabel = nil
end

local function getPingTime()
    if not Stats then
        return 0
    end

    local okStat, stat = pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]
    end)

    if not okStat or not stat then
        return 0
    end

    local okValue, value = pcall(stat.GetValue, stat)
    if not okValue or not value then
        return 0
    end

    return value / 1000
end

local function isTargetingMe()
    if not Character then
        return false
    end

    local highlightName = config.targetHighlightName
    if not highlightName or highlightName == "" then
        return true
    end

    local ok, result = pcall(function()
        return Character:FindFirstChild(highlightName)
    end)

    return ok and result ~= nil
end

local function findRealBall(folder)
    if not folder then
        return nil
    end

    local best
    for _, child in ipairs(folder:GetChildren()) do
        if child:IsA("BasePart") then
            local okAttr, isReal = pcall(child.GetAttribute, child, "realBall")
            if okAttr and isReal == true then
                return child
            elseif not best and child.Name == "Ball" then
                best = child
            end
        end
    end

    return best
end

local function getDynamicWindow(speed)
    for _, entry in ipairs(TARGET_WINDOW_BANDS) do
        if speed > entry.threshold then
            return entry.window
        end
    end
    return TARGET_WINDOW_BANDS[#TARGET_WINDOW_BANDS].window
end

local function ensureBallsFolder()
    local name = config.ballsFolderName
    if BallsFolder and BallsFolder.Parent then
        if BallsFolder.Name == name then
            return BallsFolder
        end
    end

    local folder = Workspace:FindFirstChild(name)
    if folder then
        BallsFolder = folder
        return folder
    end

    local ok, result = pcall(function()
        return Workspace:WaitForChild(name, 0.5)
    end)

    if ok then
        BallsFolder = result
    end

    return BallsFolder
end

local function setBallVisuals(ball, text)
    if BallHighlight then
        BallHighlight.Adornee = ball
        BallHighlight.Enabled = ball ~= nil
    end
    if BallBillboard then
        BallBillboard.Adornee = ball
        BallBillboard.Enabled = ball ~= nil
    end
    if BallStatsLabel then
        BallStatsLabel.Text = text or ""
    end
    trackedBall = ball
end

local function sendKeyPress(ball)
    local now = os.clock()
    local cooldown = config.cooldown or 0.1
    if now - lastFiredTime < cooldown then
        return false
    end

    lastFiredTime = now
    state.lastParry = now

    task.spawn(function()
        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.F, false, game)
        task.wait(config.fHoldTime or 0.06)
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.F, false, game)
    end)

    parryEvent:fire(ball, now)
    return true
end

local function updateCharacter(character)
    Character = character
    RootPart = nil
    Humanoid = nil

    if humanoidDiedConnection then
        humanoidDiedConnection:Disconnect()
        humanoidDiedConnection = nil
    end

    if not character then
        return
    end

    RootPart = character:FindFirstChild("HumanoidRootPart")
    if not RootPart then
        local ok, root = pcall(function()
            return character:WaitForChild("HumanoidRootPart", 5)
        end)
        if ok then
            RootPart = root
        end
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid then
        local ok, value = pcall(function()
            return character:WaitForChild("Humanoid", 5)
        end)
        if ok then
            humanoid = value
        end
    end

    Humanoid = humanoid

    if humanoid then
        humanoidDiedConnection = humanoid.Died:Connect(function()
            AutoParry.disable()
            destroyUi()
            GlobalEnv.Paws = nil
        end)
    end
end

local function handleCharacterAdded(character)
    updateCharacter(character)
end

local function handleCharacterRemoving()
    updateCharacter(nil)
    clearBallVisuals()
end

local function beginInitialization()
    if initialization.started or initialization.destroyed then
        return
    end

    initialization.started = true

    task.spawn(function()
        local ok, err = pcall(function()
            setStage("waiting-player")

            LocalPlayer = Players.LocalPlayer
            if not LocalPlayer then
                LocalPlayer = Players.PlayerAdded:Wait()
            end

            setStage("waiting-character", { player = LocalPlayer and LocalPlayer.Name or "Unknown" })

            if LocalPlayer then
                updateCharacter(LocalPlayer.Character)

                characterAddedConnection = LocalPlayer.CharacterAdded:Connect(handleCharacterAdded)
                characterRemovingConnection = LocalPlayer.CharacterRemoving:Connect(handleCharacterRemoving)

                if not Character then
                    Character = LocalPlayer.CharacterAdded:Wait()
                    updateCharacter(Character)
                end
            end

            ensureUi()

            setStage("waiting-balls")
            ensureBallsFolder()

            local folderLabel = config.ballsFolderName
            if BallsFolder then
                local okName, fullName = pcall(BallsFolder.GetFullName, BallsFolder)
                if okName and typeof(fullName) == "string" then
                    folderLabel = fullName
                else
                    folderLabel = BallsFolder.Name
                end
            end

            setStage("ready", {
                player = LocalPlayer and LocalPlayer.Name or "Unknown",
                ballsFolder = folderLabel,
            })

            initialization.completed = true
        end)

        if not ok then
            initialization.error = err
            setStage("error", { error = tostring(err) })
        end
    end)
end

local function ensureInitialization()
    if initialization.destroyed then
        initialization.destroyed = false
    end
    if initialization.completed or initialization.started then
        return
    end
    beginInitialization()
end

local function computeBallDebug(speed, tti, dist)
    return string.format("💨 Speed: %.1f\n⏱️ TTI: %.3f\n📏 Dist: %.2f", speed, tti, dist)
end

local function renderLoop()
    if initialization.destroyed then
        return
    end

    if not LocalPlayer then
        return
    end

    if not Character or not RootPart then
        updateStatusLabel({ "Auto-Parry F", "Status: waiting for character" })
        clearBallVisuals()
        return
    end

    ensureBallsFolder()
    local folder = BallsFolder
    if not folder then
        updateStatusLabel({ "Auto-Parry F", "Ball: none", "Info: waiting for balls folder" })
        clearBallVisuals()
        return
    end

    if not state.enabled then
        updateStatusLabel({ "Auto-Parry F", "Status: OFF" })
        clearBallVisuals()
        updateToggleButton()
        return
    end

    local ball = findRealBall(folder)
    if not ball or not ball:IsDescendantOf(Workspace) then
        updateStatusLabel({ "Auto-Parry F", "Ball: none", "TTI: -", "Info: waiting for realBall..." })
        clearBallVisuals()
        return
    end

    local velocity = ball.AssemblyLinearVelocity or ball.Velocity or Vector3.zero
    local speed = velocity.Magnitude

    if config.ballSpeedCheck and speed == 0 then
        local stationaryDistance = (RootPart.Position - ball.Position).Magnitude
        updateStatusLabel({
            "Auto-Parry F",
            "Ball: found (stationary)",
            string.format("Speed: %.1f | Dist: %.2f", speed, stationaryDistance),
            "Info: speed=0 -> hold",
        })
        setBallVisuals(nil, "")
        return
    end

    local distanceToPlayer = (RootPart.Position - ball.Position).Magnitude

    local adjustedDistance = distanceToPlayer
    if config.pingBased then
        adjustedDistance -= (speed * getPingTime() + (config.pingBasedOffset or 0))
    end

    local toward = speed
    if toward <= 0 then
        toward = 1
    end

    local tti = adjustedDistance / toward
    if tti < 0 then
        tti = 0
    end

    local window = config.dynamicWindow and getDynamicWindow(speed) or (config.staticTTIWindow or 0.5)

    local fired = false
    local reason = ""

    if isTargetingMe() then
        if distanceToPlayer <= (config.proximityStuds or 5) then
            if sendKeyPress(ball) then
                fired = true
                reason = "PROX"
            end
        end

        if not fired and config.useTTIWindow and (tti <= window) then
            if sendKeyPress(ball) then
                fired = true
                reason = "TTI"
            end
        end
    end

    local debugLines = {
        "Auto-Parry F",
        "Ball: found",
        string.format("Speed: %.1f | Dist: %.2f | TTI: %.3f", speed, distanceToPlayer, tti),
        string.format("Window: %.3f | TargetingMe: %s", window, tostring(isTargetingMe())),
    }

    if fired then
        table.insert(debugLines, "🔥 Press F: YES (" .. reason .. ")")
    else
        table.insert(debugLines, "Press F: no")
    end

    updateStatusLabel(debugLines)
    setBallVisuals(ball, computeBallDebug(speed, tti, distanceToPlayer))
end

local function ensureLoop()
    if loopConnection then
        return
    end

    loopConnection = RunService.PreRender:Connect(renderLoop)
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
    playerTimeout = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    remotesTimeout = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    parryRemoteTimeout = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    ballsFolderTimeout = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    verificationRetryInterval = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    proximityStuds = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    useTTIWindow = function(value)
        return typeof(value) == "boolean"
    end,
    staticTTIWindow = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    dynamicWindow = function(value)
        return typeof(value) == "boolean"
    end,
    ballSpeedCheck = function(value)
        return typeof(value) == "boolean"
    end,
    pingBased = function(value)
        return typeof(value) == "boolean"
    end,
    pingBasedOffset = function(value)
        return typeof(value) == "number"
    end,
    fHoldTime = function(value)
        return typeof(value) == "number" and value >= 0
    end,
}

AutoParry = {}

function AutoParry.enable()
    ensureInitialization()
    if state.enabled then
        return
    end

    state.enabled = true
    syncGlobalSettings()
    updateToggleButton()
    ensureLoop()
    stateChanged:fire(true)
end

function AutoParry.disable()
    if not state.enabled then
        return
    end

    state.enabled = false
    syncGlobalSettings()
    updateToggleButton()
    stateChanged:fire(false)
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

    syncGlobalSettings()
    return AutoParry.getConfig()
end

function AutoParry.getConfig()
    return cloneTable(config)
end

function AutoParry.resetConfig()
    config = Util.deepCopy(DEFAULT_CONFIG)
    syncGlobalSettings()
    return AutoParry.getConfig()
end

function AutoParry.getLastParryTime()
    return state.lastParry
end

function AutoParry.getLastParrySuccessTime()
    return state.lastSuccess
end

function AutoParry.getLastParryBroadcastTime()
    return state.lastBroadcast
end

function AutoParry.onInitStatus(callback)
    assert(typeof(callback) == "function", "AutoParry.onInitStatus expects a function")
    ensureInitialization()
    local connection = initStatus:connect(callback)
    callback(cloneTable(initProgress))
    return connection
end

function AutoParry.getInitProgress()
    ensureInitialization()
    return cloneTable(initProgress)
end

function AutoParry.onStateChanged(callback)
    assert(typeof(callback) == "function", "AutoParry.onStateChanged expects a function")
    return stateChanged:connect(callback)
end

function AutoParry.onParry(callback)
    assert(typeof(callback) == "function", "AutoParry.onParry expects a function")
    return parryEvent:connect(callback)
end

function AutoParry.onParrySuccess(callback)
    assert(typeof(callback) == "function", "AutoParry.onParrySuccess expects a function")
    return parrySuccessSignal:connect(callback)
end

function AutoParry.onParryBroadcast(callback)
    assert(typeof(callback) == "function", "AutoParry.onParryBroadcast expects a function")
    return parryBroadcastSignal:connect(callback)
end

function AutoParry.setLogger()
    -- retained for API compatibility; logging is no longer used by this module
end

function AutoParry.setLegacyPayloadBuilder()
    -- retained for API compatibility with previous implementations.
end

function AutoParry.destroy()
    AutoParry.disable()

    if loopConnection then
        loopConnection:Disconnect()
        loopConnection = nil
    end

    if humanoidDiedConnection then
        humanoidDiedConnection:Disconnect()
        humanoidDiedConnection = nil
    end

    if characterAddedConnection then
        characterAddedConnection:Disconnect()
        characterAddedConnection = nil
    end

    if characterRemovingConnection then
        characterRemovingConnection:Disconnect()
        characterRemovingConnection = nil
    end

    destroyUi()
    clearBallVisuals()

    initialization.started = false
    initialization.completed = false
    initialization.destroyed = true
    initialization.error = nil

    state.lastParry = 0
    state.lastSuccess = 0
    state.lastBroadcast = 0

    initProgress = { stage = "waiting-player" }
    applyInitStatus(cloneTable(initProgress))

    initialization.destroyed = false
end

ensureInitialization()
ensureLoop()
syncGlobalSettings()

return AutoParry

]===],
    ['src/core/verification.lua'] = [===[
-- mikkel32/AutoParry : src/core/verification.lua
-- Sequences verification steps for AutoParry startup, emitting granular
-- status updates for observers and returning the discovered resources.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")


local luauTypeof = rawget(_G, "typeof")

local Verification = {}

local function typeOf(value)
    if luauTypeof then
        local ok, result = pcall(luauTypeof, value)
        if ok then
            return result
        end
    end

    return type(value)
end

local function isCallable(value)
    return typeOf(value) == "function"
end

local function getClassName(instance)
    if instance == nil then
        return "nil"
    end

    local okClass, className = pcall(function()
        return instance.ClassName
    end)

    if okClass and type(className) == "string" then
        return className
    end

    return typeOf(instance)
end

local function cloneTable(tbl)
    local result = {}
    for key, value in pairs(tbl) do
        result[key] = value
    end
    return result
end

local function isRemoteEvent(remote)
    if remote == nil then
        return false, "nil"
    end

    local okIsA, result = pcall(function()
        local method = remote.IsA
        if not isCallable(method) then
            return nil
        end

        return method(remote, "RemoteEvent")
    end)

    if okIsA and result == true then
        local okClass, className = pcall(function()
            return remote.ClassName
        end)

        if okClass and type(className) == "string" then
            return true, className
        end

        return true, "RemoteEvent"
    end

    local okClass, className = pcall(function()
        return remote.ClassName
    end)

    if okClass and type(className) == "string" and className == "RemoteEvent" then
        return true, className
    end

    return false, okClass and className or typeOf(remote)
end

local function createRemoteFireWrapper(remote, methodName)
    return function(...)
        local current = remote[methodName]
        if not isCallable(current) then
            error(
                string.format(
                    "AutoParry: parry button missing %s",
                    methodName
                ),
                0
            )
        end

        return current(remote, ...)
    end
end

local function findRemoteFire(remote)
    local okFire, fire = pcall(function()
        return remote.Fire
    end)
    if okFire and isCallable(fire) then
        return "Fire", createRemoteFireWrapper(remote, "Fire")
    end

    return nil, nil
end

local function locateSuccessRemotes(remotes)
    local definitions = {
        { key = "ParrySuccess", name = "ParrySuccess" },
        { key = "ParrySuccessAll", name = "ParrySuccessAll" },
    }

    local success = {}

    if not remotes or typeOf(remotes.FindFirstChild) ~= "function" then
        return success
    end

    for _, definition in ipairs(definitions) do
        local okRemote, remote = pcall(remotes.FindFirstChild, remotes, definition.name)
        if okRemote and remote then
            local isEvent, className = isRemoteEvent(remote)
            if isEvent then
                success[definition.key] = {
                    remote = remote,
                    name = definition.name,
                    className = className,
                }
            else
                success[definition.key] = {
                    remote = nil,
                    name = definition.name,
                    className = className,
                    unsupported = true,
                }
            end
        else
            success[definition.key] = {
                remote = nil,
                name = definition.name,
            }
        end
    end

    return success
end

local function summarizeSuccessRemotes(successRemotes)
    local summary = {}

    for key, entry in pairs(successRemotes or {}) do
        summary[key] = {
            name = entry.name,
            available = entry.remote ~= nil and not entry.unsupported,
            unsupported = entry.unsupported == true,
            className = entry.className,
        }
    end

    return summary
end

local function waitInterval(interval)
    if interval and interval > 0 then
        task.wait(interval)
    else
        task.wait()
    end
end

local function emit(report, status)
    if report then
        report(cloneTable(status))
    end
end

local function ensurePlayer(report, timeout, retryInterval)
    emit(report, {
        stage = "waiting-player",
        step = "local-player",
        status = "pending",
        elapsed = 0,
    })

    local player = Players.LocalPlayer
    if player then
        emit(report, {
            stage = "waiting-player",
            step = "local-player",
            status = "ok",
            elapsed = 0,
        })
        return player
    end

    local start = os.clock()

    while true do
        waitInterval(retryInterval)
        player = Players.LocalPlayer

        if player then
            emit(report, {
                stage = "waiting-player",
                step = "local-player",
                status = "ok",
                elapsed = os.clock() - start,
            })
            return player
        end

        local elapsed = os.clock() - start
        emit(report, {
            stage = "waiting-player",
            step = "local-player",
            status = "waiting",
            elapsed = elapsed,
        })

        if timeout and elapsed >= timeout then
            emit(report, {
                stage = "timeout",
                step = "local-player",
                status = "failed",
                reason = "local-player",
                elapsed = elapsed,
            })

            error("AutoParry: LocalPlayer unavailable", 0)
        end
    end
end

local function ensureRemotesFolder(report, timeout, retryInterval)
    emit(report, {
        stage = "waiting-remotes",
        target = "folder",
        status = "pending",
        elapsed = 0,
    })

    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    if remotes then
        emit(report, {
            stage = "waiting-remotes",
            target = "folder",
            status = "ok",
            elapsed = 0,
        })
        return remotes
    end

    local start = os.clock()

    while true do
        waitInterval(retryInterval)
        remotes = ReplicatedStorage:FindFirstChild("Remotes")

        if remotes then
            emit(report, {
                stage = "waiting-remotes",
                target = "folder",
                status = "ok",
                elapsed = os.clock() - start,
            })
            return remotes
        end

        local elapsed = os.clock() - start
        emit(report, {
            stage = "waiting-remotes",
            target = "folder",
            status = "waiting",
            elapsed = elapsed,
        })

        if timeout and elapsed >= timeout then
            emit(report, {
                stage = "timeout",
                target = "folder",
                status = "failed",
                reason = "remotes-folder",
                elapsed = elapsed,
            })

            error("AutoParry: ReplicatedStorage.Remotes missing", 0)
        end
    end
end

local function ensureParryRemote(report, remotes, timeout, retryInterval, candidates)
    local candidateDefinitions = {}
    local candidateNames = {}

    for _, entry in ipairs(candidates) do
        local displayName = entry.displayName or entry.name
        table.insert(candidateDefinitions, entry)
        table.insert(candidateNames, displayName)
    end

    emit(report, {
        stage = "waiting-remotes",
        target = "remote",
        status = "pending",
        elapsed = 0,
        candidates = candidateNames,
    })

    local start = os.clock()

    local function inspectCandidate(candidate)
        local okFound, found = pcall(remotes.FindFirstChild, remotes, candidate.name)
        if not okFound or not found then
            return nil
        end

        local remote = found
        local containerName = nil

        if candidate.childName then
            local okChild, child = pcall(found.FindFirstChild, found, candidate.childName)
            if not okChild or not child then
                return nil
            end

            remote = child
            containerName = found.Name
        end

        local className = getClassName(remote)

        local okBindable, isBindable = pcall(function()
            local isA = remote.IsA
            if not isCallable(isA) then
                return false
            end

            return isA(remote, "BindableEvent")
        end)

        if not okBindable or not isBindable then
            emit(report, {
                stage = "error",
                target = "remote",
                status = "failed",
                reason = "parry-remote-unsupported",
                className = className,
                remoteName = remote.Name,
                candidates = candidateNames,
                message = "AutoParry: ParryButtonPress.parryButtonPress must be a BindableEvent",
            })

            error("AutoParry: ParryButtonPress.parryButtonPress must be a BindableEvent", 0)
        end

        local methodName, fire = findRemoteFire(remote)
        if not methodName or not fire then
            emit(report, {
                stage = "error",
                target = "remote",
                status = "failed",
                reason = "parry-remote-missing-method",
                className = className,
                remoteName = remote.Name,
                candidates = candidateNames,
                message = "AutoParry: ParryButtonPress.parryButtonPress missing Fire",
            })

            error("AutoParry: ParryButtonPress.parryButtonPress missing Fire", 0)
        end

        local info = {
            method = methodName,
            className = className,
            kind = className,
            remoteName = candidate.name,
            remoteChildName = remote.Name,
            remoteContainerName = containerName,
            variant = candidate.variant,
        }

        return true, remote, fire, info
    end

    while true do
        for _, candidate in ipairs(candidateDefinitions) do
            local status, remote, fire, info = inspectCandidate(candidate)
            if status then
                emit(report, {
                    stage = "waiting-remotes",
                    target = "remote",
                    status = "ok",
                    elapsed = os.clock() - start,
                    remoteName = info.remoteName,
                    remoteVariant = info.variant,
                    remoteMethod = info.method,
                    remoteClass = info.className,
                    candidates = candidateNames,
                })

                return remote, fire, info
            end
        end

        local elapsed = os.clock() - start
        emit(report, {
            stage = "waiting-remotes",
            target = "remote",
            status = "waiting",
            elapsed = elapsed,
            candidates = candidateNames,
        })

        if timeout and elapsed >= timeout then
            emit(report, {
                stage = "timeout",
                target = "remote",
                status = "failed",
                reason = "parry-remote",
                elapsed = elapsed,
                candidates = candidateNames,
            })

            error("AutoParry: parry remote missing (ParryButtonPress.parryButtonPress)", 0)
        end

        waitInterval(retryInterval)
    end
end

local function verifyBallsFolder(report, folderName, timeout, retryInterval)
    if not folderName or folderName == "" then
        return {
            verified = false,
            reason = "disabled",
        }, nil
    end

    emit(report, {
        stage = "verifying-balls",
        status = "pending",
        folderName = folderName,
        elapsed = 0,
    })

    local folder = Workspace:FindFirstChild(folderName)
    if folder then
        emit(report, {
            stage = "verifying-balls",
            status = "ok",
            folderName = folderName,
            elapsed = 0,
        })

        return {
            verified = true,
            elapsed = 0,
        }, folder
    end

    local start = os.clock()
    local limit = timeout and timeout > 0 and timeout or nil

    if limit == nil then
        emit(report, {
            stage = "verifying-balls",
            status = "warning",
            folderName = folderName,
            reason = "timeout",
            elapsed = 0,
        })

        return {
            verified = false,
            reason = "timeout",
            elapsed = 0,
        }, nil
    end

    while true do
        if limit then
            if os.clock() - start >= limit then
                break
            end
        end

        waitInterval(retryInterval)
        folder = Workspace:FindFirstChild(folderName)

        if folder then
            local elapsed = os.clock() - start
            emit(report, {
                stage = "verifying-balls",
                status = "ok",
                folderName = folderName,
                elapsed = elapsed,
            })

            return {
                verified = true,
                elapsed = elapsed,
            }, folder
        end

        local elapsed = os.clock() - start
        emit(report, {
            stage = "verifying-balls",
            status = "waiting",
            folderName = folderName,
            elapsed = elapsed,
        })
    end

    local elapsed = os.clock() - start
    emit(report, {
        stage = "verifying-balls",
        status = "warning",
        folderName = folderName,
        reason = "timeout",
        elapsed = elapsed,
    })

    return {
        verified = false,
        reason = "timeout",
        elapsed = elapsed,
    }, nil
end

function Verification.run(options)
    options = options or {}
    local config = options.config or {}
    local report = options.report
    local retryInterval = options.retryInterval or config.verificationRetryInterval or 0

    local candidateDefinitions = options.candidates or {
        {
            name = "ParryButtonPress",
            childName = "parryButtonPress",
            variant = "modern",
            displayName = "ParryButtonPress.parryButtonPress",
        },
    }

    local playerTimeout = config.playerTimeout or options.playerTimeout or 10
    local remotesTimeout = config.remotesTimeout or options.remotesTimeout or 10
    local parryRemoteTimeout = config.parryRemoteTimeout or options.parryRemoteTimeout or 10
    local ballsFolderTimeout = config.ballsFolderTimeout or options.ballsFolderTimeout or 5

    local player = ensurePlayer(report, playerTimeout, retryInterval)
    local remotes = ensureRemotesFolder(report, remotesTimeout, retryInterval)
    local remote, baseFire, remoteInfo = ensureParryRemote(report, remotes, parryRemoteTimeout, retryInterval, candidateDefinitions)

    local successRemotes = locateSuccessRemotes(remotes)

    emit(report, {
        stage = "verifying-success-remotes",
        status = "observed",
        remotes = summarizeSuccessRemotes(successRemotes),
    })

    remoteInfo = remoteInfo or {}
    remoteInfo.successRemotes = successRemotes

    local ballsStatus, ballsFolder = verifyBallsFolder(report, config.ballsFolderName or "Balls", ballsFolderTimeout, retryInterval)

    return {
        player = player,
        remotesFolder = remotes,
        parryRemote = remote,
        parryRemoteBaseFire = baseFire,
        parryRemoteInfo = remoteInfo,
        successRemotes = successRemotes,
        ballsFolder = ballsFolder,
        ballsStatus = ballsStatus,
    }
end

return Verification

]===],
    ['src/main.lua'] = [===[
-- mikkel32/AutoParry : src/main.lua
-- selene: allow(global_usage)
-- Bootstraps the AutoParry experience, wiring together the UI and core logic
-- and returning a friendly developer API.

local Require = rawget(_G, "ARequire")
assert(Require, "AutoParry: ARequire missing (loader.lua not executed)")

local Util = Require("src/shared/util.lua")
local LoadingOverlay = Require("src/ui/loading_overlay.lua")
local VerificationDashboard = Require("src/ui/verification_dashboard.lua")

local VERSION = "1.1.0"
local UI_MODULE_PATH = "src/ui/init.lua"
local PARRY_MODULE_PATH = "src/core/autoparry.lua"

local function disconnect(connection)
    if not connection then
        return
    end
    if connection.Disconnect then
        connection:Disconnect()
    elseif connection.disconnect then
        connection:disconnect()
    end
end

local function defaultStatusFormatter(state)
    if state.error then
        return state.error.message or "AutoParry failed to start."
    end

    local loader = state.loader or {}
    if loader.completed ~= true then
        local started = loader.started or 0
        local finished = loader.finished or 0
        local failed = loader.failed or 0
        local lastPath = loader.last and loader.last.path
        local total = math.max(started, finished + failed)

        if lastPath then
            if total > 0 then
                return ("Downloading %s (%d/%d)"):format(lastPath, finished + failed, total)
            else
                return ("Downloading %s…"):format(lastPath)
            end
        end

        if total > 0 then
            return ("Downloading AutoParry modules (%d/%d)"):format(finished + failed, total)
        end

        return "Preparing AutoParry download…"
    end

    local parry = state.parry or {}
    local stage = parry.stage

    if stage == "ready" then
        return "AutoParry ready!"
    elseif stage == "waiting-remotes" then
        if parry.target == "remote" then
            return "Waiting for parry remote…"
        end
        return "Waiting for Blade Ball remotes…"
    elseif stage == "waiting-player" then
        return "Waiting for your player…"
    elseif stage == "timeout" then
        return "AutoParry initialization timed out."
    end

    return "Preparing AutoParry…"
end

local function defaultProgressFormatter(state)
    local loader = state.loader or {}
    local parry = state.parry or {}

    local loaderStarted = loader.started or 0
    local loaderFinished = loader.finished or 0
    local loaderFailed = loader.failed or 0
    local loaderTotal = math.max(loaderStarted, loaderFinished + loaderFailed)
    local loaderAlpha = 0
    if loaderTotal > 0 then
        loaderAlpha = math.clamp((loaderFinished + loaderFailed) / loaderTotal, 0, 1)
    end

    if state.error then
        return loaderAlpha
    end

    local parryStage = parry.stage
    local parryAlpha = 0
    if parryStage == "ready" then
        parryAlpha = 1
    elseif parryStage == "waiting-remotes" then
        parryAlpha = 0.7
    elseif parryStage == "waiting-player" then
        parryAlpha = 0.4
    elseif parryStage == "timeout" then
        parryAlpha = 0
    end

    if loader.completed == true then
        return parryAlpha
    end

    return math.clamp(loaderAlpha * 0.7 + parryAlpha * 0.3, 0, 1)
end

local function normalizeLoadingOverlayOptions(option)
    local defaults = {
        enabled = true,
        parent = nil,
        name = nil,
        tips = nil,
        theme = nil,
        statusFormatter = nil,
        progressFormatter = nil,
        formatStatus = nil,
        formatProgress = nil,
        actions = nil,
        retryLabel = "Retry",
        cancelLabel = "Cancel",
        onRetry = nil,
        onCancel = nil,
        onOverlayCreated = nil,
        customizeOverlay = nil,
        fadeDuration = nil,
        progressDuration = nil,
    }

    if option == nil then
        return defaults
    end

    if option == false then
        defaults.enabled = false
        return defaults
    end

    if option == true then
        return defaults
    end

    if typeof(option) == "table" then
        if option.enabled ~= nil then
            defaults.enabled = option.enabled ~= false
        end

        for key, value in pairs(option) do
            if key ~= "enabled" then
                defaults[key] = value
            end
        end

        if defaults.statusFormatter == nil and typeof(defaults.formatStatus) == "function" then
            defaults.statusFormatter = defaults.formatStatus
        end
        if defaults.progressFormatter == nil and typeof(defaults.formatProgress) == "function" then
            defaults.progressFormatter = defaults.formatProgress
        end

        defaults.formatStatus = nil
        defaults.formatProgress = nil

        return defaults
    end

    return defaults
end

local function normalizeOptions(options)
    options = options or {}
    local defaults = {
        title = "AutoParry",
        autoStart = false,
        defaultEnabled = false,
        hotkey = nil,
        tooltip = nil,
        parry = nil,
        loadingOverlay = true,
    }

    local merged = Util.merge(Util.deepCopy(defaults), options)
    merged.loadingOverlay = normalizeLoadingOverlayOptions(merged.loadingOverlay)
    return merged
end

return function(options, loaderContext)
    local opts = normalizeOptions(options)
    local overlayOpts = opts.loadingOverlay
    local overlayEnabled = overlayOpts.enabled ~= false

    local overlay = nil
    local dashboard = nil
    if overlayEnabled then
        overlay = LoadingOverlay.create({
            parent = overlayOpts.parent,
            name = overlayOpts.name,
            tips = overlayOpts.tips,
            theme = overlayOpts.theme,
        })

        local customize = overlayOpts.onOverlayCreated or overlayOpts.customizeOverlay
        if typeof(customize) == "function" then
            local ok, err = pcall(customize, overlay, overlayOpts, opts)
            if not ok then
                warn("AutoParry loading overlay customization failed:", err)
            end
        end

        local mount = overlay and overlay:getDashboardMount()
        if mount then
            local okDashboard, dashboardResult = pcall(function()
                return VerificationDashboard.new({
                    parent = mount,
                    theme = overlay:getTheme(),
                })
            end)
            if okDashboard then
                dashboard = dashboardResult
                overlay:attachDashboard(dashboard)
                dashboard:update(overlayState, { progress = dashboardProgressAlpha })
                overlay:onCompleted(function()
                    dashboard = nil
                end)
            else
                warn("AutoParry dashboard initialization failed:", dashboardResult)
            end
        end
    end

    local loaderState = rawget(_G, "AutoParryLoader")
    local activeContext = loaderContext or (loaderState and loaderState.context)
    local loaderSignals = activeContext and activeContext.signals or (loaderState and loaderState.signals)
    local loaderProgress = activeContext and activeContext.progress or (loaderState and loaderState.progress) or {
        started = 0,
        finished = 0,
        failed = 0,
    }

    local overlayState = {
        loader = {
            started = loaderProgress.started or 0,
            finished = loaderProgress.finished or 0,
            failed = loaderProgress.failed or 0,
            completed = false,
            last = nil,
        },
        parry = {},
        error = nil,
    }

    local dashboardProgressAlpha = 0

    local loaderComplete = not overlayEnabled
    local parryReady = not overlayEnabled
    local bootstrapCancelled = false
    local finalizeTriggered = false
    local retryInFlight = false

    local loaderConnections = {}
    local controller = nil
    local parryConn = nil
    local initConn = nil

    local statusFormatter = overlayOpts.statusFormatter
        or overlayOpts.formatStatus
        or defaultStatusFormatter
    local progressFormatter = overlayOpts.progressFormatter
        or overlayOpts.formatProgress
        or defaultProgressFormatter

    if typeof(statusFormatter) ~= "function" then
        statusFormatter = defaultStatusFormatter
    end
    if typeof(progressFormatter) ~= "function" then
        progressFormatter = defaultProgressFormatter
    end

    local function refreshLoaderCounters()
        if loaderProgress then
            overlayState.loader.started = loaderProgress.started or overlayState.loader.started
            overlayState.loader.finished = loaderProgress.finished or overlayState.loader.finished
            overlayState.loader.failed = loaderProgress.failed or overlayState.loader.failed
        end
    end

    local function refreshLoaderCompletion()
        local started = overlayState.loader.started or 0
        local finished = overlayState.loader.finished or 0
        local failed = overlayState.loader.failed or 0
        if started > 0 and finished + failed >= started then
            overlayState.loader.completed = true
            loaderComplete = true
        end
    end

    local finalize -- forward declaration

    local applyActions -- forward declaration

    local function updateOverlay()
        if not overlay then
            return
        end

        local okStatus, statusText = pcall(statusFormatter, overlayState, overlayOpts, opts)
        if okStatus and typeof(statusText) == "string" then
            overlay:setStatus(statusText, { force = overlayState.error ~= nil })
        elseif not okStatus then
            warn("AutoParry loading overlay status formatter error:", statusText)
        end

        local okProgress, progressValue = pcall(progressFormatter, overlayState, overlayOpts, opts)
        if okProgress and typeof(progressValue) == "number" then
            local clamped = math.clamp(progressValue, 0, 1)
            overlay:setProgress(clamped, { force = overlayState.error ~= nil })
            dashboardProgressAlpha = clamped
        elseif not okProgress then
            warn("AutoParry loading overlay progress formatter error:", progressValue)
        end

        if applyActions then
            applyActions()
        end

        if dashboard then
            dashboard:update(overlayState, { progress = dashboardProgressAlpha })
        end
    end

    local function handleCancel()
        if bootstrapCancelled then
            return
        end
        bootstrapCancelled = true

        if overlay then
            overlay:setActions(nil)
        end

        if dashboard then
            dashboard:setActions(nil)
            dashboard:setStatusText("Verification cancelled")
        end

        if typeof(overlayOpts.onCancel) == "function" then
            local ok, err = pcall(overlayOpts.onCancel, {
                overlay = overlay,
                options = opts,
                state = overlayState,
                context = activeContext,
            })
            if not ok then
                warn("AutoParry loading overlay cancel handler failed:", err)
            end
        end
    end

    local function handleRetry()
        if retryInFlight then
            return
        end
        retryInFlight = true

        if typeof(overlayOpts.onRetry) == "function" then
            local ok, err = pcall(overlayOpts.onRetry, {
                overlay = overlay,
                options = opts,
                state = overlayState,
                context = activeContext,
            })
            if not ok then
                warn("AutoParry loading overlay retry handler failed:", err)
            end
            retryInFlight = false
            return
        end

        local retryContext = activeContext or (loaderState and loaderState.context)
        if not retryContext or typeof(retryContext.require) ~= "function" then
            warn("AutoParry: loader context unavailable, cannot retry bootstrap")
            retryInFlight = false
            return
        end

        bootstrapCancelled = true

        retryContext.refresh = true
        retryContext.cache = {}
        if loaderState and loaderState.progress then
            loaderState.progress.started = 0
            loaderState.progress.finished = 0
            loaderState.progress.failed = 0
        end

        overlayState.error = nil
        overlayState.loader.completed = false
        loaderComplete = not overlayEnabled
        parryReady = not overlayEnabled
        dashboardProgressAlpha = 0

        if overlay then
            overlay:setActions(nil)
            overlay:setStatus("Retrying AutoParry download…", { force = true })
            overlay:setProgress(0, { force = true })
        end

        if dashboard then
            dashboard:reset()
            dashboard:setStatusText("Reinitialising verification…")
        end

        task.spawn(function()
            local okModule, moduleOrError = pcall(retryContext.require, retryContext.entrypoint)
            if not okModule then
                warn("AutoParry: loader retry failed", moduleOrError)
                overlayState.error = {
                    kind = "loader",
                    message = tostring(moduleOrError),
                    payload = { error = moduleOrError },
                }
                updateOverlay()
                retryInFlight = false
                return
            end

            if typeof(moduleOrError) == "function" then
                local okExecute, execErr = pcall(moduleOrError, opts, retryContext)
                if not okExecute then
                    warn("AutoParry: loader retry execution failed", execErr)
                end
            end

            retryInFlight = false
        end)
    end

    applyActions = function()
        if not overlay then
            return
        end

        if overlayState.error then
            local actions = nil
            if typeof(overlayOpts.actions) == "function" then
                local ok, result = pcall(overlayOpts.actions, overlayState, overlayOpts, opts)
                if ok and typeof(result) == "table" then
                    actions = result
                elseif not ok then
                    warn("AutoParry loading overlay custom actions error:", result)
                end
            elseif typeof(overlayOpts.actions) == "table" then
                actions = overlayOpts.actions
            end

            if not actions then
                actions = {
                    {
                        id = "retry",
                        text = overlayOpts.retryLabel or "Retry",
                        callback = handleRetry,
                    },
                    {
                        id = "cancel",
                        text = overlayOpts.cancelLabel or "Cancel",
                        variant = "secondary",
                        callback = handleCancel,
                    },
                }
            end

            overlay:setActions(actions)
        else
            if typeof(overlayOpts.actions) == "table" and #overlayOpts.actions > 0 then
                overlay:setActions(overlayOpts.actions)
            else
                overlay:setActions(nil)
            end
        end
    end

    local function checkReady()
        if finalizeTriggered or bootstrapCancelled then
            return
        end

        if overlayState.error then
            return
        end

        if (not overlayEnabled or loaderComplete) and parryReady and finalize then
            finalizeTriggered = true
            finalize()
        end
    end

    if loaderSignals then
        local startedConn = loaderSignals.onFetchStarted:Connect(function(payload)
            overlayState.loader.last = payload
            refreshLoaderCounters()
            updateOverlay()
        end)
        table.insert(loaderConnections, startedConn)

        local completedConn = loaderSignals.onFetchCompleted:Connect(function(payload)
            overlayState.loader.last = payload
            refreshLoaderCounters()
            refreshLoaderCompletion()
            updateOverlay()
            checkReady()
        end)
        table.insert(loaderConnections, completedConn)

        local failedConn = loaderSignals.onFetchFailed:Connect(function(payload)
            overlayState.loader.last = payload
            refreshLoaderCounters()
            overlayState.error = {
                kind = "loader",
                message = (payload and payload.error) or (payload and payload.path and ("Failed to load %s"):format(payload.path)) or "Failed to download AutoParry modules.",
                payload = payload,
            }
            refreshLoaderCompletion()
            updateOverlay()
        end)
        table.insert(loaderConnections, failedConn)

        local completeConn = loaderSignals.onAllComplete:Connect(function()
            refreshLoaderCounters()
            refreshLoaderCompletion()
            updateOverlay()
            checkReady()
        end)
        table.insert(loaderConnections, completeConn)
    end

    refreshLoaderCounters()
    refreshLoaderCompletion()
    updateOverlay()

    local UI = Require(UI_MODULE_PATH)
    local Parry = Require(PARRY_MODULE_PATH)

    if typeof(opts.parry) == "table" then
        Parry.configure(opts.parry)
    end

    parryConn = Parry.onStateChanged(function(enabled)
        if controller then
            controller:setEnabled(enabled, { silent = true, source = "parry" })
        end
    end)

    initConn = Parry.onInitStatus(function(progress)
        overlayState.parry = Util.deepCopy(progress or {})
        local stage = progress and progress.stage

        if stage == "ready" then
            parryReady = true
            if overlayState.error and overlayState.error.kind == "parry" then
                overlayState.error = nil
            end
        elseif stage == "timeout" then
            parryReady = false
            local reason = progress and progress.reason
            local stageName = progress and progress.stage
            local message
            if reason then
                message = ("Timed out waiting for %s."):format(reason)
            elseif stageName then
                message = ("Timed out during %s."):format(stageName)
            else
                message = "AutoParry initialization timed out."
            end
            overlayState.error = {
                kind = "parry",
                message = message,
                payload = Util.deepCopy(progress or {}),
            }
        else
            if overlayState.error and overlayState.error.kind == "parry" then
                overlayState.error = nil
            end
        end

        updateOverlay()
        checkReady()
    end)

        finalize = function()
            if bootstrapCancelled then
                return
            end

            controller = UI.mount({
                title = opts.title,
                initialState = opts.autoStart or opts.defaultEnabled or Parry.isEnabled(),
                hotkey = opts.hotkey,
                tooltip = opts.tooltip,
                onToggle = function(enabled)
                    Parry.setEnabled(enabled)
                end,
            })

            if controller then
                controller:setEnabled(Parry.isEnabled(), { silent = true })
            end

            if opts.autoStart or opts.defaultEnabled then
                Parry.enable()
            else
                if controller then
                    controller:setEnabled(Parry.isEnabled(), { silent = true })
                end
            end

            if overlay then
                overlay:setActions(nil)
            overlay:complete({
                fadeDuration = overlayOpts.fadeDuration,
                progressDuration = overlayOpts.progressDuration,
            })
        end
    end

    updateOverlay()
    checkReady()

    local api = {}

    function api.getVersion()
        return VERSION
    end

    function api.isEnabled()
        return Parry.isEnabled()
    end

    function api.setEnabled(enabled)
        if controller then
            controller:setEnabled(enabled)
        else
            Parry.setEnabled(enabled)
        end
        return Parry.isEnabled()
    end

    function api.toggle()
        if controller then
            controller:toggle()
        else
            Parry.toggle()
        end
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

        disconnect(parryConn)
        parryConn = nil

        disconnect(initConn)
        initConn = nil

        for _, connection in ipairs(loaderConnections) do
            disconnect(connection)
        end
        if table.clear then
            table.clear(loaderConnections)
        else
            for index = #loaderConnections, 1, -1 do
                loaderConnections[index] = nil
            end
        end

        if controller then
            controller:destroy()
            controller = nil
        end

        if overlay and not overlay:isComplete() then
            overlay:destroy()
            overlay = nil
        end

        dashboard = nil
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
-- Futuristic dashboard controller for AutoParry with status, telemetry,
-- control toggles, and hotkey support. The module exposes a lightweight API
-- used by the runtime to keep the UI in sync with the parry core while giving
-- downstream experiences room to customise the presentation.

local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")

local Require = rawget(_G, "ARequire")
local Util = Require("src/shared/util.lua")
local LoadingOverlay = Require("src/ui/loading_overlay.lua")

local UI = {}

local Controller = {}
Controller.__index = Controller

local DASHBOARD_THEME = {
    width = 460,
    backgroundColor = Color3.fromRGB(12, 16, 32),
    backgroundTransparency = 0.04,
    strokeColor = Color3.fromRGB(0, 160, 255),
    strokeTransparency = 0.55,
    gradient = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(12, 20, 36)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 120, 200)),
    }),
    gradientTransparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.8),
        NumberSequenceKeypoint.new(1, 0.35),
    }),
    glowColor = Color3.fromRGB(0, 210, 255),
    glowTransparency = 0.82,
    headingColor = Color3.fromRGB(230, 242, 255),
    subheadingColor = Color3.fromRGB(180, 199, 230),
    badgeActiveColor = Color3.fromRGB(0, 210, 180),
    badgeIdleColor = Color3.fromRGB(62, 72, 96),
    badgeTextActive = Color3.fromRGB(10, 14, 24),
    badgeTextIdle = Color3.fromRGB(215, 228, 255),
    toggleOnColor = Color3.fromRGB(0, 210, 185),
    toggleOffColor = Color3.fromRGB(42, 52, 80),
    toggleOnTextColor = Color3.fromRGB(12, 16, 20),
    toggleOffTextColor = Color3.fromRGB(220, 234, 255),
    telemetryCardColor = Color3.fromRGB(18, 24, 40),
    telemetryStrokeColor = Color3.fromRGB(0, 155, 240),
    controlCardColor = Color3.fromRGB(14, 20, 34),
    controlStrokeColor = Color3.fromRGB(0, 135, 215),
}

local DEFAULT_TELEMETRY_CARDS = {
    {
        id = "latency",
        label = "Latency",
        value = "-- ms",
        hint = "Ping to Blade Ball server",
    },
    {
        id = "uptime",
        label = "Session",
        value = "00:00",
        hint = "Runtime since activation",
    },
    {
        id = "mesh",
        label = "Neural Mesh",
        value = "Calibrating",
        hint = "Adaptive reaction model state",
    },
}

local DEFAULT_CONTROL_SWITCHES = {
    {
        id = "adaptive",
        title = "Adaptive Reaction",
        description = "Learns opponent speed to retime parries.",
        default = true,
        badge = "AI",
    },
    {
        id = "failsafe",
        title = "Failsafe Recall",
        description = "Falls back to manual play if anomalies spike.",
        default = true,
        badge = "SAFE",
    },
    {
        id = "edge",
        title = "Edge Prediction",
        description = "Predicts ricochet chains before they happen.",
        default = false,
    },
    {
        id = "sync",
        title = "Squad Sync",
        description = "Shares telemetry with party members instantly.",
        default = true,
        badge = "LINK",
    },
}

local function ensureGuiRoot(name)
    local existing = CoreGui:FindFirstChild(name)
    if existing then
        existing:Destroy()
    end

    local sg = Instance.new("ScreenGui")
    sg.Name = name
    sg.ResetOnSpawn = false
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    sg.IgnoreGuiInset = true
    sg.Parent = CoreGui
    return sg
end

local function formatHotkeyDisplay(hotkey)
    if typeof(hotkey) == "EnumItem" then
        return hotkey.Name
    end

    if typeof(hotkey) == "table" then
        local parts = {}
        local modifiers = hotkey.modifiers or hotkey.Modifiers
        if typeof(modifiers) == "table" then
            for _, modifier in ipairs(modifiers) do
                if typeof(modifier) == "EnumItem" then
                    table.insert(parts, modifier.Name)
                elseif typeof(modifier) == "string" and modifier ~= "" then
                    table.insert(parts, modifier)
                end
            end
        end

        local key = hotkey.key or hotkey.Key
        if typeof(key) == "EnumItem" then
            table.insert(parts, key.Name)
        elseif typeof(key) == "string" and key ~= "" then
            table.insert(parts, key)
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

local function createDashboardFrame(parent)
    local frame = Instance.new("Frame")
    frame.Name = "Dashboard"
    frame.AnchorPoint = Vector2.new(0, 0)
    frame.Position = UDim2.new(0, 36, 0, 140)
    frame.Size = UDim2.new(0, DASHBOARD_THEME.width, 0, 0)
    frame.AutomaticSize = Enum.AutomaticSize.Y
    frame.BackgroundColor3 = DASHBOARD_THEME.backgroundColor
    frame.BackgroundTransparency = DASHBOARD_THEME.backgroundTransparency
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Draggable = true
    frame.ClipsDescendants = false
    frame.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 18)
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 2
    stroke.Transparency = DASHBOARD_THEME.strokeTransparency
    stroke.Color = DASHBOARD_THEME.strokeColor
    stroke.Parent = frame

    local gradient = Instance.new("UIGradient")
    gradient.Color = DASHBOARD_THEME.gradient
    gradient.Transparency = DASHBOARD_THEME.gradientTransparency
    gradient.Rotation = 125
    gradient.Parent = frame

    local glow = Instance.new("Frame")
    glow.Name = "Glow"
    glow.AnchorPoint = Vector2.new(0.5, 0)
    glow.Position = UDim2.new(0.5, 0, 0, -64)
    glow.Size = UDim2.new(0.85, 0, 0, 180)
    glow.BackgroundTransparency = 1
    glow.Parent = frame

    local glowGradient = Instance.new("UIGradient")
    glowGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, DASHBOARD_THEME.glowColor),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 255, 255)),
    })
    glowGradient.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1),
        NumberSequenceKeypoint.new(0.5, DASHBOARD_THEME.glowTransparency),
        NumberSequenceKeypoint.new(1, 1),
    })
    glowGradient.Rotation = 90
    glowGradient.Parent = glow

    local content = Instance.new("Frame")
    content.Name = "Content"
    content.BackgroundTransparency = 1
    content.Position = UDim2.new(0, 24, 0, 24)
    content.Size = UDim2.new(1, -48, 0, 0)
    content.AutomaticSize = Enum.AutomaticSize.Y
    content.Parent = frame

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 14)
    layout.Parent = content

    return frame, content
end

local function createHeader(parent, titleText, hotkeyText)
    local header = Instance.new("Frame")
    header.Name = "Header"
    header.BackgroundTransparency = 1
    header.Size = UDim2.new(1, 0, 0, 0)
    header.AutomaticSize = Enum.AutomaticSize.Y
    header.LayoutOrder = 1
    header.Parent = parent

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBlack
    title.TextSize = 30
    title.TextColor3 = DASHBOARD_THEME.headingColor
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextYAlignment = Enum.TextYAlignment.Bottom
    title.Text = tostring(titleText or "AutoParry")
    title.Size = UDim2.new(1, 0, 0, 34)
    title.Parent = header

    local tagline = Instance.new("TextLabel")
    tagline.Name = "Tagline"
    tagline.BackgroundTransparency = 1
    tagline.Font = Enum.Font.Gotham
    tagline.TextSize = 18
    tagline.TextColor3 = DASHBOARD_THEME.subheadingColor
    tagline.TextXAlignment = Enum.TextXAlignment.Left
    tagline.TextYAlignment = Enum.TextYAlignment.Top
    tagline.Text = "Neural shield online"
    tagline.Position = UDim2.new(0, 0, 0, 38)
    tagline.Size = UDim2.new(1, 0, 0, 26)
    tagline.Parent = header

    local badge = Instance.new("Frame")
    badge.Name = "StatusBadge"
    badge.AnchorPoint = Vector2.new(1, 0)
    badge.Position = UDim2.new(1, 0, 0, 2)
    badge.Size = UDim2.new(0, 120, 0, 30)
    badge.BackgroundColor3 = DASHBOARD_THEME.badgeIdleColor
    badge.BackgroundTransparency = 0.15
    badge.BorderSizePixel = 0
    badge.Parent = header

    local badgeCorner = Instance.new("UICorner")
    badgeCorner.CornerRadius = UDim.new(0, 14)
    badgeCorner.Parent = badge

    local badgeStroke = Instance.new("UIStroke")
    badgeStroke.Thickness = 1.5
    badgeStroke.Transparency = 0.4
    badgeStroke.Color = DASHBOARD_THEME.strokeColor
    badgeStroke.Parent = badge

    local badgeLabel = Instance.new("TextLabel")
    badgeLabel.Name = "Label"
    badgeLabel.BackgroundTransparency = 1
    badgeLabel.Font = Enum.Font.GothamSemibold
    badgeLabel.TextSize = 14
    badgeLabel.TextColor3 = DASHBOARD_THEME.badgeTextIdle
    badgeLabel.TextXAlignment = Enum.TextXAlignment.Center
    badgeLabel.Text = "IDLE"
    badgeLabel.Size = UDim2.new(1, 0, 1, 0)
    badgeLabel.Parent = badge

    local hotkeyLabel = Instance.new("TextLabel")
    hotkeyLabel.Name = "HotkeyLabel"
    hotkeyLabel.AnchorPoint = Vector2.new(1, 0)
    hotkeyLabel.Position = UDim2.new(1, 0, 1, 6)
    hotkeyLabel.BackgroundTransparency = 1
    hotkeyLabel.Font = Enum.Font.Gotham
    hotkeyLabel.TextSize = 14
    hotkeyLabel.TextColor3 = Color3.fromRGB(170, 188, 220)
    hotkeyLabel.TextXAlignment = Enum.TextXAlignment.Right
    hotkeyLabel.Text = hotkeyText and ("Hotkey: %s"):format(hotkeyText) or ""
    hotkeyLabel.Size = UDim2.new(0, 240, 0, 20)
    hotkeyLabel.Parent = header

    return {
        frame = header,
        title = title,
        tagline = tagline,
        badge = badge,
        badgeLabel = badgeLabel,
        hotkeyLabel = hotkeyLabel,
    }
end

local function createStatusCard(parent)
    local card = Instance.new("Frame")
    card.Name = "StatusCard"
    card.BackgroundColor3 = Color3.fromRGB(16, 24, 44)
    card.BackgroundTransparency = 0.08
    card.BorderSizePixel = 0
    card.LayoutOrder = 2
    card.Size = UDim2.new(1, 0, 0, 0)
    card.AutomaticSize = Enum.AutomaticSize.Y
    card.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 16)
    corner.Parent = card

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1.5
    stroke.Transparency = 0.45
    stroke.Color = DASHBOARD_THEME.strokeColor
    stroke.Parent = card

    local gradient = Instance.new("UIGradient")
    gradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(12, 18, 34)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 105, 180)),
    })
    gradient.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.88),
        NumberSequenceKeypoint.new(1, 0.4),
    })
    gradient.Rotation = 130
    gradient.Parent = card

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 24)
    padding.PaddingBottom = UDim.new(0, 24)
    padding.PaddingLeft = UDim.new(0, 24)
    padding.PaddingRight = UDim.new(0, 24)
    padding.Parent = card

    local header = Instance.new("TextLabel")
    header.Name = "Heading"
    header.BackgroundTransparency = 1
    header.Font = Enum.Font.GothamSemibold
    header.TextSize = 16
    header.TextColor3 = Color3.fromRGB(170, 188, 220)
    header.TextXAlignment = Enum.TextXAlignment.Left
    header.Text = "Shield control"
    header.Size = UDim2.new(1, -160, 0, 18)
    header.Parent = card

    local statusHeading = Instance.new("TextLabel")
    statusHeading.Name = "StatusHeading"
    statusHeading.BackgroundTransparency = 1
    statusHeading.Font = Enum.Font.GothamBlack
    statusHeading.TextSize = 26
    statusHeading.TextColor3 = DASHBOARD_THEME.headingColor
    statusHeading.TextXAlignment = Enum.TextXAlignment.Left
    statusHeading.Text = "AutoParry standby"
    statusHeading.Position = UDim2.new(0, 0, 0, 32)
    statusHeading.Size = UDim2.new(1, -160, 0, 32)
    statusHeading.Parent = card

    local statusSupport = Instance.new("TextLabel")
    statusSupport.Name = "StatusSupport"
    statusSupport.BackgroundTransparency = 1
    statusSupport.Font = Enum.Font.Gotham
    statusSupport.TextSize = 17
    statusSupport.TextColor3 = DASHBOARD_THEME.subheadingColor
    statusSupport.TextXAlignment = Enum.TextXAlignment.Left
    statusSupport.TextWrapped = true
    statusSupport.Text = "Neural mesh waiting for activation signal."
    statusSupport.Position = UDim2.new(0, 0, 0, 66)
    statusSupport.Size = UDim2.new(1, -160, 0, 44)
    statusSupport.Parent = card

    local toggleButton = Instance.new("TextButton")
    toggleButton.Name = "ToggleButton"
    toggleButton.AutoButtonColor = false
    toggleButton.AnchorPoint = Vector2.new(1, 0)
    toggleButton.Position = UDim2.new(1, 0, 0, 20)
    toggleButton.Size = UDim2.new(0, 160, 0, 46)
    toggleButton.BackgroundColor3 = DASHBOARD_THEME.toggleOffColor
    toggleButton.TextColor3 = DASHBOARD_THEME.toggleOffTextColor
    toggleButton.Font = Enum.Font.GothamBold
    toggleButton.TextSize = 19
    toggleButton.Text = "Activate shield"
    toggleButton.BorderSizePixel = 0
    toggleButton.Parent = card

    local toggleCorner = Instance.new("UICorner")
    toggleCorner.CornerRadius = UDim.new(0, 12)
    toggleCorner.Parent = toggleButton

    local tooltip = Instance.new("TextLabel")
    tooltip.Name = "Tooltip"
    tooltip.BackgroundTransparency = 1
    tooltip.Font = Enum.Font.Gotham
    tooltip.TextSize = 14
    tooltip.TextColor3 = Color3.fromRGB(150, 168, 205)
    tooltip.TextXAlignment = Enum.TextXAlignment.Left
    tooltip.TextWrapped = true
    tooltip.Position = UDim2.new(0, 0, 0, 118)
    tooltip.Size = UDim2.new(1, 0, 0, 20)
    tooltip.Text = ""
    tooltip.Parent = card

    local hotkeyLabel = Instance.new("TextLabel")
    hotkeyLabel.Name = "HotkeyLabel"
    hotkeyLabel.BackgroundTransparency = 1
    hotkeyLabel.Font = Enum.Font.Gotham
    hotkeyLabel.TextSize = 14
    hotkeyLabel.TextColor3 = Color3.fromRGB(170, 188, 220)
    hotkeyLabel.TextXAlignment = Enum.TextXAlignment.Right
    hotkeyLabel.AnchorPoint = Vector2.new(1, 0)
    hotkeyLabel.Position = UDim2.new(1, 0, 0, 118)
    hotkeyLabel.Size = UDim2.new(0, 160, 0, 20)
    hotkeyLabel.Text = ""
    hotkeyLabel.Parent = card

    return {
        frame = card,
        heading = statusHeading,
        support = statusSupport,
        tooltip = tooltip,
        hotkeyLabel = hotkeyLabel,
        button = toggleButton,
    }
end

local function createTelemetryCard(parent, definition)
    local card = Instance.new("Frame")
    card.Name = definition.id or "Telemetry"
    card.BackgroundColor3 = DASHBOARD_THEME.telemetryCardColor
    card.BackgroundTransparency = 0.1
    card.BorderSizePixel = 0
    card.Size = UDim2.new(0, 0, 0, 100)
    card.AutomaticSize = Enum.AutomaticSize.Y
    card.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 14)
    corner.Parent = card

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1
    stroke.Transparency = 0.5
    stroke.Color = DASHBOARD_THEME.telemetryStrokeColor
    stroke.Parent = card

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 16)
    padding.PaddingBottom = UDim.new(0, 16)
    padding.PaddingLeft = UDim.new(0, 18)
    padding.PaddingRight = UDim.new(0, 18)
    padding.Parent = card

    local label = Instance.new("TextLabel")
    label.Name = "Label"
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamSemibold
    label.TextSize = 16
    label.TextColor3 = Color3.fromRGB(185, 205, 240)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = definition.label or "Telemetry"
    label.Size = UDim2.new(1, 0, 0, 18)
    label.Parent = card

    local value = Instance.new("TextLabel")
    value.Name = "Value"
    value.BackgroundTransparency = 1
    value.Font = Enum.Font.GothamBlack
    value.TextSize = 26
    value.TextColor3 = DASHBOARD_THEME.headingColor
    value.TextXAlignment = Enum.TextXAlignment.Left
    value.Text = definition.value or "--"
    value.Position = UDim2.new(0, 0, 0, 26)
    value.Size = UDim2.new(1, 0, 0, 28)
    value.Parent = card

    local hint = Instance.new("TextLabel")
    hint.Name = "Hint"
    hint.BackgroundTransparency = 1
    hint.Font = Enum.Font.Gotham
    hint.TextSize = 14
    hint.TextColor3 = Color3.fromRGB(150, 168, 205)
    hint.TextXAlignment = Enum.TextXAlignment.Left
    hint.TextWrapped = true
    hint.Text = definition.hint or ""
    hint.Position = UDim2.new(0, 0, 0, 58)
    hint.Size = UDim2.new(1, 0, 0, 28)
    hint.Parent = card

    return {
        frame = card,
        label = label,
        value = value,
        hint = hint,
    }
end

local function createTelemetrySection(parent, definitions)
    local section = Instance.new("Frame")
    section.Name = "Telemetry"
    section.BackgroundTransparency = 1
    section.LayoutOrder = 3
    section.Size = UDim2.new(1, 0, 0, 0)
    section.AutomaticSize = Enum.AutomaticSize.Y
    section.Parent = parent

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamSemibold
    title.TextSize = 18
    title.TextColor3 = Color3.fromRGB(185, 205, 240)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "Mission telemetry"
    title.Size = UDim2.new(1, 0, 0, 22)
    title.Parent = section

    local grid = Instance.new("Frame")
    grid.Name = "Cards"
    grid.BackgroundTransparency = 1
    grid.Position = UDim2.new(0, 0, 0, 30)
    grid.Size = UDim2.new(1, 0, 0, 0)
    grid.AutomaticSize = Enum.AutomaticSize.Y
    grid.Parent = section

    local layout = Instance.new("UIGridLayout")
    layout.FillDirection = Enum.FillDirection.Horizontal
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.CellSize = UDim2.new(0.5, -12, 0, 110)
    layout.CellPadding = UDim2.new(0, 12, 0, 12)
    layout.VerticalAlignment = Enum.VerticalAlignment.Top
    layout.Parent = grid

    local cards = {}
    for _, definition in ipairs(definitions) do
        local card = createTelemetryCard(grid, definition)
        cards[definition.id or definition.label] = card
    end

    return {
        frame = section,
        grid = grid,
        layout = layout,
        cards = cards,
    }
end

local function createControlToggle(parent, definition, onToggle)
    local row = Instance.new("Frame")
    row.Name = definition.id or (definition.title or "Control")
    row.BackgroundColor3 = DASHBOARD_THEME.controlCardColor
    row.BackgroundTransparency = 0.08
    row.BorderSizePixel = 0
    row.Size = UDim2.new(1, 0, 0, 80)
    row.AutomaticSize = Enum.AutomaticSize.Y
    row.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 14)
    corner.Parent = row

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1
    stroke.Transparency = 0.5
    stroke.Color = DASHBOARD_THEME.controlStrokeColor
    stroke.Parent = row

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 18)
    padding.PaddingBottom = UDim.new(0, 18)
    padding.PaddingLeft = UDim.new(0, 20)
    padding.PaddingRight = UDim.new(0, 20)
    padding.Parent = row

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamSemibold
    title.TextSize = 17
    title.TextColor3 = DASHBOARD_THEME.headingColor
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = definition.title or "Control"
    title.Size = UDim2.new(1, -150, 0, 20)
    title.Parent = row

    local description = Instance.new("TextLabel")
    description.Name = "Description"
    description.BackgroundTransparency = 1
    description.Font = Enum.Font.Gotham
    description.TextSize = 14
    description.TextColor3 = Color3.fromRGB(160, 178, 210)
    description.TextWrapped = true
    description.TextXAlignment = Enum.TextXAlignment.Left
    description.Text = definition.description or ""
    description.Position = UDim2.new(0, 0, 0, 24)
    description.Size = UDim2.new(1, -150, 0, 34)
    description.Parent = row

    local badge
    if definition.badge then
        badge = Instance.new("TextLabel")
        badge.Name = "Badge"
        badge.BackgroundTransparency = 1
        badge.Font = Enum.Font.GothamSemibold
        badge.TextSize = 13
        badge.TextColor3 = Color3.fromRGB(180, 205, 255)
        badge.Text = definition.badge
        badge.TextXAlignment = Enum.TextXAlignment.Left
        badge.Position = UDim2.new(0, 0, 0, 58)
        badge.Size = UDim2.new(0, 80, 0, 18)
        badge.Parent = row
    end

    local switch = Instance.new("TextButton")
    switch.Name = "Switch"
    switch.AutoButtonColor = false
    switch.AnchorPoint = Vector2.new(1, 0.5)
    switch.Position = UDim2.new(1, 0, 0.5, 0)
    switch.Size = UDim2.new(0, 120, 0, 34)
    switch.BackgroundColor3 = DASHBOARD_THEME.toggleOffColor
    switch.TextColor3 = DASHBOARD_THEME.toggleOffTextColor
    switch.Font = Enum.Font.GothamBold
    switch.TextSize = 16
    switch.Text = "OFF"
    switch.BorderSizePixel = 0
    switch.Parent = row

    local switchCorner = Instance.new("UICorner")
    switchCorner.CornerRadius = UDim.new(0, 12)
    switchCorner.Parent = switch

    local currentState = definition.default == true

    local function applyState(state)
        currentState = state
        if state then
            switch.Text = "ON"
            switch.BackgroundColor3 = DASHBOARD_THEME.toggleOnColor
            switch.TextColor3 = DASHBOARD_THEME.toggleOnTextColor
        else
            switch.Text = "OFF"
            switch.BackgroundColor3 = DASHBOARD_THEME.toggleOffColor
            switch.TextColor3 = DASHBOARD_THEME.toggleOffTextColor
        end
    end

    applyState(currentState)

    local connection = switch.MouseButton1Click:Connect(function()
        local nextState = not currentState
        applyState(nextState)
        if typeof(onToggle) == "function" then
            onToggle(nextState)
        end
    end)

    return {
        frame = row,
        badge = badge,
        title = title,
        description = description,
        switch = switch,
        setState = applyState,
        getState = function()
            return currentState
        end,
        connection = connection,
    }
end

local function createControlsSection(parent, definitions, onToggle)
    local section = Instance.new("Frame")
    section.Name = "Controls"
    section.BackgroundTransparency = 1
    section.LayoutOrder = 4
    section.Size = UDim2.new(1, 0, 0, 0)
    section.AutomaticSize = Enum.AutomaticSize.Y
    section.Parent = parent

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamSemibold
    title.TextSize = 18
    title.TextColor3 = Color3.fromRGB(185, 205, 240)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "Control mesh"
    title.Size = UDim2.new(1, 0, 0, 22)
    title.Parent = section

    local list = Instance.new("Frame")
    list.Name = "List"
    list.BackgroundTransparency = 1
    list.Position = UDim2.new(0, 0, 0, 30)
    list.Size = UDim2.new(1, 0, 0, 0)
    list.AutomaticSize = Enum.AutomaticSize.Y
    list.Parent = section

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 10)
    layout.Parent = list

    local toggles = {}
    for _, definition in ipairs(definitions) do
        local toggle = createControlToggle(list, definition, function(state)
            if typeof(onToggle) == "function" then
                onToggle(definition, state)
            end
        end)
        toggles[definition.id or definition.title] = toggle
    end

    return {
        frame = section,
        list = list,
        layout = layout,
        toggles = toggles,
    }
end

local function createActionsRow(parent)
    local row = Instance.new("Frame")
    row.Name = "Actions"
    row.BackgroundTransparency = 1
    row.LayoutOrder = 5
    row.Size = UDim2.new(1, 0, 0, 0)
    row.AutomaticSize = Enum.AutomaticSize.Y
    row.Visible = false
    row.Parent = parent

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Horizontal
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    layout.Padding = UDim.new(0, 12)
    layout.Parent = row

    return {
        frame = row,
        layout = layout,
    }
end

local function styleActionButton(button, variant)
    if variant == "primary" then
        button.BackgroundColor3 = DASHBOARD_THEME.toggleOnColor
        button.TextColor3 = DASHBOARD_THEME.toggleOnTextColor
    elseif variant == "ghost" then
        button.BackgroundColor3 = Color3.fromRGB(26, 34, 52)
        button.TextColor3 = Color3.fromRGB(200, 216, 245)
    else
        button.BackgroundColor3 = Color3.fromRGB(36, 46, 70)
        button.TextColor3 = Color3.fromRGB(210, 224, 255)
    end
end

function Controller:_applyVisualState(options)
    if self._destroyed then
        return
    end

    options = options or {}
    local enabled = self._enabled

    if self.button then
        if enabled then
            self.button.Text = "Disengage shield"
            self.button.BackgroundColor3 = DASHBOARD_THEME.toggleOnColor
            self.button.TextColor3 = DASHBOARD_THEME.toggleOnTextColor
        else
            self.button.Text = "Activate shield"
            self.button.BackgroundColor3 = DASHBOARD_THEME.toggleOffColor
            self.button.TextColor3 = DASHBOARD_THEME.toggleOffTextColor
        end
    end

    if self._header then
        local badge = self._header.badge
        local badgeLabel = self._header.badgeLabel
        if badge and badgeLabel then
            if enabled then
                badge.BackgroundColor3 = DASHBOARD_THEME.badgeActiveColor
                badgeLabel.TextColor3 = DASHBOARD_THEME.badgeTextActive
                badgeLabel.Text = "ACTIVE"
            else
                badge.BackgroundColor3 = DASHBOARD_THEME.badgeIdleColor
                badgeLabel.TextColor3 = DASHBOARD_THEME.badgeTextIdle
                badgeLabel.Text = "IDLE"
            end
        end
    end

    if self._statusCard then
        if (not self._statusManual) or options.forceStatusRefresh then
            if self._statusCard.heading then
                self._statusCard.heading.Text = enabled and "AutoParry online" or "AutoParry standby"
            end
            if self._statusCard.support then
                if enabled then
                    self._statusCard.support.Text = "Neural mesh guarding every ball."
                else
                    self._statusCard.support.Text = "Neural mesh waiting for activation signal."
                end
            end
        end
    end
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
    self:_applyVisualState({ forceStatusRefresh = context.forceStatusRefresh })

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

function Controller:getDashboard()
    return self.dashboard
end

function Controller:setTooltip(text)
    if self._statusCard and self._statusCard.tooltip then
        self._statusCard.tooltip.Text = text or ""
        self._statusCard.tooltip.Visible = text ~= nil and text ~= ""
    end
end

function Controller:setHotkeyDisplay(hotkeyText)
    if self._header and self._header.hotkeyLabel then
        self._header.hotkeyLabel.Text = hotkeyText and hotkeyText ~= "" and ("Hotkey: %s"):format(hotkeyText) or ""
    end
    if self._statusCard and self._statusCard.hotkeyLabel then
        self._statusCard.hotkeyLabel.Text = hotkeyText and hotkeyText ~= "" and ("Hotkey: %s"):format(hotkeyText) or ""
    end
end

function Controller:setTagline(text)
    if self._header and self._header.tagline and text then
        self._header.tagline.Text = text
    end
end

function Controller:setStatusText(primary, secondary)
    if not self._statusCard then
        return
    end

    if primary ~= nil and self._statusCard.heading then
        self._statusCard.heading.Text = tostring(primary)
        self._statusManual = true
    end

    if secondary ~= nil and self._statusCard.support then
        self._statusCard.support.Text = tostring(secondary)
        self._statusManual = true
    end
end

function Controller:resetStatusText()
    self._statusManual = false
    self:_applyVisualState({ forceStatusRefresh = true })
end

function Controller:updateTelemetry(id, payload)
    if not self._telemetryCards then
        return
    end

    local card = self._telemetryCards[id]
    if not card then
        return
    end

    if typeof(payload) == "table" then
        if payload.label ~= nil and card.label then
            card.label.Text = tostring(payload.label)
        end
        if payload.value ~= nil and card.value then
            card.value.Text = tostring(payload.value)
        end
        if payload.hint ~= nil and card.hint then
            card.hint.Text = tostring(payload.hint)
        end
    else
        if card.value then
            card.value.Text = tostring(payload)
        end
    end
end

function Controller:setTelemetry(definitions)
    definitions = definitions or DEFAULT_TELEMETRY_CARDS

    if not self._telemetrySection then
        return
    end

    for key, card in pairs(self._telemetryCards or {}) do
        if card and card.frame then
            card.frame:Destroy()
        end
        self._telemetryCards[key] = nil
    end

    local cards = {}
    for _, definition in ipairs(definitions) do
        local card = createTelemetryCard(self._telemetrySection.grid, definition)
        cards[definition.id or definition.label] = card
    end

    self._telemetryCards = cards
    self._telemetryDefinitions = definitions
end

function Controller:getTelemetryDefinitions()
    return self._telemetryDefinitions
end

function Controller:setControls(definitions)
    definitions = definitions or DEFAULT_CONTROL_SWITCHES

    if not self._controlsSection then
        return
    end

    for _, toggle in pairs(self._controlToggles or {}) do
        if toggle.connection then
            toggle.connection:Disconnect()
        end
        if toggle.frame then
            toggle.frame:Destroy()
        end
    end

    self._controlToggles = {}
    self._controlDefinitions = definitions

    for _, definition in ipairs(definitions) do
        local toggle = createControlToggle(self._controlsSection.list, definition, function(state)
            if self._controlChanged then
                self._controlChanged:fire(definition.id or definition.title, state, definition)
            end
        end)
        self._controlToggles[definition.id or definition.title] = toggle
    end
end

function Controller:setControlState(id, enabled)
    if not self._controlToggles then
        return
    end

    local toggle = self._controlToggles[id]
    if not toggle or not toggle.setState then
        return
    end

    toggle.setState(not not enabled)
end

function Controller:getControlState(id)
    if not self._controlToggles then
        return nil
    end

    local toggle = self._controlToggles[id]
    if not toggle or not toggle.getState then
        return nil
    end

    return toggle.getState()
end

function Controller:onControlChanged(callback)
    assert(typeof(callback) == "function", "UI.onControlChanged expects a function")
    return self._controlChanged:connect(callback)
end

function Controller:setActions(actions)
    if not self._actionsRow then
        return
    end

    for _, connection in ipairs(self._actionConnections or {}) do
        connection:Disconnect()
    end
    self._actionConnections = {}

    if self._actionsRow.frame then
        for _, child in ipairs(self._actionsRow.frame:GetChildren()) do
            if child:IsA("TextButton") then
                child:Destroy()
            end
        end
    end

    if typeof(actions) ~= "table" or #actions == 0 then
        if self._actionsRow.frame then
            self._actionsRow.frame.Visible = false
        end
        return
    end

    if self._actionsRow.frame then
        self._actionsRow.frame.Visible = true
    end

    for _, action in ipairs(actions) do
        local button = Instance.new("TextButton")
        button.Name = action.id or (action.text or "Action")
        button.AutoButtonColor = false
        button.Size = UDim2.new(0, math.max(130, action.minWidth or 150), 0, 38)
        button.BackgroundColor3 = Color3.fromRGB(36, 46, 70)
        button.TextColor3 = Color3.fromRGB(215, 228, 255)
        button.Font = Enum.Font.GothamBold
        button.TextSize = 17
        button.Text = action.text or action.id or "Action"
        button.BorderSizePixel = 0
        button.Parent = self._actionsRow.frame

        styleActionButton(button, action.variant or (action.primary and "primary") or action.style)

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 12)
        corner.Parent = button

        local connection = button.MouseButton1Click:Connect(function()
            if typeof(action.callback) == "function" then
                action.callback(action, self)
            end
        end)
        table.insert(self._actionConnections, connection)
    end
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

    for _, connection in ipairs(self._actionConnections or {}) do
        connection:Disconnect()
    end
    self._actionConnections = {}

    if self._controlToggles then
        for _, toggle in pairs(self._controlToggles) do
            if toggle.connection then
                toggle.connection:Disconnect()
            end
        end
        self._controlToggles = {}
    end

    if self._controlChanged then
        self._controlChanged:destroy()
        self._controlChanged = nil
    end

    if self._hotkeyConnection then
        self._hotkeyConnection:Disconnect()
        self._hotkeyConnection = nil
    end

    if self.gui then
        self.gui:Destroy()
        self.gui = nil
    end

    self.dashboard = nil
    self.button = nil
    self._header = nil
    self._statusCard = nil
    self._telemetrySection = nil
    self._telemetryCards = nil
    self._controlsSection = nil
    self._actionsRow = nil

    if self._changed then
        self._changed:destroy()
        self._changed = nil
    end
end

function UI.mount(options)
    options = options or {}

    local gui = ensureGuiRoot("AutoParryUI")
    local dashboard, content = createDashboardFrame(gui)

    local rawHotkey = options.hotkey
    local hotkeyDescriptor = parseHotkey(rawHotkey)
    local hotkeyDisplay = formatHotkeyDisplay(hotkeyDescriptor and hotkeyDescriptor.key and hotkeyDescriptor or rawHotkey)

    local header = createHeader(content, options.title or "AutoParry", hotkeyDisplay)
    if typeof(options.tagline) == "string" then
        header.tagline.Text = options.tagline
    end

    local statusCard = createStatusCard(content)
    statusCard.tooltip.Text = options.tooltip or ""
    statusCard.tooltip.Visible = options.tooltip ~= nil and options.tooltip ~= ""
    statusCard.hotkeyLabel.Text = hotkeyDisplay and ("Hotkey: %s"):format(hotkeyDisplay) or ""

    local telemetryDefinitions = options.telemetry or DEFAULT_TELEMETRY_CARDS
    local telemetry = createTelemetrySection(content, telemetryDefinitions)

    local controlSignal = Util.Signal.new()
    local controlDefinitions = options.controls or DEFAULT_CONTROL_SWITCHES
    local controls = createControlsSection(content, controlDefinitions, function(definition, state)
        controlSignal:fire(definition.id or definition.title, state, definition)
    end)

    local actions = createActionsRow(content)

    local controller = setmetatable({
        gui = gui,
        dashboard = dashboard,
        button = statusCard.button,
        _enabled = false,
        _statusManual = false,
        _onToggle = options.onToggle,
        _connections = {},
        _actionConnections = {},
        _telemetrySection = telemetry,
        _telemetryCards = telemetry.cards,
        _telemetryDefinitions = telemetryDefinitions,
        _controlsSection = controls,
        _controlDefinitions = controlDefinitions,
        _controlToggles = controls.toggles,
        _changed = Util.Signal.new(),
        _controlChanged = controlSignal,
        _header = header,
        _statusCard = statusCard,
    }, Controller)

    controller:setHotkeyDisplay(hotkeyDisplay)

    if options.statusText or options.statusSupport then
        controller:setStatusText(options.statusText, options.statusSupport)
    end

    local buttonConnection = statusCard.button.MouseButton1Click:Connect(function()
        controller:toggle()
    end)
    table.insert(controller._connections, buttonConnection)

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

    controller:_applyVisualState({ forceStatusRefresh = true })
    controller:setTooltip(options.tooltip)

    local overlay = LoadingOverlay.getActive and LoadingOverlay.getActive()
    if overlay and not overlay:isComplete() then
        dashboard.Visible = false
        gui.Enabled = false
    else
        gui.Enabled = true
    end

    if overlay and not overlay:isComplete() then
        local connection
        connection = overlay:onCompleted(function()
            if controller._destroyed then
                return
            end
            dashboard.Visible = true
            gui.Enabled = true
            if connection then
                connection:Disconnect()
                connection = nil
            end
        end)
        table.insert(controller._connections, connection)
    end

    controller:setEnabled(options.initialState == true, { silent = true, forceStatusRefresh = true })

    return controller
end

function UI.createLoadingOverlay(options)
    return LoadingOverlay.create(options)
end

function UI.getLoadingOverlay()
    if LoadingOverlay.getActive then
        return LoadingOverlay.getActive()
    end
    return nil
end

return UI


]===],
    ['src/ui/loading_overlay.lua'] = [===[
-- mikkel32/AutoParry : src/ui/loading_overlay.lua
-- Full-screen loading overlay with spinner, progress bar, status text, and optional tips.
--
-- API:
--   local overlay = LoadingOverlay.create({
--       parent = CoreGui, -- optional custom parent
--       name = "AutoParryLoadingOverlay", -- ScreenGui name override
--       tips = { "Tip A", "Tip B" }, -- optional table of rotating tips
--       theme = { -- override any of the keys below to theme the overlay
--           backdropColor = Color3.fromRGB(6, 7, 9),
--           backdropTransparency = 0.2,
--           accentColor = Color3.fromRGB(0, 170, 255),
--           spinnerColor = Color3.fromRGB(255, 255, 255),
--           progressBackgroundColor = Color3.fromRGB(40, 40, 40),
--           progressFillColor = Color3.fromRGB(0, 170, 255),
--           statusTextColor = Color3.fromRGB(235, 235, 235),
--           tipTextColor = Color3.fromRGB(180, 180, 180),
--           containerSize = UDim2.new(0, 360, 0, 240),
--           spinnerSize = UDim2.new(0, 72, 0, 72),
--           progressBarSize = UDim2.new(0, 280, 0, 12),
--           progressTweenSeconds = 0.35,
--           statusTweenSeconds = 0.18,
--       },
--   })
--
-- Methods on the returned overlay instance:
--   overlay:setStatus(text, options?)
--   overlay:setProgress(alpha, options?)
--   overlay:setTips(tipsTable)
--   overlay:showTip(text)
--   overlay:nextTip()
--   overlay:applyTheme(themeOverrides)
--   overlay:complete()
--   overlay:onCompleted(callback) -> connection
--   overlay:isComplete() -> bool
--   overlay:destroy()
--
-- Styling hooks are exposed through the `theme` table. Downstream experiences can
-- call `overlay:applyTheme` at runtime to adjust colors, fonts, and layout metrics.

local CoreGui = game:GetService("CoreGui")
local TweenService = game:GetService("TweenService")
local ContentProvider = game:GetService("ContentProvider")
local Workspace = game:GetService("Workspace")

local Require = rawget(_G, "ARequire")
local Util = Require("src/shared/util.lua")

local LoadingOverlay = {}
LoadingOverlay.__index = LoadingOverlay

local Module = {}

local FONT_ASSET = "rbxasset://fonts/families/GothamSSm.json"
local SPINNER_ASSET = "rbxasset://textures/ui/LoadingIndicator.png"

local DEFAULT_THEME = {
    backdropColor = Color3.fromRGB(6, 6, 6),
    backdropTransparency = 0.35,
    accentColor = Color3.fromRGB(0, 170, 255),
    spinnerColor = Color3.fromRGB(255, 255, 255),
    progressBackgroundColor = Color3.fromRGB(24, 26, 40),
    progressFillColor = Color3.fromRGB(0, 170, 255),
    statusTextColor = Color3.fromRGB(240, 240, 240),
    tipTextColor = Color3.fromRGB(185, 185, 185),
    containerSize = UDim2.new(0, 640, 0, 360),
    containerTransparency = 0.08,
    containerCornerRadius = UDim.new(0, 18),
    containerStrokeColor = Color3.fromRGB(0, 150, 255),
    containerStrokeTransparency = 0.35,
    containerStrokeThickness = 2,
    spinnerSize = UDim2.new(0, 96, 0, 96),
    spinnerPosition = UDim2.new(0.5, 0, 0.22, 0),
    progressBarSize = UDim2.new(0.85, 0, 0, 14),
    progressBarPosition = UDim2.new(0.5, 0, 0.52, 0),
    statusPosition = UDim2.new(0.5, 0, 0.7, 0),
    tipPosition = UDim2.new(0.5, 0, 0.85, 0),
    progressTweenSeconds = 0.35,
    statusTweenSeconds = 0.18,
    actionsPadding = UDim.new(0, 12),
    actionsPosition = UDim2.new(0.5, 0, 1, -24),
    actionsSize = UDim2.new(0.9, 0, 0, 44),
    actionButtonHeight = 40,
    actionButtonMinWidth = 140,
    actionButtonCorner = UDim.new(0, 10),
    actionButtonFont = Enum.Font.GothamBold,
    actionButtonTextSize = 18,
    actionPrimaryColor = Color3.fromRGB(0, 170, 255),
    actionPrimaryTextColor = Color3.fromRGB(15, 15, 15),
    actionSecondaryColor = Color3.fromRGB(40, 45, 65),
    actionSecondaryTextColor = Color3.fromRGB(240, 240, 240),
    glow = {
        color = Color3.fromRGB(0, 255, 255),
        transparency = 0.55,
        size = Vector2.new(120, 160),
    },
    gradient = {
        enabled = true,
        rotation = 115,
        color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(12, 16, 36)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 170, 255)),
        }),
        transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.25),
            NumberSequenceKeypoint.new(0.55, 0.45),
            NumberSequenceKeypoint.new(1, 0.2),
        }),
    },
    hero = {
        titleFont = Enum.Font.GothamBlack,
        titleTextSize = 28,
        titleColor = Color3.fromRGB(235, 245, 255),
        subtitleFont = Enum.Font.Gotham,
        subtitleTextSize = 18,
        subtitleColor = Color3.fromRGB(188, 210, 255),
        pillFont = Enum.Font.GothamSemibold,
        pillTextSize = 14,
        pillTextColor = Color3.fromRGB(205, 225, 255),
        pillBackgroundColor = Color3.fromRGB(16, 24, 40),
        pillTransparency = 0.1,
        pillAccentColor = Color3.fromRGB(0, 210, 255),
        pillStrokeTransparency = 0.55,
        gridPadding = 12,
    },
    dashboardPanel = {
        backgroundColor = Color3.fromRGB(12, 18, 32),
        backgroundTransparency = 0.05,
        strokeColor = Color3.fromRGB(0, 170, 255),
        strokeTransparency = 0.45,
        cornerRadius = UDim.new(0, 16),
        gradient = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(10, 16, 28)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 110, 180)),
        }),
        gradientTransparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.8),
            NumberSequenceKeypoint.new(1, 0.3),
        }),
    },
    iconography = {
        spinner = SPINNER_ASSET,
        check = "rbxassetid://6031068421",
        warning = "rbxassetid://6031071051",
        error = "rbxassetid://6031094678",
        pending = "rbxassetid://6031071050",
        hologram = "rbxassetid://12148062841",
        progressArc = "rbxassetid://10957012643",
    },
    typography = {
        statusFont = Enum.Font.GothamMedium,
        statusTextSize = 20,
        tipFont = Enum.Font.Gotham,
        tipTextSize = 16,
        badgeFont = Enum.Font.GothamBold,
        badgeTextSize = 16,
        timelineHeadingFont = Enum.Font.GothamBlack,
        timelineHeadingSize = 20,
        timelineStepFont = Enum.Font.GothamSemibold,
        timelineStepSize = 18,
        timelineTooltipFont = Enum.Font.Gotham,
        timelineTooltipSize = 14,
    },
    responsive = {
        minWidth = 360,
        mediumWidth = 540,
        largeWidth = 720,
        maxWidth = 820,
        columnSpacing = 32,
    },
    hologramBadgeColor = Color3.fromRGB(0, 210, 255),
    hologramBadgeTransparency = 0.25,
    progressArcColor = Color3.fromRGB(0, 210, 255),
    progressArcTransparency = 0.4,
    dashboardMountSize = UDim2.new(1, -12, 1, -12),
}

local activeOverlay

local function mergeTable(base, overrides)
    if typeof(overrides) ~= "table" then
        return base
    end

    local merged = Util.deepCopy(base)
    for key, value in pairs(overrides) do
        if typeof(value) == "table" and typeof(merged[key]) == "table" then
            merged[key] = mergeTable(merged[key], value)
        else
            merged[key] = value
        end
    end

    return merged
end

local function mergeTheme(overrides)
    local theme = Util.deepCopy(DEFAULT_THEME)
    if typeof(overrides) == "table" then
        theme = mergeTable(theme, overrides)
        if overrides.accentColor then
            if overrides.progressFillColor == nil then
                theme.progressFillColor = overrides.accentColor
            end
            if overrides.spinnerColor == nil then
                theme.spinnerColor = overrides.accentColor
            end
        end
    end
    return theme
end

local function resolveScreenGuiParent(requestedParent)
    if typeof(requestedParent) ~= "Instance" then
        return CoreGui
    end

    local current = requestedParent
    while current do
        if current:IsA("CoreGui") or current:IsA("BasePlayerGui") then
            return current
        end

        current = current.Parent
    end

    return CoreGui
end

local function createScreenGui(options)
    local parent = resolveScreenGuiParent(options.parent)

    local gui = Instance.new("ScreenGui")
    gui.Name = options.name or "AutoParryLoadingOverlay"
    gui.DisplayOrder = 10_000
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.IgnoreGuiInset = true
    gui.Parent = parent
    return gui
end

local function createSpinner(parent, theme)
    local spinner = Instance.new("ImageLabel")
    spinner.Name = "Spinner"
    spinner.AnchorPoint = Vector2.new(0.5, 0.5)
    spinner.Size = theme.spinnerSize or DEFAULT_THEME.spinnerSize
    spinner.Position = theme.spinnerPosition or DEFAULT_THEME.spinnerPosition
    spinner.BackgroundTransparency = 1
    spinner.Image = (theme.iconography and theme.iconography.spinner)
        or theme.spinnerAsset
        or SPINNER_ASSET
    spinner.ImageColor3 = theme.spinnerColor or DEFAULT_THEME.spinnerColor
    spinner.Parent = parent
    return spinner
end

local function createProgressBar(parent, theme)
    local bar = Instance.new("Frame")
    bar.Name = "Progress"
    bar.AnchorPoint = Vector2.new(0.5, 0)
    bar.Size = theme.progressBarSize or DEFAULT_THEME.progressBarSize
    bar.Position = theme.progressBarPosition or DEFAULT_THEME.progressBarPosition
    bar.BackgroundColor3 = theme.progressBackgroundColor or DEFAULT_THEME.progressBackgroundColor
    bar.BackgroundTransparency = 0.25
    bar.BorderSizePixel = 0
    bar.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = bar

    local fill = Instance.new("Frame")
    fill.Name = "Fill"
    fill.AnchorPoint = Vector2.new(0, 0.5)
    fill.Position = UDim2.new(0, 0, 0.5, 0)
    fill.Size = UDim2.new(0, 0, 1, 0)
    fill.BackgroundColor3 = theme.progressFillColor or DEFAULT_THEME.progressFillColor
    fill.BackgroundTransparency = 0
    fill.BorderSizePixel = 0
    fill.Parent = bar

    local fillCorner = Instance.new("UICorner")
    fillCorner.CornerRadius = UDim.new(0, 6)
    fillCorner.Parent = fill

    return bar, fill
end

local function createStatusLabel(parent, theme)
    local label = Instance.new("TextLabel")
    label.Name = "Status"
    label.AnchorPoint = Vector2.new(0.5, 0)
    label.Position = theme.statusPosition or DEFAULT_THEME.statusPosition
    label.Size = UDim2.new(0.8, 0, 0, 32)
    label.BackgroundTransparency = 1
    label.Font = (theme.typography and theme.typography.statusFont)
        or DEFAULT_THEME.typography.statusFont
    label.TextSize = (theme.typography and theme.typography.statusTextSize)
        or DEFAULT_THEME.typography.statusTextSize
    label.TextColor3 = theme.statusTextColor or DEFAULT_THEME.statusTextColor
    label.Text = ""
    label.TextWrapped = true
    label.Parent = parent
    return label
end

local function createTipLabel(parent, theme)
    local label = Instance.new("TextLabel")
    label.Name = "Tip"
    label.AnchorPoint = Vector2.new(0.5, 0)
    label.Position = theme.tipPosition or DEFAULT_THEME.tipPosition
    label.Size = UDim2.new(0.9, 0, 0, 28)
    label.BackgroundTransparency = 1
    label.Font = (theme.typography and theme.typography.tipFont)
        or DEFAULT_THEME.typography.tipFont
    label.TextSize = (theme.typography and theme.typography.tipTextSize)
        or DEFAULT_THEME.typography.tipTextSize
    label.TextColor3 = theme.tipTextColor or DEFAULT_THEME.tipTextColor
    label.TextTransparency = 0.15
    label.TextWrapped = true
    label.Text = ""
    label.Visible = false
    label.Parent = parent
    return label
end

local function createHeroPill(parent, theme, text)
    local heroTheme = theme.hero or DEFAULT_THEME.hero or {}

    local pill = Instance.new("Frame")
    pill.Name = "HeroPill"
    pill.BackgroundTransparency = heroTheme.pillTransparency or 0.1
    pill.BackgroundColor3 = heroTheme.pillBackgroundColor or Color3.fromRGB(16, 24, 40)
    pill.BorderSizePixel = 0
    pill.Size = UDim2.new(0, 180, 0, 34)
    pill.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 14)
    corner.Parent = pill

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1
    stroke.Transparency = heroTheme.pillStrokeTransparency or 0.55
    stroke.Color = theme.accentColor or DEFAULT_THEME.accentColor
    stroke.Parent = pill

    local accent = Instance.new("Frame")
    accent.Name = "Accent"
    accent.AnchorPoint = Vector2.new(0, 0.5)
    accent.Position = UDim2.new(0, 10, 0.5, 0)
    accent.Size = UDim2.new(0, 10, 0, 10)
    accent.BackgroundColor3 = heroTheme.pillAccentColor or theme.accentColor or DEFAULT_THEME.accentColor
    accent.BorderSizePixel = 0
    accent.Parent = pill

    local accentCorner = Instance.new("UICorner")
    accentCorner.CornerRadius = UDim.new(1, 0)
    accentCorner.Parent = accent

    local label = Instance.new("TextLabel")
    label.Name = "Label"
    label.BackgroundTransparency = 1
    label.Size = UDim2.new(1, -36, 1, 0)
    label.Position = UDim2.new(0, 28, 0, 0)
    label.Font = heroTheme.pillFont or Enum.Font.GothamSemibold
    label.TextSize = heroTheme.pillTextSize or 14
    label.TextColor3 = heroTheme.pillTextColor or Color3.fromRGB(205, 225, 255)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = text or ""
    label.Parent = pill

    return {
        frame = pill,
        label = label,
        accent = accent,
        stroke = stroke,
    }
end

local function createActionsRow(parent, theme)
    local frame = Instance.new("Frame")
    frame.Name = "Actions"
    frame.AnchorPoint = Vector2.new(0.5, 1)
    frame.Position = theme.actionsPosition or DEFAULT_THEME.actionsPosition
    frame.Size = theme.actionsSize or DEFAULT_THEME.actionsSize
    frame.BackgroundTransparency = 1
    frame.Visible = false
    frame.Parent = parent

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Horizontal
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    layout.VerticalAlignment = Enum.VerticalAlignment.Center
    layout.Padding = theme.actionsPadding or DEFAULT_THEME.actionsPadding
    layout.Parent = frame

    return frame, layout
end

local function preloadAssets(instances)
    task.spawn(function()
        local payload = {}
        for _, item in ipairs(instances) do
            if item ~= nil then
                table.insert(payload, item)
            end
        end

        if #payload == 0 then
            return
        end

        local ok, err = pcall(function()
            ContentProvider:PreloadAsync(payload)
        end)
        if not ok then
            warn("AutoParry loading overlay preload failed:", err)
        end
    end)
end

function LoadingOverlay.new(options)
    options = options or {}
    local theme = mergeTheme(options.theme)

    local gui = createScreenGui(options)

    local backdrop = Instance.new("Frame")
    backdrop.Name = "Backdrop"
    backdrop.Size = UDim2.new(1, 0, 1, 0)
    backdrop.BackgroundColor3 = theme.backdropColor or DEFAULT_THEME.backdropColor
    backdrop.BackgroundTransparency = theme.backdropTransparency or DEFAULT_THEME.backdropTransparency
    backdrop.BorderSizePixel = 0
    backdrop.Parent = gui

    local container = Instance.new("Frame")
    container.Name = "Container"
    container.AnchorPoint = Vector2.new(0.5, 0.5)
    container.Position = UDim2.new(0.5, 0, 0.5, 0)
    container.Size = theme.containerSize or DEFAULT_THEME.containerSize
    container.BackgroundColor3 = theme.containerBackgroundColor or Color3.fromRGB(10, 14, 28)
    container.BackgroundTransparency = theme.containerTransparency or DEFAULT_THEME.containerTransparency or 0
    container.BorderSizePixel = 0
    container.ClipsDescendants = false
    container.Parent = backdrop

    local containerCorner = Instance.new("UICorner")
    containerCorner.CornerRadius = theme.containerCornerRadius or DEFAULT_THEME.containerCornerRadius
    containerCorner.Parent = container

    local containerStroke = Instance.new("UIStroke")
    containerStroke.Thickness = theme.containerStrokeThickness or DEFAULT_THEME.containerStrokeThickness or 2
    containerStroke.Color = theme.containerStrokeColor or theme.accentColor or DEFAULT_THEME.containerStrokeColor
    containerStroke.Transparency = theme.containerStrokeTransparency or DEFAULT_THEME.containerStrokeTransparency or 0.4
    containerStroke.Parent = container

    local containerGradient
    if theme.gradient and theme.gradient.enabled ~= false then
        containerGradient = Instance.new("UIGradient")
        containerGradient.Name = "ContainerGradient"
        containerGradient.Color = theme.gradient.color or DEFAULT_THEME.gradient.color
        containerGradient.Transparency = theme.gradient.transparency or DEFAULT_THEME.gradient.transparency
        containerGradient.Rotation = theme.gradient.rotation or DEFAULT_THEME.gradient.rotation or 0
        containerGradient.Parent = container
    end

    local glow
    if theme.glow then
        glow = Instance.new("ImageLabel")
        glow.Name = "Glow"
        glow.AnchorPoint = Vector2.new(0.5, 0.5)
        glow.Position = UDim2.new(0.5, 0, 0.5, 0)
        glow.Size = UDim2.new(0, (theme.glow.size and theme.glow.size.X) or 240, 0, (theme.glow.size and theme.glow.size.Y) or 320)
        glow.BackgroundTransparency = 1
        glow.Image = theme.iconography and theme.iconography.hologram or "rbxassetid://12148062841"
        glow.ImageTransparency = theme.glow.transparency or 0.55
        glow.ImageColor3 = theme.glow.color or theme.accentColor or DEFAULT_THEME.accentColor
        glow.ZIndex = 0
        glow.Parent = container
    end

    local containerPadding = Instance.new("UIPadding")
    containerPadding.PaddingTop = UDim.new(0, 28)
    containerPadding.PaddingBottom = UDim.new(0, 28)
    containerPadding.PaddingLeft = UDim.new(0, 28)
    containerPadding.PaddingRight = UDim.new(0, 28)
    containerPadding.Parent = container

    local containerLayout = Instance.new("UIListLayout")
    containerLayout.FillDirection = Enum.FillDirection.Vertical
    containerLayout.SortOrder = Enum.SortOrder.LayoutOrder
    containerLayout.Padding = UDim.new(0, 18)
    containerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    containerLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    containerLayout.Parent = container

    local heroFrame = Instance.new("Frame")
    heroFrame.Name = "Hero"
    heroFrame.BackgroundTransparency = 1
    heroFrame.Size = UDim2.new(1, 0, 0, 150)
    heroFrame.LayoutOrder = 1
    heroFrame.Parent = container

    local heroLayout = Instance.new("UIListLayout")
    heroLayout.FillDirection = Enum.FillDirection.Vertical
    heroLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    heroLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    heroLayout.SortOrder = Enum.SortOrder.LayoutOrder
    heroLayout.Padding = UDim.new(0, 8)
    heroLayout.Parent = heroFrame

    local badge = Instance.new("TextLabel")
    badge.Name = "Badge"
    badge.AnchorPoint = Vector2.new(0.5, 0)
    badge.BackgroundColor3 = theme.hologramBadgeColor or DEFAULT_THEME.hologramBadgeColor
    badge.BackgroundTransparency = theme.hologramBadgeTransparency or DEFAULT_THEME.hologramBadgeTransparency
    badge.Size = UDim2.new(0, 320, 0, 30)
    badge.Font = (theme.typography and theme.typography.badgeFont) or DEFAULT_THEME.typography.badgeFont
    badge.TextSize = (theme.typography and theme.typography.badgeTextSize) or DEFAULT_THEME.typography.badgeTextSize
    badge.TextColor3 = Color3.fromRGB(255, 255, 255)
    badge.Text = "Initializing AutoParry"
    badge.TextXAlignment = Enum.TextXAlignment.Center
    badge.LayoutOrder = 1
    badge.Parent = heroFrame

    local badgeCorner = Instance.new("UICorner")
    badgeCorner.CornerRadius = UDim.new(0, 10)
    badgeCorner.Parent = badge

    local badgeStroke = Instance.new("UIStroke")
    badgeStroke.Thickness = 1.5
    badgeStroke.Transparency = 0.35
    badgeStroke.Color = (theme.accentColor or DEFAULT_THEME.accentColor)
    badgeStroke.Parent = badge

    local heroTitle = Instance.new("TextLabel")
    heroTitle.Name = "HeroTitle"
    heroTitle.BackgroundTransparency = 1
    heroTitle.Size = UDim2.new(1, -32, 0, 34)
    heroTitle.Font = (theme.hero and theme.hero.titleFont) or DEFAULT_THEME.hero.titleFont
    heroTitle.TextSize = (theme.hero and theme.hero.titleTextSize) or DEFAULT_THEME.hero.titleTextSize
    heroTitle.TextColor3 = (theme.hero and theme.hero.titleColor) or DEFAULT_THEME.hero.titleColor
    heroTitle.Text = "Command Center Online"
    heroTitle.TextXAlignment = Enum.TextXAlignment.Center
    heroTitle.LayoutOrder = 2
    heroTitle.Parent = heroFrame

    local heroSubtitle = Instance.new("TextLabel")
    heroSubtitle.Name = "HeroSubtitle"
    heroSubtitle.BackgroundTransparency = 1
    heroSubtitle.Size = UDim2.new(0.9, 0, 0, 28)
    heroSubtitle.Font = (theme.hero and theme.hero.subtitleFont) or DEFAULT_THEME.hero.subtitleFont
    heroSubtitle.TextSize = (theme.hero and theme.hero.subtitleTextSize) or DEFAULT_THEME.hero.subtitleTextSize
    heroSubtitle.TextColor3 = (theme.hero and theme.hero.subtitleColor) or DEFAULT_THEME.hero.subtitleColor
    heroSubtitle.Text = "Neural shield calibrating advanced parry heuristics"
    heroSubtitle.TextWrapped = true
    heroSubtitle.TextXAlignment = Enum.TextXAlignment.Center
    heroSubtitle.LayoutOrder = 3
    heroSubtitle.Parent = heroFrame

    local heroHighlights = Instance.new("Frame")
    heroHighlights.Name = "HeroHighlights"
    heroHighlights.BackgroundTransparency = 1
    heroHighlights.Size = UDim2.new(1, -40, 0, 40)
    heroHighlights.LayoutOrder = 4
    heroHighlights.Parent = heroFrame

    local heroHighlightsLayout = Instance.new("UIListLayout")
    heroHighlightsLayout.FillDirection = Enum.FillDirection.Horizontal
    heroHighlightsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    heroHighlightsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    heroHighlightsLayout.SortOrder = Enum.SortOrder.LayoutOrder
    heroHighlightsLayout.Padding = UDim.new(0, (theme.hero and theme.hero.gridPadding) or DEFAULT_THEME.hero.gridPadding)
    heroHighlightsLayout.Parent = heroHighlights

    local heroPills = {}
    for _, labelText in ipairs({
        "Adaptive reaction mesh",
        "Lag-safe prediction",
        "Quantum ball tracing",
    }) do
        local pill = createHeroPill(heroHighlights, theme, labelText)
        table.insert(heroPills, pill)
    end

    local contentFrame = Instance.new("Frame")
    contentFrame.Name = "Content"
    contentFrame.BackgroundTransparency = 1
    contentFrame.Size = UDim2.new(1, 0, 1, -160)
    contentFrame.LayoutOrder = 2
    contentFrame.Parent = container

    local contentLayout = Instance.new("UIListLayout")
    contentLayout.FillDirection = Enum.FillDirection.Horizontal
    contentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    contentLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
    contentLayout.Padding = UDim.new(0, (theme.responsive and theme.responsive.columnSpacing) or DEFAULT_THEME.responsive.columnSpacing or 32)
    contentLayout.Parent = contentFrame

    local infoColumn = Instance.new("Frame")
    infoColumn.Name = "InfoColumn"
    infoColumn.Size = UDim2.new(0.46, -12, 1, -12)
    infoColumn.BackgroundTransparency = 1
    infoColumn.LayoutOrder = 1
    infoColumn.Parent = contentFrame

    local infoLayout = Instance.new("UIListLayout")
    infoLayout.FillDirection = Enum.FillDirection.Vertical
    infoLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    infoLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    infoLayout.SortOrder = Enum.SortOrder.LayoutOrder
    infoLayout.Padding = UDim.new(0, 12)
    infoLayout.Parent = infoColumn

    local visualStack = Instance.new("Frame")
    visualStack.Name = "VisualStack"
    visualStack.BackgroundTransparency = 1
    visualStack.Size = UDim2.new(1, 0, 0, 150)
    visualStack.LayoutOrder = 1
    visualStack.Parent = infoColumn

    local spinner = createSpinner(visualStack, theme)
    spinner.AnchorPoint = Vector2.new(0.5, 0.5)
    spinner.Position = UDim2.new(0.5, 0, 0.5, 0)

    local progressArc = Instance.new("ImageLabel")
    progressArc.Name = "ProgressArc"
    progressArc.AnchorPoint = Vector2.new(0.5, 0.5)
    progressArc.Position = UDim2.new(0.5, 0, 0.5, 0)
    progressArc.Size = UDim2.new(0, math.max((spinner.Size.X.Offset or 0) + 56, 136), 0, math.max((spinner.Size.Y.Offset or 0) + 56, 136))
    progressArc.BackgroundTransparency = 1
    progressArc.Image = theme.iconography and theme.iconography.progressArc or "rbxassetid://10957012643"
    progressArc.ImageColor3 = theme.progressArcColor or DEFAULT_THEME.progressArcColor
    progressArc.ImageTransparency = theme.progressArcTransparency or DEFAULT_THEME.progressArcTransparency
    progressArc.ZIndex = spinner.ZIndex - 1
    progressArc.Parent = visualStack

    local arcGradient = Instance.new("UIGradient")
    arcGradient.Name = "ProgressGradient"
    arcGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, theme.progressArcColor or DEFAULT_THEME.progressArcColor),
        ColorSequenceKeypoint.new(1, theme.progressArcColor or DEFAULT_THEME.progressArcColor),
    })
    arcGradient.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0),
        NumberSequenceKeypoint.new(0.5, 0.35),
        NumberSequenceKeypoint.new(1, 1),
    })
    arcGradient.Rotation = 0
    arcGradient.Offset = Vector2.new(-1, 0)
    arcGradient.Parent = progressArc

    local progressBar, progressFill = createProgressBar(infoColumn, theme)
    progressBar.LayoutOrder = 2

    local statusLabel = createStatusLabel(infoColumn, theme)
    statusLabel.LayoutOrder = 3

    local tipLabel = createTipLabel(infoColumn, theme)
    tipLabel.LayoutOrder = 4

    local actionsRow, actionsLayout = createActionsRow(infoColumn, theme)
    actionsRow.AnchorPoint = Vector2.new(0.5, 0)
    actionsRow.Position = UDim2.new(0.5, 0, 0, 0)
    actionsRow.LayoutOrder = 5

    local dashboardColumn = Instance.new("Frame")
    dashboardColumn.Name = "DashboardColumn"
    dashboardColumn.Size = UDim2.new(0.54, 0, 1, 0)
    dashboardColumn.BackgroundTransparency = 1
    dashboardColumn.LayoutOrder = 2
    dashboardColumn.Parent = contentFrame

    local dashboardSurface = Instance.new("Frame")
    dashboardSurface.Name = "DashboardSurface"
    dashboardSurface.AnchorPoint = Vector2.new(0.5, 0.5)
    dashboardSurface.Position = UDim2.new(0.5, 0, 0.5, 0)
    dashboardSurface.Size = UDim2.new(1, -4, 1, -4)
    dashboardSurface.BackgroundColor3 = (theme.dashboardPanel and theme.dashboardPanel.backgroundColor) or DEFAULT_THEME.dashboardPanel.backgroundColor
    dashboardSurface.BackgroundTransparency = (theme.dashboardPanel and theme.dashboardPanel.backgroundTransparency) or DEFAULT_THEME.dashboardPanel.backgroundTransparency
    dashboardSurface.BorderSizePixel = 0
    dashboardSurface.Parent = dashboardColumn

    local dashboardCorner = Instance.new("UICorner")
    dashboardCorner.CornerRadius = (theme.dashboardPanel and theme.dashboardPanel.cornerRadius) or DEFAULT_THEME.dashboardPanel.cornerRadius
    dashboardCorner.Parent = dashboardSurface

    local dashboardStroke = Instance.new("UIStroke")
    dashboardStroke.Thickness = 1.6
    dashboardStroke.Color = (theme.dashboardPanel and theme.dashboardPanel.strokeColor) or DEFAULT_THEME.dashboardPanel.strokeColor
    dashboardStroke.Transparency = (theme.dashboardPanel and theme.dashboardPanel.strokeTransparency) or DEFAULT_THEME.dashboardPanel.strokeTransparency
    dashboardStroke.Parent = dashboardSurface

    local dashboardGradient = Instance.new("UIGradient")
    dashboardGradient.Color = (theme.dashboardPanel and theme.dashboardPanel.gradient) or DEFAULT_THEME.dashboardPanel.gradient
    dashboardGradient.Transparency = (theme.dashboardPanel and theme.dashboardPanel.gradientTransparency) or DEFAULT_THEME.dashboardPanel.gradientTransparency
    dashboardGradient.Rotation = 120
    dashboardGradient.Parent = dashboardSurface

    local dashboardMount = Instance.new("Frame")
    dashboardMount.Name = "DashboardMount"
    dashboardMount.BackgroundTransparency = 1
    dashboardMount.Size = theme.dashboardMountSize or DEFAULT_THEME.dashboardMountSize
    dashboardMount.Position = UDim2.new(0.5, 0, 0.5, 0)
    dashboardMount.AnchorPoint = Vector2.new(0.5, 0.5)
    dashboardMount.Parent = dashboardSurface

    preloadAssets({
        spinner,
        progressBar,
        FONT_ASSET,
        SPINNER_ASSET,
        progressArc,
        badge,
        (theme.iconography and theme.iconography.check) or nil,
        (theme.iconography and theme.iconography.warning) or nil,
        (theme.iconography and theme.iconography.error) or nil,
        (theme.iconography and theme.iconography.pending) or nil,
    })

    local self = setmetatable({
        _gui = gui,
        _backdrop = backdrop,
        _container = container,
        _spinner = spinner,
        _progressBar = progressBar,
        _progressFill = progressFill,
        _statusLabel = statusLabel,
        _tipLabel = tipLabel,
        _actionsRow = actionsRow,
        _actionsLayout = actionsLayout,
        _dashboardMount = dashboardMount,
        _progressArc = progressArc,
        _progressArcGradient = arcGradient,
        _badge = badge,
        _heroFrame = heroFrame,
        _heroTitle = heroTitle,
        _heroSubtitle = heroSubtitle,
        _heroHighlightsFrame = heroHighlights,
        _heroPills = heroPills,
        _heroTitleText = heroTitle.Text,
        _heroSubtitleText = heroSubtitle.Text,
        _heroHighlightTexts = {
            heroPills[1] and heroPills[1].label and heroPills[1].label.Text or "Adaptive reaction mesh",
            heroPills[2] and heroPills[2].label and heroPills[2].label.Text or "Lag-safe prediction",
            heroPills[3] and heroPills[3].label and heroPills[3].label.Text or "Quantum ball tracing",
        },
        _contentFrame = contentFrame,
        _contentLayout = contentLayout,
        _infoColumn = infoColumn,
        _infoLayout = infoLayout,
        _visualStack = visualStack,
        _dashboardColumn = dashboardColumn,
        _dashboardSurface = dashboardSurface,
        _dashboardStroke = dashboardStroke,
        _dashboardGradient = dashboardGradient,
        _containerGlow = glow,
        _containerGradient = containerGradient,
        _viewportConnection = nil,
        _badgeStatus = "Initializing AutoParry",
        _badgeProgress = 0,
        _dashboard = nil,
        _progress = 0,
        _completed = false,
        _destroyed = false,
        _theme = theme,
        _tips = nil,
        _tipIndex = 0,
        _connections = {},
        _completedSignal = Util.Signal.new(),
        _actionButtons = {},
        _actionConnections = {},
        _actions = nil,
    }, LoadingOverlay)

    local spinnerTween = TweenService:Create(spinner, TweenInfo.new(1.2, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1), {
        Rotation = 360,
    })
    spinnerTween:Play()
    self._spinnerTween = spinnerTween

    self:_connectResponsiveLayout()

    if typeof(options.tips) == "table" then
        self:setTips(options.tips)
    end

    if typeof(options.heroTitle) == "string" then
        self:setHeroTitle(options.heroTitle)
    end
    if typeof(options.heroSubtitle) == "string" then
        self:setHeroSubtitle(options.heroSubtitle)
    end
    if typeof(options.heroHighlights) == "table" then
        self:setHeroHighlights(options.heroHighlights)
    end

    self:_refreshBadge()

    return self
end

function LoadingOverlay:_applyResponsiveLayout(viewportSize)
    if self._destroyed then
        return
    end

    local container = self._container
    if not container then
        return
    end

    local theme = self._theme or DEFAULT_THEME
    local responsive = theme.responsive or DEFAULT_THEME.responsive or {}
    local viewportWidth = viewportSize and viewportSize.X or (theme.containerSize and theme.containerSize.X.Offset) or 640
    local minWidth = responsive.minWidth or 360
    local maxWidth = responsive.maxWidth or viewportWidth
    local desiredWidth = math.clamp(math.floor(viewportWidth * 0.7), minWidth, maxWidth)
    local defaultHeight = (theme.containerSize and theme.containerSize.Y.Offset)
        or (DEFAULT_THEME.containerSize and DEFAULT_THEME.containerSize.Y.Offset)
        or 360

    container.Size = UDim2.new(0, desiredWidth, 0, defaultHeight)

    local contentLayout = self._contentLayout
    local infoColumn = self._infoColumn
    local dashboardColumn = self._dashboardColumn
    local heroFrame = self._heroFrame
    if not infoColumn or not dashboardColumn then
        return
    end

    local columnSpacing = responsive.columnSpacing or 32
    if contentLayout then
        contentLayout.Padding = UDim.new(0, columnSpacing)
    end

    if viewportWidth <= (responsive.mediumWidth or 540) then
        if contentLayout then
            contentLayout.FillDirection = Enum.FillDirection.Vertical
            contentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        end

        infoColumn.Size = UDim2.new(1, -32, 0, 260)
        dashboardColumn.Size = UDim2.new(1, -32, 0, 320)

        if heroFrame then
            heroFrame.Size = UDim2.new(1, 0, 0, 190)
        end
    elseif viewportWidth <= (responsive.largeWidth or 720) then
        if contentLayout then
            contentLayout.FillDirection = Enum.FillDirection.Vertical
            contentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        end

        infoColumn.Size = UDim2.new(1, -32, 0, 300)
        dashboardColumn.Size = UDim2.new(1, -32, 0, 340)

        if heroFrame then
            heroFrame.Size = UDim2.new(1, 0, 0, 180)
        end
    else
        if contentLayout then
            contentLayout.FillDirection = Enum.FillDirection.Horizontal
            contentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        end

        infoColumn.Size = UDim2.new(0.46, -columnSpacing, 1, -12)
        dashboardColumn.Size = UDim2.new(0.54, 0, 1, -12)

        if heroFrame then
            heroFrame.Size = UDim2.new(1, 0, 0, 150)
        end
    end
end

function LoadingOverlay:_connectResponsiveLayout()
    local function applyFromCamera(camera)
        if not camera then
            self:_applyResponsiveLayout(nil)
            return
        end
        self:_applyResponsiveLayout(camera.ViewportSize)
    end

    local function connectViewport(camera)
        if self._viewportConnection then
            self._viewportConnection:Disconnect()
            self._viewportConnection = nil
        end
        if not camera then
            return
        end
        applyFromCamera(camera)
        local connection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
            applyFromCamera(camera)
        end)
        table.insert(self._connections, connection)
        self._viewportConnection = connection
    end

    connectViewport(Workspace.CurrentCamera)

    local cameraChanged = Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
        connectViewport(Workspace.CurrentCamera)
    end)
    table.insert(self._connections, cameraChanged)
end

local function truncateBadgeText(text)
    if typeof(text) ~= "string" then
        return ""
    end

    local sanitized = text:gsub("%s+", " ")
    if #sanitized > 40 then
        sanitized = sanitized:sub(1, 40) .. "…"
    end
    return sanitized
end

function LoadingOverlay:_refreshBadge()
    if not self._badge then
        return
    end

    local status = truncateBadgeText(self._badgeStatus or "Initializing AutoParry")
    local progress = self._badgeProgress
    if typeof(progress) == "number" then
        self._badge.Text = string.format("%s  •  %d%%", status, math.floor(math.clamp(progress, 0, 1) * 100 + 0.5))
    else
        self._badge.Text = status
    end
end

function LoadingOverlay:_setBadgeStatus(text)
    self._badgeStatus = text or self._badgeStatus
    self:_refreshBadge()
end

function LoadingOverlay:_setBadgeProgress(alpha)
    self._badgeProgress = alpha
    self:_refreshBadge()
end

function LoadingOverlay:_updateProgressVisual(alpha, tweenDuration)
    if self._progressArcGradient then
        if self._progressArcTween then
            self._progressArcTween:Cancel()
        end
        local targetOffset = Vector2.new(math.clamp(alpha * 2 - 1, -1, 1), 0)
        local tween = TweenService:Create(self._progressArcGradient, TweenInfo.new(tweenDuration or self._theme.progressTweenSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            Offset = targetOffset,
            Rotation = 360 * math.clamp(alpha, 0, 1),
        })
        self._progressArcTween = tween
        tween:Play()
    end

    self:_setBadgeProgress(alpha)
end

function LoadingOverlay:_applyTipVisibility()
    if not self._tipLabel then
        return
    end
    local visible = self._tipLabel.Text ~= nil and self._tipLabel.Text ~= ""
    self._tipLabel.Visible = visible
end

function LoadingOverlay:setHeroTitle(text)
    if self._destroyed then
        return
    end

    if typeof(text) ~= "string" then
        return
    end

    self._heroTitleText = text
    if self._heroTitle then
        self._heroTitle.Text = text
    end
end

function LoadingOverlay:setHeroSubtitle(text)
    if self._destroyed then
        return
    end

    if typeof(text) ~= "string" then
        return
    end

    self._heroSubtitleText = text
    if self._heroSubtitle then
        self._heroSubtitle.Text = text
    end
end

function LoadingOverlay:setHeroHighlights(highlights)
    if self._destroyed then
        return
    end

    if typeof(highlights) ~= "table" then
        return
    end

    self._heroHighlightTexts = {}

    if not self._heroPills then
        return
    end

    for index, pill in ipairs(self._heroPills) do
        local value = highlights[index]
        if typeof(value) ~= "string" then
            value = pill.label and pill.label.Text or ""
        end
        self._heroHighlightTexts[index] = value
        if pill.label then
            pill.label.Text = value
        end
    end
end

function LoadingOverlay:getTheme()
    return self._theme
end

function LoadingOverlay:getDashboardMount()
    return self._dashboardMount
end

function LoadingOverlay:attachDashboard(dashboard)
    if self._destroyed then
        if dashboard and dashboard.destroy then
            dashboard:destroy()
        end
        return
    end

    if self._dashboard and self._dashboard ~= dashboard and self._dashboard.destroy then
        self._dashboard:destroy()
    end

    self._dashboard = dashboard

    if dashboard then
        if dashboard.applyTheme then
            dashboard:applyTheme(self._theme)
        end
        if dashboard.setProgress then
            dashboard:setProgress(self._progress)
        end
        if dashboard.setStatusText and self._statusLabel then
            dashboard:setStatusText(self._statusLabel.Text)
        end
    end
end

function LoadingOverlay:updateDashboardTelemetry(telemetry)
    if self._destroyed then
        return
    end

    if self._dashboard and self._dashboard.setTelemetry then
        self._dashboard:setTelemetry(telemetry)
    end
end

function LoadingOverlay:setDashboardControls(controls)
    if self._destroyed then
        return
    end

    if self._dashboard and self._dashboard.setControls then
        self._dashboard:setControls(controls)
    end
end

function LoadingOverlay:setTips(tips)
    if self._destroyed then
        return
    end
    if typeof(tips) == "table" and #tips > 0 then
        self._tips = tips
        self._tipIndex = 0
        self:nextTip()
    else
        self._tips = nil
        self._tipIndex = 0
        self:showTip(nil)
    end
end

local function styleActionButton(button, theme, action)
    local isSecondary = action.variant == "secondary" or action.kind == "cancel"
    button.AutoButtonColor = true
    button.BorderSizePixel = 0
    button.BackgroundColor3 = action.backgroundColor
        or (isSecondary and (theme.actionSecondaryColor or DEFAULT_THEME.actionSecondaryColor)
            or (theme.actionPrimaryColor or DEFAULT_THEME.actionPrimaryColor))
    button.TextColor3 = action.textColor
        or (isSecondary and (theme.actionSecondaryTextColor or DEFAULT_THEME.actionSecondaryTextColor)
            or (theme.actionPrimaryTextColor or DEFAULT_THEME.actionPrimaryTextColor))
    button.Font = action.font or theme.actionButtonFont or DEFAULT_THEME.actionButtonFont
    button.TextSize = action.textSize or theme.actionButtonTextSize or DEFAULT_THEME.actionButtonTextSize
end

local function destroyButtons(buttons)
    if not buttons then
        return
    end
    for _, button in ipairs(buttons) do
        if button and button.Destroy then
            button:Destroy()
        end
    end
end

local function disconnectConnections(connections)
    if not connections then
        return
    end
    for _, connection in ipairs(connections) do
        if connection then
            if connection.Disconnect then
                connection:Disconnect()
            elseif connection.disconnect then
                connection:disconnect()
            end
        end
    end
end

function LoadingOverlay:setActions(actions)
    if self._destroyed then
        return
    end

    self._actions = actions

    if not self._actionsRow then
        local row, layout = createActionsRow(self._container, self._theme)
        self._actionsRow = row
        self._actionsLayout = layout
    end

    disconnectConnections(self._actionConnections)
    destroyButtons(self._actionButtons)

    self._actionConnections = {}
    self._actionButtons = {}

    if typeof(actions) ~= "table" or #actions == 0 then
        if self._actionsRow then
            self._actionsRow.Visible = false
        end
        if self._dashboard and self._dashboard.setActions then
            self._dashboard:setActions(nil)
        end
        return
    end

    local theme = self._theme or DEFAULT_THEME
    self._actionsRow.Visible = true
    self._actionsRow.Position = theme.actionsPosition or DEFAULT_THEME.actionsPosition
    self._actionsRow.Size = theme.actionsSize or DEFAULT_THEME.actionsSize
    if self._actionsLayout then
        self._actionsLayout.Padding = theme.actionsPadding or DEFAULT_THEME.actionsPadding
    end

    for index, action in ipairs(actions) do
        local button = Instance.new("TextButton")
        button.Name = action.name or action.id or string.format("Action%d", index)
        button.Size = UDim2.new(0, action.width or theme.actionButtonMinWidth or DEFAULT_THEME.actionButtonMinWidth, 0, action.height or theme.actionButtonHeight or DEFAULT_THEME.actionButtonHeight)
        button.Text = action.text or action.label or "Action"
        styleActionButton(button, theme, action)
        button.Parent = self._actionsRow

        local corner = Instance.new("UICorner")
        corner.CornerRadius = theme.actionButtonCorner or DEFAULT_THEME.actionButtonCorner
        corner.Parent = button

        local connection
        if typeof(action.callback) == "function" then
            connection = button.MouseButton1Click:Connect(function()
                if self._destroyed then
                    return
                end
                action.callback(self, action)
            end)
        end

        table.insert(self._actionButtons, button)
        table.insert(self._actionConnections, connection)
    end

    if self._dashboard and self._dashboard.setActions then
        self._dashboard:setActions(actions)
    end
end

function LoadingOverlay:nextTip()
    if self._destroyed then
        return
    end
    if not self._tips or #self._tips == 0 then
        self:showTip(nil)
        return
    end
    self._tipIndex = self._tipIndex % #self._tips + 1
    self:showTip(self._tips[self._tipIndex])
end

function LoadingOverlay:showTip(text)
    if self._destroyed then
        return
    end
    self._tipLabel.Text = text or ""
    self:_applyTipVisibility()
end

function LoadingOverlay:setStatus(text, options)
    if self._destroyed then
        return
    end
    options = options or {}
    text = text or ""

    local label = self._statusLabel
    if label.Text == text and not options.force then
        return
    end

    label.TextTransparency = 1
    label.Text = text
    label.Visible = text ~= ""

    self:_setBadgeStatus(text)

    if self._statusTween then
        self._statusTween:Cancel()
    end

    local tween = TweenService:Create(label, TweenInfo.new(options.duration or self._theme.statusTweenSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        TextTransparency = 0,
    })
    self._statusTween = tween
    tween:Play()

    if self._dashboard and self._dashboard.setStatusText then
        self._dashboard:setStatusText(text)
    end
end

function LoadingOverlay:setProgress(alpha, options)
    if self._destroyed then
        return
    end

    alpha = math.clamp(tonumber(alpha) or 0, 0, 1)
    options = options or {}

    if self._progress == alpha and not options.force then
        return
    end

    self._progress = alpha

    if self._progressTween then
        self._progressTween:Cancel()
        self._progressTween = nil
    end
    if self._progressTweenConnection then
        self._progressTweenConnection:Disconnect()
        self._progressTweenConnection = nil
    end

    local tween = TweenService:Create(self._progressFill, TweenInfo.new(options.duration or self._theme.progressTweenSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Size = UDim2.new(alpha, 0, 1, 0),
    })
    self._progressTween = tween
    self._progressTweenConnection = tween.Completed:Connect(function()
        if self._progressTween == tween then
            self._progressTween = nil
        end
        if self._progressTweenConnection then
            self._progressTweenConnection:Disconnect()
            self._progressTweenConnection = nil
        end
    end)
    tween:Play()

    self:_updateProgressVisual(alpha, options.duration)

    if self._dashboard and self._dashboard.setProgress then
        self._dashboard:setProgress(alpha)
    end
end

function LoadingOverlay:applyTheme(themeOverrides)
    if self._destroyed then
        return
    end

    self._theme = mergeTheme(themeOverrides)

    local theme = self._theme

    if self._backdrop then
        self._backdrop.BackgroundColor3 = theme.backdropColor or DEFAULT_THEME.backdropColor
        self._backdrop.BackgroundTransparency = theme.backdropTransparency or DEFAULT_THEME.backdropTransparency
    end
    if self._container then
        self._container.Size = theme.containerSize or DEFAULT_THEME.containerSize
        self._container.BackgroundColor3 = theme.containerBackgroundColor or Color3.fromRGB(10, 14, 28)
        self._container.BackgroundTransparency = theme.containerTransparency or DEFAULT_THEME.containerTransparency or 0
    end
    if self._containerGradient then
        self._containerGradient.Color = theme.gradient and theme.gradient.color or DEFAULT_THEME.gradient.color
        self._containerGradient.Transparency = theme.gradient and theme.gradient.transparency or DEFAULT_THEME.gradient.transparency
        self._containerGradient.Rotation = theme.gradient and theme.gradient.rotation or DEFAULT_THEME.gradient.rotation or 0
    end
    if self._containerGlow then
        local glowTheme = theme.glow or DEFAULT_THEME.glow or {}
        self._containerGlow.ImageColor3 = glowTheme.color or theme.accentColor or DEFAULT_THEME.accentColor
        self._containerGlow.ImageTransparency = glowTheme.transparency or 0.55
        if glowTheme.size then
            self._containerGlow.Size = UDim2.new(0, glowTheme.size.X, 0, glowTheme.size.Y)
        end
    end
    if self._spinner then
        self._spinner.ImageColor3 = theme.spinnerColor or DEFAULT_THEME.spinnerColor
        self._spinner.Size = theme.spinnerSize or DEFAULT_THEME.spinnerSize
        self._spinner.Position = UDim2.new(0.5, 0, 0.5, 0)
        local spinnerImage = (theme.iconography and theme.iconography.spinner)
            or theme.spinnerAsset
            or SPINNER_ASSET
        if spinnerImage then
            self._spinner.Image = spinnerImage
        end
    end
    if self._progressBar then
        self._progressBar.Size = theme.progressBarSize or DEFAULT_THEME.progressBarSize
        self._progressBar.BackgroundColor3 = theme.progressBackgroundColor or DEFAULT_THEME.progressBackgroundColor
    end
    if self._progressFill then
        self._progressFill.BackgroundColor3 = theme.progressFillColor or DEFAULT_THEME.progressFillColor
        self._progressFill.Size = UDim2.new(self._progress, 0, 1, 0)
    end
    if self._progressArc then
        self._progressArc.Image = theme.iconography and theme.iconography.progressArc or self._progressArc.Image
        self._progressArc.ImageColor3 = theme.progressArcColor or DEFAULT_THEME.progressArcColor
        self._progressArc.ImageTransparency = theme.progressArcTransparency or DEFAULT_THEME.progressArcTransparency
        local spinnerSize = self._spinner and self._spinner.Size
        local width = spinnerSize and spinnerSize.X.Offset or 96
        local height = spinnerSize and spinnerSize.Y.Offset or 96
        self._progressArc.Size = UDim2.new(0, math.max(width + 40, 120), 0, math.max(height + 40, 120))
    end
    if self._progressArcGradient then
        local arcColor = theme.progressArcColor or DEFAULT_THEME.progressArcColor
        self._progressArcGradient.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, arcColor),
            ColorSequenceKeypoint.new(1, arcColor),
        })
    end
    if self._statusLabel then
        self._statusLabel.TextColor3 = theme.statusTextColor or DEFAULT_THEME.statusTextColor
        self._statusLabel.Font = (theme.typography and theme.typography.statusFont) or DEFAULT_THEME.typography.statusFont
        self._statusLabel.TextSize = (theme.typography and theme.typography.statusTextSize) or DEFAULT_THEME.typography.statusTextSize
    end
    if self._tipLabel then
        self._tipLabel.TextColor3 = theme.tipTextColor or DEFAULT_THEME.tipTextColor
        self._tipLabel.Font = (theme.typography and theme.typography.tipFont) or DEFAULT_THEME.typography.tipFont
        self._tipLabel.TextSize = (theme.typography and theme.typography.tipTextSize) or DEFAULT_THEME.typography.tipTextSize
    end
    if self._badge then
        self._badge.BackgroundColor3 = theme.hologramBadgeColor or DEFAULT_THEME.hologramBadgeColor
        self._badge.BackgroundTransparency = theme.hologramBadgeTransparency or DEFAULT_THEME.hologramBadgeTransparency
        self._badge.Font = (theme.typography and theme.typography.badgeFont) or DEFAULT_THEME.typography.badgeFont
        self._badge.TextSize = (theme.typography and theme.typography.badgeTextSize) or DEFAULT_THEME.typography.badgeTextSize
    end
    if self._actionsRow then
        self._actionsRow.AnchorPoint = Vector2.new(0.5, 0)
        self._actionsRow.Position = UDim2.new(0.5, 0, 0, 0)
        self._actionsRow.Size = theme.actionsSize or DEFAULT_THEME.actionsSize
    end
    if self._actionsLayout then
        self._actionsLayout.Padding = theme.actionsPadding or DEFAULT_THEME.actionsPadding
    end
    local heroTheme = theme.hero or DEFAULT_THEME.hero
    if self._heroTitle then
        self._heroTitle.Font = heroTheme.titleFont or DEFAULT_THEME.hero.titleFont
        self._heroTitle.TextSize = heroTheme.titleTextSize or DEFAULT_THEME.hero.titleTextSize
        self._heroTitle.TextColor3 = heroTheme.titleColor or DEFAULT_THEME.hero.titleColor
        if self._heroTitleText then
            self._heroTitle.Text = self._heroTitleText
        end
    end
    if self._heroSubtitle then
        self._heroSubtitle.Font = heroTheme.subtitleFont or DEFAULT_THEME.hero.subtitleFont
        self._heroSubtitle.TextSize = heroTheme.subtitleTextSize or DEFAULT_THEME.hero.subtitleTextSize
        self._heroSubtitle.TextColor3 = heroTheme.subtitleColor or DEFAULT_THEME.hero.subtitleColor
        if self._heroSubtitleText then
            self._heroSubtitle.Text = self._heroSubtitleText
        end
    end
    if self._heroHighlightsFrame then
        local layout = self._heroHighlightsFrame:FindFirstChildOfClass("UIListLayout")
        if layout then
            layout.Padding = UDim.new(0, heroTheme.gridPadding or DEFAULT_THEME.hero.gridPadding)
        end
    end
    if self._heroPills then
        for index, pill in ipairs(self._heroPills) do
            if pill.frame then
                pill.frame.BackgroundColor3 = heroTheme.pillBackgroundColor or DEFAULT_THEME.hero.pillBackgroundColor
                pill.frame.BackgroundTransparency = heroTheme.pillTransparency or DEFAULT_THEME.hero.pillTransparency
            end
            if pill.stroke then
                pill.stroke.Color = theme.accentColor or DEFAULT_THEME.accentColor
                pill.stroke.Transparency = heroTheme.pillStrokeTransparency or DEFAULT_THEME.hero.pillStrokeTransparency
            end
            if pill.accent then
                pill.accent.BackgroundColor3 = heroTheme.pillAccentColor or theme.accentColor or DEFAULT_THEME.accentColor
            end
            if pill.label then
                pill.label.Font = heroTheme.pillFont or DEFAULT_THEME.hero.pillFont
                pill.label.TextSize = heroTheme.pillTextSize or DEFAULT_THEME.hero.pillTextSize
                pill.label.TextColor3 = heroTheme.pillTextColor or DEFAULT_THEME.hero.pillTextColor
                if self._heroHighlightTexts and typeof(self._heroHighlightTexts[index]) == "string" then
                    pill.label.Text = self._heroHighlightTexts[index]
                end
            end
        end
    end
    if self._contentLayout then
        self._contentLayout.Padding = UDim.new(0, (theme.responsive and theme.responsive.columnSpacing) or DEFAULT_THEME.responsive.columnSpacing or 32)
    end
    local panelTheme = theme.dashboardPanel or DEFAULT_THEME.dashboardPanel
    if self._dashboardSurface then
        self._dashboardSurface.BackgroundColor3 = panelTheme.backgroundColor or DEFAULT_THEME.dashboardPanel.backgroundColor
        self._dashboardSurface.BackgroundTransparency = panelTheme.backgroundTransparency or DEFAULT_THEME.dashboardPanel.backgroundTransparency
    end
    if self._dashboardStroke then
        self._dashboardStroke.Color = panelTheme.strokeColor or DEFAULT_THEME.dashboardPanel.strokeColor
        self._dashboardStroke.Transparency = panelTheme.strokeTransparency or DEFAULT_THEME.dashboardPanel.strokeTransparency
    end
    if self._dashboardGradient then
        self._dashboardGradient.Color = panelTheme.gradient or DEFAULT_THEME.dashboardPanel.gradient
        self._dashboardGradient.Transparency = panelTheme.gradientTransparency or DEFAULT_THEME.dashboardPanel.gradientTransparency
    end
    if self._actions then
        self:setActions(self._actions)
    end

    self:_refreshBadge()
    self:_updateProgressVisual(self._progress, 0.1)
    self:_applyResponsiveLayout(Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize or nil)

    if self._dashboard and self._dashboard.applyTheme then
        self._dashboard:applyTheme(theme)
    end
end

function LoadingOverlay:isComplete()
    return self._completed
end

function LoadingOverlay:onCompleted(callback)
    assert(typeof(callback) == "function", "LoadingOverlay:onCompleted expects a function")
    if self._completed then
        task.spawn(callback, self)
        return { Disconnect = function() end, disconnect = function() end }
    end
    return self._completedSignal:connect(callback)
end

function LoadingOverlay:complete(options)
    if self._destroyed or self._completed then
        return
    end

    options = options or {}

    self:setProgress(1, { duration = options.progressDuration or 0.25, force = true })

    self._completed = true

    self:_setBadgeStatus("Verification Complete")

    if self._spinnerTween then
        self._spinnerTween:Cancel()
        self._spinnerTween = nil
    end

    local fadeTween = TweenService:Create(self._backdrop, TweenInfo.new(options.fadeDuration or 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        BackgroundTransparency = 1,
    })

    local containerFade = TweenService:Create(self._container, TweenInfo.new(options.fadeDuration or 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        BackgroundTransparency = 1,
    })

    local statusFade
    if self._statusLabel then
        statusFade = TweenService:Create(self._statusLabel, TweenInfo.new(options.fadeDuration or 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            TextTransparency = 1,
        })
    end
    local tipFade
    if self._tipLabel then
        tipFade = TweenService:Create(self._tipLabel, TweenInfo.new(options.fadeDuration or 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            TextTransparency = 1,
        })
    end
    local actionsFade
    if self._actionsRow and #self._actionButtons > 0 then
        actionsFade = TweenService:Create(self._actionsRow, TweenInfo.new(options.fadeDuration or 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            BackgroundTransparency = 1,
        })
        for _, button in ipairs(self._actionButtons) do
            local buttonFade = TweenService:Create(button, TweenInfo.new(options.fadeDuration or 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                BackgroundTransparency = 1,
                TextTransparency = 1,
            })
            buttonFade:Play()
        end
    end
    local spinnerFade
    if self._spinner then
        spinnerFade = TweenService:Create(self._spinner, TweenInfo.new(options.fadeDuration or 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            ImageTransparency = 1,
        })
    end

    fadeTween.Completed:Connect(function()
        if self._completedSignal then
            self._completedSignal:fire(self)
        end
        self:destroy()
    end)

    fadeTween:Play()
    containerFade:Play()
    if statusFade then
        statusFade:Play()
    end
    if tipFade then
        tipFade:Play()
    end
    if actionsFade then
        actionsFade:Play()
    end
    if spinnerFade then
        spinnerFade:Play()
    end
end

function LoadingOverlay:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true

    if self._spinnerTween then
        self._spinnerTween:Cancel()
        self._spinnerTween = nil
    end
    if self._progressTween then
        self._progressTween:Cancel()
        self._progressTween = nil
    end
    if self._progressTweenConnection then
        self._progressTweenConnection:Disconnect()
        self._progressTweenConnection = nil
    end
    if self._statusTween then
        self._statusTween:Cancel()
        self._statusTween = nil
    end
    if self._progressArcTween then
        self._progressArcTween:Cancel()
        self._progressArcTween = nil
    end

    if self._completedSignal then
        self._completedSignal:destroy()
        self._completedSignal = nil
    end

    disconnectConnections(self._actionConnections)
    self._actionConnections = nil
    destroyButtons(self._actionButtons)
    self._actionButtons = nil

    disconnectConnections(self._connections)
    self._connections = nil
    self._viewportConnection = nil

    if self._dashboard and self._dashboard.destroy then
        self._dashboard:destroy()
    end
    self._dashboard = nil

    if self._gui then
        self._gui:Destroy()
        self._gui = nil
    end

    if activeOverlay == self then
        activeOverlay = nil
    end
end

function Module.create(options)
    if activeOverlay then
        activeOverlay:destroy()
    end

    local overlay = LoadingOverlay.new(options)
    activeOverlay = overlay
    return overlay
end

function Module.getActive()
    return activeOverlay
end

return Module

]===],
    ['src/ui/verification_dashboard.lua'] = [===[
-- mikkel32/AutoParry : src/ui/verification_dashboard.lua
-- Futuristic verification dashboard used by the loading overlay. Renders a
-- neon timeline that visualises the orchestrator's verification stages with
-- animated status icons, tooltips, and action hooks.

local TweenService = game:GetService("TweenService")

local Require = rawget(_G, "ARequire")
local Util = Require("src/shared/util.lua")

local VerificationDashboard = {}
VerificationDashboard.__index = VerificationDashboard

local STATUS_PRIORITY = {
    pending = 0,
    active = 1,
    ok = 2,
    warning = 3,
    failed = 4,
}

local STEP_DEFINITIONS = {
    {
        id = "player",
        title = "Player Sync",
        description = "Locking on to your avatar and character rig.",
        tooltip = "AutoParry waits for the LocalPlayer and character to spawn before continuing.",
    },
    {
        id = "remotes",
        title = "Remotes",
        description = "Scanning Blade Ball network remotes.",
        tooltip = "Detects the parry remote and required folders inside ReplicatedStorage.Remotes.",
    },
    {
        id = "success",
        title = "Success Events",
        description = "Tracking parry success broadcasts.",
        tooltip = "Watches ParrySuccess events so AutoParry can react instantly to successes.",
    },
    {
        id = "balls",
        title = "Ball Telemetry",
        description = "Locating live balls for prediction.",
        tooltip = "Ensures the configured balls folder exists so projectiles can be analysed.",
    },
}

local DEFAULT_THEME = {
    accentColor = Color3.fromRGB(0, 210, 255),
    backgroundTransparency = 1,
    cardColor = Color3.fromRGB(22, 28, 48),
    cardTransparency = 0.08,
    cardStrokeColor = Color3.fromRGB(0, 150, 255),
    cardStrokeTransparency = 0.45,
    connectorColor = Color3.fromRGB(0, 170, 255),
    connectorTransparency = 0.55,
    pendingColor = Color3.fromRGB(95, 112, 140),
    activeColor = Color3.fromRGB(0, 195, 255),
    okColor = Color3.fromRGB(0, 230, 180),
    warningColor = Color3.fromRGB(255, 196, 0),
    failedColor = Color3.fromRGB(255, 70, 95),
    tooltipBackground = Color3.fromRGB(12, 16, 32),
    tooltipTransparency = 0.05,
    tooltipTextColor = Color3.fromRGB(215, 230, 255),
    titleFont = Enum.Font.GothamBlack,
    titleTextSize = 20,
    subtitleFont = Enum.Font.Gotham,
    subtitleTextSize = 16,
    stepTitleFont = Enum.Font.GothamSemibold,
    stepTitleTextSize = 17,
    stepStatusFont = Enum.Font.Gotham,
    stepStatusTextSize = 14,
    tooltipFont = Enum.Font.Gotham,
    tooltipTextSize = 14,
    actionFont = Enum.Font.GothamBold,
    actionTextSize = 16,
    actionHeight = 36,
    actionCorner = UDim.new(0, 10),
    actionPrimaryColor = Color3.fromRGB(0, 210, 255),
    actionPrimaryTextColor = Color3.fromRGB(10, 12, 20),
    actionSecondaryColor = Color3.fromRGB(30, 40, 60),
    actionSecondaryTextColor = Color3.fromRGB(215, 230, 255),
    logo = {
        width = 230,
        text = "AutoParry",
        font = Enum.Font.GothamBlack,
        textSize = 28,
        textGradient = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(0, 210, 255)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 236, 173)),
        }),
        textGradientRotation = 15,
        textStrokeColor = Color3.fromRGB(10, 12, 24),
        textStrokeTransparency = 0.6,
        primaryColor = Color3.fromRGB(235, 245, 255),
        tagline = "Neural shield online",
        taglineFont = Enum.Font.Gotham,
        taglineTextSize = 15,
        taglineColor = Color3.fromRGB(188, 206, 255),
        taglineTransparency = 0,
        backgroundColor = Color3.fromRGB(16, 20, 36),
        backgroundTransparency = 0.08,
        strokeColor = Color3.fromRGB(0, 180, 255),
        strokeTransparency = 0.35,
        gradient = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(12, 18, 30)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 195, 255)),
        }),
        gradientTransparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.55),
            NumberSequenceKeypoint.new(0.4, 0.35),
            NumberSequenceKeypoint.new(1, 0.15),
        }),
        gradientRotation = 120,
        glyphImage = "rbxassetid://12148062841",
        glyphColor = Color3.fromRGB(0, 230, 200),
        glyphTransparency = 0.2,
    },
    iconography = {
        pending = "rbxassetid://6031071050",
        active = "rbxassetid://6031075929",
        check = "rbxassetid://6031068421",
        warning = "rbxassetid://6031071051",
        error = "rbxassetid://6031094678",
    },
    telemetry = {
        titleFont = Enum.Font.GothamBold,
        titleTextSize = 16,
        valueFont = Enum.Font.GothamBlack,
        valueTextSize = 24,
        labelFont = Enum.Font.Gotham,
        labelTextSize = 14,
        cardColor = Color3.fromRGB(18, 24, 40),
        cardTransparency = 0.08,
        cardStrokeColor = Color3.fromRGB(0, 160, 255),
        cardStrokeTransparency = 0.45,
        accentColor = Color3.fromRGB(0, 210, 255),
    },
    controls = {
        headerFont = Enum.Font.GothamBold,
        headerTextSize = 16,
        headerColor = Color3.fromRGB(220, 234, 255),
        descriptionFont = Enum.Font.Gotham,
        descriptionTextSize = 14,
        descriptionColor = Color3.fromRGB(178, 194, 230),
        toggleOnColor = Color3.fromRGB(0, 210, 255),
        toggleOffColor = Color3.fromRGB(32, 42, 64),
        toggleOnTextColor = Color3.fromRGB(12, 16, 20),
        toggleOffTextColor = Color3.fromRGB(220, 234, 255),
        toggleCorner = UDim.new(0, 12),
        toggleStrokeColor = Color3.fromRGB(0, 210, 255),
        toggleStrokeTransparency = 0.4,
        toggleBadgeFont = Enum.Font.GothamSemibold,
        toggleBadgeSize = 13,
        toggleBadgeColor = Color3.fromRGB(170, 200, 255),
        sectionBackground = Color3.fromRGB(14, 18, 32),
        sectionTransparency = 0.08,
        sectionStrokeColor = Color3.fromRGB(0, 170, 255),
        sectionStrokeTransparency = 0.5,
        sectionGradient = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(12, 18, 30)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 120, 200)),
        }),
        sectionGradientTransparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.85),
            NumberSequenceKeypoint.new(1, 0.3),
        }),
    },
}

local DEFAULT_TELEMETRY = {
    {
        id = "latency",
        label = "Latency",
        value = "-- ms",
        hint = "Ping to Blade Ball server",
    },
    {
        id = "uptime",
        label = "Session",
        value = "00:00",
        hint = "Runtime since activation",
    },
    {
        id = "autotune",
        label = "Auto-Tune",
        value = "Calibrating",
        hint = "Adaptive neural mesh status",
    },
}

local CONTROL_DEFINITIONS = {
    {
        id = "adaptive",
        title = "Adaptive Reaction",
        description = "Auto-learns opponent speed to retime parries in real-time.",
        default = true,
        badge = "AI",
    },
    {
        id = "failsafe",
        title = "Failsafe Recall",
        description = "Instantly revert to manual control if anomalies are detected.",
        default = true,
        badge = "SAFE",
    },
    {
        id = "edge",
        title = "Edge Prediction",
        description = "Predict ricochet vectors and pre-aim at the next ball handoff.",
        default = false,
    },
    {
        id = "audible",
        title = "Audible Cues",
        description = "Emit positional pings for high-priority parry windows.",
        default = true,
    },
    {
        id = "ghost",
        title = "Ghost Anticipation",
        description = "Simulate incoming trajectories to pre-charge counter windows.",
        default = false,
    },
    {
        id = "autosync",
        title = "Autosync Party",
        description = "Synchronise teammates with shared parry telemetry.",
        default = true,
        badge = "TEAM",
    },
}

local STATUS_STYLE = {
    pending = function(theme)
        return {
            icon = theme.iconography.pending,
            color = theme.pendingColor,
            label = "Pending",
            strokeTransparency = 0.7,
        }
    end,
    active = function(theme)
        return {
            icon = theme.iconography.active or theme.iconography.pending,
            color = theme.activeColor,
            label = "Scanning…",
            strokeTransparency = 0.35,
        }
    end,
    ok = function(theme)
        return {
            icon = theme.iconography.check,
            color = theme.okColor,
            label = "Ready",
            strokeTransparency = 0.2,
        }
    end,
    warning = function(theme)
        return {
            icon = theme.iconography.warning,
            color = theme.warningColor,
            label = "Warning",
            strokeTransparency = 0.25,
        }
    end,
    failed = function(theme)
        return {
            icon = theme.iconography.error,
            color = theme.failedColor,
            label = "Failed",
            strokeTransparency = 0.15,
        }
    end,
}

local function mergeTable(base, overrides)
    if typeof(overrides) ~= "table" then
        return base
    end

    local merged = Util.deepCopy(base)
    for key, value in pairs(overrides) do
        if typeof(value) == "table" and typeof(merged[key]) == "table" then
            merged[key] = mergeTable(merged[key], value)
        else
            merged[key] = value
        end
    end
    return merged
end

local function createLogoBadge(parent, theme)
    local config = mergeTable(DEFAULT_THEME.logo, theme.logo or {})

    local badge = Instance.new("Frame")
    badge.Name = "LogoBadge"
    badge.AnchorPoint = Vector2.new(0, 0.5)
    badge.Position = UDim2.new(0, 0, 0.5, 0)
    badge.Size = UDim2.new(1, 0, 1, -8)
    badge.BackgroundColor3 = config.backgroundColor or theme.cardColor
    badge.BackgroundTransparency = config.backgroundTransparency or 0.1
    badge.BorderSizePixel = 0
    badge.ClipsDescendants = true
    badge.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 14)
    corner.Parent = badge

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1.6
    stroke.Transparency = config.strokeTransparency or 0.35
    stroke.Color = config.strokeColor or theme.accentColor
    stroke.Parent = badge

    local gradient = Instance.new("UIGradient")
    gradient.Color = config.gradient or DEFAULT_THEME.logo.gradient
    gradient.Transparency = config.gradientTransparency or DEFAULT_THEME.logo.gradientTransparency
    gradient.Rotation = config.gradientRotation or DEFAULT_THEME.logo.gradientRotation or 120
    gradient.Parent = badge

    local glyph = Instance.new("ImageLabel")
    glyph.Name = "Glyph"
    glyph.AnchorPoint = Vector2.new(0, 0.5)
    glyph.Position = UDim2.new(0, 14, 0.5, 0)
    glyph.Size = UDim2.new(0, 34, 0, 34)
    glyph.BackgroundTransparency = 1
    glyph.Image = config.glyphImage or (theme.iconography and theme.iconography.hologram) or ""
    glyph.ImageColor3 = config.glyphColor or theme.accentColor
    glyph.ImageTransparency = config.glyphTransparency or 0.2
    glyph.Parent = badge

    local wordmark = Instance.new("TextLabel")
    wordmark.Name = "Wordmark"
    wordmark.AnchorPoint = Vector2.new(0, 0.5)
    wordmark.Position = UDim2.new(0, 58, 0.5, -10)
    wordmark.Size = UDim2.new(1, -70, 0, 30)
    wordmark.BackgroundTransparency = 1
    wordmark.Font = config.font or DEFAULT_THEME.logo.font
    wordmark.TextSize = config.textSize or DEFAULT_THEME.logo.textSize
    wordmark.Text = string.upper(config.text or DEFAULT_THEME.logo.text)
    wordmark.TextColor3 = config.primaryColor or Color3.fromRGB(235, 245, 255)
    wordmark.TextXAlignment = Enum.TextXAlignment.Left
    wordmark.TextStrokeColor3 = config.textStrokeColor or Color3.fromRGB(10, 12, 24)
    wordmark.TextStrokeTransparency = config.textStrokeTransparency or 0.6
    wordmark.Parent = badge

    local wordmarkGradient = Instance.new("UIGradient")
    wordmarkGradient.Name = "WordmarkGradient"
    wordmarkGradient.Color = config.textGradient or DEFAULT_THEME.logo.textGradient
    wordmarkGradient.Rotation = config.textGradientRotation or DEFAULT_THEME.logo.textGradientRotation or 0
    wordmarkGradient.Parent = wordmark

    local tagline = Instance.new("TextLabel")
    tagline.Name = "Tagline"
    tagline.AnchorPoint = Vector2.new(0, 0.5)
    tagline.Position = UDim2.new(0, 58, 0.5, 16)
    tagline.Size = UDim2.new(1, -70, 0, 22)
    tagline.BackgroundTransparency = 1
    tagline.Font = config.taglineFont or DEFAULT_THEME.logo.taglineFont
    tagline.TextSize = config.taglineTextSize or DEFAULT_THEME.logo.taglineTextSize
    tagline.TextColor3 = config.taglineColor or DEFAULT_THEME.logo.taglineColor
    tagline.Text = config.tagline or DEFAULT_THEME.logo.tagline
    tagline.TextTransparency = config.taglineTransparency or 0
    tagline.TextXAlignment = Enum.TextXAlignment.Left
    tagline.Parent = badge

    return {
        frame = badge,
        stroke = stroke,
        gradient = gradient,
        glyph = glyph,
        wordmark = wordmark,
        wordmarkGradient = wordmarkGradient,
        tagline = tagline,
    }
end

local function createTooltip(parent, theme, text)
    local tooltip = Instance.new("TextLabel")
    tooltip.Name = "Tooltip"
    tooltip.AnchorPoint = Vector2.new(0.5, 1)
    tooltip.Position = UDim2.new(0.5, 0, 0, -6)
    tooltip.BackgroundColor3 = theme.tooltipBackground
    tooltip.BackgroundTransparency = theme.tooltipTransparency
    tooltip.TextColor3 = theme.tooltipTextColor
    tooltip.Text = text or ""
    tooltip.TextWrapped = true
    tooltip.Visible = false
    tooltip.Size = UDim2.new(0.9, 0, 0, 48)
    tooltip.Font = theme.tooltipFont
    tooltip.TextSize = theme.tooltipTextSize
    tooltip.ZIndex = 4
    tooltip.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = tooltip

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1
    stroke.Transparency = 0.4
    stroke.Color = theme.accentColor
    stroke.Parent = tooltip

    return tooltip
end

local function createStep(parent, definition, theme)
    local frame = Instance.new("Frame")
    frame.Name = definition.id
    frame.Size = UDim2.new(1, 0, 0, 72)
    frame.BackgroundColor3 = theme.cardColor
    frame.BackgroundTransparency = theme.cardTransparency
    frame.BorderSizePixel = 0
    frame.Parent = parent
    frame.ClipsDescendants = true
    frame.ZIndex = 2

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 12)
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1.5
    stroke.Color = theme.cardStrokeColor
    stroke.Transparency = theme.cardStrokeTransparency
    stroke.Parent = frame

    local gradient = Instance.new("UIGradient")
    gradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, theme.cardColor),
        ColorSequenceKeypoint.new(1, theme.cardColor:Lerp(theme.accentColor, 0.08)),
    })
    gradient.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, theme.cardTransparency + 0.05),
        NumberSequenceKeypoint.new(1, theme.cardTransparency + 0.15),
    })
    gradient.Rotation = 120
    gradient.Parent = frame

    local icon = Instance.new("ImageLabel")
    icon.Name = "StatusIcon"
    icon.AnchorPoint = Vector2.new(0.5, 0.5)
    icon.Position = UDim2.new(0, 34, 0.5, 0)
    icon.Size = UDim2.new(0, 36, 0, 36)
    icon.BackgroundTransparency = 1
    icon.Image = theme.iconography.pending
    icon.ImageTransparency = 0.25
    icon.ImageColor3 = theme.pendingColor
    icon.ZIndex = 3
    icon.Parent = frame

    local iconGlow = Instance.new("UIStroke")
    iconGlow.Thickness = 2
    iconGlow.Transparency = 0.4
    iconGlow.Color = theme.pendingColor
    iconGlow.Parent = icon

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.AnchorPoint = Vector2.new(0, 0)
    title.Position = UDim2.new(0, 66, 0, 10)
    title.Size = UDim2.new(1, -90, 0, 24)
    title.BackgroundTransparency = 1
    title.Font = theme.stepTitleFont
    title.TextSize = theme.stepTitleTextSize
    title.TextColor3 = Color3.fromRGB(235, 240, 255)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = definition.title
    title.Parent = frame

    local status = Instance.new("TextLabel")
    status.Name = "Status"
    status.AnchorPoint = Vector2.new(0, 0)
    status.Position = UDim2.new(0, 66, 0, 34)
    status.Size = UDim2.new(1, -90, 0, 24)
    status.BackgroundTransparency = 1
    status.Font = theme.stepStatusFont
    status.TextSize = theme.stepStatusTextSize
    status.TextColor3 = Color3.fromRGB(180, 194, 235)
    status.TextXAlignment = Enum.TextXAlignment.Left
    status.Text = definition.description
    status.Parent = frame

    local connector = Instance.new("Frame")
    connector.Name = "Connector"
    connector.AnchorPoint = Vector2.new(0.5, 0)
    connector.Position = UDim2.new(0, 34, 1, -4)
    connector.Size = UDim2.new(0, 4, 0, 24)
    connector.BackgroundColor3 = theme.connectorColor
    connector.BackgroundTransparency = theme.connectorTransparency
    connector.BorderSizePixel = 0
    connector.ZIndex = 1
    connector.Parent = frame

    local tooltip = createTooltip(frame, theme, definition.tooltip)

    local hoverArea = Instance.new("TextButton")
    hoverArea.Name = "Hover"
    hoverArea.BackgroundTransparency = 1
    hoverArea.Text = ""
    hoverArea.Size = UDim2.new(1, 0, 1, 0)
    hoverArea.AutoButtonColor = false
    hoverArea.ZIndex = 5
    hoverArea.Parent = frame

    local step = {
        id = definition.id,
        frame = frame,
        icon = icon,
        iconGlow = iconGlow,
        title = title,
        status = status,
        connector = connector,
        tooltip = tooltip,
        hoverArea = hoverArea,
        state = "pending",
        priority = STATUS_PRIORITY.pending,
        iconTween = nil,
    }

    hoverArea.MouseEnter:Connect(function()
        tooltip.Visible = true
        tooltip.TextTransparency = 1
        TweenService:Create(
            tooltip,
            TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
            { TextTransparency = 0.05, BackgroundTransparency = theme.tooltipTransparency }
        ):Play()
    end)

    local function hideTooltip()
        if tooltip.Visible then
            TweenService:Create(
                tooltip,
                TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
                { TextTransparency = 1, BackgroundTransparency = 1 }
            ):Play()
            task.delay(0.22, function()
                tooltip.Visible = false
            end)
        end
    end

    hoverArea.MouseLeave:Connect(hideTooltip)
    hoverArea.MouseButton1Down:Connect(hideTooltip)

    return step
end

local function createTelemetryCard(parent, theme, definition)
    local telemetryTheme = theme.telemetry or DEFAULT_THEME.telemetry

    local card = Instance.new("Frame")
    card.Name = string.format("Telemetry_%s", definition.id)
    card.BackgroundColor3 = telemetryTheme.cardColor
    card.BackgroundTransparency = telemetryTheme.cardTransparency
    card.BorderSizePixel = 0
    card.Size = UDim2.new(0, 0, 0, 96)
    card.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 12)
    corner.Parent = card

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1.1
    stroke.Transparency = telemetryTheme.cardStrokeTransparency
    stroke.Color = telemetryTheme.cardStrokeColor
    stroke.Parent = card

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 10)
    padding.PaddingBottom = UDim.new(0, 12)
    padding.PaddingLeft = UDim.new(0, 12)
    padding.PaddingRight = UDim.new(0, 12)
    padding.Parent = card

    local label = Instance.new("TextLabel")
    label.Name = "Label"
    label.BackgroundTransparency = 1
    label.Size = UDim2.new(1, 0, 0, 18)
    label.Font = telemetryTheme.labelFont
    label.TextSize = telemetryTheme.labelTextSize
    label.TextColor3 = (telemetryTheme.accentColor or theme.accentColor):Lerp(Color3.new(1, 1, 1), 0.35)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = definition.label or definition.id
    label.Parent = card

    local value = Instance.new("TextLabel")
    value.Name = "Value"
    value.BackgroundTransparency = 1
    value.Size = UDim2.new(1, 0, 0, 32)
    value.Position = UDim2.new(0, 0, 0, 20)
    value.Font = telemetryTheme.valueFont
    value.TextSize = telemetryTheme.valueTextSize
    value.TextXAlignment = Enum.TextXAlignment.Left
    value.TextColor3 = Color3.fromRGB(235, 245, 255)
    value.Text = tostring(definition.value or "--")
    value.Parent = card

    local hint = Instance.new("TextLabel")
    hint.Name = "Hint"
    hint.BackgroundTransparency = 1
    hint.Size = UDim2.new(1, 0, 0, 22)
    hint.Position = UDim2.new(0, 0, 0, 54)
    hint.Font = telemetryTheme.labelFont
    hint.TextSize = telemetryTheme.labelTextSize - 1
    hint.TextColor3 = Color3.fromRGB(176, 196, 230)
    hint.TextXAlignment = Enum.TextXAlignment.Left
    hint.TextTransparency = 0.15
    hint.TextWrapped = true
    hint.Text = definition.hint or ""
    hint.Parent = card

    return {
        frame = card,
        stroke = stroke,
        label = label,
        value = value,
        hint = hint,
        definition = definition,
    }
end

local function createControlToggle(parent, theme, definition)
    local controlsTheme = theme.controls or DEFAULT_THEME.controls

    local button = Instance.new("TextButton")
    button.Name = definition.id or "Control"
    button.AutoButtonColor = false
    button.BackgroundColor3 = controlsTheme.toggleOffColor
    button.BorderSizePixel = 0
    button.Size = UDim2.new(0, 240, 0, 96)
    button.Text = ""
    button.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = controlsTheme.toggleCorner or DEFAULT_THEME.controls.toggleCorner
    corner.Parent = button

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1.25
    stroke.Color = controlsTheme.toggleStrokeColor or DEFAULT_THEME.controls.toggleStrokeColor
    stroke.Transparency = controlsTheme.toggleStrokeTransparency or DEFAULT_THEME.controls.toggleStrokeTransparency
    stroke.Parent = button

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 14)
    padding.PaddingBottom = UDim.new(0, 14)
    padding.PaddingLeft = UDim.new(0, 16)
    padding.PaddingRight = UDim.new(0, 16)
    padding.Parent = button

    local indicator = Instance.new("Frame")
    indicator.Name = "Indicator"
    indicator.BackgroundColor3 = controlsTheme.toggleOnColor or DEFAULT_THEME.controls.toggleOnColor
    indicator.BackgroundTransparency = 0.35
    indicator.BorderSizePixel = 0
    indicator.Size = UDim2.new(0, 4, 1, -28)
    indicator.Position = UDim2.new(0, -2, 0, 14)
    indicator.Visible = false
    indicator.Parent = button

    local indicatorCorner = Instance.new("UICorner")
    indicatorCorner.CornerRadius = UDim.new(1, 0)
    indicatorCorner.Parent = indicator

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.BackgroundTransparency = 1
    title.Size = UDim2.new(1, -8, 0, 24)
    title.Position = UDim2.new(0, 0, 0, 0)
    title.Font = controlsTheme.headerFont or DEFAULT_THEME.controls.headerFont
    title.TextSize = controlsTheme.headerTextSize or DEFAULT_THEME.controls.headerTextSize
    title.TextColor3 = controlsTheme.headerColor or DEFAULT_THEME.controls.headerColor
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = definition.title or definition.id
    title.Parent = button

    local badge
    if definition.badge then
        badge = Instance.new("TextLabel")
        badge.Name = "Badge"
        badge.AnchorPoint = Vector2.new(1, 0)
        badge.Position = UDim2.new(1, 0, 0, 0)
        badge.Size = UDim2.new(0, 52, 0, 22)
        badge.BackgroundTransparency = 0.2
        badge.BackgroundColor3 = (controlsTheme.toggleStrokeColor or DEFAULT_THEME.controls.toggleStrokeColor):Lerp(Color3.new(1, 1, 1), 0.3)
        badge.Font = controlsTheme.toggleBadgeFont or DEFAULT_THEME.controls.toggleBadgeFont
        badge.TextSize = controlsTheme.toggleBadgeSize or DEFAULT_THEME.controls.toggleBadgeSize
        badge.TextColor3 = controlsTheme.toggleBadgeColor or DEFAULT_THEME.controls.toggleBadgeColor
        badge.TextXAlignment = Enum.TextXAlignment.Center
        badge.Text = tostring(definition.badge)
        badge.Parent = button

        local badgeCorner = Instance.new("UICorner")
        badgeCorner.CornerRadius = UDim.new(0, 10)
        badgeCorner.Parent = badge
    end

    local description = Instance.new("TextLabel")
    description.Name = "Description"
    description.BackgroundTransparency = 1
    description.Position = UDim2.new(0, 0, 0, 30)
    description.Size = UDim2.new(1, -8, 0, 38)
    description.TextWrapped = true
    description.TextXAlignment = Enum.TextXAlignment.Left
    description.Font = controlsTheme.descriptionFont or DEFAULT_THEME.controls.descriptionFont
    description.TextSize = controlsTheme.descriptionTextSize or DEFAULT_THEME.controls.descriptionTextSize
    description.TextColor3 = controlsTheme.descriptionColor or DEFAULT_THEME.controls.descriptionColor
    description.Text = definition.description or ""
    description.Parent = button

    local status = Instance.new("TextLabel")
    status.Name = "Status"
    status.AnchorPoint = Vector2.new(1, 1)
    status.Position = UDim2.new(1, 0, 1, -2)
    status.Size = UDim2.new(0, 70, 0, 18)
    status.BackgroundTransparency = 1
    status.Font = controlsTheme.descriptionFont or DEFAULT_THEME.controls.descriptionFont
    status.TextSize = (controlsTheme.descriptionTextSize or DEFAULT_THEME.controls.descriptionTextSize) - 1
    status.TextColor3 = controlsTheme.descriptionColor or DEFAULT_THEME.controls.descriptionColor
    status.TextXAlignment = Enum.TextXAlignment.Right
    status.Text = "OFF"
    status.Parent = button

    return {
        button = button,
        indicator = indicator,
        title = title,
        description = description,
        badge = badge,
        status = status,
        stroke = stroke,
        definition = definition,
        enabled = false,
    }
end

local function styleControlToggle(toggle, theme, enabled)
    local controlsTheme = theme.controls or DEFAULT_THEME.controls
    local onColor = controlsTheme.toggleOnColor or DEFAULT_THEME.controls.toggleOnColor
    local offColor = controlsTheme.toggleOffColor or DEFAULT_THEME.controls.toggleOffColor
    local onTextColor = controlsTheme.toggleOnTextColor or DEFAULT_THEME.controls.toggleOnTextColor
    local offTextColor = controlsTheme.toggleOffTextColor or controlsTheme.headerColor or DEFAULT_THEME.controls.headerColor
    local descriptionColor = controlsTheme.descriptionColor or DEFAULT_THEME.controls.descriptionColor

    if toggle.button then
        toggle.button.BackgroundColor3 = enabled and onColor:Lerp(Color3.new(1, 1, 1), 0.08) or offColor
    end
    if toggle.stroke then
        toggle.stroke.Color = controlsTheme.toggleStrokeColor or DEFAULT_THEME.controls.toggleStrokeColor
        toggle.stroke.Transparency = enabled and 0.18 or (controlsTheme.toggleStrokeTransparency or DEFAULT_THEME.controls.toggleStrokeTransparency)
    end
    if toggle.indicator then
        toggle.indicator.Visible = enabled
        toggle.indicator.BackgroundColor3 = onColor
    end
    if toggle.title then
        toggle.title.TextColor3 = enabled and onTextColor or offTextColor
    end
    if toggle.description then
        toggle.description.TextColor3 = enabled and descriptionColor or descriptionColor:Lerp(Color3.new(0.6, 0.66, 0.8), 0.35)
    end
    if toggle.status then
        toggle.status.Text = enabled and "ON" or "OFF"
        toggle.status.TextColor3 = enabled and onTextColor or descriptionColor
    end
    if toggle.badge then
        toggle.badge.TextColor3 = controlsTheme.toggleBadgeColor or DEFAULT_THEME.controls.toggleBadgeColor
        toggle.badge.BackgroundTransparency = enabled and 0.1 or 0.35
    end

    toggle.enabled = enabled
end

local function styleActionButton(button, theme, action)
    local isSecondary = action.variant == "secondary" or action.kind == "cancel"
    button.AutoButtonColor = true
    button.BackgroundColor3 = isSecondary and theme.actionSecondaryColor or theme.actionPrimaryColor
    button.TextColor3 = isSecondary and theme.actionSecondaryTextColor or theme.actionPrimaryTextColor
    button.Font = theme.actionFont
    button.TextSize = theme.actionTextSize
    button.Size = UDim2.new(0, action.width or 140, 0, theme.actionHeight)

    local corner = Instance.new("UICorner")
    corner.CornerRadius = theme.actionCorner
    corner.Parent = button

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1.5
    stroke.Transparency = 0.35
    stroke.Color = theme.accentColor
    stroke.Parent = button
end

function VerificationDashboard.new(options)
    options = options or {}
    local theme = mergeTable(DEFAULT_THEME, options.theme or {})

    local parent = options.parent
    assert(parent, "VerificationDashboard.new requires a parent frame")

    local root = Instance.new("Frame")
    root.Name = options.name or "VerificationDashboard"
    root.BackgroundTransparency = theme.backgroundTransparency
    root.BackgroundColor3 = Color3.new(0, 0, 0)
    root.Size = UDim2.new(1, 0, 1, 0)
    root.BorderSizePixel = 0
    root.Parent = parent

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 12)
    padding.PaddingBottom = UDim.new(0, 12)
    padding.PaddingLeft = UDim.new(0, 12)
    padding.PaddingRight = UDim.new(0, 12)
    padding.Parent = root

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Stretch
    layout.VerticalAlignment = Enum.VerticalAlignment.Top
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 18)
    layout.Parent = root

    local header = Instance.new("Frame")
    header.Name = "Header"
    header.BackgroundTransparency = 1
    header.Size = UDim2.new(1, 0, 0, 96)
    header.LayoutOrder = 1
    header.Parent = root

    local headerLayout = Instance.new("UIListLayout")
    headerLayout.FillDirection = Enum.FillDirection.Horizontal
    headerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    headerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    headerLayout.SortOrder = Enum.SortOrder.LayoutOrder
    headerLayout.Padding = UDim.new(0, 18)
    headerLayout.Parent = header

    local logoContainer = Instance.new("Frame")
    logoContainer.Name = "LogoContainer"
    logoContainer.BackgroundTransparency = 1
    logoContainer.Size = UDim2.new(0, 230, 1, 0)
    logoContainer.Parent = header

    local logoElements = createLogoBadge(logoContainer, theme)

    local textContainer = Instance.new("Frame")
    textContainer.Name = "HeaderText"
    textContainer.BackgroundTransparency = 1
    textContainer.Size = UDim2.new(1, -230, 1, 0)
    textContainer.Parent = header

    local textLayout = Instance.new("UIListLayout")
    textLayout.FillDirection = Enum.FillDirection.Vertical
    textLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    textLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    textLayout.SortOrder = Enum.SortOrder.LayoutOrder
    textLayout.Padding = UDim.new(0, 4)
    textLayout.Parent = textContainer

    local title = Instance.new("TextLabel")
    title.Name = "Heading"
    title.BackgroundTransparency = 1
    title.Size = UDim2.new(1, 0, 0, 30)
    title.Font = theme.titleFont
    title.TextSize = theme.titleTextSize
    title.TextColor3 = Color3.fromRGB(235, 245, 255)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "Verification Timeline"
    title.LayoutOrder = 1
    title.Parent = textContainer

    local subtitle = Instance.new("TextLabel")
    subtitle.Name = "Subtitle"
    subtitle.BackgroundTransparency = 1
    subtitle.Size = UDim2.new(1, 0, 0, 24)
    subtitle.Font = theme.subtitleFont
    subtitle.TextSize = theme.subtitleTextSize
    subtitle.TextColor3 = Color3.fromRGB(170, 184, 220)
    subtitle.TextXAlignment = Enum.TextXAlignment.Left
    subtitle.Text = "Preparing AutoParry systems…"
    subtitle.LayoutOrder = 2
    subtitle.Parent = textContainer

    local telemetryFrame = Instance.new("Frame")
    telemetryFrame.Name = "Telemetry"
    telemetryFrame.BackgroundTransparency = 1
    telemetryFrame.Size = UDim2.new(1, 0, 0, 110)
    telemetryFrame.LayoutOrder = 2
    telemetryFrame.Parent = root

    local telemetryGrid = Instance.new("UIGridLayout")
    telemetryGrid.FillDirection = Enum.FillDirection.Horizontal
    telemetryGrid.HorizontalAlignment = Enum.HorizontalAlignment.Left
    telemetryGrid.VerticalAlignment = Enum.VerticalAlignment.Top
    telemetryGrid.SortOrder = Enum.SortOrder.LayoutOrder
    telemetryGrid.CellPadding = UDim2.new(0, 12, 0, 12)
    telemetryGrid.CellSize = UDim2.new(0.333, -12, 0, 96)
    telemetryGrid.Parent = telemetryFrame

    local telemetryCards = {}
    for index, definition in ipairs(DEFAULT_TELEMETRY) do
        local card = createTelemetryCard(telemetryFrame, theme, definition)
        card.frame.LayoutOrder = index
        telemetryCards[definition.id] = card
    end

    local controlPanel = Instance.new("Frame")
    controlPanel.Name = "ControlPanel"
    controlPanel.BackgroundColor3 = theme.controls.sectionBackground or DEFAULT_THEME.controls.sectionBackground
    controlPanel.BackgroundTransparency = theme.controls.sectionTransparency or DEFAULT_THEME.controls.sectionTransparency
    controlPanel.BorderSizePixel = 0
    controlPanel.LayoutOrder = 3
    controlPanel.AutomaticSize = Enum.AutomaticSize.Y
    controlPanel.Size = UDim2.new(1, 0, 0, 200)
    controlPanel.Parent = root

    local controlCorner = Instance.new("UICorner")
    controlCorner.CornerRadius = DEFAULT_THEME.controls.toggleCorner
    controlCorner.Parent = controlPanel

    local controlStroke = Instance.new("UIStroke")
    controlStroke.Thickness = 1.2
    controlStroke.Color = theme.controls.sectionStrokeColor or DEFAULT_THEME.controls.sectionStrokeColor
    controlStroke.Transparency = theme.controls.sectionStrokeTransparency or DEFAULT_THEME.controls.sectionStrokeTransparency
    controlStroke.Parent = controlPanel

    local controlGradient = Instance.new("UIGradient")
    controlGradient.Color = theme.controls.sectionGradient or DEFAULT_THEME.controls.sectionGradient
    controlGradient.Transparency = theme.controls.sectionGradientTransparency or DEFAULT_THEME.controls.sectionGradientTransparency
    controlGradient.Rotation = 115
    controlGradient.Parent = controlPanel

    local controlPadding = Instance.new("UIPadding")
    controlPadding.PaddingTop = UDim.new(0, 18)
    controlPadding.PaddingBottom = UDim.new(0, 18)
    controlPadding.PaddingLeft = UDim.new(0, 18)
    controlPadding.PaddingRight = UDim.new(0, 18)
    controlPadding.Parent = controlPanel

    local controlStack = Instance.new("Frame")
    controlStack.Name = "ControlStack"
    controlStack.BackgroundTransparency = 1
    controlStack.AutomaticSize = Enum.AutomaticSize.Y
    controlStack.Size = UDim2.new(1, 0, 0, 0)
    controlStack.Parent = controlPanel

    local controlLayout = Instance.new("UIListLayout")
    controlLayout.FillDirection = Enum.FillDirection.Vertical
    controlLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    controlLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    controlLayout.SortOrder = Enum.SortOrder.LayoutOrder
    controlLayout.Padding = UDim.new(0, 12)
    controlLayout.Parent = controlStack

    local controlHeader = Instance.new("TextLabel")
    controlHeader.Name = "ControlHeader"
    controlHeader.BackgroundTransparency = 1
    controlHeader.Size = UDim2.new(1, 0, 0, 26)
    controlHeader.Font = theme.controls.headerFont or DEFAULT_THEME.controls.headerFont
    controlHeader.TextSize = theme.controls.headerTextSize or DEFAULT_THEME.controls.headerTextSize
    controlHeader.TextColor3 = theme.controls.headerColor or DEFAULT_THEME.controls.headerColor
    controlHeader.TextXAlignment = Enum.TextXAlignment.Left
    controlHeader.Text = "Command matrix"
    controlHeader.LayoutOrder = 1
    controlHeader.Parent = controlStack

    local controlGridContainer = Instance.new("Frame")
    controlGridContainer.Name = "ControlGrid"
    controlGridContainer.BackgroundTransparency = 1
    controlGridContainer.AutomaticSize = Enum.AutomaticSize.Y
    controlGridContainer.Size = UDim2.new(1, 0, 0, 0)
    controlGridContainer.LayoutOrder = 2
    controlGridContainer.Parent = controlStack

    local controlGrid = Instance.new("UIGridLayout")
    controlGrid.FillDirection = Enum.FillDirection.Horizontal
    controlGrid.HorizontalAlignment = Enum.HorizontalAlignment.Left
    controlGrid.VerticalAlignment = Enum.VerticalAlignment.Top
    controlGrid.SortOrder = Enum.SortOrder.LayoutOrder
    controlGrid.CellPadding = UDim2.new(0, 12, 0, 12)
    controlGrid.CellSize = UDim2.new(0.5, -12, 0, 96)
    controlGrid.FillDirectionMaxCells = 2
    controlGrid.Parent = controlGridContainer

    local controlButtons = {}

    local timelineCard = Instance.new("Frame")
    timelineCard.Name = "TimelineCard"
    timelineCard.BackgroundColor3 = theme.cardColor
    timelineCard.BackgroundTransparency = theme.cardTransparency
    timelineCard.BorderSizePixel = 0
    timelineCard.AutomaticSize = Enum.AutomaticSize.Y
    timelineCard.Size = UDim2.new(1, 0, 0, 200)
    timelineCard.LayoutOrder = 4
    timelineCard.Parent = root

    local timelineCorner = Instance.new("UICorner")
    timelineCorner.CornerRadius = UDim.new(0, 14)
    timelineCorner.Parent = timelineCard

    local timelineStroke = Instance.new("UIStroke")
    timelineStroke.Thickness = 1.4
    timelineStroke.Color = theme.cardStrokeColor
    timelineStroke.Transparency = theme.cardStrokeTransparency
    timelineStroke.Parent = timelineCard

    local timelinePadding = Instance.new("UIPadding")
    timelinePadding.PaddingTop = UDim.new(0, 18)
    timelinePadding.PaddingBottom = UDim.new(0, 18)
    timelinePadding.PaddingLeft = UDim.new(0, 18)
    timelinePadding.PaddingRight = UDim.new(0, 18)
    timelinePadding.Parent = timelineCard

    local timelineLayout = Instance.new("UIListLayout")
    timelineLayout.FillDirection = Enum.FillDirection.Vertical
    timelineLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    timelineLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    timelineLayout.SortOrder = Enum.SortOrder.LayoutOrder
    timelineLayout.Padding = UDim.new(0, 14)
    timelineLayout.Parent = timelineCard

    local progressTrack = Instance.new("Frame")
    progressTrack.Name = "ProgressTrack"
    progressTrack.Size = UDim2.new(1, 0, 0, 8)
    progressTrack.BackgroundColor3 = Color3.fromRGB(26, 32, 52)
    progressTrack.BackgroundTransparency = 0.2
    progressTrack.BorderSizePixel = 0
    progressTrack.LayoutOrder = 1
    progressTrack.Parent = timelineCard

    local trackCorner = Instance.new("UICorner")
    trackCorner.CornerRadius = UDim.new(0, 6)
    trackCorner.Parent = progressTrack

    local progressFill = Instance.new("Frame")
    progressFill.Name = "Fill"
    progressFill.Size = UDim2.new(0, 0, 1, 0)
    progressFill.BackgroundColor3 = theme.accentColor
    progressFill.BorderSizePixel = 0
    progressFill.Parent = progressTrack

    local progressCorner = Instance.new("UICorner")
    progressCorner.CornerRadius = UDim.new(0, 6)
    progressCorner.Parent = progressFill

    local glow = Instance.new("UIGradient")
    glow.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, theme.accentColor),
        ColorSequenceKeypoint.new(1, theme.accentColor:lerp(Color3.new(1, 1, 1), 0.25)),
    })
    glow.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.1),
        NumberSequenceKeypoint.new(1, 0.4),
    })
    glow.Parent = progressFill

    local listFrame = Instance.new("Frame")
    listFrame.Name = "Steps"
    listFrame.BackgroundTransparency = 1
    listFrame.AutomaticSize = Enum.AutomaticSize.Y
    listFrame.Size = UDim2.new(1, 0, 0, 0)
    listFrame.LayoutOrder = 2
    listFrame.Parent = timelineCard

    local listLayout = Instance.new("UIListLayout")
    listLayout.FillDirection = Enum.FillDirection.Vertical
    listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    listLayout.Padding = UDim.new(0, 10)
    listLayout.Parent = listFrame

    local steps = {}
    for index, definition in ipairs(STEP_DEFINITIONS) do
        local step = createStep(listFrame, definition, theme)
        step.frame.LayoutOrder = index
        if index == #STEP_DEFINITIONS then
            step.connector.Visible = false
        end
        steps[definition.id] = step
    end

    local actionsFrame = Instance.new("Frame")
    actionsFrame.Name = "Actions"
    actionsFrame.BackgroundTransparency = 1
    actionsFrame.LayoutOrder = 5
    actionsFrame.Size = UDim2.new(1, 0, 0, theme.actionHeight + 12)
    actionsFrame.Visible = false
    actionsFrame.Parent = root

    local actionsLayout = Instance.new("UIListLayout")
    actionsLayout.FillDirection = Enum.FillDirection.Horizontal
    actionsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    actionsLayout.SortOrder = Enum.SortOrder.LayoutOrder
    actionsLayout.Padding = UDim.new(0, 12)
    actionsLayout.Parent = actionsFrame

    local self = setmetatable({
        _theme = theme,
        _root = root,
        _layout = layout,
        _header = header,
        _title = title,
        _subtitle = subtitle,
        _telemetryFrame = telemetryFrame,
        _telemetryGrid = telemetryGrid,
        _telemetryCards = telemetryCards,
        _controlPanel = controlPanel,
        _controlStroke = controlStroke,
        _controlGradient = controlGradient,
        _controlHeader = controlHeader,
        _controlGrid = controlGrid,
        _controlButtons = controlButtons,
        _controlConnections = {},
        _controlState = {},
        _controlDefinitions = CONTROL_DEFINITIONS,
        _onControlChanged = options and options.onControlToggle or nil,
        _timelineCard = timelineCard,
        _timelineStroke = timelineStroke,
        _progressFill = progressFill,
        _progressTween = nil,
        _stepsFrame = listFrame,
        _steps = steps,
        _stepStates = {},
        _actionsFrame = actionsFrame,
        _actionsLayout = actionsLayout,
        _actionButtons = {},
        _actionConnections = {},
        _actions = nil,
        _headerText = textContainer,
        _logoContainer = logoContainer,
        _logoFrame = logoElements and logoElements.frame,
        _logoStroke = logoElements and logoElements.stroke,
        _logoGradient = logoElements and logoElements.gradient,
        _logoGlyph = logoElements and logoElements.glyph,
        _logoWordmark = logoElements and logoElements.wordmark,
        _logoWordmarkGradient = logoElements and logoElements.wordmarkGradient,
        _logoTagline = logoElements and logoElements.tagline,
        _logoShimmerTween = nil,
        _destroyed = false,
    }, VerificationDashboard)

    for _, definition in ipairs(STEP_DEFINITIONS) do
        self._stepStates[definition.id] = { status = "pending", priority = STATUS_PRIORITY.pending }
    end

    self:_applyLogoTheme()
    self:_startLogoShimmer()
    self:setControls(options.controls)
    self:setTelemetry(options.telemetry)
    self:setProgress(0)

    return self
end

function VerificationDashboard:_stopLogoShimmer()
    if self._logoShimmerTween then
        self._logoShimmerTween:Cancel()
        self._logoShimmerTween = nil
    end
end

function VerificationDashboard:_startLogoShimmer()
    if self._destroyed then
        return
    end

    if not self._logoGradient then
        return
    end

    self:_stopLogoShimmer()

    local tween = TweenService:Create(
        self._logoGradient,
        TweenInfo.new(4.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
        { Offset = Vector2.new(0.35, 0) }
    )
    self._logoGradient.Offset = Vector2.new(-0.35, 0)
    tween:Play()
    self._logoShimmerTween = tween
end

function VerificationDashboard:_applyLogoTheme()
    if self._destroyed then
        return
    end

    local theme = self._theme or DEFAULT_THEME
    local config = mergeTable(DEFAULT_THEME.logo, theme.logo or {})
    local logoWidth = config.width or DEFAULT_THEME.logo.width or 230

    if self._logoContainer then
        self._logoContainer.Size = UDim2.new(0, logoWidth, 1, 0)
    end

    if self._headerText then
        self._headerText.Size = UDim2.new(1, -logoWidth, 1, 0)
    end

    if self._logoFrame then
        self._logoFrame.BackgroundColor3 = config.backgroundColor or theme.cardColor
        self._logoFrame.BackgroundTransparency = config.backgroundTransparency or 0.1
    end

    if self._logoStroke then
        self._logoStroke.Color = config.strokeColor or theme.accentColor
        self._logoStroke.Transparency = config.strokeTransparency or 0.35
    end

    if self._logoGradient then
        self._logoGradient.Color = config.gradient or DEFAULT_THEME.logo.gradient
        self._logoGradient.Transparency = config.gradientTransparency or DEFAULT_THEME.logo.gradientTransparency
        self._logoGradient.Rotation = config.gradientRotation or DEFAULT_THEME.logo.gradientRotation or 120
    end

    if self._logoGlyph then
        self._logoGlyph.Image = config.glyphImage or (theme.iconography and theme.iconography.hologram) or ""
        self._logoGlyph.ImageColor3 = config.glyphColor or theme.accentColor
        self._logoGlyph.ImageTransparency = config.glyphTransparency or 0.2
    end

    if self._logoWordmark then
        self._logoWordmark.Font = config.font or DEFAULT_THEME.logo.font
        self._logoWordmark.TextSize = config.textSize or DEFAULT_THEME.logo.textSize
        self._logoWordmark.Text = string.upper(config.text or DEFAULT_THEME.logo.text)
        self._logoWordmark.TextColor3 = config.primaryColor or Color3.fromRGB(235, 245, 255)
        self._logoWordmark.TextStrokeColor3 = config.textStrokeColor or Color3.fromRGB(10, 12, 24)
        self._logoWordmark.TextStrokeTransparency = config.textStrokeTransparency or 0.6
    end

    if self._logoWordmarkGradient then
        self._logoWordmarkGradient.Color = config.textGradient or DEFAULT_THEME.logo.textGradient
        self._logoWordmarkGradient.Rotation = config.textGradientRotation or DEFAULT_THEME.logo.textGradientRotation or 0
    end

    if self._logoTagline then
        self._logoTagline.Font = config.taglineFont or DEFAULT_THEME.logo.taglineFont
        self._logoTagline.TextSize = config.taglineTextSize or DEFAULT_THEME.logo.taglineTextSize
        self._logoTagline.TextColor3 = config.taglineColor or DEFAULT_THEME.logo.taglineColor
        self._logoTagline.TextTransparency = config.taglineTransparency or DEFAULT_THEME.logo.taglineTransparency or 0
        self._logoTagline.Text = config.tagline or DEFAULT_THEME.logo.tagline
    end
end

function VerificationDashboard:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true

    self:_stopLogoShimmer()

    for _, connection in ipairs(self._actionConnections) do
        if connection then
            if connection.Disconnect then
                connection:Disconnect()
            elseif connection.disconnect then
                connection:disconnect()
            end
        end
    end

    for _, connection in ipairs(self._controlConnections) do
        if connection then
            if connection.Disconnect then
                connection:Disconnect()
            elseif connection.disconnect then
                connection:disconnect()
            end
        end
    end

    for _, button in ipairs(self._actionButtons) do
        if button and button.Destroy then
            button:Destroy()
        end
    end

    if self._controlButtons then
        for _, toggle in pairs(self._controlButtons) do
            if toggle and toggle.button and toggle.button.Destroy then
                toggle.button:Destroy()
            end
        end
        self._controlButtons = {}
    end

    if self._root then
        self._root:Destroy()
        self._root = nil
    end
end

function VerificationDashboard:getRoot()
    return self._root
end

function VerificationDashboard:getTheme()
    return self._theme
end

function VerificationDashboard:applyTheme(theme)
    if self._destroyed then
        return
    end

    if theme then
        self._theme = mergeTable(DEFAULT_THEME, theme)
    end

    local currentTheme = self._theme

    self:_stopLogoShimmer()
    self:_applyLogoTheme()

    if self._title then
        self._title.Font = currentTheme.titleFont
        self._title.TextSize = currentTheme.titleTextSize
    end
    if self._subtitle then
        self._subtitle.Font = currentTheme.subtitleFont
        self._subtitle.TextSize = currentTheme.subtitleTextSize
    end

    if self._actionsFrame then
        self._actionsFrame.Size = UDim2.new(1, 0, 0, currentTheme.actionHeight + 12)
    end

    if self._progressFill then
        self._progressFill.BackgroundColor3 = currentTheme.accentColor
    end

    if self._telemetryCards then
        local telemetryTheme = currentTheme.telemetry or DEFAULT_THEME.telemetry
        for _, card in pairs(self._telemetryCards) do
            if card.frame then
                card.frame.BackgroundColor3 = telemetryTheme.cardColor
                card.frame.BackgroundTransparency = telemetryTheme.cardTransparency
            end
            if card.stroke then
                card.stroke.Color = telemetryTheme.cardStrokeColor
                card.stroke.Transparency = telemetryTheme.cardStrokeTransparency
            end
            if card.label then
                card.label.Font = telemetryTheme.labelFont
                card.label.TextSize = telemetryTheme.labelTextSize
                card.label.TextColor3 = (telemetryTheme.accentColor or currentTheme.accentColor):Lerp(Color3.new(1, 1, 1), 0.35)
            end
            if card.value then
                card.value.Font = telemetryTheme.valueFont
                card.value.TextSize = telemetryTheme.valueTextSize
                card.value.TextColor3 = Color3.fromRGB(235, 245, 255)
            end
            if card.hint then
                card.hint.Font = telemetryTheme.labelFont
                card.hint.TextSize = math.max((telemetryTheme.labelTextSize or DEFAULT_THEME.telemetry.labelTextSize) - 1, 10)
                card.hint.TextColor3 = Color3.fromRGB(176, 196, 230)
            end
        end
    end

    if self._controlPanel then
        local controlsTheme = currentTheme.controls or DEFAULT_THEME.controls
        self._controlPanel.BackgroundColor3 = controlsTheme.sectionBackground or DEFAULT_THEME.controls.sectionBackground
        self._controlPanel.BackgroundTransparency = controlsTheme.sectionTransparency or DEFAULT_THEME.controls.sectionTransparency
        if self._controlStroke then
            self._controlStroke.Color = controlsTheme.sectionStrokeColor or DEFAULT_THEME.controls.sectionStrokeColor
            self._controlStroke.Transparency = controlsTheme.sectionStrokeTransparency or DEFAULT_THEME.controls.sectionStrokeTransparency
        end
        if self._controlGradient then
            self._controlGradient.Color = controlsTheme.sectionGradient or DEFAULT_THEME.controls.sectionGradient
            self._controlGradient.Transparency = controlsTheme.sectionGradientTransparency or DEFAULT_THEME.controls.sectionGradientTransparency
        end
        if self._controlHeader then
            self._controlHeader.Font = controlsTheme.headerFont or DEFAULT_THEME.controls.headerFont
            self._controlHeader.TextSize = controlsTheme.headerTextSize or DEFAULT_THEME.controls.headerTextSize
            self._controlHeader.TextColor3 = controlsTheme.headerColor or DEFAULT_THEME.controls.headerColor
        end
        if self._controlButtons then
            for id, toggle in pairs(self._controlButtons) do
                local state = self._controlState and self._controlState[id]
                if state == nil then
                    state = toggle.enabled
                end
                styleControlToggle(toggle, currentTheme, not not state)
            end
        end
    end

    if self._timelineCard then
        self._timelineCard.BackgroundColor3 = currentTheme.cardColor
        self._timelineCard.BackgroundTransparency = currentTheme.cardTransparency
    end
    if self._timelineStroke then
        self._timelineStroke.Color = currentTheme.cardStrokeColor
        self._timelineStroke.Transparency = currentTheme.cardStrokeTransparency
    end

    for _, definition in ipairs(STEP_DEFINITIONS) do
        local step = self._steps[definition.id]
        if step then
            step.frame.BackgroundColor3 = currentTheme.cardColor
            step.frame.BackgroundTransparency = currentTheme.cardTransparency
            if step.frame:FindFirstChildOfClass("UIStroke") then
                local stroke = step.frame:FindFirstChildOfClass("UIStroke")
                stroke.Color = currentTheme.cardStrokeColor
                stroke.Transparency = currentTheme.cardStrokeTransparency
            end
            step.icon.ImageColor3 = currentTheme.pendingColor
            step.icon.Image = currentTheme.iconography.pending
            if step.iconGlow then
                step.iconGlow.Color = currentTheme.pendingColor
            end
            step.title.Font = currentTheme.stepTitleFont
            step.title.TextSize = currentTheme.stepTitleTextSize
            step.status.Font = currentTheme.stepStatusFont
            step.status.TextSize = currentTheme.stepStatusTextSize
            step.connector.BackgroundColor3 = currentTheme.connectorColor
            step.connector.BackgroundTransparency = currentTheme.connectorTransparency
            if step.tooltip then
                step.tooltip.Font = currentTheme.tooltipFont
                step.tooltip.TextSize = currentTheme.tooltipTextSize
                step.tooltip.BackgroundColor3 = currentTheme.tooltipBackground
                step.tooltip.BackgroundTransparency = currentTheme.tooltipTransparency
                step.tooltip.TextColor3 = currentTheme.tooltipTextColor
            end
        end
    end

    for _, connection in ipairs(self._actionConnections) do
        if connection then
            if connection.Disconnect then
                connection:Disconnect()
            elseif connection.disconnect then
                connection:disconnect()
            end
        end
    end
    self._actionConnections = {}

    for _, button in ipairs(self._actionButtons) do
        if button and button.Destroy then
            button:Destroy()
        end
    end
    self._actionButtons = {}

    if self._actions then
        self:setActions(self._actions)
    end

    self:_startLogoShimmer()
end

function VerificationDashboard:setStatusText(text)
    if self._destroyed then
        return
    end
    if self._subtitle then
        self._subtitle.Text = text or ""
    end
end

function VerificationDashboard:setTelemetry(telemetry)
    if self._destroyed then
        return
    end

    telemetry = telemetry or {}

    if not self._telemetryCards then
        return
    end

    for id, card in pairs(self._telemetryCards) do
        local payload = telemetry[id]
        if payload == nil and typeof(telemetry) == "table" then
            payload = telemetry[string.upper(id or "")] or telemetry[string.lower(id or "")]
        end

        local valueText = payload
        local hintText

        if typeof(payload) == "table" then
            valueText = payload.value or payload.text or payload.display or payload[1]
            hintText = payload.hint or payload.description or payload.label
        end

        if valueText ~= nil and card.value then
            card.value.Text = tostring(valueText)
        elseif card.definition and card.definition.value and card.value then
            card.value.Text = tostring(card.definition.value)
        end

        if card.hint then
            if hintText ~= nil then
                card.hint.Text = tostring(hintText)
            elseif card.definition then
                card.hint.Text = card.definition.hint or ""
            end
        end
    end
end

function VerificationDashboard:setProgress(alpha)
    if self._destroyed then
        return
    end

    alpha = math.clamp(alpha or 0, 0, 1)

    if self._progressTween then
        self._progressTween:Cancel()
        self._progressTween = nil
    end

    if not self._progressFill then
        return
    end

    local tween = TweenService:Create(self._progressFill, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Size = UDim2.new(alpha, 0, 1, 0),
    })
    self._progressTween = tween
    tween:Play()
end

function VerificationDashboard:reset()
    if self._destroyed then
        return
    end

    for _, definition in ipairs(STEP_DEFINITIONS) do
        local step = self._steps[definition.id]
        if step then
            step.state = "pending"
            step.priority = STATUS_PRIORITY.pending
            step.status.Text = definition.description
            if step.iconTween then
                step.iconTween:Cancel()
                step.iconTween = nil
            end
            step.icon.Image = self._theme.iconography.pending
            step.icon.ImageColor3 = self._theme.pendingColor
            if step.iconGlow then
                step.iconGlow.Color = self._theme.pendingColor
            end
            step.connector.BackgroundTransparency = self._theme.connectorTransparency
            step.connector.BackgroundColor3 = self._theme.connectorColor
            if step.tooltip then
                step.tooltip.Text = definition.tooltip
            end
        end
        self._stepStates[definition.id] = { status = "pending", priority = STATUS_PRIORITY.pending }
    end

    self:setProgress(0)
    self:setStatusText("Preparing AutoParry systems…")
end

local function resolveStyle(theme, status)
    local resolver = STATUS_STYLE[status]
    if resolver then
        return resolver(theme)
    end
    return STATUS_STYLE.pending(theme)
end

function VerificationDashboard:_applyStepState(id, status, message, tooltip)
    if self._destroyed then
        return
    end

    local step = self._steps[id]
    if not step then
        return
    end

    local current = self._stepStates[id]
    current = current or { status = "pending", priority = STATUS_PRIORITY.pending }
    local newPriority = STATUS_PRIORITY[status] or STATUS_PRIORITY.pending
    if current.priority and current.priority > newPriority then
        return
    end

    self._stepStates[id] = { status = status, priority = newPriority }

    local style = resolveStyle(self._theme, status)

    local label = message or style.label
    if label and label ~= "" then
        step.status.Text = label
    end

    if tooltip and step.tooltip then
        step.tooltip.Text = tooltip
    end

    if step.iconTween then
        step.iconTween:Cancel()
        step.iconTween = nil
    end

    if style.icon then
        step.icon.Image = style.icon
    end

    local tween = TweenService:Create(step.icon, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        ImageColor3 = style.color,
        ImageTransparency = 0,
    })
    step.iconTween = tween
    tween:Play()

    if step.iconGlow then
        step.iconGlow.Color = style.color
        step.iconGlow.Transparency = 0.35
    end

    if step.connector then
        step.connector.BackgroundColor3 = style.color
        step.connector.BackgroundTransparency = status == "pending" and self._theme.connectorTransparency or 0.15
    end

    step.state = status
end

local function formatElapsed(seconds)
    if not seconds or seconds <= 0 then
        return nil
    end
    if seconds < 1 then
        return string.format("%.2f s", seconds)
    end
    return string.format("%.1f s", seconds)
end

function VerificationDashboard:_applyParrySnapshot(snapshot)
    if typeof(snapshot) ~= "table" then
        return
    end

    local stage = snapshot.stage
    local status = snapshot.status
    local target = snapshot.target or snapshot.step

    if stage == "ready" then
        self:_applyStepState("player", "ok", "Player locked")
        self:_applyStepState("remotes", "ok", string.format("%s (%s)", snapshot.remoteName or "Parry remote", snapshot.remoteVariant or "detected"))
        if snapshot.successEvents then
            self:_applyStepState("success", "ok", "Success listeners wired")
        else
            self:_applyStepState("success", "ok", "Success listeners active")
        end
        if snapshot.successEvents and snapshot.successEvents.Balls then
            self:_applyStepState("balls", "ok", "Ball telemetry streaming")
        else
            self:_applyStepState("balls", "ok", "Ready for match")
        end
        return
    end

    if stage == "timeout" then
        local reason = snapshot.reason or target
        if reason == "local-player" or target == "local-player" then
            self:_applyStepState("player", "failed", "Timed out waiting for player")
        elseif reason == "remotes-folder" or target == "folder" then
            self:_applyStepState("remotes", "failed", "Remotes folder missing")
        elseif reason == "parry-remote" or target == "remote" then
            self:_applyStepState("remotes", "failed", "Parry remote unavailable")
        elseif reason == "balls-folder" then
            self:_applyStepState("balls", "warning", "Balls folder not found")
        end
        return
    end

    if stage == "error" then
        if target == "remote" then
            self:_applyStepState("remotes", "failed", snapshot.message or "Unsupported parry remote")
        elseif target == "folder" then
            self:_applyStepState("remotes", "failed", snapshot.message or "Remotes folder removed")
        else
            self:_applyStepState("success", "warning", snapshot.message or "Verification error")
        end
        return
    end

    if stage == "waiting-player" then
        if status == "ok" then
            local elapsed = formatElapsed(snapshot.elapsed)
            self:_applyStepState("player", "ok", elapsed and ("Player ready (" .. elapsed .. ")") or "Player ready")
        elseif status == "waiting" or status == "pending" then
            self:_applyStepState("player", "active", "Waiting for player…")
        end
        return
    end

    if stage == "waiting-remotes" then
        if target == "folder" then
            if status == "ok" then
                self:_applyStepState("remotes", "active", "Remotes folder located")
            elseif status == "waiting" or status == "pending" then
                self:_applyStepState("remotes", "active", "Searching for Remotes folder…")
            end
        elseif target == "remote" then
            if status == "ok" then
                local name = snapshot.remoteName or "Parry remote"
                local variant = snapshot.remoteVariant or "detected"
                self:_applyStepState("remotes", "ok", string.format("%s (%s)", name, variant))
            elseif status == "waiting" or status == "pending" then
                self:_applyStepState("remotes", "active", "Scanning for parry remote…")
            end
        end
        return
    end

    if stage == "verifying-success-remotes" then
        self:_applyStepState("success", "active", "Hooking success events…")
        if snapshot.remotes then
            self:_applyStepState("success", "ok", "Success listeners bound")
        end
        return
    end

    if stage == "verifying-balls" then
        if status == "ok" then
            self:_applyStepState("balls", "ok", "Ball telemetry online")
        elseif status == "waiting" then
            self:_applyStepState("balls", "active", "Searching for balls…")
        elseif status == "warning" then
            self:_applyStepState("balls", "warning", "Ball folder timeout", "AutoParry will continue without ball telemetry if the folder is missing.")
        end
        return
    end
end

local function extractErrorReason(errorState)
    if typeof(errorState) ~= "table" then
        return nil, nil
    end

    local payload = errorState.payload
    local reason = errorState.reason
    if payload and typeof(payload) == "table" then
        reason = payload.reason or payload.target or payload.step or reason
    end

    return reason, payload
end

function VerificationDashboard:_applyError(errorState)
    if not errorState then
        return
    end

    local reason, payload = extractErrorReason(errorState)
    local message = errorState.message or "Verification error"

    if reason == "local-player" then
        self:_applyStepState("player", "failed", message)
    elseif reason == "remotes-folder" or reason == "parry-remote" or reason == "remote" then
        self:_applyStepState("remotes", "failed", message)
    elseif reason == "balls-folder" or reason == "balls" then
        self:_applyStepState("balls", "warning", message)
    else
        self:_applyStepState("success", "warning", message)
    end

    if payload and payload.elapsed then
        self:setStatusText(string.format("Failed after %s", formatElapsed(payload.elapsed) or "0 s"))
    else
        self:setStatusText(message)
    end
end

function VerificationDashboard:update(state, context)
    if self._destroyed then
        return
    end

    state = state or {}

    if state.parry then
        self:_applyParrySnapshot(state.parry)
    elseif state.stage then
        self:_applyParrySnapshot(state)
    end

    if state.error then
        self:_applyError(state.error)
    end

    if context and context.progress then
        self:setProgress(context.progress)
    end
end

function VerificationDashboard:setActions(actions)
    if self._destroyed then
        return
    end

    self._actions = actions

    for _, connection in ipairs(self._actionConnections) do
        if connection then
            if connection.Disconnect then
                connection:Disconnect()
            elseif connection.disconnect then
                connection:disconnect()
            end
        end
    end
    self._actionConnections = {}

    for _, button in ipairs(self._actionButtons) do
        if button and button.Destroy then
            button:Destroy()
        end
    end
    self._actionButtons = {}

    if typeof(actions) ~= "table" or #actions == 0 then
        if self._actionsFrame then
            self._actionsFrame.Visible = false
        end
        return
    end

    if not self._actionsFrame then
        return
    end

    self._actionsFrame.Visible = true

    for index, action in ipairs(actions) do
        local button = Instance.new("TextButton")
        button.Name = action.id or action.name or string.format("Action%d", index)
        button.Text = action.text or action.label or "Action"
        button.BackgroundTransparency = 0
        button.ZIndex = 5
        button.Parent = self._actionsFrame

        styleActionButton(button, self._theme, action)

        local connection
        if typeof(action.callback) == "function" then
            connection = button.MouseButton1Click:Connect(function()
                action.callback(self, action)
            end)
        end

        table.insert(self._actionButtons, button)
        table.insert(self._actionConnections, connection)
    end
end

function VerificationDashboard:setControls(controls)
    if self._destroyed then
        return
    end

    controls = controls or self._controlDefinitions or CONTROL_DEFINITIONS

    if typeof(controls) ~= "table" then
        controls = CONTROL_DEFINITIONS
    end

    self._controlDefinitions = controls

    for _, connection in ipairs(self._controlConnections) do
        if connection then
            if connection.Disconnect then
                connection:Disconnect()
            elseif connection.disconnect then
                connection:disconnect()
            end
        end
    end
    self._controlConnections = {}

    if self._controlButtons then
        for _, toggle in pairs(self._controlButtons) do
            if toggle and toggle.button and toggle.button.Destroy then
                toggle.button:Destroy()
            end
        end
    end

    self._controlButtons = {}
    self._controlState = {}

    local grid = self._controlGrid
    if not grid then
        return
    end

    local container = grid.Parent
    if not container then
        return
    end

    for index, definition in ipairs(controls) do
        local id = definition.id or string.format("Control%d", index)
        local toggle = createControlToggle(container, self._theme, definition)
        toggle.button.LayoutOrder = index
        toggle.definition = definition
        self._controlButtons[id] = toggle

        local enabled = definition.enabled
        if enabled == nil then
            enabled = definition.default
        end
        if enabled == nil then
            enabled = true
        end
        enabled = not not enabled
        self._controlState[id] = enabled
        styleControlToggle(toggle, self._theme, enabled)

        local connection = toggle.button.MouseButton1Click:Connect(function()
            self:toggleControl(id)
        end)
        table.insert(self._controlConnections, connection)
    end
end

function VerificationDashboard:setControlState(id, enabled)
    if self._destroyed then
        return
    end

    if id == nil then
        return
    end

    id = tostring(id)
    enabled = not not enabled

    if not self._controlState then
        self._controlState = {}
    end

    self._controlState[id] = enabled

    local toggle = self._controlButtons and self._controlButtons[id]
    if toggle then
        styleControlToggle(toggle, self._theme, enabled)
        if toggle.definition and typeof(toggle.definition.callback) == "function" then
            toggle.definition.callback(self, enabled, toggle)
        end
    end

    if self._onControlChanged then
        self._onControlChanged(id, enabled, toggle and toggle.definition or nil)
    end
end

function VerificationDashboard:toggleControl(id)
    if self._destroyed or id == nil then
        return
    end

    id = tostring(id)
    local current = self._controlState and self._controlState[id]
    if current == nil then
        return
    end
    self:setControlState(id, not current)
end

function VerificationDashboard:getControlState(id)
    if not self._controlState then
        return nil
    end
    return self._controlState[id]
end

return VerificationDashboard

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
    "dashboard": {
      "size": {
        "x": { "scale": 0, "offset": 460 },
        "y": { "scale": 0, "offset": 0 }
      },
      "position": {
        "x": { "scale": 0, "offset": 36 },
        "y": { "scale": 0, "offset": 140 }
      },
      "backgroundColor3": { "r": 12, "g": 16, "b": 32 },
      "automaticSize": "Y",
      "borderSizePixel": 0,
      "active": true,
      "draggable": true,
      "header": {
        "title": {
          "text": "Snapshot Title",
          "font": "GothamBlack",
          "textSize": 30,
          "textColor3": { "r": 230, "g": 242, "b": 255 },
          "size": {
            "x": { "scale": 1, "offset": 0 },
            "y": { "scale": 0, "offset": 34 }
          },
          "position": {
            "x": { "scale": 0, "offset": 0 },
            "y": { "scale": 0, "offset": 0 }
          },
          "textXAlignment": "Left",
          "textYAlignment": "Bottom",
          "backgroundTransparency": 1
        },
        "tagline": {
          "text": "Neural shield online",
          "font": "Gotham",
          "textSize": 18,
          "textColor3": { "r": 180, "g": 199, "b": 230 },
          "size": {
            "x": { "scale": 1, "offset": 0 },
            "y": { "scale": 0, "offset": 26 }
          },
          "position": {
            "x": { "scale": 0, "offset": 0 },
            "y": { "scale": 0, "offset": 38 }
          },
          "textXAlignment": "Left",
          "textYAlignment": "Top",
          "backgroundTransparency": 1
        },
        "hotkeyLabel": {
          "text": "Hotkey: G",
          "font": "Gotham",
          "textSize": 14,
          "textColor3": { "r": 170, "g": 188, "b": 220 },
          "size": {
            "x": { "scale": 0, "offset": 240 },
            "y": { "scale": 0, "offset": 20 }
          },
          "position": {
            "x": { "scale": 1, "offset": 0 },
            "y": { "scale": 1, "offset": 6 }
          },
          "textXAlignment": "Right",
          "textYAlignment": "Center",
          "backgroundTransparency": 1
        },
        "badge": {
          "backgroundColor3": { "r": 62, "g": 72, "b": 96 },
          "text": "IDLE",
          "textColor3": { "r": 215, "g": 228, "b": 255 }
        }
      },
      "statusCard": {
        "backgroundColor3": { "r": 16, "g": 24, "b": 44 },
        "heading": {
          "text": "AutoParry standby",
          "font": "GothamBlack",
          "textSize": 26,
          "textColor3": { "r": 230, "g": 242, "b": 255 },
          "size": {
            "x": { "scale": 1, "offset": -160 },
            "y": { "scale": 0, "offset": 32 }
          },
          "position": {
            "x": { "scale": 0, "offset": 0 },
            "y": { "scale": 0, "offset": 32 }
          },
          "textXAlignment": "Left",
          "textYAlignment": "Center",
          "backgroundTransparency": 1
        },
        "support": {
          "text": "Neural mesh waiting for activation signal.",
          "font": "Gotham",
          "textSize": 17,
          "textColor3": { "r": 180, "g": 199, "b": 230 },
          "size": {
            "x": { "scale": 1, "offset": -160 },
            "y": { "scale": 0, "offset": 44 }
          },
          "position": {
            "x": { "scale": 0, "offset": 0 },
            "y": { "scale": 0, "offset": 66 }
          },
          "textXAlignment": "Left",
          "textYAlignment": "Center",
          "backgroundTransparency": 1
        },
        "hotkeyLabel": {
          "text": "Hotkey: G",
          "font": "Gotham",
          "textSize": 14,
          "textColor3": { "r": 170, "g": 188, "b": 220 },
          "size": {
            "x": { "scale": 0, "offset": 160 },
            "y": { "scale": 0, "offset": 20 }
          },
          "position": {
            "x": { "scale": 1, "offset": 0 },
            "y": { "scale": 0, "offset": 118 }
          },
          "textXAlignment": "Right",
          "textYAlignment": "Center",
          "backgroundTransparency": 1
        },
        "tooltip": {
          "text": "Tap to toggle",
          "font": "Gotham",
          "textSize": 14,
          "textColor3": { "r": 150, "g": 168, "b": 205 },
          "size": {
            "x": { "scale": 1, "offset": 0 },
            "y": { "scale": 0, "offset": 20 }
          },
          "position": {
            "x": { "scale": 0, "offset": 0 },
            "y": { "scale": 0, "offset": 118 }
          },
          "textXAlignment": "Left",
          "textYAlignment": "Center",
          "backgroundTransparency": 1
        },
        "button": {
          "name": "ToggleButton",
          "text": "Activate shield",
          "font": "GothamBold",
          "textSize": 19,
          "textColor3": { "r": 220, "g": 234, "b": 255 },
          "size": {
            "x": { "scale": 0, "offset": 160 },
            "y": { "scale": 0, "offset": 46 }
          },
          "position": {
            "x": { "scale": 1, "offset": 0 },
            "y": { "scale": 0, "offset": 20 }
          },
          "backgroundColor3": { "r": 42, "g": 52, "b": 80 },
          "autoButtonColor": false
        }
      },
      "telemetry": {
        "title": {
          "text": "Mission telemetry",
          "font": "GothamSemibold",
          "textSize": 18,
          "textColor3": { "r": 185, "g": 205, "b": 240 },
          "size": {
            "x": { "scale": 1, "offset": 0 },
            "y": { "scale": 0, "offset": 22 }
          },
          "position": {
            "x": { "scale": 0, "offset": 0 },
            "y": { "scale": 0, "offset": 0 }
          },
          "textXAlignment": "Left",
          "textYAlignment": "Center",
          "backgroundTransparency": 1
        },
        "cards": [
          {
            "name": "latency",
            "size": {
              "x": { "scale": 0, "offset": 0 },
              "y": { "scale": 0, "offset": 100 }
            },
            "backgroundColor3": { "r": 18, "g": 24, "b": 40 },
            "label": {
              "text": "Latency",
              "font": "GothamSemibold",
              "textSize": 16,
              "textColor3": { "r": 185, "g": 205, "b": 240 },
              "size": {
                "x": { "scale": 1, "offset": 0 },
                "y": { "scale": 0, "offset": 18 }
              },
              "position": {
                "x": { "scale": 0, "offset": 0 },
                "y": { "scale": 0, "offset": 0 }
              },
              "textXAlignment": "Left",
              "textYAlignment": "Center",
              "backgroundTransparency": 1
            },
            "value": {
              "text": "-- ms",
              "font": "GothamBlack",
              "textSize": 26,
              "textColor3": { "r": 230, "g": 242, "b": 255 },
              "size": {
                "x": { "scale": 1, "offset": 0 },
                "y": { "scale": 0, "offset": 28 }
              },
              "position": {
                "x": { "scale": 0, "offset": 0 },
                "y": { "scale": 0, "offset": 26 }
              },
              "textXAlignment": "Left",
              "textYAlignment": "Center",
              "backgroundTransparency": 1
            },
            "hint": {
              "text": "Ping to Blade Ball server",
              "font": "Gotham",
              "textSize": 14,
              "textColor3": { "r": 150, "g": 168, "b": 205 },
              "size": {
                "x": { "scale": 1, "offset": 0 },
                "y": { "scale": 0, "offset": 28 }
              },
              "position": {
                "x": { "scale": 0, "offset": 0 },
                "y": { "scale": 0, "offset": 58 }
              },
              "textXAlignment": "Left",
              "textYAlignment": "Center",
              "backgroundTransparency": 1
            }
          },
          {
            "name": "mesh",
            "size": {
              "x": { "scale": 0, "offset": 0 },
              "y": { "scale": 0, "offset": 100 }
            },
            "backgroundColor3": { "r": 18, "g": 24, "b": 40 },
            "label": {
              "text": "Neural Mesh",
              "font": "GothamSemibold",
              "textSize": 16,
              "textColor3": { "r": 185, "g": 205, "b": 240 },
              "size": {
                "x": { "scale": 1, "offset": 0 },
                "y": { "scale": 0, "offset": 18 }
              },
              "position": {
                "x": { "scale": 0, "offset": 0 },
                "y": { "scale": 0, "offset": 0 }
              },
              "textXAlignment": "Left",
              "textYAlignment": "Center",
              "backgroundTransparency": 1
            },
            "value": {
              "text": "Calibrating",
              "font": "GothamBlack",
              "textSize": 26,
              "textColor3": { "r": 230, "g": 242, "b": 255 },
              "size": {
                "x": { "scale": 1, "offset": 0 },
                "y": { "scale": 0, "offset": 28 }
              },
              "position": {
                "x": { "scale": 0, "offset": 0 },
                "y": { "scale": 0, "offset": 26 }
              },
              "textXAlignment": "Left",
              "textYAlignment": "Center",
              "backgroundTransparency": 1
            },
            "hint": {
              "text": "Adaptive reaction model state",
              "font": "Gotham",
              "textSize": 14,
              "textColor3": { "r": 150, "g": 168, "b": 205 },
              "size": {
                "x": { "scale": 1, "offset": 0 },
                "y": { "scale": 0, "offset": 28 }
              },
              "position": {
                "x": { "scale": 0, "offset": 0 },
                "y": { "scale": 0, "offset": 58 }
              },
              "textXAlignment": "Left",
              "textYAlignment": "Center",
              "backgroundTransparency": 1
            }
          },
          {
            "name": "uptime",
            "size": {
              "x": { "scale": 0, "offset": 0 },
              "y": { "scale": 0, "offset": 100 }
            },
            "backgroundColor3": { "r": 18, "g": 24, "b": 40 },
            "label": {
              "text": "Session",
              "font": "GothamSemibold",
              "textSize": 16,
              "textColor3": { "r": 185, "g": 205, "b": 240 },
              "size": {
                "x": { "scale": 1, "offset": 0 },
                "y": { "scale": 0, "offset": 18 }
              },
              "position": {
                "x": { "scale": 0, "offset": 0 },
                "y": { "scale": 0, "offset": 0 }
              },
              "textXAlignment": "Left",
              "textYAlignment": "Center",
              "backgroundTransparency": 1
            },
            "value": {
              "text": "00:00",
              "font": "GothamBlack",
              "textSize": 26,
              "textColor3": { "r": 230, "g": 242, "b": 255 },
              "size": {
                "x": { "scale": 1, "offset": 0 },
                "y": { "scale": 0, "offset": 28 }
              },
              "position": {
                "x": { "scale": 0, "offset": 0 },
                "y": { "scale": 0, "offset": 26 }
              },
              "textXAlignment": "Left",
              "textYAlignment": "Center",
              "backgroundTransparency": 1
            },
            "hint": {
              "text": "Runtime since activation",
              "font": "Gotham",
              "textSize": 14,
              "textColor3": { "r": 150, "g": 168, "b": 205 },
              "size": {
                "x": { "scale": 1, "offset": 0 },
                "y": { "scale": 0, "offset": 28 }
              },
              "position": {
                "x": { "scale": 0, "offset": 0 },
                "y": { "scale": 0, "offset": 58 }
              },
              "textXAlignment": "Left",
              "textYAlignment": "Center",
              "backgroundTransparency": 1
            }
          }
        ]
      },
      "controls": {
        "title": {
          "text": "Control mesh",
          "font": "GothamSemibold",
          "textSize": 18,
          "textColor3": { "r": 185, "g": 205, "b": 240 },
          "size": {
            "x": { "scale": 1, "offset": 0 },
            "y": { "scale": 0, "offset": 22 }
          },
          "position": {
            "x": { "scale": 0, "offset": 0 },
            "y": { "scale": 0, "offset": 0 }
          },
          "textXAlignment": "Left",
          "textYAlignment": "Center",
          "backgroundTransparency": 1
        },
        "toggles": [
          {
            "name": "adaptive",
            "title": {
              "text": "Adaptive Reaction",
              "font": "GothamSemibold",
              "textSize": 17,
              "textColor3": { "r": 230, "g": 242, "b": 255 },
              "size": {
                "x": { "scale": 1, "offset": -150 },
                "y": { "scale": 0, "offset": 20 }
              },
              "position": {
                "x": { "scale": 0, "offset": 0 },
                "y": { "scale": 0, "offset": 0 }
              },
              "textXAlignment": "Left",
              "textYAlignment": "Center",
              "backgroundTransparency": 1
            },
            "description": {
              "text": "Learns opponent speed to retime parries.",
              "font": "Gotham",
              "textSize": 14,
              "textColor3": { "r": 160, "g": 178, "b": 210 },
              "size": {
                "x": { "scale": 1, "offset": -150 },
                "y": { "scale": 0, "offset": 34 }
              },
              "position": {
                "x": { "scale": 0, "offset": 0 },
                "y": { "scale": 0, "offset": 24 }
              },
              "textXAlignment": "Left",
              "textYAlignment": "Center",
              "backgroundTransparency": 1
            },
            "badge": {
              "text": "AI",
              "font": "GothamSemibold",
              "textSize": 13,
              "textColor3": { "r": 180, "g": 205, "b": 255 },
              "size": {
                "x": { "scale": 0, "offset": 80 },
                "y": { "scale": 0, "offset": 18 }
              },
              "position": {
                "x": { "scale": 0, "offset": 0 },
                "y": { "scale": 0, "offset": 58 }
              },
              "textXAlignment": "Left",
              "textYAlignment": "Center",
              "backgroundTransparency": 1
            },
            "switch": {
              "name": "Switch",
              "text": "ON",
              "font": "GothamBold",
              "textSize": 16,
              "textColor3": { "r": 12, "g": 16, "b": 20 },
              "size": {
                "x": { "scale": 0, "offset": 120 },
                "y": { "scale": 0, "offset": 34 }
              },
              "position": {
                "x": { "scale": 1, "offset": 0 },
                "y": { "scale": 0.5, "offset": 0 }
              },
              "backgroundColor3": { "r": 0, "g": 210, "b": 185 },
              "autoButtonColor": false
            }
          },
          {
            "name": "edge",
            "title": {
              "text": "Edge Prediction",
              "font": "GothamSemibold",
              "textSize": 17,
              "textColor3": { "r": 230, "g": 242, "b": 255 },
              "size": {
                "x": { "scale": 1, "offset": -150 },
                "y": { "scale": 0, "offset": 20 }
              },
              "position": {
                "x": { "scale": 0, "offset": 0 },
                "y": { "scale": 0, "offset": 0 }
              },
              "textXAlignment": "Left",
              "textYAlignment": "Center",
              "backgroundTransparency": 1
            },
            "description": {
              "text": "Predicts ricochet chains before they happen.",
              "font": "Gotham",
              "textSize": 14,
              "textColor3": { "r": 160, "g": 178, "b": 210 },
              "size": {
                "x": { "scale": 1, "offset": -150 },
                "y": { "scale": 0, "offset": 34 }
              },
              "position": {
                "x": { "scale": 0, "offset": 0 },
                "y": { "scale": 0, "offset": 24 }
              },
              "textXAlignment": "Left",
              "textYAlignment": "Center",
              "backgroundTransparency": 1
            },
            "switch": {
              "name": "Switch",
              "text": "OFF",
              "font": "GothamBold",
              "textSize": 16,
              "textColor3": { "r": 220, "g": 234, "b": 255 },
              "size": {
                "x": { "scale": 0, "offset": 120 },
                "y": { "scale": 0, "offset": 34 }
              },
              "position": {
                "x": { "scale": 1, "offset": 0 },
                "y": { "scale": 0.5, "offset": 0 }
              },
              "backgroundColor3": { "r": 42, "g": 52, "b": 80 },
              "autoButtonColor": false
            }
          },
          {
            "name": "failsafe",
            "title": {
              "text": "Failsafe Recall",
              "font": "GothamSemibold",
              "textSize": 17,
              "textColor3": { "r": 230, "g": 242, "b": 255 },
              "size": {
                "x": { "scale": 1, "offset": -150 },
                "y": { "scale": 0, "offset": 20 }
              },
              "position": {
                "x": { "scale": 0, "offset": 0 },
                "y": { "scale": 0, "offset": 0 }
              },
              "textXAlignment": "Left",
              "textYAlignment": "Center",
              "backgroundTransparency": 1
            },
            "description": {
              "text": "Falls back to manual play if anomalies spike.",
              "font": "Gotham",
              "textSize": 14,
              "textColor3": { "r": 160, "g": 178, "b": 210 },
              "size": {
                "x": { "scale": 1, "offset": -150 },
                "y": { "scale": 0, "offset": 34 }
              },
              "position": {
                "x": { "scale": 0, "offset": 0 },
                "y": { "scale": 0, "offset": 24 }
              },
              "textXAlignment": "Left",
              "textYAlignment": "Center",
              "backgroundTransparency": 1
            },
            "badge": {
              "text": "SAFE",
              "font": "GothamSemibold",
              "textSize": 13,
              "textColor3": { "r": 180, "g": 205, "b": 255 },
              "size": {
                "x": { "scale": 0, "offset": 80 },
                "y": { "scale": 0, "offset": 18 }
              },
              "position": {
                "x": { "scale": 0, "offset": 0 },
                "y": { "scale": 0, "offset": 58 }
              },
              "textXAlignment": "Left",
              "textYAlignment": "Center",
              "backgroundTransparency": 1
            },
            "switch": {
              "name": "Switch",
              "text": "ON",
              "font": "GothamBold",
              "textSize": 16,
              "textColor3": { "r": 12, "g": 16, "b": 20 },
              "size": {
                "x": { "scale": 0, "offset": 120 },
                "y": { "scale": 0, "offset": 34 }
              },
              "position": {
                "x": { "scale": 1, "offset": 0 },
                "y": { "scale": 0.5, "offset": 0 }
              },
              "backgroundColor3": { "r": 0, "g": 210, "b": 185 },
              "autoButtonColor": false
            }
          },
          {
            "name": "sync",
            "title": {
              "text": "Squad Sync",
              "font": "GothamSemibold",
              "textSize": 17,
              "textColor3": { "r": 230, "g": 242, "b": 255 },
              "size": {
                "x": { "scale": 1, "offset": -150 },
                "y": { "scale": 0, "offset": 20 }
              },
              "position": {
                "x": { "scale": 0, "offset": 0 },
                "y": { "scale": 0, "offset": 0 }
              },
              "textXAlignment": "Left",
              "textYAlignment": "Center",
              "backgroundTransparency": 1
            },
            "description": {
              "text": "Shares telemetry with party members instantly.",
              "font": "Gotham",
              "textSize": 14,
              "textColor3": { "r": 160, "g": 178, "b": 210 },
              "size": {
                "x": { "scale": 1, "offset": -150 },
                "y": { "scale": 0, "offset": 34 }
              },
              "position": {
                "x": { "scale": 0, "offset": 0 },
                "y": { "scale": 0, "offset": 24 }
              },
              "textXAlignment": "Left",
              "textYAlignment": "Center",
              "backgroundTransparency": 1
            },
            "badge": {
              "text": "LINK",
              "font": "GothamSemibold",
              "textSize": 13,
              "textColor3": { "r": 180, "g": 205, "b": 255 },
              "size": {
                "x": { "scale": 0, "offset": 80 },
                "y": { "scale": 0, "offset": 18 }
              },
              "position": {
                "x": { "scale": 0, "offset": 0 },
                "y": { "scale": 0, "offset": 58 }
              },
              "textXAlignment": "Left",
              "textYAlignment": "Center",
              "backgroundTransparency": 1
            },
            "switch": {
              "name": "Switch",
              "text": "ON",
              "font": "GothamBold",
              "textSize": 16,
              "textColor3": { "r": 12, "g": 16, "b": 20 },
              "size": {
                "x": { "scale": 0, "offset": 120 },
                "y": { "scale": 0, "offset": 34 }
              },
              "position": {
                "x": { "scale": 1, "offset": 0 },
                "y": { "scale": 0.5, "offset": 0 }
              },
              "backgroundColor3": { "r": 0, "g": 210, "b": 185 },
              "autoButtonColor": false
            }
          }
        ]
      },
      "actions": {
        "visible": false,
        "buttonCount": 0
      }
    }
  }
}

]===],
}
