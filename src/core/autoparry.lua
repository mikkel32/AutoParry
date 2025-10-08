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
local CoreGui = game:GetService("CoreGui")

local Require = rawget(_G, "ARequire")
local Util = Require and Require("src/shared/util.lua") or require(script.Parent.Parent.shared.util)

local Signal = Util.Signal
local Verification = Require and Require("src/core/verification.lua") or require(script.Parent.verification)
local ImmortalModule = Require and Require("src/core/immortal.lua") or require(script.Parent.immortal)

local DEFAULT_CONFIG = {
    -- public API configuration that remains relevant for the PERFECT-PARRY rule
    safeRadius = 10,
    confidenceZ = 2.2,
    activationLatency = 0.12,
    targetHighlightName = "Highlight",
    ballsFolderName = "Balls",
    playerTimeout = 10,
    remotesTimeout = 10,
    ballsFolderTimeout = 5,
    verificationRetryInterval = 0,
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
local EPSILON = 1e-6
local SMOOTH_ALPHA = 0.25
local KAPPA_ALPHA = 0.3
local DKAPPA_ALPHA = 0.3
local ACTIVATION_LATENCY_ALPHA = 0.2
local SIGMA_FLOORS = {
    d = 0.01,
    vr = 1.5,
    ar = 10,
    jr = 80,
}

local PHYSICS_LIMITS = {
    curvature = 5,
    curvatureRate = 120,
    radialAcceleration = 650,
    radialJerk = 20000,
}
local state = {
    enabled = false,
    connection = nil,
    lastParry = 0,
    lastSuccess = 0,
    lastBroadcast = 0,
    immortalEnabled = false,
}

local initialization = {
    started = false,
    completed = false,
    destroyed = false,
    error = nil,
    token = 0,
}

local initStatus = Signal.new()
local initProgress = { stage = "waiting-player" }
local stateChanged = Signal.new()
local parryEvent = Signal.new()
local parrySuccessSignal = Signal.new()
local parryBroadcastSignal = Signal.new()
local immortalStateChanged = Signal.new()

local LocalPlayer: Player?
local Character: Model?
local RootPart: BasePart?
local Humanoid: Humanoid?
local BallsFolder: Instance?
local watchedBallsFolder: Instance?
local RemotesFolder: Instance?

local ParryInputInfo: {[string]: any}?
local verificationWatchers: { { RBXScriptConnection? } } = {}
local successConnections: { RBXScriptConnection? } = {}
local successStatusSnapshot: { [string]: boolean }?
local ballsFolderStatusSnapshot: { [string]: any }?
local ballsFolderConnections: { RBXScriptConnection? }?
local restartPending = false
local scheduleRestart
local syncImmortalContext = function() end

local UiRoot: ScreenGui?
local ToggleButton: TextButton?
local ImmortalButton: TextButton?
local RemoveButton: TextButton?
local StatusLabel: TextLabel?
local BallHighlight: Highlight?
local BallBillboard: BillboardGui?
local BallStatsLabel: TextLabel?

local loopConnection: RBXScriptConnection?
local humanoidDiedConnection: RBXScriptConnection?
local characterAddedConnection: RBXScriptConnection?
local characterRemovingConnection: RBXScriptConnection?

local trackedBall: BasePart?
local parryHeld = false
local parryHeldBallId: string?

local immortalController = ImmortalModule and ImmortalModule.new({}) or nil

type RollingStat = {
    count: number,
    mean: number,
    m2: number,
}

type TelemetryState = {
    lastPosition: Vector3?,
    lastVelocity: Vector3?,
    lastAcceleration: Vector3?,
    velocity: Vector3,
    acceleration: Vector3,
    jerk: Vector3,
    kappa: number,
    dkappa: number,
    lastRawKappa: number?,
    filteredD: number,
    filteredVr: number,
    filteredAr: number,
    filteredJr: number,
    statsD: RollingStat,
    statsVr: RollingStat,
    statsAr: RollingStat,
    statsJr: RollingStat,
    lastUpdate: number,
    triggerTime: number?,
    latencySampled: boolean?,
}

local telemetryStates: { [string]: TelemetryState } = {}
local telemetryTimeoutSeconds = 3
local activationLatencyEstimate = DEFAULT_CONFIG.activationLatency
local perfectParrySnapshot = {
    mu = 0,
    sigma = 0,
    delta = 0,
    z = DEFAULT_CONFIG.confidenceZ,
}

local pingSample = { value = 0, time = 0 }
local PING_REFRESH_INTERVAL = 0.1
local PROXIMITY_PRESS_GRACE = 0.05
local PROXIMITY_HOLD_GRACE = 0.1

local function newRollingStat(): RollingStat
    return { count = 0, mean = 0, m2 = 0 }
end

local function isFiniteNumber(value: number?)
    return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function updateRollingStat(stat: RollingStat, sample: number)
    if not stat then
        return
    end

    if not isFiniteNumber(sample) then
        return
    end

    local count = stat.count + 1
    stat.count = count
    local delta = sample - stat.mean
    stat.mean += delta / count
    local delta2 = sample - stat.mean
    stat.m2 += delta * delta2
end

local function getRollingStd(stat: RollingStat?, floor: number)
    if not stat or stat.count < 2 then
        return floor
    end

    local variance = stat.m2 / (stat.count - 1)
    if variance < 0 then
        variance = 0
    end

    local std = math.sqrt(variance)
    if std < floor then
        std = floor
    end
    return std
end

local function emaScalar(previous: number?, sample: number, alpha: number)
    if not previous then
        return sample
    end
    return previous + (sample - previous) * alpha
end

local function emaVector(previous: Vector3?, sample: Vector3, alpha: number)
    if not previous then
        return sample
    end
    return previous + (sample - previous) * alpha
end

local function clampWithOverflow(value: number, limit: number?)
    if not limit or limit <= 0 then
        return value, 0
    end

    local absValue = math.abs(value)
    if absValue <= limit then
        return value, 0
    end

    local sign = if value >= 0 then 1 else -1
    local overflow = absValue - limit
    return sign * limit, overflow
end

local function ensureTelemetry(ballId: string, now: number): TelemetryState
    local telemetry = telemetryStates[ballId]
    if telemetry then
        return telemetry
    end

    telemetry = {
        lastPosition = nil,
        lastVelocity = nil,
        lastAcceleration = nil,
        velocity = Vector3.zero,
        acceleration = Vector3.zero,
        jerk = Vector3.zero,
        kappa = 0,
        dkappa = 0,
        lastRawKappa = nil,
        filteredD = 0,
        filteredVr = 0,
        filteredAr = 0,
        filteredJr = 0,
        statsD = newRollingStat(),
        statsVr = newRollingStat(),
        statsAr = newRollingStat(),
        statsJr = newRollingStat(),
        lastUpdate = now,
        triggerTime = nil,
        latencySampled = true,
    }

    telemetryStates[ballId] = telemetry
    return telemetry
end

local function cleanupTelemetry(now: number)
    for id, telemetry in pairs(telemetryStates) do
        if now - (telemetry.lastUpdate or 0) > telemetryTimeoutSeconds then
            telemetryStates[id] = nil
        end
    end
end

local function resetActivationLatency()
    activationLatencyEstimate = config.activationLatency or DEFAULT_CONFIG.activationLatency or 0
    if activationLatencyEstimate < 0 then
        activationLatencyEstimate = 0
    end
    perfectParrySnapshot.mu = 0
    perfectParrySnapshot.sigma = 0
    perfectParrySnapshot.delta = 0
    perfectParrySnapshot.z = config.confidenceZ or DEFAULT_CONFIG.confidenceZ or perfectParrySnapshot.z
end

resetActivationLatency()

local AutoParry
local updateCharacter
local beginInitialization
local publishReadyStatus
local setBallsFolderWatcher

local function cloneTable(tbl)
    return Util.deepCopy(tbl)
end

local function safeDisconnect(connection)
    if not connection then
        return
    end

    local ok, disconnectMethod = pcall(function()
        return connection.Disconnect or connection.disconnect
    end)

    if ok and typeof(disconnectMethod) == "function" then
        pcall(disconnectMethod, connection)
    end
end

local function disconnectConnections(connections)
    for index = #connections, 1, -1 do
        local connection = connections[index]
        safeDisconnect(connection)
        connections[index] = nil
    end
end

local function connectSignal(signal, handler)
    if not signal or typeof(handler) ~= "function" then
        return nil
    end

    local ok, connectMethod = pcall(function()
        return signal.Connect or signal.connect
    end)

    if not ok or typeof(connectMethod) ~= "function" then
        return nil
    end

    local success, connection = pcall(connectMethod, signal, handler)
    if success then
        return connection
    end

    return nil
end

local function connectInstanceEvent(instance, eventName, handler)
    if not instance or typeof(handler) ~= "function" then
        return nil
    end

    local ok, event = pcall(function()
        return instance[eventName]
    end)

    if not ok or event == nil then
        return nil
    end

    return connectSignal(event, handler)
end

local function connectPropertyChangedSignal(instance, propertyName, handler)
    if not instance or typeof(handler) ~= "function" then
        return nil
    end

    local ok, getter = pcall(function()
        return instance.GetPropertyChangedSignal
    end)

    if not ok or typeof(getter) ~= "function" then
        return nil
    end

    local success, signal = pcall(getter, instance, propertyName)
    if not success or signal == nil then
        return nil
    end

    return connectSignal(signal, handler)
end

local function connectClientEvent(remote, handler)
    if not remote or typeof(handler) ~= "function" then
        return nil
    end

    local ok, signal = pcall(function()
        return remote.OnClientEvent
    end)

    if not ok or signal == nil then
        return nil
    end

    local success, connection = pcall(function()
        return signal:Connect(handler)
    end)

    if success and connection then
        return connection
    end

    local okMethod, connectMethod = pcall(function()
        return signal.Connect or signal.connect
    end)

    if okMethod and typeof(connectMethod) == "function" then
        local okConnect, alternative = pcall(connectMethod, signal, handler)
        if okConnect then
            return alternative
        end
    end

    return nil
end

local function disconnectVerificationWatchers()
    for index = #verificationWatchers, 1, -1 do
        local connections = verificationWatchers[index]
        if connections then
            disconnectConnections(connections)
        end
        verificationWatchers[index] = nil
    end
end

local function disconnectSuccessListeners()
    disconnectConnections(successConnections)
    successStatusSnapshot = nil
end

local function clearRemoteState()
    disconnectVerificationWatchers()
    disconnectSuccessListeners()
    ParryInputInfo = nil
    RemotesFolder = nil
    if ballsFolderConnections then
        disconnectConnections(ballsFolderConnections)
        ballsFolderConnections = nil
    end
    BallsFolder = nil
    watchedBallsFolder = nil
    pendingBallsFolderSearch = false
    ballsFolderStatusSnapshot = nil
    if syncImmortalContext then
        syncImmortalContext()
    end
end

local function configureSuccessListeners(successRemotes)
    disconnectSuccessListeners()

    local status = {
        ParrySuccess = false,
        ParrySuccessAll = false,
    }

    if not successRemotes then
        successStatusSnapshot = status
        return status
    end

    local function connectEntry(key, entry, callback)
        if not entry then
            return
        end

        if entry.unsupported then
            status[key] = false
            return
        end

        local remote = entry.remote
        if not remote then
            return
        end

        local connection = connectClientEvent(remote, callback)
        if connection then
            table.insert(successConnections, connection)
            status[key] = true
        end
    end

    connectEntry("ParrySuccess", successRemotes.ParrySuccess, function(...)
        local now = os.clock()
        state.lastSuccess = now
        parrySuccessSignal:fire(...)
    end)

    connectEntry("ParrySuccessAll", successRemotes.ParrySuccessAll, function(...)
        local now = os.clock()
        state.lastBroadcast = now
        parryBroadcastSignal:fire(...)
    end)

    successStatusSnapshot = status
    return status
end

local function watchResource(instance, reason)
    if not instance then
        return
    end

    local triggered = false
    local connections = {}

    local function restart()
        if triggered then
            return
        end
        triggered = true
        scheduleRestart(reason)
    end

    local parentConnection = connectPropertyChangedSignal(instance, "Parent", function()
        local ok, parent = pcall(function()
            return instance.Parent
        end)

        if not ok or parent == nil then
            restart()
        end
    end)

    if parentConnection then
        table.insert(connections, parentConnection)
    end

    local ancestryConnection = connectInstanceEvent(instance, "AncestryChanged", function(_, parent)
        if parent == nil then
            restart()
        end
    end)

    if ancestryConnection then
        table.insert(connections, ancestryConnection)
    end

    local destroyingConnection = connectInstanceEvent(instance, "Destroying", function()
        restart()
    end)

    if destroyingConnection then
        table.insert(connections, destroyingConnection)
    end

    if #connections > 0 then
        table.insert(verificationWatchers, connections)
    end
end


scheduleRestart = function(reason)
    if restartPending or initialization.destroyed then
        return
    end

    restartPending = true
    initialization.completed = false
    initialization.token += 1
    initialization.started = false
    initialization.error = nil

    local payload = { stage = "restarting", reason = reason }

    if ParryInputInfo then
        if ParryInputInfo.remoteName then
            payload.remoteName = ParryInputInfo.remoteName
        end
        if ParryInputInfo.variant then
            payload.remoteVariant = ParryInputInfo.variant
        end
        if ParryInputInfo.className then
            payload.remoteClass = ParryInputInfo.className
        end
        if ParryInputInfo.keyCode then
            payload.inputKey = ParryInputInfo.keyCode
        end
        if ParryInputInfo.method then
            payload.inputMethod = ParryInputInfo.method
        end
    end

    applyInitStatus(payload)

    task.defer(function()
        restartPending = false
        if initialization.destroyed then
            return
        end

        clearRemoteState()
        beginInitialization()
    end)
end

function setBallsFolderWatcher(folder)
    if ballsFolderConnections then
        disconnectConnections(ballsFolderConnections)
        ballsFolderConnections = nil
    end

    if not folder then
        return
    end

    local connections = {}
    local triggered = false

    local function restart(reason)
        if triggered then
            return
        end
        triggered = true
        scheduleRestart(reason)
    end

    local function currentParent()
        local ok, parent = pcall(function()
            return folder.Parent
        end)
        if ok then
            return parent
        end
        return nil
    end

    local parentConnection = connectPropertyChangedSignal(folder, "Parent", function()
        if currentParent() == nil then
            restart("balls-folder-missing")
        end
    end)
    if parentConnection then
        table.insert(connections, parentConnection)
    end

    local ancestryConnection = connectInstanceEvent(folder, "AncestryChanged", function(_, parent)
        if parent == nil then
            restart("balls-folder-missing")
        end
    end)
    if ancestryConnection then
        table.insert(connections, ancestryConnection)
    end

    local destroyingConnection = connectInstanceEvent(folder, "Destroying", function()
        restart("balls-folder-missing")
    end)
    if destroyingConnection then
        table.insert(connections, destroyingConnection)
    end

    local nameConnection = connectPropertyChangedSignal(folder, "Name", function()
        local okName, currentName = pcall(function()
            return folder.Name
        end)
        if not okName or currentName ~= config.ballsFolderName then
            restart("balls-folder-missing")
        end
    end)
    if nameConnection then
        table.insert(connections, nameConnection)
    end

    ballsFolderConnections = connections
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

local function formatImmortalText(enabled)
    if enabled then
        return "IMMORTAL: ON"
    end
    return "IMMORTAL: OFF"
end

local function formatImmortalColor(enabled)
    if enabled then
        return Color3.fromRGB(0, 170, 85)
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
    settings.SafeRadius = config.safeRadius
    settings.ConfidenceZ = config.confidenceZ
    settings.ActivationLatency = activationLatencyEstimate
    settings.PerfectParry = perfectParrySnapshot
    settings.Immortal = state.immortalEnabled
end

local function updateToggleButton()
    if not ToggleButton then
        return
    end

    ToggleButton.Text = formatToggleText(state.enabled)
    ToggleButton.BackgroundColor3 = formatToggleColor(state.enabled)
end

local function updateImmortalButton()
    if not ImmortalButton then
        return
    end

    ImmortalButton.Text = formatImmortalText(state.immortalEnabled)
    ImmortalButton.BackgroundColor3 = formatImmortalColor(state.immortalEnabled)
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

local function syncImmortalContextImpl()
    if not immortalController then
        return
    end

    immortalController:setContext({
        player = LocalPlayer,
        character = Character,
        humanoid = Humanoid,
        rootPart = RootPart,
        ballsFolder = BallsFolder,
    })

    immortalController:setBallsFolder(BallsFolder)
    immortalController:setEnabled(state.immortalEnabled)
end

syncImmortalContext = syncImmortalContextImpl

local function enterRespawnWaitState()
    if LocalPlayer then
        setStage("waiting-character", { player = LocalPlayer.Name })
    else
        setStage("waiting-character")
    end

    updateStatusLabel({ "Auto-Parry F", "Status: waiting for respawn" })
end

local function clearBallVisualsInternal()
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

local function safeClearBallVisuals()
    -- Some exploit environments aggressively nil out locals when reloading the
    -- module; guard the call so we gracefully fall back instead of throwing.
    if typeof(clearBallVisualsInternal) == "function" then
        clearBallVisualsInternal()
        return
    end

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

local function destroyDashboardUi()
    if not CoreGui then
        return
    end

    for _, name in ipairs({ "AutoParryUI", "AutoParryLoadingOverlay" }) do
        local screen = CoreGui:FindFirstChild(name)
        if screen then
            screen:Destroy()
        end
    end
end

local function removePlayerGuiUi()
    local player = Players.LocalPlayer
    if not player then
        return
    end

    local playerGui = player:FindFirstChildOfClass("PlayerGui")
    if not playerGui then
        return
    end

    local legacyScreen = playerGui:FindFirstChild("AutoParryF_UI")
    if legacyScreen then
        legacyScreen:Destroy()
    end
end

local function removeAutoParryExperience()
    local destroyOk, destroyErr = pcall(function()
        if typeof(AutoParry) == "table" and typeof(AutoParry.destroy) == "function" then
            AutoParry.destroy()
        end
    end)
    if not destroyOk then
        warn("AutoParry: failed to destroy core:", destroyErr)
    end

    GlobalEnv.Paws = nil

    local cleanupOk, cleanupErr = pcall(function()
        removePlayerGuiUi()
        destroyDashboardUi()
    end)
    if not cleanupOk then
        warn("AutoParry: failed to clear UI:", cleanupErr)
    end
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

    local immortalBtn = Instance.new("TextButton")
    immortalBtn.Size = UDim2.fromOffset(180, 34)
    immortalBtn.Position = UDim2.fromOffset(10, 54)
    immortalBtn.BackgroundColor3 = formatImmortalColor(state.immortalEnabled)
    immortalBtn.TextColor3 = Color3.new(1, 1, 1)
    immortalBtn.Font = Enum.Font.GothamBold
    immortalBtn.TextSize = 18
    immortalBtn.BorderSizePixel = 0
    immortalBtn.Text = formatImmortalText(state.immortalEnabled)
    immortalBtn.Parent = gui
    immortalBtn.MouseButton1Click:Connect(function()
        AutoParry.toggleImmortal()
    end)

    local removeBtn = Instance.new("TextButton")
    removeBtn.Size = UDim2.fromOffset(180, 30)
    removeBtn.Position = UDim2.fromOffset(10, 94)
    removeBtn.BackgroundColor3 = Color3.fromRGB(120, 0, 0)
    removeBtn.TextColor3 = Color3.new(1, 1, 1)
    removeBtn.Font = Enum.Font.GothamBold
    removeBtn.TextSize = 18
    removeBtn.BorderSizePixel = 0
    removeBtn.Text = "REMOVE Auto-Parry"
    removeBtn.Parent = gui
    removeBtn.MouseButton1Click:Connect(function()
        removeAutoParryExperience()
    end)

    local status = Instance.new("TextLabel")
    status.Size = UDim2.fromOffset(320, 120)
    status.Position = UDim2.fromOffset(10, 132)
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
    ImmortalButton = immortalBtn
    RemoveButton = removeBtn
    StatusLabel = status
    BallHighlight = highlight
    BallBillboard = billboard
    BallStatsLabel = statsLabel

    updateToggleButton()
    updateImmortalButton()
    updateStatusLabel({ "Auto-Parry F", "Status: initializing" })
end

local function destroyUi()
    safeClearBallVisuals()
    if UiRoot then
        UiRoot:Destroy()
    end
    UiRoot = nil
    ToggleButton = nil
    ImmortalButton = nil
    RemoveButton = nil
    StatusLabel = nil
    BallHighlight = nil
    BallBillboard = nil
    BallStatsLabel = nil
end

local function getPingTime()
    local now = os.clock()
    if now - pingSample.time < PING_REFRESH_INTERVAL then
        return pingSample.value
    end

    local seconds = pingSample.value
    if Stats then
        local okStat, stat = pcall(function()
            return Stats.Network.ServerStatsItem["Data Ping"]
        end)

        if okStat and stat then
            local okValue, value = pcall(stat.GetValue, stat)
            if okValue and value then
                seconds = value / 1000
            end
        end
    end

    if not isFiniteNumber(seconds) or seconds < 0 then
        seconds = 0
    end

    pingSample.value = seconds
    pingSample.time = now

    return seconds
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

local pendingBallsFolderSearch = false

local function isValidBallsFolder(candidate, expectedName)
    if not candidate then
        return false
    end

    local okParent, parent = pcall(function()
        return candidate.Parent
    end)
    if not okParent or parent == nil then
        return false
    end

    local okName, name = pcall(function()
        return candidate.Name
    end)
    if not okName or name ~= expectedName then
        return false
    end

    return true
end

local function ensureBallsFolder(allowYield: boolean?)
    local expectedName = config.ballsFolderName
    if typeof(expectedName) ~= "string" or expectedName == "" then
        return nil
    end

    if not isValidBallsFolder(BallsFolder, expectedName) then
        BallsFolder = nil
        watchedBallsFolder = nil
        setBallsFolderWatcher(nil)
        syncImmortalContext()

        local found = Workspace:FindFirstChild(expectedName)
        if isValidBallsFolder(found, expectedName) then
            BallsFolder = found
            syncImmortalContext()
        end
    end

    if BallsFolder then
        if watchedBallsFolder ~= BallsFolder and initialization.completed then
            setBallsFolderWatcher(BallsFolder)
            watchedBallsFolder = BallsFolder
            publishReadyStatus()
        end

        syncImmortalContext()
        return BallsFolder
    end

    if allowYield then
        local timeout = config.ballsFolderTimeout
        local ok, result = pcall(function()
            if timeout and timeout > 0 then
                return Workspace:WaitForChild(expectedName, timeout)
            end
            return Workspace:WaitForChild(expectedName)
        end)

        if ok and isValidBallsFolder(result, expectedName) then
            BallsFolder = result

            if initialization.completed then
                setBallsFolderWatcher(BallsFolder)
                watchedBallsFolder = BallsFolder
                publishReadyStatus()
            end

            syncImmortalContext()
            return BallsFolder
        end

        return nil
    end

    if not pendingBallsFolderSearch and not initialization.destroyed then
        pendingBallsFolderSearch = true
        task.defer(function()
            pendingBallsFolderSearch = false
            if initialization.destroyed then
                return
            end

            ensureBallsFolder(true)
        end)
    end

    return nil
end

local function getBallsFolderLabel()
    local folderLabel = config.ballsFolderName
    local folder = BallsFolder

    if folder then
        local okName, fullName = pcall(folder.GetFullName, folder)
        if okName and typeof(fullName) == "string" then
            folderLabel = fullName
        else
            folderLabel = folder.Name
        end
    end

    return folderLabel
end

function publishReadyStatus()
    local payload = {
        stage = "ready",
        player = LocalPlayer and LocalPlayer.Name or "Unknown",
        ballsFolder = getBallsFolderLabel(),
    }

    if ParryInputInfo then
        if ParryInputInfo.remoteName then
            payload.remoteName = ParryInputInfo.remoteName
        end
        if ParryInputInfo.className then
            payload.remoteClass = ParryInputInfo.className
        end
        if ParryInputInfo.variant then
            payload.remoteVariant = ParryInputInfo.variant
        end
        if ParryInputInfo.method then
            payload.remoteMethod = ParryInputInfo.method
        end
        if ParryInputInfo.keyCode then
            payload.inputKey = ParryInputInfo.keyCode
        end
    end

    if successStatusSnapshot then
        payload.successEvents = cloneTable(successStatusSnapshot)
    end

    if ballsFolderStatusSnapshot then
        payload.ballsFolderStatus = cloneTable(ballsFolderStatusSnapshot)
    end

    applyInitStatus(payload)
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

local function getBallIdentifier(ball)
    if not ball then
        return nil
    end

    local ok, id = pcall(ball.GetDebugId, ball, 0)
    if ok and typeof(id) == "string" then
        return id
    end

    return tostring(ball)
end


local function pressParry(ball: BasePart?, ballId: string?)
    if parryHeld then
        if parryHeldBallId == ballId then
            return false
        end

        -- release the existing hold before pressing for a new ball
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.F, false, game)
        parryHeld = false
        parryHeldBallId = nil
    end

    parryHeld = true
    parryHeldBallId = ballId

    local now = os.clock()
    state.lastParry = now

    if ballId then
        local telemetry = telemetryStates[ballId]
        if telemetry then
            telemetry.triggerTime = now
            telemetry.latencySampled = false
        end
    end

    VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.F, false, game)
    parryEvent:fire(ball, now)
    return true
end

local function releaseParry()
    if not parryHeld then
        return
    end

    local ballId = parryHeldBallId
    parryHeld = false
    parryHeldBallId = nil
    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.F, false, game)

    if ballId then
        local telemetry = telemetryStates[ballId]
        if telemetry then
            telemetry.triggerTime = nil
            telemetry.latencySampled = true
        end
    end
end

local function handleHumanoidDied()
    releaseParry()
    safeClearBallVisuals()
    enterRespawnWaitState()
    updateCharacter(nil)
    if immortalController then
        immortalController:handleHumanoidDied()
    end
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
        humanoidDiedConnection = humanoid.Died:Connect(handleHumanoidDied)
    end

    if initialization.completed and character then
        ensureBallsFolder(false)
        publishReadyStatus()
    end

    syncImmortalContext()
end

local function handleCharacterAdded(character)
    updateCharacter(character)
end

local function handleCharacterRemoving()
    releaseParry()
    safeClearBallVisuals()
    enterRespawnWaitState()
    updateCharacter(nil)
end

local function beginInitialization()
    if initialization.destroyed then
        return
    end

    initialization.token += 1
    local token = initialization.token

    initialization.started = true
    initialization.completed = false
    initialization.error = nil

    task.spawn(function()
        local function report(status)
            if initialization.token ~= token or initialization.destroyed then
                return
            end

            applyInitStatus(status)
        end

        local ok, result = pcall(function()
            return Verification.run({
                config = config,
                report = report,
                retryInterval = config.verificationRetryInterval,
            })
        end)

        if initialization.token ~= token or initialization.destroyed then
            return
        end

        if not ok then
            initialization.error = result

            local payload = { stage = initProgress.stage == "timeout" and "timeout" or "error" }
            payload.message = tostring(result)

            if initProgress.reason then
                payload.reason = initProgress.reason
            end

            if initProgress.target then
                payload.target = initProgress.target
            end

            if initProgress.className then
                payload.className = initProgress.className
            end

            if initProgress.elapsed then
                payload.elapsed = initProgress.elapsed
            end

            applyInitStatus(payload)
            initialization.started = false
            return
        end

        local verificationResult = result

        LocalPlayer = verificationResult.player
        RemotesFolder = verificationResult.remotesFolder
        ParryInputInfo = verificationResult.parryInputInfo

        syncImmortalContext()

        disconnectVerificationWatchers()

        if RemotesFolder then
            watchResource(RemotesFolder, "remotes-folder-removed")
        end

        configureSuccessListeners(verificationResult.successRemotes)

        if verificationResult.successRemotes then
            local localEntry = verificationResult.successRemotes.ParrySuccess
            if localEntry and localEntry.remote then
                watchResource(localEntry.remote, "removeevents-local-missing")
            end

            local broadcastEntry = verificationResult.successRemotes.ParrySuccessAll
            if broadcastEntry and broadcastEntry.remote then
                watchResource(broadcastEntry.remote, "removeevents-all-missing")
            end
        end

        if verificationResult.ballsFolder then
            BallsFolder = verificationResult.ballsFolder
        else
            BallsFolder = nil
        end
        setBallsFolderWatcher(BallsFolder)
        watchedBallsFolder = BallsFolder

        syncImmortalContext()

        if LocalPlayer then
            safeDisconnect(characterAddedConnection)
            safeDisconnect(characterRemovingConnection)

            characterAddedConnection = LocalPlayer.CharacterAdded:Connect(handleCharacterAdded)
            characterRemovingConnection = LocalPlayer.CharacterRemoving:Connect(handleCharacterRemoving)

            local currentCharacter = LocalPlayer.Character
            if currentCharacter then
                updateCharacter(currentCharacter)
            else
                local okChar, char = pcall(function()
                    return LocalPlayer.CharacterAdded:Wait()
                end)
                if okChar and char then
                    updateCharacter(char)
                end
            end
        end

        ensureUi()

        setStage("waiting-character", { player = LocalPlayer and LocalPlayer.Name or "Unknown" })

        setStage("waiting-balls")
        ensureBallsFolder(true)

        if BallsFolder then
            setBallsFolderWatcher(BallsFolder)
            watchedBallsFolder = BallsFolder
        else
            setBallsFolderWatcher(nil)
        end

        if verificationResult.ballsStatus then
            ballsFolderStatusSnapshot = cloneTable(verificationResult.ballsStatus)
        else
            ballsFolderStatusSnapshot = nil
        end

        publishReadyStatus()
        initialization.completed = true
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

local function computeBallDebug(
    speed,
    distance,
    safeRadius,
    mu,
    sigma,
    inequality,
    delta,
    tti,
    ttp,
    tth,
    pressRadius,
    holdRadius
)
    return string.format(
        "💨 Speed: %.1f\n📏 Dist: %.2f (safe: %.1f | press: %.1f | hold: %.1f)\nμ: %.3f\nσ: %.3f\nμ+zσ: %.3f\nΔ: %.3f\nTTI: %.3f\nTTP: %.3f\nTTH: %.3f",
        speed,
        distance,
        safeRadius,
        pressRadius,
        holdRadius,
        mu,
        sigma,
        inequality,
        delta,
        tti,
        ttp,
        tth
    )
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
        safeClearBallVisuals()
        releaseParry()
        return
    end

    ensureBallsFolder(false)
    local folder = BallsFolder
    if not folder then
        updateStatusLabel({ "Auto-Parry F", "Ball: none", "Info: waiting for balls folder" })
        safeClearBallVisuals()
        releaseParry()
        return
    end

    if not state.enabled then
        releaseParry()
        updateStatusLabel({ "Auto-Parry F", "Status: OFF" })
        safeClearBallVisuals()
        updateToggleButton()
        return
    end

    local now = os.clock()
    cleanupTelemetry(now)

    local ball = findRealBall(folder)
    if not ball or not ball:IsDescendantOf(Workspace) then
        updateStatusLabel({ "Auto-Parry F", "Ball: none", "Info: waiting for realBall..." })
        safeClearBallVisuals()
        releaseParry()
        return
    end

    local ballId = getBallIdentifier(ball)
    if not ballId then
        updateStatusLabel({ "Auto-Parry F", "Ball: unknown", "Info: missing identifier" })
        safeClearBallVisuals()
        releaseParry()
        return
    end

    local telemetry = ensureTelemetry(ballId, now)
    local previousUpdate = telemetry.lastUpdate or now
    local dt = now - previousUpdate
    if not isFiniteNumber(dt) or dt <= 0 then
        dt = 1 / 240
    end
    dt = math.clamp(dt, 1 / 240, 0.5)
    telemetry.lastUpdate = now

    local ballPosition = ball.Position
    local playerPosition = RootPart.Position
    local relative = ballPosition - playerPosition
    local distance = relative.Magnitude
    local unit = Vector3.zero
    if distance > EPSILON then
        unit = relative / distance
    end

    local safeRadius = config.safeRadius or 0
    local d0 = distance - safeRadius

    local rawVelocity = Vector3.zero
    if telemetry.lastPosition then
        rawVelocity = (ballPosition - telemetry.lastPosition) / dt
    end
    telemetry.lastPosition = ballPosition

    local rawAcceleration = Vector3.zero
    if telemetry.lastVelocity then
        rawAcceleration = (rawVelocity - telemetry.lastVelocity) / dt
    end

    local rawJerk = Vector3.zero
    if telemetry.lastAcceleration then
        rawJerk = (rawAcceleration - telemetry.lastAcceleration) / dt
    end

    telemetry.lastVelocity = rawVelocity
    telemetry.lastAcceleration = rawAcceleration

    local velocity = emaVector(telemetry.velocity, rawVelocity, SMOOTH_ALPHA)
    telemetry.velocity = velocity
    local acceleration = emaVector(telemetry.acceleration, rawAcceleration, SMOOTH_ALPHA)
    telemetry.acceleration = acceleration
    local jerk = emaVector(telemetry.jerk, rawJerk, SMOOTH_ALPHA)
    telemetry.jerk = jerk

    local vNorm2 = velocity:Dot(velocity)
    if vNorm2 < EPSILON then
        vNorm2 = EPSILON
    end

    local rawSpeed = rawVelocity.Magnitude
    local rawSpeedSq = rawVelocity:Dot(rawVelocity)
    local rawKappa = 0
    if rawSpeed > EPSILON then
        rawKappa = rawVelocity:Cross(rawAcceleration).Magnitude / math.max(rawSpeedSq * rawSpeed, EPSILON)
    end

    local filteredKappaRaw = emaScalar(telemetry.kappa, rawKappa, KAPPA_ALPHA)
    local filteredKappa, kappaOverflow = clampWithOverflow(filteredKappaRaw, PHYSICS_LIMITS.curvature)
    telemetry.kappa = filteredKappa

    local dkappaRaw = 0
    if telemetry.lastRawKappa ~= nil then
        dkappaRaw = (rawKappa - telemetry.lastRawKappa) / math.max(dt, EPSILON)
    end
    telemetry.lastRawKappa = rawKappa

    local filteredDkappaRaw = emaScalar(telemetry.dkappa, dkappaRaw, DKAPPA_ALPHA)
    local filteredDkappa, dkappaOverflow = clampWithOverflow(filteredDkappaRaw, PHYSICS_LIMITS.curvatureRate)
    telemetry.dkappa = filteredDkappa

    local rawVr = -unit:Dot(rawVelocity)
    local filteredVr = emaScalar(telemetry.filteredVr, -unit:Dot(velocity), SMOOTH_ALPHA)
    telemetry.filteredVr = filteredVr

    local filteredArEstimate = -unit:Dot(acceleration) + filteredKappa * vNorm2
    local filteredArRaw = emaScalar(telemetry.filteredAr, filteredArEstimate, SMOOTH_ALPHA)
    local filteredAr, arOverflow = clampWithOverflow(filteredArRaw, PHYSICS_LIMITS.radialAcceleration)
    telemetry.filteredAr = filteredAr

    local dotVA = velocity:Dot(acceleration)
    local filteredJrEstimate = -unit:Dot(jerk) + filteredDkappa * vNorm2 + 2 * filteredKappa * dotVA
    local filteredJrRaw = emaScalar(telemetry.filteredJr, filteredJrEstimate, SMOOTH_ALPHA)
    local filteredJr, jrOverflow = clampWithOverflow(filteredJrRaw, PHYSICS_LIMITS.radialJerk)
    telemetry.filteredJr = filteredJr

    local rawAr = -unit:Dot(rawAcceleration) + rawKappa * rawSpeedSq
    local rawJr = -unit:Dot(rawJerk) + dkappaRaw * rawSpeedSq + 2 * rawKappa * rawVelocity:Dot(rawAcceleration)

    local filteredD = emaScalar(telemetry.filteredD, d0, SMOOTH_ALPHA)
    telemetry.filteredD = filteredD

    updateRollingStat(telemetry.statsD, d0 - filteredD)
    updateRollingStat(telemetry.statsVr, rawVr - filteredVr)
    updateRollingStat(telemetry.statsAr, rawAr - filteredAr)
    updateRollingStat(telemetry.statsJr, rawJr - filteredJr)

    local sigmaD = getRollingStd(telemetry.statsD, SIGMA_FLOORS.d)
    local sigmaVr = getRollingStd(telemetry.statsVr, SIGMA_FLOORS.vr)
    local sigmaAr = getRollingStd(telemetry.statsAr, SIGMA_FLOORS.ar)
    local sigmaJr = getRollingStd(telemetry.statsJr, SIGMA_FLOORS.jr)

    local sigmaArExtraSq = 0
    local sigmaArOverflow = 0
    if arOverflow > 0 then
        sigmaArExtraSq += arOverflow * arOverflow
    end
    if kappaOverflow and kappaOverflow > 0 then
        local extra = kappaOverflow * vNorm2
        sigmaArExtraSq += extra * extra
    end
    if sigmaArExtraSq > 0 then
        sigmaArOverflow = math.sqrt(sigmaArExtraSq)
        sigmaAr = math.sqrt(sigmaAr * sigmaAr + sigmaArExtraSq)
    end

    local sigmaJrExtraSq = 0
    local sigmaJrOverflow = 0
    if jrOverflow > 0 then
        sigmaJrExtraSq += jrOverflow * jrOverflow
    end
    if kappaOverflow and kappaOverflow > 0 then
        local extra = 2 * kappaOverflow * math.abs(dotVA)
        sigmaJrExtraSq += extra * extra
    end
    if dkappaOverflow and dkappaOverflow > 0 then
        local extra = dkappaOverflow * vNorm2
        sigmaJrExtraSq += extra * extra
    end
    if sigmaJrExtraSq > 0 then
        sigmaJrOverflow = math.sqrt(sigmaJrExtraSq)
        sigmaJr = math.sqrt(sigmaJr * sigmaJr + sigmaJrExtraSq)
    end

    local ping = getPingTime()
    local delta = 0.5 * ping + activationLatencyEstimate

    local delta2 = delta * delta
    local mu = filteredD - filteredVr * delta - 0.5 * filteredAr * delta2 - (1 / 6) * filteredJr * delta2 * delta

    local sigmaSquared = sigmaD * sigmaD
    sigmaSquared += (delta2) * (sigmaVr * sigmaVr)
    sigmaSquared += (0.25 * delta2 * delta2) * (sigmaAr * sigmaAr)
    sigmaSquared += ((1 / 36) * delta2 * delta2 * delta2) * (sigmaJr * sigmaJr)
    local sigma = math.sqrt(math.max(sigmaSquared, 0))

    local z = config.confidenceZ or DEFAULT_CONFIG.confidenceZ
    if not isFiniteNumber(z) or z < 0 then
        z = DEFAULT_CONFIG.confidenceZ or 2.2
    end

    local muValid = isFiniteNumber(mu)
    local sigmaValid = isFiniteNumber(sigma)
    if not muValid then
        mu = 0
    end
    if not sigmaValid then
        sigma = 0
    end
    local muPlus = math.huge
    local muMinus = math.huge
    if muValid and sigmaValid then
        muPlus = mu + z * sigma
        muMinus = mu - z * sigma
    end

    perfectParrySnapshot.mu = mu
    perfectParrySnapshot.sigma = sigma
    perfectParrySnapshot.delta = delta
    perfectParrySnapshot.z = z

    local targetingMe = isTargetingMe()
    local fired = false
    local released = false

    local approachSpeed = math.max(filteredVr, rawVr, 0)
    local approaching = approachSpeed > EPSILON
    local timeToImpact = math.huge
    if approaching then
        local speed = math.max(approachSpeed, EPSILON)
        timeToImpact = distance / speed
    end

    local responseWindow = math.max(delta + PROXIMITY_PRESS_GRACE, PROXIMITY_PRESS_GRACE)
    local holdWindow = responseWindow + PROXIMITY_HOLD_GRACE

    local dynamicLead = 0
    if approaching then
        dynamicLead = math.max(approachSpeed * responseWindow, 0)
    end
    dynamicLead = math.min(dynamicLead, safeRadius * 0.5)

    local pressRadius = safeRadius + dynamicLead
    local holdLead = 0
    if approaching then
        holdLead = math.max(approachSpeed * PROXIMITY_HOLD_GRACE, safeRadius * 0.1)
    else
        holdLead = safeRadius * 0.1
    end
    holdLead = math.min(holdLead, safeRadius * 0.5)
    local holdRadius = pressRadius + holdLead

    local timeToPressRadius = math.huge
    local timeToHoldRadius = math.huge
    if approaching then
        local speed = math.max(approachSpeed, EPSILON)
        timeToPressRadius = math.max(distance - pressRadius, 0) / speed
        timeToHoldRadius = math.max(distance - holdRadius, 0) / speed
    end

    local proximityPress =
        targetingMe
        and approaching
        and (distance <= pressRadius or timeToPressRadius <= responseWindow or timeToImpact <= responseWindow)

    local proximityHold =
        targetingMe
        and approaching
        and (distance <= holdRadius or timeToHoldRadius <= holdWindow or timeToImpact <= holdWindow)

    local shouldPress = proximityPress
    if not shouldPress then
        shouldPress = targetingMe and muValid and sigmaValid and muPlus <= 0
    end

    local shouldHold = proximityHold
    if targetingMe and muValid and sigmaValid and muMinus < 0 then
        shouldHold = true
    end
    if shouldPress then
        shouldHold = true
    end

    if shouldPress then
        fired = pressParry(ball, ballId)
    end

    if parryHeld and parryHeldBallId == ballId then
        local triggerTime = telemetry and telemetry.triggerTime
        if triggerTime and telemetry and not telemetry.latencySampled and d0 <= 0 then
            local sample = now - triggerTime
            if sample > 0 and sample < 2 then
                activationLatencyEstimate = emaScalar(activationLatencyEstimate, sample, ACTIVATION_LATENCY_ALPHA)
                if activationLatencyEstimate < 0 then
                    activationLatencyEstimate = 0
                end
                telemetry.latencySampled = true
                if GlobalEnv and GlobalEnv.Paws then
                    GlobalEnv.Paws.ActivationLatency = activationLatencyEstimate
                end
            end
        end
    end

    if parryHeld then
        if (not shouldHold) or (parryHeldBallId and parryHeldBallId ~= ballId) then
            releaseParry()
            released = true
        end
    end

    local debugLines = {
        "Auto-Parry F",
        string.format("Ball: %s", ball.Name),
        string.format("d0: %.3f | vr: %.3f", filteredD, filteredVr),
        string.format("ar: %.3f | jr: %.3f", filteredAr, filteredJr),
        string.format("μ: %.3f | σ: %.3f | z: %.2f", mu, sigma, z),
        string.format("μ+zσ: %.3f | μ−zσ: %.3f", muPlus, muMinus),
        string.format("Δ: %.3f | ping: %.3f | act: %.3f", delta, ping, activationLatencyEstimate),
        string.format("TTI: %.3f | TTpress: %.3f | TThold: %.3f", timeToImpact, timeToPressRadius, timeToHoldRadius),
        string.format("Rad: safe %.2f | press %.2f | hold %.2f", safeRadius, pressRadius, holdRadius),
        string.format("Prox: press %s | hold %s", tostring(proximityPress), tostring(proximityHold)),
        string.format("Targeting: %s", tostring(targetingMe)),
        string.format("ParryHeld: %s", tostring(parryHeld)),
        string.format("Immortal: %s", tostring(state.immortalEnabled)),
    }

    if sigmaArOverflow > 0 or sigmaJrOverflow > 0 then
        table.insert(debugLines, string.format("σ infl.: ar %.2f | jr %.2f", sigmaArOverflow, sigmaJrOverflow))
    end

    if fired then
        table.insert(debugLines, "🔥 Press F: proximity/inequality met")
    elseif parryHeld and not released then
        table.insert(debugLines, "Hold: maintaining expanded proximity window")
    else
        table.insert(debugLines, "Hold: conditions not met")
    end

    updateStatusLabel(debugLines)
    setBallVisuals(
        ball,
        computeBallDebug(
            velocity.Magnitude,
            distance,
            safeRadius,
            mu,
            sigma,
            muPlus,
            delta,
            timeToImpact,
            timeToPressRadius,
            timeToHoldRadius,
            pressRadius,
            holdRadius
        )
    )
end


local function ensureLoop()
    if loopConnection then
        return
    end

    loopConnection = RunService.PreRender:Connect(renderLoop)
end

local validators = {
    safeRadius = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    confidenceZ = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    activationLatency = function(value)
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
    ballsFolderTimeout = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    verificationRetryInterval = function(value)
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
    releaseParry()
    telemetryStates = {}
    trackedBall = nil
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

function AutoParry.setImmortalEnabled(enabled)
    local desired = not not enabled

    local changed = state.immortalEnabled ~= desired
    state.immortalEnabled = desired

    syncImmortalContext()
    updateImmortalButton()
    syncGlobalSettings()

    if changed then
        immortalStateChanged:fire(state.immortalEnabled)
    end

    return state.immortalEnabled
end

function AutoParry.toggleImmortal()
    return AutoParry.setImmortalEnabled(not state.immortalEnabled)
end

function AutoParry.isImmortalEnabled()
    return state.immortalEnabled
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

    if key == "activationLatency" then
        activationLatencyEstimate = config.activationLatency or DEFAULT_CONFIG.activationLatency or 0
        if activationLatencyEstimate < 0 then
            activationLatencyEstimate = 0
        end
    elseif key == "confidenceZ" then
        perfectParrySnapshot.z = config.confidenceZ or DEFAULT_CONFIG.confidenceZ or perfectParrySnapshot.z
    end
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
    resetActivationLatency()
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

function AutoParry.onImmortalChanged(callback)
    assert(typeof(callback) == "function", "AutoParry.onImmortalChanged expects a function")
    return immortalStateChanged:connect(callback)
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
    AutoParry.setImmortalEnabled(false)
    if immortalController then
        immortalController:destroy()
    end

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

    clearRemoteState()
    restartPending = false
    initialization.token += 1

    destroyUi()
    safeClearBallVisuals()

    initialization.started = false
    initialization.completed = false
    initialization.destroyed = true
    initialization.error = nil

    state.lastParry = 0
    state.lastSuccess = 0
    state.lastBroadcast = 0
    releaseParry()
    telemetryStates = {}
    trackedBall = nil
    BallsFolder = nil
    watchedBallsFolder = nil
    pendingBallsFolderSearch = false
    ballsFolderStatusSnapshot = nil
    if ballsFolderConnections then
        disconnectConnections(ballsFolderConnections)
        ballsFolderConnections = nil
    end
    LocalPlayer = nil
    Character = nil
    RootPart = nil
    Humanoid = nil
    resetActivationLatency()

    initProgress = { stage = "waiting-player" }
    applyInitStatus(cloneTable(initProgress))

    GlobalEnv.Paws = nil

    initialization.destroyed = false
end

ensureInitialization()
ensureLoop()
syncGlobalSettings()
syncImmortalContext()

return AutoParry
