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
local Verification = Require and Require("src/core/verification.lua") or require(script.Parent.verification)
local ImmortalModule = Require and Require("src/core/immortal.lua") or require(script.Parent.immortal)

    local DEFAULT_CONFIG = {
        -- public API configuration that remains relevant for the PERFECT-PARRY rule
        safeRadius = 10,
        curvatureLeadScale = 0.12,
        curvatureHoldBoost = 0.5,
        confidenceZ = 2.2,
    activationLatency = 0.12,
    targetHighlightName = "Highlight",
    ballsFolderName = "Balls",
    playerTimeout = 10,
    remotesTimeout = 10,
    ballsFolderTimeout = 5,
    verificationRetryInterval = 0,
    oscillationFrequency = 3,
    oscillationDistanceDelta = 0.35,
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
local VR_SIGN_EPSILON = 1e-3
local OSCILLATION_HISTORY_SECONDS = 0.6
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
    lastD0: number?,
    lastD0Delta: number,
    d0DeltaHistory: { { time: number, delta: number } },
    lastVrSign: number?,
    vrSignFlips: { { time: number, sign: number } },
    lastOscillationCheck: number,
    lastOscillationFrequency: number,
    lastOscillationDelta: number,
    lastOscillationCount: number,
    oscillationActive: boolean,
    lastOscillationTrigger: number,
    lastOscillationApplied: number,
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

local function trimHistory(history, cutoff)
    if not history then
        return
    end

    while #history > 0 and history[1].time < cutoff do
        table.remove(history, 1)
    end
end

local function evaluateOscillation(telemetry: TelemetryState?, now: number)
    if not telemetry then
        return false, 0, 0, 0
    end

    local freqThreshold = config.oscillationFrequency or 0
    if freqThreshold <= 0 then
        telemetry.oscillationActive = false
        telemetry.lastOscillationFrequency = 0
        telemetry.lastOscillationCount = 0
        telemetry.lastOscillationDelta = 0
        telemetry.lastOscillationCheck = now
        return false, 0, 0, 0
    end

    local flips = telemetry.vrSignFlips or {}
    local flipCount = #flips
    telemetry.lastOscillationCount = flipCount

    if flipCount < math.max(2, math.ceil(freqThreshold)) then
        telemetry.oscillationActive = false
        telemetry.lastOscillationFrequency = 0
        telemetry.lastOscillationDelta = 0
        telemetry.lastOscillationCheck = now
        return false, 0, flipCount, 0
    end

    local lastIndex = flipCount
    local requiredFlips = math.max(math.ceil(freqThreshold), 2)
    local firstIndex = math.max(1, lastIndex - requiredFlips + 1)
    local earliest = flips[firstIndex].time
    local latest = flips[lastIndex].time
    local span = math.max(latest - earliest, EPSILON)
    local intervals = lastIndex - firstIndex
    local frequency = intervals / span

    local d0Threshold = config.oscillationDistanceDelta or 0
    local d0History = telemetry.d0DeltaHistory or {}
    local windowStart = earliest
    local maxDelta = 0
    local smallDeltaCount = 0
    local considered = 0
    for _, entry in ipairs(d0History) do
        if entry.time >= windowStart then
            considered += 1
            maxDelta = math.max(maxDelta, entry.delta)
            if entry.delta <= d0Threshold then
                smallDeltaCount += 1
            end
        end
    end

    telemetry.lastOscillationFrequency = frequency
    telemetry.lastOscillationDelta = maxDelta
    telemetry.lastOscillationCheck = now

    local distanceGate = d0Threshold <= 0 or considered == 0 or smallDeltaCount == considered
    local triggered = frequency >= freqThreshold and distanceGate
    telemetry.oscillationActive = triggered
    if triggered then
        telemetry.lastOscillationTrigger = now
    end

    return triggered, frequency, flipCount, maxDelta
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
        lastD0 = nil,
        lastD0Delta = 0,
        d0DeltaHistory = {},
        lastVrSign = nil,
        vrSignFlips = {},
        lastOscillationCheck = now,
        lastOscillationFrequency = 0,
        lastOscillationDelta = 0,
        lastOscillationCount = 0,
        oscillationActive = false,
        lastOscillationTrigger = 0,
        lastOscillationApplied = 0,
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
    syncImmortalContext()
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

local function syncImmortalContext()
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

local function enterRespawnWaitState()
    if LocalPlayer then
        setStage("waiting-character", { player = LocalPlayer.Name })
    else
        setStage("waiting-character")
    end

    updateStatusLabel({ "Auto-Parry F", "Status: waiting for respawn" })
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
        AutoParry.destroy()
        GlobalEnv.Paws = nil
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
    clearBallVisuals()
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


local function pressParry(ball: BasePart?, ballId: string?, force: boolean?)
    local forcing = force == true
    if parryHeld then
        local sameBall = parryHeldBallId == ballId
        if sameBall and not forcing then
            return false
        end

        -- release the existing hold before pressing again or for a new ball
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.F, false, game)
        parryHeld = false
        parryHeldBallId = nil
    end

    VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.F, false, game)
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
    clearBallVisuals()
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
    clearBallVisuals()
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
        clearBallVisuals()
        releaseParry()
        return
    end

    ensureBallsFolder(false)
    local folder = BallsFolder
    if not folder then
        updateStatusLabel({ "Auto-Parry F", "Ball: none", "Info: waiting for balls folder" })
        clearBallVisuals()
        releaseParry()
        return
    end

    if not state.enabled then
        releaseParry()
        updateStatusLabel({ "Auto-Parry F", "Status: OFF" })
        clearBallVisuals()
        updateToggleButton()
        return
    end

    local now = os.clock()
    cleanupTelemetry(now)

    local ball = findRealBall(folder)
    if not ball or not ball:IsDescendantOf(Workspace) then
        updateStatusLabel({ "Auto-Parry F", "Ball: none", "Info: waiting for realBall..." })
        clearBallVisuals()
        releaseParry()
        return
    end

    local ballId = getBallIdentifier(ball)
    if not ballId then
        updateStatusLabel({ "Auto-Parry F", "Ball: unknown", "Info: missing identifier" })
        clearBallVisuals()
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
    local vrSign = 0
    if filteredVr > VR_SIGN_EPSILON then
        vrSign = 1
    elseif filteredVr < -VR_SIGN_EPSILON then
        vrSign = -1
    end
    if vrSign ~= 0 then
        local previousSign = telemetry.lastVrSign
        if previousSign and previousSign ~= 0 and previousSign ~= vrSign then
            local flips = telemetry.vrSignFlips
            flips[#flips + 1] = { time = now, sign = vrSign }
        end
        telemetry.lastVrSign = vrSign
    end
    trimHistory(telemetry.vrSignFlips, now - OSCILLATION_HISTORY_SECONDS)

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
    local d0Delta = 0
    if telemetry.lastD0 ~= nil then
        d0Delta = d0 - telemetry.lastD0
    end
    telemetry.lastD0 = d0
    telemetry.lastD0Delta = d0Delta
    local d0History = telemetry.d0DeltaHistory
    d0History[#d0History + 1] = { time = now, delta = math.abs(d0Delta) }
    trimHistory(d0History, now - OSCILLATION_HISTORY_SECONDS)

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

    local responseWindowBase = math.max(delta + PROXIMITY_PRESS_GRACE, PROXIMITY_PRESS_GRACE)
    local responseWindow = responseWindowBase

    local curveLeadTime = 0
    local curveLeadDistance = 0
    local curveHoldDistance = 0
    local curveSeverity = 0
    local curveJerkSeverity = 0

    if approaching then
        local curvatureLeadScale = config.curvatureLeadScale
        if curvatureLeadScale == nil then
            curvatureLeadScale = DEFAULT_CONFIG.curvatureLeadScale
        end

        local curvatureHoldBoost = config.curvatureHoldBoost
        if curvatureHoldBoost == nil then
            curvatureHoldBoost = DEFAULT_CONFIG.curvatureHoldBoost
        end

        if curvatureLeadScale and curvatureLeadScale > 0 then
            local kappaLimit = PHYSICS_LIMITS.curvature or 0
            local dkappaLimit = PHYSICS_LIMITS.curvatureRate or 0
            local arLimit = PHYSICS_LIMITS.radialAcceleration or 0
            local jrLimit = PHYSICS_LIMITS.radialJerk or 0

            local normalizedKappa = 0
            if kappaLimit > 0 then
                normalizedKappa = math.clamp(math.abs(filteredKappa) / kappaLimit, 0, 1)
            end

            local normalizedDkappa = 0
            if dkappaLimit > 0 then
                normalizedDkappa = math.clamp(math.abs(filteredDkappa) / dkappaLimit, 0, 1)
            end

            local normalizedAr = 0
            if arLimit > 0 then
                normalizedAr = math.clamp(math.max(filteredAr, 0) / arLimit, 0, 1)
            end

            local normalizedJerkOverflow = 0
            if jrLimit > 0 then
                local overflow = math.max(jrOverflow or 0, sigmaJrOverflow or 0)
                if overflow > 0 then
                    normalizedJerkOverflow = math.clamp(overflow / jrLimit, 0, 1)
                end
            end

            curveSeverity = math.max(normalizedKappa, normalizedDkappa, normalizedAr)
            if normalizedJerkOverflow > 0 then
                curveJerkSeverity = normalizedJerkOverflow
                curveSeverity = math.clamp(curveSeverity + normalizedJerkOverflow, 0, 1)
            end

            if curveSeverity > 0 then
                curveLeadTime = curvatureLeadScale * curveSeverity
                if curveLeadTime > 0 then
                    responseWindow += curveLeadTime
                    curveLeadDistance = approachSpeed * curveLeadTime
                    if curvatureHoldBoost and curvatureHoldBoost > 0 then
                        curveHoldDistance = curveLeadDistance * curvatureHoldBoost
                    end
                end
            end
        end
    end

    local holdWindow = responseWindow + PROXIMITY_HOLD_GRACE

    local dynamicLeadBase = 0
    if approaching then
        dynamicLeadBase = math.max(approachSpeed * responseWindowBase, 0)
    end
    dynamicLeadBase = math.min(dynamicLeadBase, safeRadius * 0.5)

    local dynamicLead = 0
    if approaching then
        dynamicLead = math.max(approachSpeed * responseWindow, 0)
    end
    dynamicLead = math.min(dynamicLead, safeRadius * 0.5)
    local curveLeadApplied = math.max(dynamicLead - dynamicLeadBase, 0)

    local pressRadius = safeRadius + dynamicLead

    local holdLeadBase = 0
    if approaching then
        holdLeadBase = math.max(approachSpeed * PROXIMITY_HOLD_GRACE, safeRadius * 0.1)
    else
        holdLeadBase = safeRadius * 0.1
    end
    holdLeadBase = math.min(holdLeadBase, safeRadius * 0.5)

    local holdLead = math.min(holdLeadBase + curveHoldDistance, safeRadius * 0.5)
    local curveHoldApplied = math.max(holdLead - holdLeadBase, 0)
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

    local oscillationTriggered = false
    local spamFallback = false
    if telemetry then
        oscillationTriggered = evaluateOscillation(telemetry, now)
        if oscillationTriggered and parryHeld and parryHeldBallId == ballId then
            local lastApplied = telemetry.lastOscillationApplied or 0
            if now - lastApplied > (1 / 120) then
                spamFallback = pressParry(ball, ballId, true)
                if spamFallback then
                    telemetry.lastOscillationApplied = now
                end
            end
        end
    end

    if spamFallback then
        fired = true
    end

    if shouldPress then
        local pressed = pressParry(ball, ballId)
        fired = pressed or fired
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
        string.format(
            "Curve lead: sev %.2f | jerk %.2f | Δt %.3f | target %.3f | pressΔ %.3f | holdΔ %.3f",
            curveSeverity,
            curveJerkSeverity,
            curveLeadTime,
            curveLeadDistance,
            curveLeadApplied,
            curveHoldApplied
        ),
        string.format("Rad: safe %.2f | press %.2f | hold %.2f", safeRadius, pressRadius, holdRadius),
        string.format("Prox: press %s | hold %s", tostring(proximityPress), tostring(proximityHold)),
        string.format(
            "Osc: trig %s | flips %d | freq %.2f | dΔ %.3f | spam %s",
            tostring(telemetry.oscillationActive),
            telemetry.lastOscillationCount or 0,
            telemetry.lastOscillationFrequency or 0,
            telemetry.lastOscillationDelta or 0,
            tostring(spamFallback)
        ),
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
    curvatureLeadScale = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    curvatureHoldBoost = function(value)
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
    oscillationFrequency = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    oscillationDistanceDelta = function(value)
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
    clearBallVisuals()

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

    initialization.destroyed = false
end

ensureInitialization()
ensureLoop()
syncGlobalSettings()
syncImmortalContext()

return AutoParry

]===],
    ['src/core/immortal.lua'] = [===[
-- mikkel32/AutoParry : src/core/immortal.lua
-- Teleport-focused evasion controller that implements the "Immortal" mode
-- described in the provided GodTeleportCore specification. The controller is
-- inert until enabled, after which it drives humanoid root-part teleports
-- using a constant-time MPC planner constrained to the 80-stud ball radius.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Stats = game:FindService("Stats")

local Immortal = {}
Immortal.__index = Immortal

local min = math.min
local max = math.max
local sin = math.sin
local cos = math.cos
local sqrt = math.sqrt
local TAU = 2 * math.pi

local MAX_RANGE_FROM_BALL = 80.0
local HUMANOID_RADIUS = 2.1
local SAFE_MARGIN = 1.1
local Y_HOVER = 6.0

local H_BASE = 1.0
local H_SPEED_GAIN = 0.007
local H_PING_GAIN = 0.8
local H_MIN = 0.7
local H_MAX = 2.0

local N_T_FINE = 8
local N_T_COARSE = 8
local CENTER_FRACTIONS = { 0.0, 0.15, 0.3, 0.5, 0.7, 1.0 }

local RADII_PRIMARY = { 44.0, 56.0, 68.0, 76.0, 80.0 }
local RADII_BACKUP = { 80.0, 72.0, 64.0 }
local EXTRA_LAYERS_Y = { -2.0, 0.0, 2.0 }
local N_DIRS = 44

local PING_MULT = 1.30
local LATENCY_FACTOR = 1.0

local ACCEL_DECAY = 0.92
local ACCEL_FLOOR = 60.0
local ACCEL_CAP = 500.0
local CURV_DECAY = 0.90
local CURV_CAP = 0.60
local CURV_SCALE = 0.72

local IMMEDIATE_DANGER_TTI = 0.075
local IMMEDIATE_DANGER_RAD = 6.0

local TP_CD_SAFE = 0.012
local TP_CD_DANGER = 0.005

local SAFE_MARGIN2_STRONG = 81.0
local SAFE_MARGIN2_MIN = 9.0
local NUDGE_PROB = 0.06
local NUDGE_GAIN2 = 8.0

local CONE_BASE_DEG = 28.0
local CONE_SPEED_GAIN = 0.10

local DRIFT_GUARD = 2.5
local HYSTERESIS_WEIGHT2 = 6.0
local CHAIN_TRIGGER2 = 4.0

local function safeUnit(v)
    local m = v.Magnitude
    if m > 1e-6 then
        return v / m
    end
    return Vector3.zero
end

local function ballRadiusOf(part)
    local s = part.Size
    return 0.5 * math.max(s.X, math.max(s.Y, s.Z))
end

local function clampToRange(currentBallPos, p)
    local d = p - currentBallPos
    local m = d.Magnitude
    if m > MAX_RANGE_FROM_BALL and m > 1e-6 then
        return currentBallPos + d * (MAX_RANGE_FROM_BALL / m)
    end
    return p
end

local function isInstanceDestroyed(instance)
    if not instance then
        return true
    end

    if instance.Parent then
        return false
    end

    local ok, isDescendant = pcall(function()
        return instance:IsDescendantOf(game)
    end)

    return not ok or not isDescendant
end

local function futureBallPos(bPos, bVel, t, ping)
    local look = t + ping * PING_MULT
    if look < 0 then
        look = 0
    end
    return bPos + bVel * look
end

local function getPingSeconds()
    local seconds = 0
    if not Stats then
        return seconds
    end

    local okStat, stat = pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]
    end)

    if not okStat or not stat then
        return seconds
    end

    local okValue, value = pcall(stat.GetValue, stat)
    if okValue and value then
        seconds = (value or 0) / 1000
    end

    return seconds
end

local function createTimeBasis()
    local basis = {}
    if N_T_FINE > 1 then
        for k = 0, N_T_FINE - 1 do
            local f = k / (N_T_FINE - 1)
            table.insert(basis, f * f)
        end
    else
        table.insert(basis, 0.0)
    end

    if N_T_COARSE > 0 then
        local dt = 1 / math.max(N_T_COARSE - 1, 1)
        for j = 0, N_T_COARSE - 1 do
            local f = j * dt
            if f > 0 then
                table.insert(basis, f)
            end
        end
    end

    basis[#basis] = 1.0
    return basis
end

local T_BASIS = createTimeBasis()

local function createDirs(rng)
    local dirs = table.create(N_DIRS)
    local phase = rng:NextNumber(0, TAU)
    for i = 1, N_DIRS do
        local theta = phase + TAU * (i - 1) / N_DIRS
        dirs[i] = Vector3.new(cos(theta), 0, sin(theta))
    end
    return dirs
end

local function isBallValid(ball)
    return ball and ball:IsA("BasePart") and ball:IsDescendantOf(Workspace)
end

function Immortal.new(options)
    local self = setmetatable({}, Immortal)
    self._options = options or {}
    self._enabled = false
    self._player = options and options.player or nil
    self._character = options and options.character or nil
    self._humanoid = options and options.humanoid or nil
    self._rootPart = options and options.rootPart or nil
    self._ballsFolder = options and options.ballsFolder or nil

    self._rng = Random.new()
    self._dirs = createDirs(self._rng)
    self._timeBuffer = table.create(#T_BASIS)
    self._radiusBuffer = table.create(#T_BASIS)
    self._mpcCenters = table.create(#CENTER_FRACTIONS)

    self._highlight = nil
    self._heartbeat = nil

    self._lastBallVel = nil
    self._aWorst = ACCEL_FLOOR
    self._kappaWorst = 0.05
    self._lastTeleport = 0
    self._lastGoodTarget = nil
    self._nextBackupTarget = nil
    self._lastMoveDir = nil

    return self
end

function Immortal:_ensureHighlightParent()
    if not self._highlight then
        return
    end

    if isInstanceDestroyed(self._highlight) then
        self._highlight = nil
        return
    end

    local player = self._player or Players.LocalPlayer
    if not player then
        return
    end

    local playerGui = player:FindFirstChildOfClass("PlayerGui")
    if not playerGui then
        local ok, gui = pcall(function()
            return player:WaitForChild("PlayerGui", 0.1)
        end)
        playerGui = ok and gui or nil
    end

    if playerGui and self._highlight.Parent ~= playerGui then
        local ok = pcall(function()
            self._highlight.Parent = playerGui
        end)
        if not ok then
            self._highlight = nil
        end
    end
end

function Immortal:_ensureHighlight()
    if self._highlight then
        if isInstanceDestroyed(self._highlight) then
            self._highlight = nil
        else
            self:_ensureHighlightParent()
            if self._highlight then
                return self._highlight
            end
        end
    end

    local player = self._player or Players.LocalPlayer
    if not player then
        return nil
    end

    local playerGui = player:FindFirstChildOfClass("PlayerGui")
    if not playerGui then
        local ok, gui = pcall(function()
            return player:WaitForChild("PlayerGui", 0.1)
        end)
        playerGui = ok and gui or nil
    end

    if not playerGui then
        return nil
    end

    local highlight = Instance.new("Highlight")
    highlight.Name = "ImmortalHighlight"
    highlight.FillColor = Color3.fromRGB(0, 255, 0)
    highlight.OutlineColor = Color3.fromRGB(0, 255, 0)
    highlight.FillTransparency = 0.3
    highlight.OutlineTransparency = 0
    highlight.Enabled = false

    local ok = pcall(function()
        highlight.Parent = playerGui
    end)

    if not ok then
        highlight:Destroy()
        return nil
    end

    self._highlight = highlight
    return highlight
end

function Immortal:_setHighlightTarget(ball)
    local highlight = self:_ensureHighlight()
    if not highlight then
        return
    end

    if ball and isBallValid(ball) then
        highlight.Adornee = ball
        highlight.Enabled = true
    else
        highlight.Adornee = nil
        highlight.Enabled = false
    end
end

function Immortal:_clearHighlight()
    if self._highlight then
        self._highlight.Enabled = false
        self._highlight.Adornee = nil
    end
end

function Immortal:_findBall()
    local folder = self._ballsFolder
    if not folder then
        return nil
    end

    local best = nil
    for _, child in ipairs(folder:GetChildren()) do
        if child:IsA("BasePart") then
            if child:GetAttribute("realBall") then
                return child
            elseif not best and child.Name == "Ball" then
                best = child
            end
        end
    end

    return best
end

function Immortal:_updateBounds(vNow, dt)
    local vPrev = self._lastBallVel
    if vPrev and dt > 1e-6 then
        local aVec = (vNow - vPrev) / dt
        local aMag = aVec.Magnitude
        local speed = math.max(vNow.Magnitude, 1e-6)
        local kappaInst = (vNow:Cross(aVec)).Magnitude / (speed * speed * speed)

        self._aWorst = min(ACCEL_CAP, max(ACCEL_FLOOR, ACCEL_DECAY * self._aWorst + (1 - ACCEL_DECAY) * aMag))
        self._kappaWorst = min(CURV_CAP, max(0.0, CURV_DECAY * self._kappaWorst + (1 - CURV_DECAY) * kappaInst))
    end

    self._lastBallVel = vNow
end

function Immortal:_precomputeHorizon(bPos, bVel, bSpeed, bRad, ping, H)
    local CT = self._timeBuffer
    local R2 = self._radiusBuffer
    local MPC = self._mpcCenters

    local latBase = bSpeed * ping * LATENCY_FACTOR * PING_MULT

    for i = 1, #T_BASIS do
        local t = H * T_BASIS[i]
        local c = futureBallPos(bPos, bVel, t, ping)
        CT[i] = c

        local curv = CURV_SCALE * (bSpeed * bSpeed) * self._kappaWorst * t * t
        local R = bRad + (bSpeed * t) + 0.5 * self._aWorst * t * t + latBase + HUMANOID_RADIUS + SAFE_MARGIN + curv
        R2[i] = R * R
    end

    for j = 1, #CENTER_FRACTIONS do
        local f = CENTER_FRACTIONS[j]
        MPC[j] = futureBallPos(bPos, bVel, H * f, ping)
    end
end

function Immortal:_minMargin2(target)
    local CT = self._timeBuffer
    local R2 = self._radiusBuffer
    local minM2 = math.huge

    for i = 1, #CT do
        local c = CT[i]
        local dx = target.X - c.X
        local dy = target.Y - c.Y
        local dz = target.Z - c.Z
        local d2 = dx * dx + dy * dy + dz * dz
        local m2 = d2 - R2[i]
        if m2 < minM2 then
            minM2 = m2
            if minM2 <= 0 then
                return minM2
            end
        end
    end

    return minM2
end

function Immortal:_clearNow2(target)
    local c0 = self._timeBuffer[1]
    if not c0 then
        return math.huge
    end

    local dx = target.X - c0.X
    local dy = target.Y - c0.Y
    local dz = target.Z - c0.Z
    local d2 = dx * dx + dy * dy + dz * dz
    return d2 - self._radiusBuffer[1]
end

function Immortal:_inForbiddenCone(currentBallPos, target, vBall, bSpeed)
    local sp = bSpeed
    if sp < 1e-3 then
        return false
    end

    local bt = target - currentBallPos
    bt = Vector3.new(bt.X, 0, bt.Z)
    local btMag = bt.Magnitude
    if btMag < 1e-3 then
        return true
    end
    local btU = bt / btMag

    local vXZ = Vector3.new(vBall.X, 0, vBall.Z)
    local vm = vXZ.Magnitude
    if vm < 1e-3 then
        return false
    end
    local vU = vXZ / vm

    local coneDeg = CONE_BASE_DEG + CONE_SPEED_GAIN * (sp / 10.0)
    if coneDeg > 75 then
        coneDeg = 75
    end
    local cosTh = math.cos(math.rad(coneDeg))
    local dot = btU:Dot(vU)
    local radiusFrac = btMag / MAX_RANGE_FROM_BALL
    local bias = 0.05 * (1 - radiusFrac)
    return dot > (cosTh - bias)
end

function Immortal:_scoreCandidate(p, currentBallPos)
    if self:_clearNow2(p) <= 0 then
        return -math.huge
    end

    local robustM2 = self:_minMargin2(p)
    local d = currentBallPos - p
    local dm = d.Magnitude
    if dm > 1e-6 then
        local drift = d * (DRIFT_GUARD / dm)
        local m2Drift = self:_minMargin2(p + drift)
        if m2Drift < robustM2 then
            robustM2 = m2Drift
        end
    end

    local lastMoveDir = self._lastMoveDir
    local hrp = self._rootPart
    if lastMoveDir and hrp then
        local step = p - hrp.Position
        step = Vector3.new(step.X, 0, step.Z)
        local sm = step.Magnitude
        if sm > 1e-6 then
            local dir = step / sm
            local dot = dir:Dot(lastMoveDir)
            local penalty = (1 - max(dot, -1.0)) * HYSTERESIS_WEIGHT2
            robustM2 -= penalty
        end
    end

    return robustM2
end

function Immortal:_tryAtRadius(center, radius, currentBallPos, baseUp, vBall, bSpeed)
    local bestTarget = nil
    local bestScore = -math.huge

    local CT = self._timeBuffer
    local dirs = self._dirs

    local vdir = safeUnit((#CT >= 2) and (CT[2] - CT[1]) or Vector3.new(1, 0, 0))
    local hrp = self._rootPart
    local away = safeUnit(hrp and (hrp.Position - center) or Vector3.new(1, 0, 0))
    local tleft = Vector3.new(-vdir.Z, 0, vdir.X)
    local tright = Vector3.new(vdir.Z, 0, -vdir.X)
    local prim = { away, tleft, tright }

    for _, dir in ipairs(prim) do
        if dir.Magnitude > 0.1 then
            for _, yoff in ipairs(EXTRA_LAYERS_Y) do
                local raw = center + dir * radius + Vector3.new(0, baseUp + yoff, 0)
                local p = clampToRange(currentBallPos, raw)
                if not self:_inForbiddenCone(currentBallPos, p, vBall, bSpeed) then
                    local sc = self:_scoreCandidate(p, currentBallPos)
                    if sc > bestScore then
                        bestScore = sc
                        bestTarget = p
                        if sc >= SAFE_MARGIN2_STRONG then
                            return bestTarget, bestScore, true
                        end
                    end
                end
            end
        end
    end

    for i = 1, #dirs do
        local dir = dirs[i]
        for _, yoff in ipairs(EXTRA_LAYERS_Y) do
            local raw = center + dir * radius + Vector3.new(0, baseUp + yoff, 0)
            local p = clampToRange(currentBallPos, raw)
            if not self:_inForbiddenCone(currentBallPos, p, vBall, bSpeed) then
                local sc = self:_scoreCandidate(p, currentBallPos)
                if sc > bestScore then
                    bestScore = sc
                    bestTarget = p
                    if sc >= SAFE_MARGIN2_STRONG then
                        return bestTarget, bestScore, true
                    end
                end
            end
        end
    end

    return bestTarget, bestScore, false
end

function Immortal:_planTargets(currentBallPos, vBall, bSpeed)
    local bestTarget = nil
    local bestScore = -math.huge
    local backup = nil
    local backupScore = -math.huge

    local hrp = self._rootPart

    if self._lastGoodTarget then
        local tgt = clampToRange(currentBallPos, self._lastGoodTarget)
        if not self:_inForbiddenCone(currentBallPos, tgt, vBall, bSpeed) then
            local sc = self:_scoreCandidate(tgt, currentBallPos)
            if sc >= SAFE_MARGIN2_MIN then
                bestTarget = tgt
                bestScore = sc
                backup = tgt
                backupScore = sc
            end
        end
    end

    local MPC = self._mpcCenters
    for ci = 1, #MPC do
        local c = MPC[ci]
        local speedBoostY = min(6.0, (bSpeed / 30.0) * 2.0)
        local up = Y_HOVER + speedBoostY
        for ri = 1, #RADII_PRIMARY do
            local rad = min(RADII_PRIMARY[ri], MAX_RANGE_FROM_BALL)
            local t, sc, ok = self:_tryAtRadius(c, rad, currentBallPos, up, vBall, bSpeed)
            if sc > bestScore then
                bestScore = sc
                bestTarget = t
            end
            if ok or (bestScore >= SAFE_MARGIN2_MIN) then
                local cj = min(#MPC, ci + 2)
                local c2 = MPC[cj]
                for rj = 1, #RADII_BACKUP do
                    local rad2 = min(RADII_BACKUP[rj], MAX_RANGE_FROM_BALL)
                    local tb, sb = self:_tryAtRadius(c2, rad2, currentBallPos, up, vBall, bSpeed)
                    if sb > backupScore then
                        backup = tb
                        backupScore = sb
                    end
                end
                return bestTarget or backup, backup
            end
        end
    end

    if not backup then
        local away = safeUnit(hrp and (hrp.Position - currentBallPos) or Vector3.new(1, 0, 0))
        if away.Magnitude < 1e-6 then
            away = Vector3.new(1, 0, 0)
        end
        backup = clampToRange(currentBallPos, currentBallPos + away * MAX_RANGE_FROM_BALL) + Vector3.new(0, Y_HOVER, 0)
    end

    return bestTarget or backup, backup
end

function Immortal:_doTeleport(target, danger)
    if not self._rootPart or not target then
        return
    end

    local now = os.clock()
    local cd = danger and TP_CD_DANGER or TP_CD_SAFE
    if now - self._lastTeleport < cd then
        return
    end
    self._lastTeleport = now

    local from = self._rootPart.Position
    self._rootPart.CFrame = CFrame.new(target)

    pcall(function()
        self._rootPart.AssemblyLinearVelocity = Vector3.zero
        self._rootPart.AssemblyAngularVelocity = Vector3.zero
    end)

    self._lastGoodTarget = target

    local delta = target - from
    delta = Vector3.new(delta.X, 0, delta.Z)
    local dm = delta.Magnitude
    if dm > 1e-6 then
        self._lastMoveDir = delta / dm
    end
end

function Immortal:_resetPlanner()
    self._nextBackupTarget = nil
    self._lastGoodTarget = nil
    self._lastMoveDir = nil
end

function Immortal:_heartbeatStep(dt)
    if not self._enabled then
        return
    end

    local hrp = self._rootPart
    if not hrp then
        self:_clearHighlight()
        self:_resetPlanner()
        return
    end

    local ball = self:_findBall()
    if not isBallValid(ball) then
        self:_setHighlightTarget(nil)
        self:_resetPlanner()
        return
    end

    self:_setHighlightTarget(ball)

    local bPos = ball.Position
    local bVel = ball.AssemblyLinearVelocity or ball.Velocity
    local bSpeed = bVel.Magnitude
    local ping = getPingSeconds()
    local selfPos = hrp.Position
    local bRad = ballRadiusOf(ball)

    self:_updateBounds(bVel, dt)

    local H = H_BASE + H_SPEED_GAIN * min(bSpeed, 140) + H_PING_GAIN * ping
    H = max(H_MIN, min(H_MAX, H))

    local diff = selfPos - bPos
    if diff.Magnitude > MAX_RANGE_FROM_BALL + 1.0 then
        local clamped = clampToRange(bPos, selfPos)
        self:_doTeleport(Vector3.new(clamped.X, Y_HOVER, clamped.Z), true)
        return
    end

    self:_precomputeHorizon(bPos, bVel, bSpeed, bRad, ping, H)

    do
        local c0 = self._timeBuffer[1]
        local dx = selfPos.X - c0.X
        local dy = selfPos.Y - c0.Y
        local dz = selfPos.Z - c0.Z
        local d2 = dx * dx + dy * dy + dz * dz
        if d2 <= math.max(self._radiusBuffer[1], IMMEDIATE_DANGER_RAD * IMMEDIATE_DANGER_RAD) then
            local away = safeUnit(Vector3.new(dx, dy, dz))
            local desired = bPos + away * MAX_RANGE_FROM_BALL
            self:_doTeleport(Vector3.new(desired.X, Y_HOVER, desired.Z), true)
            return
        end
    end

    do
        local vSelf = hrp.AssemblyLinearVelocity or Vector3.zero
        local r = bPos - selfPos
        local vRel = bVel - vSelf
        local v2 = vRel:Dot(vRel)
        local eta
        local miss
        if v2 < 1e-6 then
            eta = math.huge
            miss = r.Magnitude
        else
            local tStar = -r:Dot(vRel) / v2
            if tStar < 0 then
                tStar = 0
            end
            eta = tStar
            miss = (r + vRel * tStar).Magnitude
        end

        local etaLook = min(eta + ping * PING_MULT, H)
        local touchRad = sqrt(self._radiusBuffer[1])
        if etaLook <= IMMEDIATE_DANGER_TTI or miss <= touchRad then
            local tgt, backup = self:_planTargets(bPos, bVel, bSpeed)
            self._nextBackupTarget = backup
            self:_doTeleport(tgt, true)
            if self:_minMargin2(tgt) < CHAIN_TRIGGER2 and backup then
                self:_doTeleport(backup, true)
            end
            return
        end
    end

    local curM2 = self:_minMargin2(selfPos)
    if curM2 <= 0.0 then
        local tgt, backup = self:_planTargets(bPos, bVel, bSpeed)
        self._nextBackupTarget = backup
        self:_doTeleport(tgt, true)
        if self:_minMargin2(tgt) < CHAIN_TRIGGER2 and backup then
            self:_doTeleport(backup, true)
        end
        return
    end

    if self._nextBackupTarget and curM2 < SAFE_MARGIN2_MIN then
        self:_doTeleport(self._nextBackupTarget, true)
        self._nextBackupTarget = nil
        return
    end

    if curM2 < SAFE_MARGIN2_STRONG and self._rng:NextNumber() < NUDGE_PROB then
        local tgt, backup = self:_planTargets(bPos, bVel, bSpeed)
        if tgt then
            local m2 = self:_minMargin2(tgt)
            if m2 > curM2 + NUDGE_GAIN2 then
                self._nextBackupTarget = backup
                self:_doTeleport(tgt, false)
                return
            end
        end
    end
end

function Immortal:setContext(context)
    context = context or {}
    if context.player ~= nil then
        self._player = context.player
    end
    if context.character ~= nil then
        self._character = context.character
    end
    if context.humanoid ~= nil then
        self._humanoid = context.humanoid
    end
    if context.rootPart ~= nil then
        self._rootPart = context.rootPart
    end
    if context.ballsFolder ~= nil then
        self._ballsFolder = context.ballsFolder
    end

    self:_ensureHighlightParent()

    if not self._character or not self._rootPart then
        self:_clearHighlight()
        self:_resetPlanner()
    end
end

function Immortal:setBallsFolder(folder)
    if self._ballsFolder == folder then
        return
    end
    self._ballsFolder = folder
end

function Immortal:_start()
    if self._heartbeat then
        return
    end

    self:_ensureHighlight()
    self:_resetPlanner()
    self._heartbeat = RunService.Heartbeat:Connect(function(dt)
        self:_heartbeatStep(dt)
    end)
end

function Immortal:_stop()
    if self._heartbeat then
        self._heartbeat:Disconnect()
        self._heartbeat = nil
    end
    self:_clearHighlight()
    self:_resetPlanner()
end

function Immortal:setEnabled(enabled)
    enabled = not not enabled
    if self._enabled == enabled then
        return
    end

    self._enabled = enabled

    if enabled then
        self:_start()
    else
        self:_stop()
    end
end

function Immortal:isEnabled()
    return self._enabled
end

function Immortal:handleHumanoidDied()
    self:_clearHighlight()
    self:_resetPlanner()
end

function Immortal:destroy()
    self:setEnabled(false)
    if self._highlight then
        self._highlight:Destroy()
        self._highlight = nil
    end
end

return Immortal

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

local function announceParryInput(report)
    emit(report, {
        stage = "parry-input",
        target = "virtual-input",
        status = "pending",
        elapsed = 0,
    })

    local info = {
        method = "VirtualInputManager:SendKeyEvent",
        className = "VirtualInputManager",
        kind = "virtual-input",
        remoteName = "VirtualInputManager",
        remoteChildName = "SendKeyEvent",
        remoteContainerName = "VirtualInputManager",
        variant = "F-key",
        keyCode = "F",
    }

    emit(report, {
        stage = "parry-input",
        target = "virtual-input",
        status = "ok",
        elapsed = 0,
        remoteName = info.remoteName,
        remoteChildName = info.remoteChildName,
        remoteVariant = info.variant,
        remoteMethod = info.method,
        className = info.className,
        keyCode = info.keyCode,
        message = "AutoParry will press the F key locally via VirtualInputManager.",
    })

    return info
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

    local playerTimeout = config.playerTimeout or options.playerTimeout or 10
    local remotesTimeout = config.remotesTimeout or options.remotesTimeout or 10
    local ballsFolderTimeout = config.ballsFolderTimeout or options.ballsFolderTimeout or 5

    local player = ensurePlayer(report, playerTimeout, retryInterval)
    local remotes = ensureRemotesFolder(report, remotesTimeout, retryInterval)
    local inputInfo = announceParryInput(report)

    local successRemotes = locateSuccessRemotes(remotes)

    emit(report, {
        stage = "verifying-success-remotes",
        status = "observed",
        remotes = summarizeSuccessRemotes(successRemotes),
    })

    inputInfo = inputInfo or {}
    inputInfo.successRemotes = successRemotes

    local ballsStatus, ballsFolder = verifyBallsFolder(report, config.ballsFolderName or "Balls", ballsFolderTimeout, retryInterval)

    return {
        player = player,
        remotesFolder = remotes,
        parryInputInfo = inputInfo,
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

local HttpService = game:GetService("HttpService")

local VERSION = "1.1.0"
local UI_MODULE_PATH = "src/ui/init.lua"
local PARRY_MODULE_PATH = "src/core/autoparry.lua"
local ERROR_DOCS_URL = "https://github.com/mikkel32/AutoParry#troubleshooting"
local REASON_STAGE_MAP = {
    ["local-player"] = "player",
    ["player"] = "player",
    ["waiting-player"] = "player",
    ["remotes"] = "remotes",
    ["waiting-remotes"] = "remotes",
    ["remotes-folder"] = "remotes",
    ["remote"] = "remotes",
    ["parry-remote"] = "remotes",
    ["parry-input"] = "remotes",
    ["virtual-input"] = "remotes",
    ["success"] = "success",
    ["success-events"] = "success",
    ["balls"] = "balls",
    ["balls-folder"] = "balls",
}

local function formatSeconds(seconds)
    if not seconds or seconds <= 0 then
        return nil
    end
    if seconds < 1 then
        return string.format("%.2f s", seconds)
    end
    return string.format("%.1f s", seconds)
end

local function resolveStageId(value)
    if value == nil then
        return nil
    end
    local text = string.lower(tostring(value))
    return REASON_STAGE_MAP[text]
end

local function buildErrorDetail(state)
    local errorState = state.error or {}
    local detail = {
        kind = "error",
        title = errorState.title or errorState.message or "AutoParry encountered an error",
        summary = errorState.message or "AutoParry failed to start.",
        message = errorState.message or "AutoParry failed to start.",
        reason = errorState.reason,
        docsLink = errorState.docsLink or ERROR_DOCS_URL,
        entries = {},
        tips = {},
        timeline = {},
        meta = {},
    }

    local copyLines = {}
    local function pushCopy(line)
        if typeof(line) == "string" and line ~= "" then
            table.insert(copyLines, line)
        end
    end

    pushCopy(detail.title)
    if detail.summary and detail.summary ~= detail.title then
        pushCopy(detail.summary)
    end

    local function addEntry(label, value, kind)
        if value == nil then
            return
        end
        if typeof(value) ~= "string" then
            value = tostring(value)
        end
        if value == "" then
            return
        end
        table.insert(detail.entries, { label = label, value = value, kind = kind })
        pushCopy(string.format("%s: %s", label, value))
    end

    local function addTips(tips)
        if tips == nil then
            return
        end
        if typeof(tips) == "table" then
            for _, tip in ipairs(tips) do
                if tip ~= nil then
                    local text = typeof(tip) == "string" and tip or tostring(tip)
                    table.insert(detail.tips, text)
                    pushCopy("Tip: " .. text)
                end
            end
        else
            local text = typeof(tips) == "string" and tips or tostring(tips)
            table.insert(detail.tips, text)
            pushCopy("Tip: " .. text)
        end
    end

    local payload = errorState.payload
    if typeof(payload) == "table" then
        if detail.reason == nil and payload.reason ~= nil then
            detail.reason = payload.reason
        end
    end

    if errorState.kind == "loader" then
        detail.title = errorState.message or "Module download failed"
        detail.summary = errorState.message or "AutoParry could not download required modules."
        detail.message = detail.summary

        local last = state.loader and state.loader.last
        local path = payload and payload.path or (last and last.path)
        addEntry("Module", path, "path")

        local errMsg = payload and (payload.error or payload.message)
        addEntry("Loader error", errMsg)

        if payload and (payload.stackTrace or payload.stack) then
            local stack = payload.stackTrace or payload.stack
            detail.logs = detail.logs or {}
            table.insert(detail.logs, { label = "Stack trace", value = stack, kind = "stack" })
            pushCopy("Stack trace:\n" .. stack)
        end

        addTips(payload and payload.remediation)

        if #detail.tips == 0 then
            addTips({
                "Check your network connection and retry the AutoParry download.",
                "Ensure your executor allows HttpGet/HttpPost for AutoParry modules.",
            })
        end

        local stage = resolveStageId("remotes") or "remotes"
        table.insert(detail.timeline, {
            id = stage,
            status = "failed",
            message = detail.summary,
            tooltip = path and string.format("Failed to fetch %s", path) or detail.summary,
        })
        detail.meta[stage] = "Download failure"
        detail.failingStage = stage
        detail.timelineStatus = "failed"
    elseif errorState.kind == "parry" then
        detail.title = errorState.message or "AutoParry verification failed"
        detail.summary = errorState.message or "AutoParry failed during verification."
        detail.message = detail.summary

        if payload and payload.stage then
            addEntry("Verification stage", payload.stage)
        end
        if payload and payload.step then
            addEntry("Step", payload.step)
        end
        if payload and payload.target then
            addEntry("Target", payload.target)
        end
        if payload and payload.remoteName then
            addEntry("Remote", payload.remoteName)
        end
        if payload and payload.remoteVariant then
            addEntry("Variant", payload.remoteVariant)
        end
        if payload and payload.remoteClass then
            addEntry("Remote class", payload.remoteClass)
        end
        if payload and payload.elapsed then
            addEntry("Elapsed", formatSeconds(payload.elapsed))
        end

        local stage = resolveStageId(detail.reason)
            or (payload and (resolveStageId(payload.step) or resolveStageId(payload.stage)))
            or "success"
        detail.failingStage = stage

        local status = "failed"
        local reasonLower = detail.reason and string.lower(tostring(detail.reason)) or nil
        if reasonLower == "balls" or reasonLower == "balls-folder" or (payload and payload.step == "balls") then
            status = "warning"
        end

        table.insert(detail.timeline, {
            id = stage,
            status = status,
            message = detail.summary,
            tooltip = detail.summary,
        })
        detail.timelineStatus = status
        detail.meta[stage] = payload and (payload.reason or payload.step or payload.stage) or detail.reason

        if payload and payload.stackTrace then
            detail.logs = detail.logs or {}
            table.insert(detail.logs, { label = "Stack trace", value = payload.stackTrace, kind = "stack" })
            pushCopy("Stack trace:\n" .. payload.stackTrace)
        end

        if payload and payload.tip then
            addTips(payload.tip)
        end

        if reasonLower == "local-player" then
            addTips("Wait for your avatar to spawn in before retrying AutoParry.")
        elseif reasonLower == "remotes-folder" or reasonLower == "parry-remote" or reasonLower == "remote" or reasonLower == "parry-input" then
            addTips("Make sure Roblox has focus so AutoParry can press the F key with VirtualInputManager.")
        elseif reasonLower == "balls" or reasonLower == "balls-folder" then
            addTips("Ensure a match is active with balls in play before enabling AutoParry.")
        end
    end

    if detail.reason then
        addEntry("Reason", detail.reason)
    end

    if payload and typeof(payload) == "table" then
        local ok, encoded = pcall(HttpService.JSONEncode, HttpService, payload)
        if ok then
            detail.payloadText = encoded
            pushCopy("Payload: " .. encoded)
        end
    elseif payload ~= nil then
        addEntry("Payload", tostring(payload))
    end

    if #detail.tips == 0 and errorState.kind ~= "loader" then
        addTips("Retry the bootstrap from the overlay controls when the issue is resolved.")
    end

    detail.copyText = table.concat(copyLines, "\n")

    return detail
end

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
        local detail = buildErrorDetail(state)
        if typeof(state.error) == "table" then
            state.error.detail = detail
        end
        return {
            text = detail.summary or detail.message or "AutoParry failed to start.",
            detail = detail,
        }
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
                return {
                    text = ("Downloading %s (%d/%d)"):format(lastPath, finished + failed, total),
                }
            else
                return {
                    text = ("Downloading %s…"):format(lastPath),
                }
            end
        end

        if total > 0 then
            return {
                text = ("Downloading AutoParry modules (%d/%d)"):format(finished + failed, total),
            }
        end

        return { text = "Preparing AutoParry download…" }
    end

    local parry = state.parry or {}
    local stage = parry.stage

    if stage == "ready" then
        return { text = "AutoParry ready!" }
    elseif stage == "waiting-remotes" then
        if parry.target == "remote" then
            return { text = "Preparing F-key parry input…" }
        end
        return { text = "Waiting for Blade Ball remotes…" }
    elseif stage == "parry-input" then
        return { text = "Arming F-key parry input…" }
    elseif stage == "waiting-player" then
        return { text = "Waiting for your player…" }
    elseif stage == "timeout" then
        return { text = "AutoParry initialization timed out." }
    end

    return { text = "Preparing AutoParry…" }
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
    elseif parryStage == "parry-input" then
        parryAlpha = 0.85
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

    local DIAGNOSTIC_STAGE_ORDER = { "player", "remotes", "success", "balls" }
    local MAX_DIAGNOSTIC_EVENTS = 120
    local DIAGNOSTIC_STAGE_INFO = {
        player = {
            id = "player",
            title = "Player readiness",
            description = "Ensure your avatar is loaded.",
        },
        remotes = {
            id = "remotes",
            title = "Game remotes",
            description = "Connect to Blade Ball remotes.",
        },
        success = {
            id = "success",
            title = "Success feedback",
            description = "Listen for parry success events.",
        },
        balls = {
            id = "balls",
            title = "Ball telemetry",
            description = "Track balls for prediction.",
        },
    }

    local diagnosticsState = {
        stages = {},
        events = {},
        errors = {},
        eventSequence = 0,
        startClock = os.clock(),
        lastParrySignature = nil,
        panelSynced = false,
    }

    local controller = nil

    local function diagnosticsDeepCopy(value)
        if Util and Util.deepCopy then
            return Util.deepCopy(value)
        end
        if typeof(value) ~= "table" then
            return value
        end
        local copy = {}
        for key, item in pairs(value) do
            copy[key] = diagnosticsDeepCopy(item)
        end
        return copy
    end

    local function resetDiagnosticsState()
        diagnosticsState.stages = {}
        for _, id in ipairs(DIAGNOSTIC_STAGE_ORDER) do
            local info = DIAGNOSTIC_STAGE_INFO[id]
            diagnosticsState.stages[id] = {
                id = id,
                title = info.title,
                description = info.description,
                status = "pending",
                message = info.description,
                detail = nil,
            }
        end
        diagnosticsState.events = {}
        diagnosticsState.errors = {}
        diagnosticsState.eventSequence = 0
        diagnosticsState.startClock = os.clock()
        diagnosticsState.lastParrySignature = nil
        diagnosticsState.panelSynced = false
    end

    resetDiagnosticsState()

    local function diagnosticsStagesToArray()
        local list = {}
        for _, id in ipairs(DIAGNOSTIC_STAGE_ORDER) do
            local stage = diagnosticsState.stages[id]
            if stage then
                table.insert(list, {
                    id = stage.id or id,
                    title = stage.title or (DIAGNOSTIC_STAGE_INFO[id] and DIAGNOSTIC_STAGE_INFO[id].title) or id,
                    description = stage.description or (DIAGNOSTIC_STAGE_INFO[id] and DIAGNOSTIC_STAGE_INFO[id].description) or "",
                    status = stage.status or "pending",
                    message = stage.message or stage.description or "",
                    detail = stage.detail,
                })
            end
        end
        return list
    end

    local function broadcastDiagnosticsStages()
        if controller and controller.setDiagnosticsStages then
            controller:setDiagnosticsStages(diagnosticsStagesToArray())
        end
    end

    local function updateDiagnosticsStage(id, props)
        props = props or {}
        local info = DIAGNOSTIC_STAGE_INFO[id]
        local stage = diagnosticsState.stages[id]
        if not stage then
            stage = {
                id = id,
                title = info and info.title or id,
                description = info and info.description or "",
                status = "pending",
                message = info and info.description or "",
                detail = nil,
            }
            diagnosticsState.stages[id] = stage
        end

        local changed = false

        if props.status and stage.status ~= props.status then
            stage.status = props.status
            changed = true
        end

        if props.message ~= nil then
            local message = props.message
            if message == false then
                message = stage.description
            end
            if stage.message ~= message then
                stage.message = message
                changed = true
            end
        end

        if props.detail ~= nil or props.clearDetail then
            local detail = props.detail
            if props.clearDetail or detail == false or detail == "" then
                detail = nil
            end
            if stage.detail ~= detail then
                stage.detail = detail
                changed = true
            end
        end

        return changed
    end

    local function formatInitElapsed(seconds)
        if typeof(seconds) ~= "number" then
            return nil
        end
        if seconds < 0 then
            seconds = 0
        end
        if seconds >= 120 then
            return string.format("%d s", math.floor(seconds + 0.5))
        elseif seconds >= 10 then
            return string.format("%.1f s", seconds)
        end
        return string.format("%.2f s", seconds)
    end

    local function applyParrySnapshotToDiagnostics(snapshot)
        if typeof(snapshot) ~= "table" then
            return
        end

        local stage = snapshot.stage
        local status = snapshot.status
        local target = snapshot.target or snapshot.step
        local changed = false

        local function mark(id, state, message, detail, clearDetail)
            if not id then
                return
            end
            local props = { status = state }
            if message ~= nil then
                props.message = message
            end
            if detail ~= nil then
                props.detail = detail
            end
            if clearDetail then
                props.clearDetail = true
            end
            if updateDiagnosticsStage(id, props) then
                changed = true
            end
        end

        if stage == "ready" then
            mark("player", "ok", "Player locked", nil, true)
            local remoteMessage = string.format("%s (%s)", snapshot.remoteName or "Parry remote", snapshot.remoteVariant or "detected")
            mark("remotes", "ok", remoteMessage, nil, true)
            if snapshot.successEvents then
                mark("success", "ok", "Success listeners wired", nil, true)
            else
                mark("success", "ok", "Success listeners active", nil, true)
            end
            if snapshot.successEvents and snapshot.successEvents.Balls then
                mark("balls", "ok", "Ball telemetry streaming", nil, true)
            else
                mark("balls", "ok", "Ready for match", nil, true)
            end
        elseif stage == "timeout" then
            local reason = snapshot.reason or target
            if reason == "local-player" or target == "local-player" then
                mark("player", "failed", "Timed out waiting for player", nil, true)
            elseif reason == "remotes-folder" or target == "folder" then
                mark("remotes", "failed", "Remotes folder missing", nil, true)
            elseif reason == "parry-remote" or reason == "parry-input" or target == "remote" then
                mark("remotes", "failed", "F-key input unavailable", nil, true)
            elseif reason == "balls-folder" then
                mark("balls", "warning", "Balls folder not found", "AutoParry will continue without ball telemetry if the folder is missing.")
            else
                mark("success", "warning", snapshot.message or "Verification timeout", snapshot.message)
            end
        elseif stage == "error" then
            if target == "remote" then
                mark("remotes", "failed", snapshot.message or "Virtual input unavailable", nil, true)
            elseif target == "folder" then
                mark("remotes", "failed", snapshot.message or "Remotes folder removed", nil, true)
            else
                mark("success", "warning", snapshot.message or "Verification error", snapshot.message)
            end
        elseif stage == "waiting-player" or stage == "waiting-character" then
            if status == "ok" then
                local elapsed = formatInitElapsed(snapshot.elapsed)
                local message = elapsed and string.format("Player ready (%s)", elapsed) or "Player ready"
                mark("player", "ok", message, nil, true)
            elseif status == "waiting" or status == "pending" then
                mark("player", "active", "Waiting for player…", nil, true)
            end
        elseif stage == "waiting-remotes" then
            if target == "folder" then
                if status == "ok" then
                    mark("remotes", "active", "Remotes folder located", nil, true)
                else
                    mark("remotes", "active", "Searching for Remotes folder…", nil, true)
                end
            elseif target == "remote" then
                if status == "ok" then
                    local name = snapshot.remoteName or "Virtual input"
                    local variant = snapshot.remoteVariant or "F key"
                    mark("remotes", "ok", string.format("%s (%s)", name, variant), nil, true)
                else
                    mark("remotes", "active", "Preparing F-key parry input…", nil, true)
                end
            end
        elseif stage == "parry-input" then
            if status == "ok" then
                local name = snapshot.remoteName or "Virtual input"
                local variant = snapshot.remoteVariant or "F key"
                mark("remotes", "ok", string.format("%s (%s)", name, variant), nil, true)
            else
                mark("remotes", "active", "Arming F-key parry input…", nil, true)
            end
        elseif stage == "verifying-success-remotes" then
            if snapshot.remotes or status == "ok" then
                mark("success", "ok", "Success listeners bound", nil, true)
            else
                mark("success", "active", "Hooking success events…", nil, true)
            end
        elseif stage == "verifying-balls" then
            if status == "ok" then
                mark("balls", "ok", "Ball telemetry online", nil, true)
            elseif status == "warning" then
                mark("balls", "warning", "Ball folder timeout", "AutoParry will continue without ball telemetry if the folder is missing.")
            elseif status == "waiting" or status == "pending" then
                mark("balls", "active", "Searching for balls…", nil, true)
            end
        elseif stage == "restarting" then
            local reason = snapshot.reason or target
            local detail = reason and string.format("Reason: %s", reason) or nil
            mark("remotes", "active", "Reinitialising verification…", detail, reason == nil)
        end

        if changed then
            broadcastDiagnosticsStages()
        end
    end

    local function describeParryProgress(progress)
        local stage = progress.stage
        local status = progress.status
        local target = progress.target or progress.step
        local reason = progress.reason
        local message
        local severity = "info"
        local detail = progress.message

        if stage == "ready" then
            severity = "success"
            message = "Verification complete"
        elseif stage == "waiting-player" or stage == "waiting-character" then
            if status == "ok" then
                severity = "success"
                local elapsed = formatInitElapsed(progress.elapsed)
                message = elapsed and string.format("Player ready (%s)", elapsed) or "Player ready"
            else
                message = "Waiting for player"
            end
        elseif stage == "waiting-remotes" then
            if target == "folder" then
                if status == "ok" then
                    severity = "success"
                    message = "Remotes folder located"
                else
                    message = "Searching for remotes folder"
                end
            else
                if status == "ok" then
                    severity = "success"
                    message = string.format("Virtual input ready (%s)", progress.remoteVariant or "F key")
                else
                    message = "Preparing F-key parry input"
                end
            end
        elseif stage == "parry-input" then
            if status == "ok" then
                severity = "success"
                message = string.format("Virtual input ready (%s)", progress.remoteVariant or "F key")
            else
                message = "Arming F-key parry input"
            end
        elseif stage == "verifying-success-remotes" then
            if progress.remotes or status == "ok" then
                severity = "success"
                message = "Success listeners bound"
            else
                message = "Hooking success events"
            end
        elseif stage == "verifying-balls" then
            if status == "ok" then
                severity = "success"
                message = "Ball telemetry verified"
            elseif status == "warning" then
                severity = "warning"
                message = "Ball folder timeout"
                detail = "AutoParry will continue without ball telemetry if the folder is missing."
            else
                message = "Searching for balls"
            end
        elseif stage == "timeout" then
            severity = "error"
            local reasonText = reason or target
            if reasonText == "local-player" then
                message = "Timed out waiting for player"
            elseif reasonText == "remotes-folder" then
                message = "Timed out waiting for remotes folder"
            elseif reasonText == "parry-remote" or reasonText == "remote" or reasonText == "parry-input" then
                message = "Timed out preparing F-key parry input"
            elseif reasonText == "balls-folder" then
                message = "Ball folder timed out"
            else
                message = progress.message or "AutoParry initialization timed out"
            end
        elseif stage == "error" then
            severity = "error"
            message = progress.message or "Verification error"
        elseif stage == "restarting" then
            severity = "warning"
            if reason then
                message = string.format("Restarting verification (%s)", reason)
            else
                message = "Restarting verification"
            end
            detail = progress.message or detail
        end

        if not message then
            message = stage or "Verification update"
        end

        return message, severity, detail
    end

    local function recordDiagnosticEvent(event)
        if typeof(event) ~= "table" then
            return
        end

        local copy = diagnosticsDeepCopy(event)
        diagnosticsState.eventSequence += 1
        copy.sequence = diagnosticsState.eventSequence
        copy.timestamp = copy.timestamp or os.clock()

        if #diagnosticsState.events >= MAX_DIAGNOSTIC_EVENTS then
            table.remove(diagnosticsState.events, 1)
        end
        table.insert(diagnosticsState.events, copy)

        if controller and controller.pushDiagnosticsEvent then
            controller:pushDiagnosticsEvent(copy)
        end
    end

    local function recordLoaderEvent(kind, payload)
        local path = payload and payload.path
        local message
        local severity = "info"
        local detail

        if kind == "started" then
            message = path and ("Downloading %s"):format(path) or "Downloading AutoParry modules"
        elseif kind == "completed" then
            severity = "success"
            message = path and ("Downloaded %s"):format(path) or "Module downloaded"
        elseif kind == "failed" then
            severity = "error"
            message = path and ("Failed to download %s"):format(path) or "Module download failed"
            if payload and payload.error then
                detail = tostring(payload.error)
            end
        elseif kind == "all-complete" then
            severity = "success"
            message = "AutoParry download complete"
        else
            message = kind
        end

        recordDiagnosticEvent({
            kind = "loader",
            action = kind,
            severity = severity,
            message = message,
            detail = detail,
            payload = payload and diagnosticsDeepCopy(payload) or nil,
            timestamp = os.clock(),
        })
    end

    local function recordParrySnapshot(progress)
        if typeof(progress) ~= "table" then
            return
        end

        local stage = progress.stage or "unknown"
        local status = progress.status or ""
        local target = progress.target or progress.step or ""
        local reason = progress.reason or ""
        local signature = string.format("%s|%s|%s|%s", stage, status, target, progress.message or reason or "")

        if diagnosticsState.lastParrySignature == signature then
            return
        end

        diagnosticsState.lastParrySignature = signature

        local message, severity, detail = describeParryProgress(progress)

        recordDiagnosticEvent({
            kind = "parry",
            stage = stage,
            status = progress.status,
            target = target,
            severity = severity or "info",
            message = message or stage,
            detail = detail or progress.message,
            payload = diagnosticsDeepCopy(progress),
            timestamp = os.clock(),
        })
    end

    local function upsertDiagnosticsError(entry)
        if typeof(entry) ~= "table" then
            return
        end

        local id = entry.id or entry.kind or "error"
        local stored = diagnosticsState.errors[id]
        if not stored then
            stored = {
                id = id,
                kind = entry.kind,
                severity = entry.severity or "error",
                message = entry.message or "AutoParry error",
                payload = entry.payload and diagnosticsDeepCopy(entry.payload) or nil,
                active = entry.active ~= false,
            }
            diagnosticsState.errors[id] = stored
        else
            stored.kind = entry.kind or stored.kind
            stored.severity = entry.severity or stored.severity or "error"
            if entry.message ~= nil then
                stored.message = entry.message
            end
            if entry.payload ~= nil then
                stored.payload = entry.payload and diagnosticsDeepCopy(entry.payload) or nil
            end
            if entry.active ~= nil then
                stored.active = entry.active ~= false
            end
        end

        if controller and controller.showDiagnosticsError then
            controller:showDiagnosticsError(diagnosticsDeepCopy(stored))
        end
    end

    local function resolveDiagnosticsError(kind, message)
        if not kind then
            return
        end

        local stored = diagnosticsState.errors[kind]
        if not stored then
            return
        end

        if message then
            stored.message = message
        end

        if stored.active then
            stored.active = false
        end

        if controller and controller.showDiagnosticsError then
            controller:showDiagnosticsError(diagnosticsDeepCopy(stored))
        end
    end

    local function applyDiagnosticsError(errorState)
        if not errorState then
            return
        end

        local id = errorState.id or errorState.kind or "error"
        upsertDiagnosticsError({
            id = id,
            kind = errorState.kind,
            severity = errorState.severity or "error",
            message = errorState.message or "AutoParry error",
            payload = errorState.payload,
            active = errorState.active ~= false,
        })
    end

    local function syncDiagnosticsToController()
        if not controller then
            return
        end

        controller:resetDiagnostics()
        controller:setDiagnosticsStages(diagnosticsStagesToArray())
        for _, event in ipairs(diagnosticsState.events) do
            controller:pushDiagnosticsEvent(event)
        end
        for _, errorEntry in pairs(diagnosticsState.errors) do
            controller:showDiagnosticsError(diagnosticsDeepCopy(errorEntry))
        end
        diagnosticsState.panelSynced = true
    end

    local loaderComplete = not overlayEnabled
    local parryReady = not overlayEnabled
    local bootstrapCancelled = false
    local finalizeTriggered = false
    local retryInFlight = false

    local loaderConnections = {}
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

        local okStatus, statusResult = pcall(statusFormatter, overlayState, overlayOpts, opts)
        if okStatus then
            local statusPayload
            if typeof(statusResult) == "table" then
                statusPayload = statusResult
            elseif typeof(statusResult) == "string" then
                statusPayload = { text = statusResult }
            elseif statusResult ~= nil then
                statusPayload = { text = tostring(statusResult) }
            else
                statusPayload = { text = "" }
            end

            overlay:setStatus(statusPayload, { force = overlayState.error ~= nil })
            if overlay.setErrorDetails then
                overlay:setErrorDetails(statusPayload.detail)
            end
            if overlayState.error and statusPayload.detail then
                overlayState.error.detail = statusPayload.detail
                applyDiagnosticsError(overlayState.error)
            end
        else
            warn("AutoParry loading overlay status formatter error:", statusResult)
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

        resetDiagnosticsState()
        if controller then
            syncDiagnosticsToController()
        end

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
            recordLoaderEvent("started", payload)
            updateOverlay()
        end)
        table.insert(loaderConnections, startedConn)

        local completedConn = loaderSignals.onFetchCompleted:Connect(function(payload)
            overlayState.loader.last = payload
            refreshLoaderCounters()
            refreshLoaderCompletion()
            recordLoaderEvent("completed", payload)
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
            recordLoaderEvent("failed", payload)
            refreshLoaderCompletion()
            updateOverlay()
            applyDiagnosticsError(overlayState.error)
        end)
        table.insert(loaderConnections, failedConn)

        local completeConn = loaderSignals.onAllComplete:Connect(function()
            refreshLoaderCounters()
            refreshLoaderCompletion()
            recordLoaderEvent("all-complete")
            resolveDiagnosticsError("loader")
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
        applyParrySnapshotToDiagnostics(overlayState.parry)
        recordParrySnapshot(progress or overlayState.parry)
        local stage = progress and progress.stage

        if stage == "ready" then
            parryReady = true
            if overlayState.error and overlayState.error.kind == "parry" then
                overlayState.error = nil
            end
            resolveDiagnosticsError("parry", "AutoParry ready")
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
            resolveDiagnosticsError("parry")
        end

        if overlayState.error then
            applyDiagnosticsError(overlayState.error)
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
                syncDiagnosticsToController()
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

function Util.deepCopy(value, seen)
    if typeof(value) ~= "table" then
        return value
    end

    seen = seen or {}
    local existing = seen[value]
    if existing ~= nil then
        return existing
    end

    local copy = {}
    seen[value] = copy

    for key, val in pairs(value) do
        local copiedKey = Util.deepCopy(key, seen)
        local copiedValue = Util.deepCopy(val, seen)
        copy[copiedKey] = copiedValue
    end

    local metatable = getmetatable(value)
    if metatable ~= nil then
        if typeof(metatable) == "table" then
            setmetatable(copy, Util.deepCopy(metatable, seen))
        else
            setmetatable(copy, metatable)
        end
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
    ['src/ui/diagnostics_panel.lua'] = [===[
-- mikkel32/AutoParry : src/ui/diagnostics_panel.lua
-- Diagnostics side panel that visualises verification stages, loader/parry
-- event history, and surfaced errors. Built to remain available after the
-- onboarding overlay fades so players can keep digging into what happened.

local TweenService = game:GetService("TweenService")

local Require = rawget(_G, "ARequire")
local Util = Require and Require("src/shared/util.lua")

local DiagnosticsPanel = {}
DiagnosticsPanel.__index = DiagnosticsPanel

local DEFAULT_THEME = {
    backgroundColor = Color3.fromRGB(20, 24, 32),
    backgroundTransparency = 0.08,
    strokeColor = Color3.fromRGB(72, 108, 172),
    strokeTransparency = 0.65,
    sectionCorner = UDim.new(0, 14),
    sectionPadding = 16,
    sectionSpacing = 12,
    headerFont = Enum.Font.GothamSemibold,
    headerTextSize = 18,
    headerTextColor = Color3.fromRGB(210, 224, 250),
    headerInactiveColor = Color3.fromRGB(140, 156, 190),
    headerIcon = "rbxassetid://6031090990",
    bodyPadding = 14,
    statusFonts = {
        title = Enum.Font.GothamSemibold,
        message = Enum.Font.Gotham,
        detail = Enum.Font.Gotham,
    },
    statusTextSizes = {
        title = 16,
        message = 14,
        detail = 13,
    },
    stageBackground = Color3.fromRGB(26, 30, 40),
    stageTransparency = 0.05,
    stageStrokeColor = Color3.fromRGB(82, 132, 200),
    stageStrokeTransparency = 0.52,
    stageCorner = UDim.new(0, 12),
    stageSpacing = 10,
    statusColors = {
        pending = Color3.fromRGB(132, 148, 188),
        active = Color3.fromRGB(112, 198, 255),
        ok = Color3.fromRGB(118, 228, 182),
        warning = Color3.fromRGB(255, 198, 110),
        failed = Color3.fromRGB(248, 110, 128),
    },
    statusTextColor = Color3.fromRGB(198, 212, 240),
    statusDetailColor = Color3.fromRGB(160, 176, 210),
    statusDetailTransparency = 0.2,
    iconAssets = {
        pending = "rbxassetid://6031071050",
        active = "rbxassetid://6031075929",
        ok = "rbxassetid://6031068421",
        warning = "rbxassetid://6031071051",
        failed = "rbxassetid://6031094678",
    },
    filterButton = {
        font = Enum.Font.Gotham,
        textSize = 14,
        activeColor = Color3.fromRGB(82, 156, 255),
        inactiveColor = Color3.fromRGB(48, 60, 86),
        activeText = Color3.fromRGB(12, 16, 26),
        inactiveText = Color3.fromRGB(198, 212, 240),
        corner = UDim.new(0, 10),
        padding = Vector2.new(12, 6),
    },
    eventBackground = Color3.fromRGB(24, 28, 36),
    eventTransparency = 0.04,
    eventStrokeColor = Color3.fromRGB(70, 106, 170),
    eventStrokeTransparency = 0.65,
    eventCorner = UDim.new(0, 10),
    eventMessageFont = Enum.Font.Gotham,
    eventMessageSize = 14,
    eventDetailSize = 13,
    eventTagFont = Enum.Font.GothamSemibold,
    eventTagSize = 13,
    severityColors = {
        info = Color3.fromRGB(120, 170, 240),
        success = Color3.fromRGB(118, 228, 182),
        warning = Color3.fromRGB(255, 198, 110),
        error = Color3.fromRGB(248, 110, 128),
    },
    badge = {
        background = Color3.fromRGB(48, 56, 76),
        backgroundResolved = Color3.fromRGB(36, 42, 58),
        textActive = Color3.fromRGB(232, 242, 255),
        textResolved = Color3.fromRGB(160, 176, 210),
        corner = UDim.new(0, 10),
        font = Enum.Font.GothamSemibold,
        textSize = 14,
        padding = Vector2.new(12, 8),
    },
}

local DEFAULT_STAGES = {
    { id = "player", title = "Player readiness", description = "Ensure your avatar is loaded." },
    { id = "remotes", title = "Game remotes", description = "Connect to Blade Ball remotes." },
    { id = "success", title = "Success feedback", description = "Listen for parry success events." },
    { id = "balls", title = "Ball telemetry", description = "Track balls for prediction." },
}

local DEFAULT_FILTERS = {
    { id = "all", label = "All" },
    { id = "loader", label = "Loader" },
    { id = "parry", label = "Parry" },
    { id = "warnings", label = "Warnings" },
    { id = "errors", label = "Errors" },
}

local DEFAULT_STAGE_MAP = {}
for _, definition in ipairs(DEFAULT_STAGES) do
    DEFAULT_STAGE_MAP[definition.id] = definition
end

local function deepCopy(data)
    if Util and Util.deepCopy then
        return Util.deepCopy(data)
    end

    if typeof(data) ~= "table" then
        return data
    end

    local copy = {}
    for key, value in pairs(data) do
        copy[key] = deepCopy(value)
    end
    return copy
end

local function mergeTheme(theme)
    if typeof(theme) ~= "table" then
        return deepCopy(DEFAULT_THEME)
    end

    local merged = deepCopy(DEFAULT_THEME)
    for key, value in pairs(theme) do
        merged[key] = value
    end
    return merged
end

local function createSection(theme, parent, name, layoutOrder)
    local container = Instance.new("Frame")
    container.Name = name .. "Section"
    container.BackgroundColor3 = theme.backgroundColor
    container.BackgroundTransparency = theme.backgroundTransparency
    container.BorderSizePixel = 0
    container.AutomaticSize = Enum.AutomaticSize.Y
    container.Size = UDim2.new(1, 0, 0, 0)
    container.LayoutOrder = layoutOrder or 1
    container.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = theme.sectionCorner
    corner.Parent = container

    local stroke = Instance.new("UIStroke")
    stroke.Color = theme.strokeColor
    stroke.Transparency = theme.strokeTransparency
    stroke.Parent = container

    local header = Instance.new("TextButton")
    header.Name = "Header"
    header.AutoButtonColor = false
    header.BackgroundTransparency = 1
    header.BorderSizePixel = 0
    header.Size = UDim2.new(1, -theme.sectionPadding * 2, 0, 36)
    header.Position = UDim2.new(0, theme.sectionPadding, 0, theme.sectionPadding)
    header.Font = theme.headerFont
    header.TextSize = theme.headerTextSize
    header.TextColor3 = theme.headerTextColor
    header.TextXAlignment = Enum.TextXAlignment.Left
    header.Text = name
    header.Parent = container

    local icon = Instance.new("ImageLabel")
    icon.Name = "Chevron"
    icon.BackgroundTransparency = 1
    icon.Size = UDim2.new(0, 16, 0, 16)
    icon.Position = UDim2.new(1, -4, 0.5, 0)
    icon.AnchorPoint = Vector2.new(1, 0.5)
    icon.Image = theme.headerIcon
    icon.ImageColor3 = theme.headerTextColor
    icon.Parent = header

    local body = Instance.new("Frame")
    body.Name = "Body"
    body.BackgroundTransparency = 1
    body.Position = UDim2.new(0, theme.sectionPadding, 0, theme.sectionPadding + header.Size.Y.Offset + theme.sectionSpacing)
    body.Size = UDim2.new(1, -theme.sectionPadding * 2, 0, 0)
    body.AutomaticSize = Enum.AutomaticSize.Y
    body.Parent = container

    local bodyLayout = Instance.new("UIListLayout")
    bodyLayout.FillDirection = Enum.FillDirection.Vertical
    bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
    bodyLayout.Padding = UDim.new(0, theme.sectionSpacing)
    bodyLayout.Parent = body

    local section = {
        frame = container,
        header = header,
        chevron = icon,
        body = body,
        layout = bodyLayout,
        collapsed = false,
        theme = theme,
    }

    function section:setCollapsed(collapsed)
        collapsed = not not collapsed
        if self.collapsed == collapsed then
            return
        end

        self.collapsed = collapsed
        body.Visible = not collapsed
        header.TextColor3 = collapsed and theme.headerInactiveColor or theme.headerTextColor

        local rotation = collapsed and 90 or 0
        local tween = TweenService:Create(icon, TweenInfo.new(0.18, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {
            Rotation = rotation,
        })
        tween:Play()

        if collapsed then
            container.AutomaticSize = Enum.AutomaticSize.None
            container.Size = UDim2.new(1, 0, 0, header.Size.Y.Offset + theme.sectionPadding * 2)
        else
            container.AutomaticSize = Enum.AutomaticSize.Y
            container.Size = UDim2.new(1, 0, 0, 0)
        end
    end

    header.MouseButton1Click:Connect(function()
        section:setCollapsed(not section.collapsed)
    end)

    return section
end

local function createStageRow(theme, parent, definition)
    local frame = Instance.new("Frame")
    frame.Name = definition.id or "Stage"
    frame.BackgroundColor3 = theme.stageBackground
    frame.BackgroundTransparency = theme.stageTransparency
    frame.BorderSizePixel = 0
    frame.AutomaticSize = Enum.AutomaticSize.Y
    frame.Size = UDim2.new(1, 0, 0, 72)
    frame.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = theme.stageCorner
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color = theme.stageStrokeColor
    stroke.Transparency = theme.stageStrokeTransparency
    stroke.Parent = frame

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, theme.bodyPadding)
    padding.PaddingBottom = UDim.new(0, theme.bodyPadding)
    padding.PaddingLeft = UDim.new(0, theme.bodyPadding)
    padding.PaddingRight = UDim.new(0, theme.bodyPadding)
    padding.Parent = frame

    local icon = Instance.new("ImageLabel")
    icon.Name = "StatusIcon"
    icon.BackgroundTransparency = 1
    icon.Size = UDim2.new(0, 24, 0, 24)
    icon.Position = UDim2.new(0, 0, 0, 0)
    icon.Image = theme.iconAssets.pending
    icon.ImageColor3 = theme.statusColors.pending
    icon.Parent = frame

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.BackgroundTransparency = 1
    title.Position = UDim2.new(0, 32, 0, 0)
    title.Size = UDim2.new(1, -32, 0, 20)
    title.Font = theme.statusFonts.title
    title.TextSize = theme.statusTextSizes.title
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextColor3 = theme.statusTextColor
    title.Text = definition.title or "Stage"
    title.Parent = frame

    local message = Instance.new("TextLabel")
    message.Name = "Message"
    message.BackgroundTransparency = 1
    message.Position = UDim2.new(0, 32, 0, 22)
    message.Size = UDim2.new(1, -32, 0, 18)
    message.Font = theme.statusFonts.message
    message.TextSize = theme.statusTextSizes.message
    message.TextXAlignment = Enum.TextXAlignment.Left
    message.TextColor3 = theme.statusDetailColor
    message.Text = definition.description or ""
    message.TextWrapped = true
    message.Parent = frame

    local detail = Instance.new("TextLabel")
    detail.Name = "Detail"
    detail.BackgroundTransparency = 1
    detail.Position = UDim2.new(0, 32, 0, 42)
    detail.Size = UDim2.new(1, -32, 0, 16)
    detail.Font = theme.statusFonts.detail
    detail.TextSize = theme.statusTextSizes.detail
    detail.TextXAlignment = Enum.TextXAlignment.Left
    detail.TextColor3 = theme.statusDetailColor
    detail.TextTransparency = theme.statusDetailTransparency
    detail.TextWrapped = true
    detail.Visible = false
    detail.Parent = frame

    return {
        frame = frame,
        icon = icon,
        title = title,
        message = message,
        detail = detail,
    }
end

local function formatElapsed(startClock, timestamp)
    if not timestamp or not startClock then
        return nil
    end
    local seconds = math.max(0, timestamp - startClock)
    if seconds >= 120 then
        return string.format("+%d s", math.floor(seconds + 0.5))
    end
    return string.format("+%.1f s", seconds)
end

local function createEventRow(theme, parent, event, startClock)
    local frame = Instance.new("Frame")
    frame.Name = string.format("Event%d", event.sequence or 0)
    frame.BackgroundColor3 = theme.eventBackground
    frame.BackgroundTransparency = theme.eventTransparency
    frame.BorderSizePixel = 0
    frame.AutomaticSize = Enum.AutomaticSize.Y
    frame.Size = UDim2.new(1, 0, 0, 48)
    frame.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = theme.eventCorner
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color = theme.eventStrokeColor
    stroke.Transparency = theme.eventStrokeTransparency
    stroke.Parent = frame

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, theme.bodyPadding)
    padding.PaddingBottom = UDim.new(0, theme.bodyPadding)
    padding.PaddingLeft = UDim.new(0, theme.bodyPadding)
    padding.PaddingRight = UDim.new(0, theme.bodyPadding)
    padding.Parent = frame

    local tag = Instance.new("TextLabel")
    tag.Name = "Tag"
    tag.BackgroundTransparency = 1
    tag.Size = UDim2.new(0, 70, 0, 18)
    tag.Font = theme.eventTagFont
    tag.TextSize = theme.eventTagSize
    tag.TextXAlignment = Enum.TextXAlignment.Left
    tag.TextColor3 = theme.statusDetailColor
    tag.Text = string.upper(event.kind or "")
    tag.Parent = frame

    local timeLabel = Instance.new("TextLabel")
    timeLabel.Name = "Timestamp"
    timeLabel.BackgroundTransparency = 1
    timeLabel.Size = UDim2.new(0, 70, 0, 18)
    timeLabel.Position = UDim2.new(1, -70, 0, 0)
    timeLabel.Font = theme.eventTagFont
    timeLabel.TextSize = theme.eventTagSize
    timeLabel.TextXAlignment = Enum.TextXAlignment.Right
    timeLabel.TextColor3 = theme.statusDetailColor
    timeLabel.Text = formatElapsed(startClock, event.timestamp)
    timeLabel.Parent = frame

    local message = Instance.new("TextLabel")
    message.Name = "Message"
    message.BackgroundTransparency = 1
    message.Position = UDim2.new(0, 0, 0, 20)
    message.Size = UDim2.new(1, 0, 0, 20)
    message.Font = theme.eventMessageFont
    message.TextSize = theme.eventMessageSize
    message.TextXAlignment = Enum.TextXAlignment.Left
    message.TextColor3 = theme.statusTextColor
    message.TextWrapped = true
    message.Text = event.message or ""
    message.Parent = frame

    local detail = Instance.new("TextLabel")
    detail.Name = "Detail"
    detail.BackgroundTransparency = 1
    detail.Position = UDim2.new(0, 0, 0, 40)
    detail.Size = UDim2.new(1, 0, 0, 16)
    detail.Font = theme.eventMessageFont
    detail.TextSize = theme.eventDetailSize
    detail.TextXAlignment = Enum.TextXAlignment.Left
    detail.TextColor3 = theme.statusDetailColor
    detail.TextTransparency = 0.1
    detail.TextWrapped = true
    detail.Visible = false
    detail.Parent = frame

    return {
        frame = frame,
        tag = tag,
        timestamp = timeLabel,
        message = message,
        detail = detail,
    }
end

local function createBadge(theme, parent, id)
    local frame = Instance.new("Frame")
    frame.Name = id or "Badge"
    frame.BackgroundColor3 = theme.badge.background
    frame.BackgroundTransparency = 0
    frame.BorderSizePixel = 0
    frame.Size = UDim2.new(0, 0, 0, 30)
    frame.AutomaticSize = Enum.AutomaticSize.X
    frame.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = theme.badge.corner
    corner.Parent = frame

    local padding = Instance.new("UIPadding")
    padding.PaddingLeft = UDim.new(0, theme.badge.padding.X)
    padding.PaddingRight = UDim.new(0, theme.badge.padding.X)
    padding.PaddingTop = UDim.new(0, theme.badge.padding.Y)
    padding.PaddingBottom = UDim.new(0, theme.badge.padding.Y)
    padding.Parent = frame

    local label = Instance.new("TextLabel")
    label.Name = "Label"
    label.BackgroundTransparency = 1
    label.Font = theme.badge.font
    label.TextSize = theme.badge.textSize
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextColor3 = theme.badge.textActive
    label.Text = id or "Error"
    label.Parent = frame

    return {
        frame = frame,
        label = label,
    }
end

function DiagnosticsPanel.new(options)
    options = options or {}
    local parent = assert(options.parent, "DiagnosticsPanel.new requires a parent")

    local theme = mergeTheme(options.theme)

    local frame = Instance.new("Frame")
    frame.Name = options.name or "DiagnosticsPanel"
    frame.BackgroundTransparency = 1
    frame.Size = UDim2.new(1, 0, 0, 0)
    frame.AutomaticSize = Enum.AutomaticSize.Y
    frame.Parent = parent

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, theme.sectionSpacing)
    layout.Parent = frame

    local stagesSection = createSection(theme, frame, "Verification stages", 1)
    local eventsSection = createSection(theme, frame, "Event history", 2)
    local errorsSection = createSection(theme, frame, "Alerts", 3)

    local stageRows = {}
    local stageOrder = {}
    for index, definition in ipairs(DEFAULT_STAGES) do
        local row = createStageRow(theme, stagesSection.body, definition)
        row.frame.LayoutOrder = index
        stageRows[definition.id] = row
        stageOrder[index] = definition.id
    end

    local filterRow = Instance.new("Frame")
    filterRow.Name = "Filters"
    filterRow.BackgroundTransparency = 1
    filterRow.Size = UDim2.new(1, 0, 0, 32)
    filterRow.Parent = eventsSection.body

    local filterLayout = Instance.new("UIListLayout")
    filterLayout.FillDirection = Enum.FillDirection.Horizontal
    filterLayout.SortOrder = Enum.SortOrder.LayoutOrder
    filterLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    filterLayout.Padding = UDim.new(0, 8)
    filterLayout.Parent = filterRow

    local filterButtons = {}

    local eventList = Instance.new("Frame")
    eventList.Name = "Events"
    eventList.BackgroundTransparency = 1
    eventList.Size = UDim2.new(1, 0, 0, 0)
    eventList.AutomaticSize = Enum.AutomaticSize.Y
    eventList.Parent = eventsSection.body

    local eventLayout = Instance.new("UIListLayout")
    eventLayout.FillDirection = Enum.FillDirection.Vertical
    eventLayout.SortOrder = Enum.SortOrder.LayoutOrder
    eventLayout.Padding = UDim.new(0, theme.sectionSpacing)
    eventLayout.Parent = eventList

    local badges = Instance.new("Frame")
    badges.Name = "Badges"
    badges.BackgroundTransparency = 1
    badges.Size = UDim2.new(1, 0, 0, 32)
    badges.AutomaticSize = Enum.AutomaticSize.Y
    badges.Parent = errorsSection.body

    local badgesLayout = Instance.new("UIListLayout")
    badgesLayout.FillDirection = Enum.FillDirection.Horizontal
    badgesLayout.SortOrder = Enum.SortOrder.LayoutOrder
    badgesLayout.Padding = UDim.new(0, 8)
    badgesLayout.Parent = badges

    local self = setmetatable({
        _theme = theme,
        frame = frame,
        _sections = {
            stages = stagesSection,
            events = eventsSection,
            errors = errorsSection,
        },
        _stageRows = stageRows,
        _stageOrder = stageOrder,
        _events = {},
        _eventRows = {},
        _filters = {},
        _filterButtons = filterButtons,
        _activeFilter = nil,
        _badges = {},
        _startClock = os.clock(),
    }, DiagnosticsPanel)

    for _, filter in ipairs(DEFAULT_FILTERS) do
        local button = Instance.new("TextButton")
        button.Name = string.format("Filter_%s", filter.id)
        button.AutoButtonColor = false
        button.BackgroundColor3 = theme.filterButton.inactiveColor
        button.TextColor3 = theme.filterButton.inactiveText
        button.Font = theme.filterButton.font
        button.TextSize = theme.filterButton.textSize
        button.Text = filter.label or filter.id
        button.BorderSizePixel = 0
        button.Size = UDim2.new(0, math.max(60, button.TextBounds.X + theme.filterButton.padding.X * 2), 0, 26)
        button.Parent = filterRow

        local corner = Instance.new("UICorner")
        corner.CornerRadius = theme.filterButton.corner
        corner.Parent = button

        self._filters[filter.id] = filter
        self._filterButtons[filter.id] = button

        button.MouseButton1Click:Connect(function()
            self:setFilter(filter.id)
        end)
    end

    self:setFilter("all")

    return self
end

function DiagnosticsPanel:_styleStageRow(row, stage)
    if not row then
        return
    end

    local status = stage.status or "pending"
    local theme = self._theme
    local colors = theme.statusColors
    local iconAssets = theme.iconAssets

    row.title.Text = stage.title or row.title.Text
    row.message.Text = stage.message or stage.description or ""
    row.detail.Visible = stage.detail ~= nil and stage.detail ~= ""
    row.detail.Text = stage.detail or ""

    local color = colors[status] or colors.pending
    row.icon.Image = iconAssets[status] or iconAssets.pending
    row.icon.ImageColor3 = color
    row.title.TextColor3 = color
    row.message.TextColor3 = theme.statusTextColor
    row.detail.TextColor3 = theme.statusDetailColor
end

function DiagnosticsPanel:_updateEventRow(entry, event)
    if not entry or not event then
        return
    end

    local theme = self._theme
    local severity = event.severity or "info"
    local color = theme.severityColors[severity] or theme.statusDetailColor

    entry.tag.Text = string.upper(event.kind or "")
    entry.tag.TextColor3 = color
    entry.timestamp.Text = formatElapsed(self._startClock, event.timestamp)
    entry.message.Text = event.message or ""

    if event.detail and event.detail ~= "" then
        entry.detail.Visible = true
        entry.detail.Text = event.detail
    else
        entry.detail.Visible = false
    end

    entry.frame.LayoutOrder = -(event.sequence or 0)
end

function DiagnosticsPanel:_isEventVisible(event)
    local filterId = self._activeFilter or "all"
    if filterId == "all" then
        return true
    end

    if filterId == "loader" then
        return event.kind == "loader"
    elseif filterId == "parry" then
        return event.kind == "parry"
    elseif filterId == "warnings" then
        return event.severity == "warning"
    elseif filterId == "errors" then
        return event.severity == "error"
    end

    return true
end

function DiagnosticsPanel:_applyFilter()
    for _, entry in ipairs(self._eventRows) do
        local event = entry.event
        entry.frame.Visible = self:_isEventVisible(event)
    end
end

function DiagnosticsPanel:_styleFilterButtons()
    local theme = self._theme
    for id, button in pairs(self._filterButtons) do
        local active = id == self._activeFilter
        button.BackgroundColor3 = active and theme.filterButton.activeColor or theme.filterButton.inactiveColor
        button.TextColor3 = active and theme.filterButton.activeText or theme.filterButton.inactiveText
    end
end

function DiagnosticsPanel:setFilter(id)
    id = id or "all"
    if not self._filters[id] then
        id = "all"
    end
    self._activeFilter = id
    self:_styleFilterButtons()
    self:_applyFilter()
end

function DiagnosticsPanel:setCollapsed(sectionId, collapsed)
    local section = self._sections[sectionId]
    if section then
        section:setCollapsed(collapsed)
    end
end

function DiagnosticsPanel:setStages(stages)
    local map = {}
    if typeof(stages) == "table" then
        if stages[1] ~= nil then
            for _, stage in ipairs(stages) do
                local id = stage.id or stage.name
                if id then
                    map[id] = stage
                end
            end
        else
            map = stages
        end
    end

    for _, id in ipairs(self._stageOrder) do
        local row = self._stageRows[id]
        if row then
            local stage = map[id] or map[row.frame.Name]
            if stage then
                self:_styleStageRow(row, stage)
            end
        end
    end
end

function DiagnosticsPanel:pushEvent(event)
    if typeof(event) ~= "table" then
        return
    end

    local copied = deepCopy(event)
    copied.sequence = copied.sequence or (#self._events + 1)
    copied.timestamp = copied.timestamp or os.clock()

    table.insert(self._events, copied)

    local entry = createEventRow(self._theme, self._sections.events.body.Events, copied, self._startClock)
    entry.event = copied
    table.insert(self._eventRows, entry)

    self:_updateEventRow(entry, copied)
    self:_applyFilter()
end

function DiagnosticsPanel:showError(errorInfo)
    if errorInfo == nil then
        for _, badge in pairs(self._badges) do
            badge.frame:Destroy()
        end
        self._badges = {}
        return
    end

    local id = tostring(errorInfo.id or errorInfo.kind or (#self._badges + 1))
    local badge = self._badges[id]
    if not badge then
        badge = createBadge(self._theme, self._sections.errors.body.Badges, id)
        self._badges[id] = badge
    end

    local active = errorInfo.active ~= false
    local severity = errorInfo.severity or "error"
    local theme = self._theme

    badge.label.Text = errorInfo.message or errorInfo.text or id
    badge.label.TextColor3 = active and theme.badge.textActive or theme.badge.textResolved
    badge.frame.BackgroundColor3 = active and theme.badge.background or theme.badge.backgroundResolved
    badge.frame.LayoutOrder = active and 0 or 1

    badge.active = active
    badge.severity = severity
end

function DiagnosticsPanel:reset()
    for _, entry in ipairs(self._eventRows) do
        entry.frame:Destroy()
    end
    self._eventRows = {}
    self._events = {}

    for _, badge in pairs(self._badges) do
        badge.frame:Destroy()
    end
    self._badges = {}

    self._startClock = os.clock()
    self:setFilter("all")

    for _, id in ipairs(self._stageOrder) do
        local row = self._stageRows[id]
        if row then
            row.icon.ImageColor3 = self._theme.statusColors.pending
            row.icon.Image = self._theme.iconAssets.pending
            row.title.TextColor3 = self._theme.statusColors.pending
            local definition = DEFAULT_STAGE_MAP[id]
            row.message.Text = definition and definition.description or ""
            row.message.TextColor3 = self._theme.statusDetailColor
            row.detail.Visible = false
            row.detail.Text = ""
        end
    end
end

function DiagnosticsPanel:destroy()
    if self._destroyed then
        return
    end

    self._destroyed = true

    if self.frame then
        self.frame:Destroy()
        self.frame = nil
    end

    self._sections = nil
    self._stageRows = nil
    self._eventRows = nil
    self._badges = nil
end

return DiagnosticsPanel

]===],
    ['src/ui/init.lua'] = [===[
-- mikkel32/AutoParry : src/ui/init.lua
-- selene: allow(global_usage)
-- Professional dashboard controller for AutoParry with status, telemetry,
-- control toggles, and hotkey support. The module exposes a lightweight API
-- used by the runtime to keep the UI in sync with the parry core while giving
-- downstream experiences room to customise the presentation.

local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Require = rawget(_G, "ARequire")
local Util = Require("src/shared/util.lua")
local LoadingOverlay = Require("src/ui/loading_overlay.lua")
local DiagnosticsPanel = Require("src/ui/diagnostics_panel.lua")

local UI = {}

local UIFLEX_SUPPORTED = pcall(function()
    local layout = Instance.new("UIFlexLayout")
    layout:Destroy()
end)

local function newFlexLayout(fillDirection)
    local layout
    if UIFLEX_SUPPORTED then
        layout = Instance.new("UIFlexLayout")
    else
        layout = Instance.new("UIListLayout")
    end

    if fillDirection then
        pcall(function()
            layout.FillDirection = fillDirection
        end)
    end

    return layout
end

local function trySetLayoutProperty(layout, property, value)
    pcall(function()
        layout[property] = value
    end)
end

local Controller = {}
Controller.__index = Controller

local DASHBOARD_THEME = {
    widths = {
        min = 360,
        medium = 480,
        large = 620,
    },
    minContentWidth = 280,
    breakpoints = {
        medium = 900,
        large = 1280,
    },
    spacing = {
        padding = {
            min = 18,
            medium = 22,
            large = 26,
        },
        paddingY = {
            min = 20,
            medium = 26,
            large = 30,
        },
        blockGap = {
            min = 14,
            medium = 18,
            large = 22,
        },
        columnGap = {
            min = 0,
            medium = 18,
            large = 24,
        },
        sectionGap = {
            min = 14,
            medium = 16,
            large = 18,
        },
        cardGap = {
            min = 12,
            medium = 14,
            large = 16,
        },
        cardPadding = {
            min = 16,
            medium = 20,
            large = 24,
        },
        controlPadding = {
            min = 18,
            medium = 22,
            large = 26,
        },
        marginX = {
            min = 20,
            medium = 40,
            large = 48,
        },
        marginTop = {
            min = 70,
            medium = 120,
            large = 140,
        },
        minMargin = 12,
    },
    telemetryCardHeight = 116,
    backgroundColor = Color3.fromRGB(24, 28, 36),
    backgroundTransparency = 0.05,
    strokeColor = Color3.fromRGB(94, 148, 214),
    strokeTransparency = 0.5,
    gradient = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(28, 32, 42)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(82, 156, 255)),
    }),
    gradientTransparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.9),
        NumberSequenceKeypoint.new(1, 0.35),
    }),
    glowColor = Color3.fromRGB(82, 156, 255),
    glowTransparency = 0.85,
    headingColor = Color3.fromRGB(232, 238, 248),
    subheadingColor = Color3.fromRGB(188, 202, 224),
    badgeActiveColor = Color3.fromRGB(88, 206, 157),
    badgeIdleColor = Color3.fromRGB(56, 64, 82),
    badgeTextActive = Color3.fromRGB(12, 16, 26),
    badgeTextIdle = Color3.fromRGB(216, 226, 244),
    toggleOnColor = Color3.fromRGB(82, 156, 255),
    toggleOffColor = Color3.fromRGB(44, 50, 62),
    toggleOnTextColor = Color3.fromRGB(12, 16, 26),
    toggleOffTextColor = Color3.fromRGB(216, 226, 244),
    telemetryCardColor = Color3.fromRGB(26, 30, 40),
    telemetryStrokeColor = Color3.fromRGB(94, 148, 214),
    controlCardColor = Color3.fromRGB(24, 28, 36),
    controlStrokeColor = Color3.fromRGB(94, 148, 214),
}

local DEFAULT_TELEMETRY_CARDS = {
    {
        id = "latency",
        label = "Network Latency",
        value = "-- ms",
        hint = "Round-trip time to the Blade Ball server.",
    },
    {
        id = "uptime",
        label = "Session Length",
        value = "00:00",
        hint = "Elapsed runtime since activation.",
    },
    {
        id = "assist",
        label = "Timing Engine",
        value = "Calibrating",
        hint = "Status of AutoParry's adaptive timing model.",
    },
}

local DEFAULT_CONTROL_SWITCHES = {
    {
        id = "adaptive",
        title = "Adaptive Timing",
        description = "Adjusts parry timing from recent plays.",
        default = true,
        badge = "SMART",
    },
    {
        id = "failsafe",
        title = "Safety Net",
        description = "Returns control to you if anomalies spike.",
        default = true,
        badge = "SAFE",
    },
    {
        id = "edge",
        title = "Advanced Prediction",
        description = "Forecasts ricochet chains before they happen.",
        default = false,
    },
    {
        id = "sync",
        title = "Team Sync",
        description = "Shares telemetry with party members instantly.",
        default = true,
        badge = "LINK",
    },
}

local DEFAULT_VIEWPORT_SIZE = Vector2.new(DASHBOARD_THEME.widths.medium, 720)

local function getLoaderProgressAndSignals()
    local loaderState = rawget(_G, "AutoParryLoader")
    if typeof(loaderState) ~= "table" then
        return nil, nil
    end

    local context = loaderState.context
    local progress = (typeof(context) == "table" and context.progress) or loaderState.progress
    local signals = (typeof(context) == "table" and context.signals) or loaderState.signals

    if typeof(progress) ~= "table" then
        progress = nil
    end
    if typeof(signals) ~= "table" then
        signals = nil
    end

    return progress, signals
end

local function isLoaderInProgress(progress)
    if typeof(progress) ~= "table" then
        return false
    end

    local started = tonumber(progress.started) or 0
    local finished = tonumber(progress.finished) or 0
    local failed = tonumber(progress.failed) or 0

    if started <= 0 then
        return false
    end

    return finished + failed < started
end

local function getActiveOverlay()
    if typeof(LoadingOverlay) == "table" and typeof(LoadingOverlay.getActive) == "function" then
        local ok, overlayInstance = pcall(LoadingOverlay.getActive)
        if ok then
            return overlayInstance
        end
    end

    return nil
end

local function getBreakpointForViewport(viewportSize)
    local width = viewportSize and viewportSize.X or DEFAULT_VIEWPORT_SIZE.X
    if DASHBOARD_THEME.breakpoints and DASHBOARD_THEME.breakpoints.large and width >= DASHBOARD_THEME.breakpoints.large then
        return "large"
    end
    if DASHBOARD_THEME.breakpoints and DASHBOARD_THEME.breakpoints.medium and width >= DASHBOARD_THEME.breakpoints.medium then
        return "medium"
    end
    return "min"
end

local function getResponsiveValue(values, breakpoint)
    if not values then
        return nil
    end

    local value = values[breakpoint]
    if value ~= nil then
        return value
    end

    if breakpoint == "large" then
        value = values.medium or values.min
    elseif breakpoint == "medium" then
        value = values.large or values.min
    else
        value = values.medium or values.large
    end

    if value ~= nil then
        return value
    end

    return values.default or values.min or values.medium or values.large
end

local function resolveLayoutMetrics(viewportSize)
    viewportSize = viewportSize or DEFAULT_VIEWPORT_SIZE
    local viewportWidth = viewportSize.X
    if viewportWidth <= 0 then
        viewportWidth = DEFAULT_VIEWPORT_SIZE.X
    end

    local breakpoint = getBreakpointForViewport(viewportSize)
    local desiredWidth = getResponsiveValue(DASHBOARD_THEME.widths, breakpoint) or DASHBOARD_THEME.widths.medium
    local minContentWidth = DASHBOARD_THEME.minContentWidth or desiredWidth
    local marginX = getResponsiveValue(DASHBOARD_THEME.spacing.marginX, breakpoint) or 24
    local minMargin = DASHBOARD_THEME.spacing.minMargin or 12
    marginX = math.max(minMargin, marginX)

    local availableWidth = math.max(viewportWidth - (marginX * 2), 0)
    if availableWidth < minContentWidth then
        local adjustedMargin = math.max(minMargin, math.floor((viewportWidth - minContentWidth) / 2))
        marginX = adjustedMargin
        availableWidth = math.max(viewportWidth - (marginX * 2), 0)
    end

    local effectiveMin = math.min(minContentWidth, availableWidth)
    if effectiveMin <= 0 then
        effectiveMin = math.min(minContentWidth, math.max(viewportWidth - (minMargin * 2), 0))
    end

    local effectiveMax = math.max(availableWidth, effectiveMin)
    if effectiveMax <= 0 then
        effectiveMax = math.max(effectiveMin, math.max(viewportWidth - (minMargin * 2), 0))
    end

    local resolvedWidth = math.clamp(desiredWidth, effectiveMin, effectiveMax)
    if resolvedWidth <= 0 then
        resolvedWidth = effectiveMax > 0 and effectiveMax or math.max(desiredWidth, math.max(viewportWidth - (minMargin * 2), 0))
    end
    resolvedWidth = math.min(resolvedWidth, viewportWidth)

    local topOffset = getResponsiveValue(DASHBOARD_THEME.spacing.marginTop, breakpoint) or 120
    local paddingX = getResponsiveValue(DASHBOARD_THEME.spacing.padding, breakpoint) or 20
    local paddingY = getResponsiveValue(DASHBOARD_THEME.spacing.paddingY, breakpoint) or paddingX
    local blockGap = getResponsiveValue(DASHBOARD_THEME.spacing.blockGap, breakpoint) or 16
    local columnGap = getResponsiveValue(DASHBOARD_THEME.spacing.columnGap, breakpoint) or 0
    local sectionGap = getResponsiveValue(DASHBOARD_THEME.spacing.sectionGap, breakpoint) or 14
    local cardGap = getResponsiveValue(DASHBOARD_THEME.spacing.cardGap, breakpoint) or sectionGap
    local cardPadding = getResponsiveValue(DASHBOARD_THEME.spacing.cardPadding, breakpoint) or 18
    local controlPadding = getResponsiveValue(DASHBOARD_THEME.spacing.controlPadding, breakpoint) or cardPadding
    local splitColumns = breakpoint ~= "min"
    local telemetryColumns = splitColumns and 2 or 1
    local controlSwitchWidth = splitColumns and 120 or 108

    return {
        breakpoint = breakpoint,
        width = math.floor(resolvedWidth + 0.5),
        sideMargin = marginX,
        topOffset = topOffset,
        paddingX = paddingX,
        paddingY = paddingY,
        blockGap = blockGap,
        columnGap = columnGap,
        sectionGap = sectionGap,
        cardGap = cardGap,
        cardPadding = cardPadding,
        controlPadding = controlPadding,
        splitColumns = splitColumns,
        telemetryColumns = telemetryColumns,
        telemetryCardHeight = DASHBOARD_THEME.telemetryCardHeight,
        controlSwitchWidth = controlSwitchWidth,
    }
end

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
    frame.AnchorPoint = Vector2.new(0.5, 0)
    frame.Position = UDim2.new(0.5, 0, 0, 0)
    frame.Size = UDim2.new(0, DASHBOARD_THEME.widths.medium, 0, 0)
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
    content.Size = UDim2.new(1, 0, 0, 0)
    content.AutomaticSize = Enum.AutomaticSize.Y
    content.Parent = frame

    local padding = Instance.new("UIPadding")
    padding.Parent = content

    local layout = newFlexLayout(Enum.FillDirection.Vertical)
    trySetLayoutProperty(layout, "SortOrder", Enum.SortOrder.LayoutOrder)
    trySetLayoutProperty(layout, "HorizontalAlignment", Enum.HorizontalAlignment.Left)
    trySetLayoutProperty(layout, "VerticalAlignment", Enum.VerticalAlignment.Top)
    trySetLayoutProperty(layout, "Wraps", false)
    trySetLayoutProperty(layout, "Padding", UDim.new(0, DASHBOARD_THEME.spacing.blockGap.min))
    layout.Parent = content

    local columnsContainer = Instance.new("Frame")
    columnsContainer.Name = "Columns"
    columnsContainer.BackgroundTransparency = 1
    columnsContainer.Size = UDim2.new(1, 0, 0, 0)
    columnsContainer.AutomaticSize = Enum.AutomaticSize.Y
    columnsContainer.LayoutOrder = 3
    columnsContainer.Parent = content

    local columnsLayout = newFlexLayout(Enum.FillDirection.Horizontal)
    trySetLayoutProperty(columnsLayout, "HorizontalAlignment", Enum.HorizontalAlignment.Left)
    trySetLayoutProperty(columnsLayout, "VerticalAlignment", Enum.VerticalAlignment.Top)
    trySetLayoutProperty(columnsLayout, "Wraps", true)
    trySetLayoutProperty(columnsLayout, "SortOrder", Enum.SortOrder.LayoutOrder)
    columnsLayout.Parent = columnsContainer

    local leftColumn = Instance.new("Frame")
    leftColumn.Name = "LeftColumn"
    leftColumn.BackgroundTransparency = 1
    leftColumn.Size = UDim2.new(1, 0, 0, 0)
    leftColumn.AutomaticSize = Enum.AutomaticSize.Y
    leftColumn.LayoutOrder = 1
    leftColumn.Parent = columnsContainer

    local leftLayout = Instance.new("UIListLayout")
    leftLayout.FillDirection = Enum.FillDirection.Vertical
    leftLayout.SortOrder = Enum.SortOrder.LayoutOrder
    leftLayout.Padding = UDim.new(0, DASHBOARD_THEME.spacing.sectionGap.min)
    leftLayout.Parent = leftColumn

    local rightColumn = Instance.new("Frame")
    rightColumn.Name = "RightColumn"
    rightColumn.BackgroundTransparency = 1
    rightColumn.Size = UDim2.new(1, 0, 0, 0)
    rightColumn.AutomaticSize = Enum.AutomaticSize.Y
    rightColumn.LayoutOrder = 2
    rightColumn.Parent = columnsContainer

    local rightLayout = Instance.new("UIListLayout")
    rightLayout.FillDirection = Enum.FillDirection.Vertical
    rightLayout.SortOrder = Enum.SortOrder.LayoutOrder
    rightLayout.Padding = UDim.new(0, DASHBOARD_THEME.spacing.sectionGap.min)
    rightLayout.Parent = rightColumn

    local shell = {}
    local metricListeners = {}
    local currentMetrics

    function shell:getMetrics()
        return currentMetrics
    end

    function shell:addMetricListener(callback)
        assert(typeof(callback) == "function", "Dashboard shell expects a function listener")
        local listener = {
            callback = callback,
            connected = true,
        }
        table.insert(metricListeners, listener)
        if currentMetrics then
            callback(currentMetrics)
        end

        return function()
            listener.connected = false
        end
    end

    function shell:applyMetrics(metrics)
        if not metrics then
            return
        end

        currentMetrics = metrics

        frame.Size = UDim2.new(0, metrics.width, 0, 0)
        frame.Position = UDim2.new(0.5, 0, 0, metrics.topOffset)

        padding.PaddingLeft = UDim.new(0, metrics.paddingX)
        padding.PaddingRight = UDim.new(0, metrics.paddingX)
        padding.PaddingTop = UDim.new(0, metrics.paddingY)
        padding.PaddingBottom = UDim.new(0, metrics.paddingY)

        layout.Padding = UDim.new(0, metrics.blockGap)

        columnsLayout.Padding = UDim.new(0, metrics.columnGap)
        columnsLayout.HorizontalAlignment = metrics.splitColumns and Enum.HorizontalAlignment.Left or Enum.HorizontalAlignment.Center

        local columnOffset = math.floor((metrics.columnGap or 0) / 2)
        if metrics.splitColumns then
            leftColumn.Size = UDim2.new(0.5, -columnOffset, 0, 0)
            rightColumn.Size = UDim2.new(0.5, -columnOffset, 0, 0)
        else
            leftColumn.Size = UDim2.new(1, 0, 0, 0)
            rightColumn.Size = UDim2.new(1, 0, 0, 0)
        end

        leftLayout.Padding = UDim.new(0, metrics.sectionGap)
        rightLayout.Padding = UDim.new(0, metrics.sectionGap)

        for index = #metricListeners, 1, -1 do
            local listener = metricListeners[index]
            if listener.connected and listener.callback then
                listener.callback(metrics)
            else
                table.remove(metricListeners, index)
            end
        end
    end

    shell.content = content
    shell.layout = layout
    shell.padding = padding
    shell.columns = {
        left = leftColumn,
        right = rightColumn,
    }
    shell.columnLayouts = {
        left = leftLayout,
        right = rightLayout,
    }
    shell.columnsContainer = columnsContainer
    shell.columnsLayout = columnsLayout

    return frame, shell
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
    tagline.Text = "Precision parry automation"
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

local function createDashboardCard(shell, parent, options)
    options = options or {}

    local card = Instance.new("Frame")
    card.Name = options.name or "Card"
    card.BackgroundColor3 = options.backgroundColor or DASHBOARD_THEME.telemetryCardColor
    card.BackgroundTransparency = options.backgroundTransparency or 0.08
    card.BorderSizePixel = 0
    card.Size = UDim2.new(1, 0, 0, 0)
    card.AutomaticSize = Enum.AutomaticSize.Y
    card.LayoutOrder = options.layoutOrder or 0
    card.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, options.cornerRadius or 14)
    corner.Parent = card

    if options.strokeColor then
        local stroke = Instance.new("UIStroke")
        stroke.Thickness = options.strokeThickness or 1
        stroke.Transparency = options.strokeTransparency or 0.5
        stroke.Color = options.strokeColor
        stroke.Parent = card
    end

    local padding = Instance.new("UIPadding")
    padding.Parent = card

    local function apply(metrics)
        local basePadding
        if options.paddingToken == "control" then
            basePadding = metrics and metrics.controlPadding or DASHBOARD_THEME.spacing.controlPadding.medium
        else
            basePadding = metrics and metrics.cardPadding or DASHBOARD_THEME.spacing.cardPadding.medium
        end

        local top = options.paddingTop or basePadding
        local bottom = options.paddingBottom or basePadding
        local left = options.paddingLeft or options.horizontalPadding or basePadding
        local right = options.paddingRight or options.horizontalPadding or basePadding

        if typeof(options.padding) == "function" then
            local resolved = options.padding(metrics) or {}
            top = resolved.top or resolved.y or resolved.vertical or top
            bottom = resolved.bottom or resolved.y or resolved.vertical or bottom
            left = resolved.left or resolved.x or resolved.horizontal or left
            right = resolved.right or resolved.x or resolved.horizontal or right
        elseif typeof(options.padding) == "table" then
            top = options.padding.top or options.padding[1] or options.padding.y or options.padding.vertical or top
            bottom = options.padding.bottom or options.padding[2] or options.padding.y or options.padding.vertical or bottom
            left = options.padding.left or options.padding[3] or options.padding.x or options.padding.horizontal or left
            right = options.padding.right or options.padding[4] or options.padding.x or options.padding.horizontal or right
        end

        padding.PaddingTop = UDim.new(0, top)
        padding.PaddingBottom = UDim.new(0, bottom)
        padding.PaddingLeft = UDim.new(0, left)
        padding.PaddingRight = UDim.new(0, right)
    end

    apply(nil)

    local disconnect
    if shell and shell.addMetricListener then
        local function onMetrics(metrics)
            if not card.Parent then
                if disconnect then
                    disconnect()
                    disconnect = nil
                end
                return
            end

            apply(metrics)
        end

        local remover = shell:addMetricListener(onMetrics)
        disconnect = function()
            remover()
        end

        card.AncestryChanged:Connect(function(_, parent)
            if not parent and disconnect then
                disconnect()
                disconnect = nil
            end
        end)
    end

    return card, padding
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
    header.Text = "Control status"
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
    statusSupport.Text = "Assist engine standing by for activation."
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
    toggleButton.Text = "Enable AutoParry"
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

local function createTelemetryCard(shell, parent, definition)
    local card = createDashboardCard(shell, parent, {
        name = definition.id or "Telemetry",
        backgroundColor = DASHBOARD_THEME.telemetryCardColor,
        backgroundTransparency = 0.1,
        strokeColor = DASHBOARD_THEME.telemetryStrokeColor,
        strokeTransparency = 0.5,
        padding = function(metrics)
            local base = metrics and metrics.cardPadding or DASHBOARD_THEME.spacing.cardPadding.medium
            return {
                top = base,
                bottom = base,
                horizontal = base + 2,
            }
        end,
    })

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

local function createTelemetrySection(shell, definitions)
    local section = Instance.new("Frame")
    section.Name = "Telemetry"
    section.BackgroundTransparency = 1
    section.LayoutOrder = 3
    section.Size = UDim2.new(1, 0, 0, 0)
    section.AutomaticSize = Enum.AutomaticSize.Y
    local targetParent
    if shell then
        if shell.columns and shell.columns.left then
            targetParent = shell.columns.left
        elseif shell.content then
            targetParent = shell.content
        end
    end
    section.Parent = targetParent

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

    local function applyMetrics(metrics)
        if not layout.Parent then
            return
        end

        local columns = metrics and metrics.telemetryColumns or 1
        local gap = metrics and metrics.cardGap or 12
        local height = metrics and metrics.telemetryCardHeight or DASHBOARD_THEME.telemetryCardHeight

        if columns > 1 then
            layout.CellSize = UDim2.new(1 / columns, -gap, 0, height)
        else
            layout.CellSize = UDim2.new(1, 0, 0, height)
        end
        layout.CellPadding = UDim2.new(0, gap, 0, gap)
    end

    if shell and shell.addMetricListener then
        local disconnect = shell:addMetricListener(applyMetrics)
        section.AncestryChanged:Connect(function(_, parentFrame)
            if not parentFrame then
                disconnect()
            end
        end)
    else
        applyMetrics(nil)
    end

    for _, definition in ipairs(definitions) do
        local card = createTelemetryCard(shell, grid, definition)
        cards[definition.id or definition.label] = card
    end

    return {
        frame = section,
        grid = grid,
        layout = layout,
        cards = cards,
        applyMetrics = applyMetrics,
    }
end

local function createControlToggle(shell, parent, definition, onToggle)
    local row = createDashboardCard(shell, parent, {
        name = definition.id or (definition.title or "Control"),
        backgroundColor = DASHBOARD_THEME.controlCardColor,
        backgroundTransparency = 0.08,
        strokeColor = DASHBOARD_THEME.controlStrokeColor,
        paddingToken = "control",
        padding = function(metrics)
            local base = metrics and metrics.controlPadding or DASHBOARD_THEME.spacing.controlPadding.medium
            return {
                top = base,
                bottom = base,
                horizontal = base + 2,
            }
        end,
    })

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamSemibold
    title.TextSize = 17
    title.TextColor3 = DASHBOARD_THEME.headingColor
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = definition.title or "Control"
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

    local function applyResponsiveMetrics(metrics)
        local switchWidth = metrics and metrics.controlSwitchWidth or 120
        local spacing = 24
        switch.Size = UDim2.new(0, switchWidth, 0, 34)
        title.Size = UDim2.new(1, -(switchWidth + spacing), 0, 20)
        description.Size = UDim2.new(1, -(switchWidth + spacing), 0, 34)
    end

    applyResponsiveMetrics(shell and shell:getMetrics())

    if shell and shell.addMetricListener then
        local disconnect = shell:addMetricListener(function(metrics)
            if not row.Parent then
                disconnect()
                return
            end
            applyResponsiveMetrics(metrics)
        end)

        row.AncestryChanged:Connect(function(_, parentFrame)
            if not parentFrame then
                disconnect()
            end
        end)
    end

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

local function createControlsSection(shell, definitions, onToggle)
    local section = Instance.new("Frame")
    section.Name = "Controls"
    section.BackgroundTransparency = 1
    section.LayoutOrder = 4
    section.Size = UDim2.new(1, 0, 0, 0)
    section.AutomaticSize = Enum.AutomaticSize.Y
    local targetParent
    if shell then
        if shell.columns and shell.columns.right then
            targetParent = shell.columns.right
        elseif shell.content then
            targetParent = shell.content
        end
    end
    section.Parent = targetParent

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamSemibold
    title.TextSize = 18
    title.TextColor3 = Color3.fromRGB(185, 205, 240)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "Control center"
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
    layout.Padding = UDim.new(0, 12)
    layout.Parent = list

    local function applyMetrics(metrics)
        if metrics then
            layout.Padding = UDim.new(0, metrics.sectionGap)
        end
    end

    if shell and shell.addMetricListener then
        local disconnect = shell:addMetricListener(function(metrics)
            if not section.Parent then
                disconnect()
                return
            end
            applyMetrics(metrics)
        end)

        section.AncestryChanged:Connect(function(_, parentFrame)
            if not parentFrame then
                disconnect()
            end
        end)
    end

    local toggles = {}
    for _, definition in ipairs(definitions) do
        local toggle = createControlToggle(shell, list, definition, function(state)
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

local function createDiagnosticsSection(shell, options)
    local section = Instance.new("Frame")
    section.Name = "Diagnostics"
    section.BackgroundTransparency = 1
    section.Size = UDim2.new(1, 0, 0, 0)
    section.AutomaticSize = Enum.AutomaticSize.Y
    section.LayoutOrder = 1

    local targetParent
    if shell then
        if shell.columns and shell.columns.right then
            targetParent = shell.columns.right
        elseif shell.content then
            targetParent = shell.content
        end
    end

    section.Parent = targetParent

    local panel = DiagnosticsPanel.new({
        parent = section,
        theme = options and options.theme,
    })

    return {
        frame = section,
        panel = panel,
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
            self.button.Text = "Disable AutoParry"
            self.button.BackgroundColor3 = DASHBOARD_THEME.toggleOnColor
            self.button.TextColor3 = DASHBOARD_THEME.toggleOnTextColor
        else
            self.button.Text = "Enable AutoParry"
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
                self._statusCard.heading.Text = enabled and "AutoParry active" or "AutoParry standby"
            end
            if self._statusCard.support then
                if enabled then
                    self._statusCard.support.Text = "Assist engine monitoring every ball in play."
                else
                    self._statusCard.support.Text = "Assist engine standing by for activation."
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

function Controller:getColumns()
    if self._shell and self._shell.columns then
        return self._shell.columns
    end
    return nil
end

function Controller:getLayoutMetrics()
    if self._shell and self._shell.getMetrics then
        self._layoutMetrics = self._layoutMetrics or self._shell:getMetrics()
    end
    return self._layoutMetrics
end

function Controller:getDiagnosticsPanel()
    return self._diagnostics
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
        local card = createTelemetryCard(self._shell, self._telemetrySection.grid, definition)
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
        local toggle = createControlToggle(self._shell, self._controlsSection.list, definition, function(state)
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

function Controller:resetDiagnostics()
    if self._diagnostics then
        self._diagnostics:reset()
    end
end

function Controller:setDiagnosticsStages(stages)
    if self._diagnostics then
        self._diagnostics:setStages(stages)
    end
end

function Controller:pushDiagnosticsEvent(event)
    if self._diagnostics then
        self._diagnostics:pushEvent(event)
    end
end

function Controller:showDiagnosticsError(errorInfo)
    if self._diagnostics then
        self._diagnostics:showError(errorInfo)
    end
end

function Controller:setDiagnosticsFilter(filterId)
    if self._diagnostics and self._diagnostics.setFilter then
        self._diagnostics:setFilter(filterId)
    end
end

function Controller:setDiagnosticsCollapsed(sectionId, collapsed)
    if self._diagnostics and self._diagnostics.setCollapsed then
        self._diagnostics:setCollapsed(sectionId, collapsed)
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

    if self._diagnostics then
        self._diagnostics:destroy()
        self._diagnostics = nil
    end

    if self.gui then
        self.gui:Destroy()
        self.gui = nil
    end

    if self._viewportSizeConnection then
        self._viewportSizeConnection:Disconnect()
        self._viewportSizeConnection = nil
    end

    if self._workspaceCameraConnection then
        self._workspaceCameraConnection:Disconnect()
        self._workspaceCameraConnection = nil
    end

    self.dashboard = nil
    self.button = nil
    self._header = nil
    self._statusCard = nil
    self._telemetrySection = nil
    self._telemetryCards = nil
    self._controlsSection = nil
    self._diagnosticsSection = nil
    self._actionsRow = nil
    self._shell = nil
    self._columns = nil
    self._layoutMetrics = nil

    if self._changed then
        self._changed:destroy()
        self._changed = nil
    end
end

function UI.mount(options)
    options = options or {}

    local gui = ensureGuiRoot("AutoParryUI")
    local dashboard, shell = createDashboardFrame(gui)

    if dashboard then
        dashboard.Visible = false
    end
    if gui then
        gui.Enabled = false
    end

    local camera = Workspace.CurrentCamera
    if camera then
        shell:applyMetrics(resolveLayoutMetrics(camera.ViewportSize))
    else
        shell:applyMetrics(resolveLayoutMetrics(DEFAULT_VIEWPORT_SIZE))
    end

    local rawHotkey = options.hotkey
    local hotkeyDescriptor = parseHotkey(rawHotkey)
    local hotkeyDisplay = formatHotkeyDisplay(hotkeyDescriptor and hotkeyDescriptor.key and hotkeyDescriptor or rawHotkey)

    local header = createHeader(shell.content, options.title or "AutoParry", hotkeyDisplay)
    if typeof(options.tagline) == "string" then
        header.tagline.Text = options.tagline
    end

    local statusCard = createStatusCard(shell.content)
    statusCard.tooltip.Text = options.tooltip or ""
    statusCard.tooltip.Visible = options.tooltip ~= nil and options.tooltip ~= ""
    statusCard.hotkeyLabel.Text = hotkeyDisplay and ("Hotkey: %s"):format(hotkeyDisplay) or ""

    local telemetryDefinitions = options.telemetry or DEFAULT_TELEMETRY_CARDS
    local telemetry = createTelemetrySection(shell, telemetryDefinitions)

    local diagnostics = createDiagnosticsSection(shell, options and options.diagnostics)

    local controlSignal = Util.Signal.new()
    local controlDefinitions = options.controls or DEFAULT_CONTROL_SWITCHES
    local controls = createControlsSection(shell, controlDefinitions, function(definition, state)
        controlSignal:fire(definition.id or definition.title, state, definition)
    end)

    local actions = createActionsRow(shell.content)

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
        _shell = shell,
        _columns = shell.columns,
        _layoutMetrics = shell:getMetrics(),
        _diagnosticsSection = diagnostics,
        _diagnostics = diagnostics and diagnostics.panel,
        _loaderPending = false,
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

    if shell and shell.addMetricListener then
        local metricDisconnect = shell:addMetricListener(function(metrics)
            controller._layoutMetrics = metrics
        end)
        table.insert(controller._connections, {
            Disconnect = function()
                metricDisconnect()
            end,
        })
    end

    local function applyViewportMetrics(currentCamera)
        if controller._destroyed then
            return
        end

        if currentCamera then
            shell:applyMetrics(resolveLayoutMetrics(currentCamera.ViewportSize))
        else
            shell:applyMetrics(resolveLayoutMetrics(DEFAULT_VIEWPORT_SIZE))
        end
    end

    local function bindCamera(newCamera)
        if controller._viewportSizeConnection then
            controller._viewportSizeConnection:Disconnect()
            controller._viewportSizeConnection = nil
        end

        if not newCamera then
            applyViewportMetrics(nil)
            return
        end

        applyViewportMetrics(newCamera)

        controller._viewportSizeConnection = newCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
            if controller._destroyed then
                return
            end
            applyViewportMetrics(newCamera)
        end)
    end

    bindCamera(camera)

    controller._workspaceCameraConnection = Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
        if controller._destroyed then
            return
        end
        bindCamera(Workspace.CurrentCamera)
    end)

    controller:_applyVisualState({ forceStatusRefresh = true })
    controller:setTooltip(options.tooltip)

    local function trackConnection(connection)
        if connection ~= nil then
            table.insert(controller._connections, connection)
        end
    end

    local function updateVisibility()
        if controller._destroyed then
            return
        end

        local overlayInstance = getActiveOverlay()
        local overlayBlocking = overlayInstance and not overlayInstance:isComplete()
        local shouldShow = not overlayBlocking and not controller._loaderPending

        if dashboard then
            dashboard.Visible = shouldShow
        end
        if gui then
            gui.Enabled = shouldShow
        end
    end

    local overlayInstance = getActiveOverlay()
    if overlayInstance and not overlayInstance:isComplete() then
        trackConnection(overlayInstance:onCompleted(function()
            updateVisibility()
        end))
    end

    local refreshLoaderPending

    local function attachLoaderSignals(signals)
        if typeof(signals) ~= "table" then
            return
        end

        local function attach(signal)
            if typeof(signal) == "table" and typeof(signal.Connect) == "function" then
                local ok, connection = pcall(function()
                    return signal:Connect(function()
                        refreshLoaderPending()
                    end)
                end)
                if ok and connection then
                    trackConnection(connection)
                end
            end
        end

        attach(signals.onFetchStarted)
        attach(signals.onFetchCompleted)
        attach(signals.onFetchFailed)
        attach(signals.onAllComplete)
    end

    local loaderProgress, loaderSignals = getLoaderProgressAndSignals()
    controller._loaderPending = isLoaderInProgress(loaderProgress)

    refreshLoaderPending = function()
        local progress, signals = getLoaderProgressAndSignals()
        controller._loaderPending = isLoaderInProgress(progress)
        if signals and signals ~= loaderSignals then
            loaderSignals = signals
            attachLoaderSignals(signals)
        end
        updateVisibility()
    end

    if loaderSignals then
        attachLoaderSignals(loaderSignals)
    end

    updateVisibility()

    task.spawn(function()
        local observedOverlay = overlayInstance
        while not controller._destroyed do
            refreshLoaderPending()

            local currentOverlay = getActiveOverlay()
            if currentOverlay ~= observedOverlay then
                observedOverlay = currentOverlay
                if currentOverlay and not currentOverlay:isComplete() then
                    trackConnection(currentOverlay:onCompleted(function()
                        updateVisibility()
                    end))
                end
                updateVisibility()
            elseif currentOverlay and not currentOverlay:isComplete() and controller._loaderPending then
                updateVisibility()
            end

            if not controller._loaderPending and (not currentOverlay or currentOverlay:isComplete()) then
                task.wait(0.5)
            else
                task.wait(0.15)
            end
        end
    end)

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
local GuiService = game:GetService("GuiService")

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
    containerSize = UDim2.new(0, 960, 0, 580),
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
    errorPanel = {
        backgroundColor = Color3.fromRGB(44, 18, 32),
        backgroundTransparency = 0.12,
        strokeColor = Color3.fromRGB(255, 128, 164),
        strokeTransparency = 0.35,
        cornerRadius = UDim.new(0, 12),
        titleFont = Enum.Font.GothamBold,
        titleTextSize = 20,
        titleColor = Color3.fromRGB(255, 214, 228),
        summaryFont = Enum.Font.Gotham,
        summaryTextSize = 16,
        summaryColor = Color3.fromRGB(255, 226, 236),
        entryLabelFont = Enum.Font.GothamSemibold,
        entryLabelTextSize = 14,
        entryLabelColor = Color3.fromRGB(255, 174, 196),
        entryFont = Enum.Font.Code,
        entryTextSize = 14,
        entryTextColor = Color3.fromRGB(255, 236, 240),
        entryBackgroundColor = Color3.fromRGB(32, 16, 26),
        entryBackgroundTransparency = 0.2,
        entryCornerRadius = UDim.new(0, 8),
        sectionPadding = 10,
        sectionSpacing = 8,
        listSpacing = 8,
        tipFont = Enum.Font.Gotham,
        tipTextSize = 14,
        tipTextColor = Color3.fromRGB(255, 220, 232),
        badgeColor = Color3.fromRGB(255, 110, 150),
        badgeTransparency = 0.65,
        actionFont = Enum.Font.GothamSemibold,
        actionTextSize = 14,
        actionPrimaryColor = Color3.fromRGB(255, 128, 168),
        actionPrimaryTextColor = Color3.fromRGB(32, 16, 26),
        actionSecondaryColor = Color3.fromRGB(60, 30, 48),
        actionSecondaryTextColor = Color3.fromRGB(255, 226, 236),
        scrollBarColor = Color3.fromRGB(255, 156, 196),
        scrollBarTransparency = 0.55,
        icon = "rbxassetid://6031071051",
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
        minScale = 0.82,
        maxScale = 1.04,
    },
    backdropGradient = {
        color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(6, 12, 28)),
            ColorSequenceKeypoint.new(0.45, Color3.fromRGB(8, 18, 44)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(6, 12, 28)),
        }),
        transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.1),
            NumberSequenceKeypoint.new(0.5, 0.18),
            NumberSequenceKeypoint.new(1, 0.3),
        }),
        rotation = 65,
    },
    shadow = {
        padding = Vector2.new(120, 120),
        color = Color3.fromRGB(0, 32, 64),
        outerColor = Color3.fromRGB(0, 12, 24),
        transparency = 0.88,
        gradientInnerTransparency = 0.45,
    },
    hologramBadgeColor = Color3.fromRGB(0, 210, 255),
    hologramBadgeTransparency = 0.25,
    progressArcColor = Color3.fromRGB(0, 210, 255),
    progressArcTransparency = 0.4,
    dashboardMountSize = UDim2.new(0.94, 0, 0, 0),
    dashboardMaxWidth = 760,
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

local function createScreenGui(options)
    local gui = Instance.new("ScreenGui")
    gui.Name = options.name or "AutoParryLoadingOverlay"
    gui.DisplayOrder = 10_000
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.IgnoreGuiInset = true
    gui.Parent = options.parent or CoreGui
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
    backdrop.ClipsDescendants = false
    backdrop.Parent = gui

    local backdropGradientConfig = theme.backdropGradient or DEFAULT_THEME.backdropGradient
    local backdropGradient
    if backdropGradientConfig then
        backdropGradient = Instance.new("UIGradient")
        backdropGradient.Name = "BackdropGradient"
        backdropGradient.Color = backdropGradientConfig.color or DEFAULT_THEME.backdropGradient.color
        backdropGradient.Transparency = backdropGradientConfig.transparency or DEFAULT_THEME.backdropGradient.transparency
        backdropGradient.Rotation = backdropGradientConfig.rotation or DEFAULT_THEME.backdropGradient.rotation or 0
        backdropGradient.Parent = backdrop
    end

    local container = Instance.new("Frame")
    container.Name = "Container"
    container.AnchorPoint = Vector2.new(0.5, 0.5)
    container.Position = UDim2.new(0.5, 0, 0.5, 0)
    container.Size = theme.containerSize or DEFAULT_THEME.containerSize
    container.BackgroundColor3 = theme.containerBackgroundColor or Color3.fromRGB(10, 14, 28)
    container.BackgroundTransparency = theme.containerTransparency or DEFAULT_THEME.containerTransparency or 0
    container.BorderSizePixel = 0
    container.ClipsDescendants = false
    container.ZIndex = 2
    container.Parent = backdrop

    local containerScale = Instance.new("UIScale")
    containerScale.Name = "AdaptiveScale"
    containerScale.Scale = 1
    containerScale.Parent = container

    local shadowTheme = theme.shadow or DEFAULT_THEME.shadow
    local containerShadow
    local containerShadowGradient
    if shadowTheme then
        local paddingValue = shadowTheme.padding or DEFAULT_THEME.shadow.padding
        local paddingX, paddingY
        if typeof(paddingValue) == "Vector2" then
            paddingX = paddingValue.X
            paddingY = paddingValue.Y
        elseif typeof(paddingValue) == "number" then
            paddingX = paddingValue
            paddingY = paddingValue
        else
            paddingX = DEFAULT_THEME.shadow.padding.X
            paddingY = DEFAULT_THEME.shadow.padding.Y
        end

        containerShadow = Instance.new("Frame")
        containerShadow.Name = "Shadow"
        containerShadow.AnchorPoint = Vector2.new(0.5, 0.5)
        containerShadow.Position = UDim2.new(0.5, 0, 0.5, 0)
        containerShadow.Size = UDim2.new(
            1,
            paddingX,
            1,
            paddingY
        )
        containerShadow.BackgroundColor3 = shadowTheme.color or DEFAULT_THEME.shadow.color
        containerShadow.BackgroundTransparency = shadowTheme.transparency or DEFAULT_THEME.shadow.transparency
        containerShadow.BorderSizePixel = 0
        containerShadow.ZIndex = 0
        containerShadow.Parent = container

        local shadowCorner = Instance.new("UICorner")
        shadowCorner.CornerRadius = theme.containerCornerRadius or DEFAULT_THEME.containerCornerRadius
        shadowCorner.Parent = containerShadow

        local shadowGradient = Instance.new("UIGradient")
        shadowGradient.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, shadowTheme.color or DEFAULT_THEME.shadow.color),
            ColorSequenceKeypoint.new(1, shadowTheme.outerColor or DEFAULT_THEME.shadow.outerColor or DEFAULT_THEME.shadow.color),
        })
        shadowGradient.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, shadowTheme.gradientInnerTransparency or DEFAULT_THEME.shadow.gradientInnerTransparency or 0.5),
            NumberSequenceKeypoint.new(1, 1),
        })
        shadowGradient.Parent = containerShadow
        containerShadowGradient = shadowGradient
    end

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
    heroSubtitle.Text = "AutoParry calibrating advanced parry heuristics"
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
        "Adaptive timing engine",
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

    local errorPanel = Instance.new("Frame")
    errorPanel.Name = "ErrorPanel"
    errorPanel.BackgroundTransparency = (theme.errorPanel and theme.errorPanel.backgroundTransparency)
        or DEFAULT_THEME.errorPanel.backgroundTransparency
    errorPanel.BackgroundColor3 = (theme.errorPanel and theme.errorPanel.backgroundColor)
        or DEFAULT_THEME.errorPanel.backgroundColor
    errorPanel.BorderSizePixel = 0
    errorPanel.Visible = false
    errorPanel.AutomaticSize = Enum.AutomaticSize.Y
    errorPanel.Size = UDim2.new(1, 0, 0, 0)
    errorPanel.LayoutOrder = 4
    errorPanel.Parent = infoColumn

    local errorCorner = Instance.new("UICorner")
    errorCorner.CornerRadius = (theme.errorPanel and theme.errorPanel.cornerRadius)
        or DEFAULT_THEME.errorPanel.cornerRadius
    errorCorner.Parent = errorPanel

    local errorStroke = Instance.new("UIStroke")
    errorStroke.Thickness = 1.25
    errorStroke.Color = (theme.errorPanel and theme.errorPanel.strokeColor) or DEFAULT_THEME.errorPanel.strokeColor
    errorStroke.Transparency = (theme.errorPanel and theme.errorPanel.strokeTransparency)
        or DEFAULT_THEME.errorPanel.strokeTransparency
    errorStroke.Parent = errorPanel

    local errorPaddingValue = (theme.errorPanel and theme.errorPanel.sectionPadding)
        or DEFAULT_THEME.errorPanel.sectionPadding
        or 10
    local errorPadding = Instance.new("UIPadding")
    errorPadding.PaddingTop = UDim.new(0, errorPaddingValue)
    errorPadding.PaddingBottom = UDim.new(0, errorPaddingValue)
    errorPadding.PaddingLeft = UDim.new(0, errorPaddingValue)
    errorPadding.PaddingRight = UDim.new(0, errorPaddingValue)
    errorPadding.Parent = errorPanel

    local errorLayout = Instance.new("UIListLayout")
    errorLayout.FillDirection = Enum.FillDirection.Vertical
    errorLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    errorLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    errorLayout.SortOrder = Enum.SortOrder.LayoutOrder
    errorLayout.Padding = UDim.new(0, (theme.errorPanel and theme.errorPanel.sectionSpacing)
        or DEFAULT_THEME.errorPanel.sectionSpacing
        or 8)
    errorLayout.Parent = errorPanel

    local errorTitle = Instance.new("TextLabel")
    errorTitle.Name = "Title"
    errorTitle.BackgroundTransparency = 1
    errorTitle.AutomaticSize = Enum.AutomaticSize.Y
    errorTitle.Size = UDim2.new(1, 0, 0, 0)
    errorTitle.TextWrapped = true
    errorTitle.TextXAlignment = Enum.TextXAlignment.Left
    errorTitle.TextYAlignment = Enum.TextYAlignment.Top
    errorTitle.Font = (theme.errorPanel and theme.errorPanel.titleFont) or DEFAULT_THEME.errorPanel.titleFont
    errorTitle.TextSize = (theme.errorPanel and theme.errorPanel.titleTextSize) or DEFAULT_THEME.errorPanel.titleTextSize
    errorTitle.TextColor3 = (theme.errorPanel and theme.errorPanel.titleColor) or DEFAULT_THEME.errorPanel.titleColor
    errorTitle.Text = ""
    errorTitle.Visible = false
    errorTitle.LayoutOrder = 1
    errorTitle.Parent = errorPanel

    local errorSummary = Instance.new("TextLabel")
    errorSummary.Name = "Summary"
    errorSummary.BackgroundTransparency = 1
    errorSummary.AutomaticSize = Enum.AutomaticSize.Y
    errorSummary.Size = UDim2.new(1, 0, 0, 0)
    errorSummary.TextWrapped = true
    errorSummary.TextXAlignment = Enum.TextXAlignment.Left
    errorSummary.TextYAlignment = Enum.TextYAlignment.Top
    errorSummary.Font = (theme.errorPanel and theme.errorPanel.summaryFont) or DEFAULT_THEME.errorPanel.summaryFont
    errorSummary.TextSize = (theme.errorPanel and theme.errorPanel.summaryTextSize) or DEFAULT_THEME.errorPanel.summaryTextSize
    errorSummary.TextColor3 = (theme.errorPanel and theme.errorPanel.summaryColor) or DEFAULT_THEME.errorPanel.summaryColor
    errorSummary.Text = ""
    errorSummary.Visible = false
    errorSummary.LayoutOrder = 2
    errorSummary.Parent = errorPanel

    local errorLogScroll = Instance.new("ScrollingFrame")
    errorLogScroll.Name = "Details"
    errorLogScroll.BackgroundTransparency = 1
    errorLogScroll.BorderSizePixel = 0
    errorLogScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    errorLogScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    errorLogScroll.Size = UDim2.new(1, 0, 0, 140)
    errorLogScroll.Visible = false
    errorLogScroll.ScrollingDirection = Enum.ScrollingDirection.Y
    errorLogScroll.ScrollBarThickness = 6
    errorLogScroll.VerticalScrollBarInset = Enum.ScrollBarInset.Always
    errorLogScroll.ScrollBarImageColor3 = (theme.errorPanel and theme.errorPanel.scrollBarColor)
        or DEFAULT_THEME.errorPanel.scrollBarColor
    errorLogScroll.ScrollBarImageTransparency = (theme.errorPanel and theme.errorPanel.scrollBarTransparency)
        or DEFAULT_THEME.errorPanel.scrollBarTransparency
    errorLogScroll.LayoutOrder = 3
    errorLogScroll.Parent = errorPanel

    local errorLogPadding = Instance.new("UIPadding")
    errorLogPadding.PaddingLeft = UDim.new(0, 4)
    errorLogPadding.PaddingRight = UDim.new(0, 4)
    errorLogPadding.PaddingTop = UDim.new(0, 4)
    errorLogPadding.PaddingBottom = UDim.new(0, 4)
    errorLogPadding.Parent = errorLogScroll

    local errorLogList = Instance.new("Frame")
    errorLogList.Name = "List"
    errorLogList.BackgroundTransparency = 1
    errorLogList.AutomaticSize = Enum.AutomaticSize.Y
    errorLogList.Size = UDim2.new(1, -4, 0, 0)
    errorLogList.Parent = errorLogScroll

    local errorLogLayout = Instance.new("UIListLayout")
    errorLogLayout.FillDirection = Enum.FillDirection.Vertical
    errorLogLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    errorLogLayout.SortOrder = Enum.SortOrder.LayoutOrder
    errorLogLayout.Padding = UDim.new(0, (theme.errorPanel and theme.errorPanel.listSpacing)
        or DEFAULT_THEME.errorPanel.listSpacing
        or 8)
    errorLogLayout.Parent = errorLogList

    local errorActions = Instance.new("Frame")
    errorActions.Name = "ErrorActions"
    errorActions.BackgroundTransparency = 1
    errorActions.AutomaticSize = Enum.AutomaticSize.Y
    errorActions.Size = UDim2.new(1, 0, 0, 0)
    errorActions.Visible = false
    errorActions.LayoutOrder = 4
    errorActions.Parent = errorPanel

    local errorActionsLayout = Instance.new("UIListLayout")
    errorActionsLayout.FillDirection = Enum.FillDirection.Horizontal
    errorActionsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
    errorActionsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    errorActionsLayout.SortOrder = Enum.SortOrder.LayoutOrder
    errorActionsLayout.Padding = UDim.new(0, (theme.errorPanel and theme.errorPanel.sectionSpacing)
        or DEFAULT_THEME.errorPanel.sectionSpacing
        or 8)
    errorActionsLayout.Parent = errorActions

    local copyButton = Instance.new("TextButton")
    copyButton.Name = "CopyButton"
    copyButton.Text = "Copy error"
    copyButton.Font = (theme.errorPanel and theme.errorPanel.actionFont) or DEFAULT_THEME.errorPanel.actionFont
    copyButton.TextSize = (theme.errorPanel and theme.errorPanel.actionTextSize) or DEFAULT_THEME.errorPanel.actionTextSize
    copyButton.TextColor3 = (theme.errorPanel and theme.errorPanel.actionPrimaryTextColor)
        or DEFAULT_THEME.errorPanel.actionPrimaryTextColor
    copyButton.BackgroundColor3 = (theme.errorPanel and theme.errorPanel.actionPrimaryColor)
        or DEFAULT_THEME.errorPanel.actionPrimaryColor
    copyButton.AutoButtonColor = true
    copyButton.BackgroundTransparency = 0
    copyButton.Visible = false
    copyButton.Size = UDim2.new(0, 156, 0, 34)
    copyButton.LayoutOrder = 1
    copyButton.Parent = errorActions

    local copyCorner = Instance.new("UICorner")
    copyCorner.CornerRadius = (theme.errorPanel and theme.errorPanel.entryCornerRadius)
        or DEFAULT_THEME.errorPanel.entryCornerRadius
        or UDim.new(0, 8)
    copyCorner.Parent = copyButton

    local docsButton = Instance.new("TextButton")
    docsButton.Name = "DocsButton"
    docsButton.Text = "Open docs"
    docsButton.Font = (theme.errorPanel and theme.errorPanel.actionFont) or DEFAULT_THEME.errorPanel.actionFont
    docsButton.TextSize = (theme.errorPanel and theme.errorPanel.actionTextSize) or DEFAULT_THEME.errorPanel.actionTextSize
    docsButton.TextColor3 = (theme.errorPanel and theme.errorPanel.actionSecondaryTextColor)
        or DEFAULT_THEME.errorPanel.actionSecondaryTextColor
    docsButton.BackgroundColor3 = (theme.errorPanel and theme.errorPanel.actionSecondaryColor)
        or DEFAULT_THEME.errorPanel.actionSecondaryColor
    docsButton.AutoButtonColor = true
    docsButton.BackgroundTransparency = 0
    docsButton.Visible = false
    docsButton.Size = UDim2.new(0, 156, 0, 34)
    docsButton.LayoutOrder = 2
    docsButton.Parent = errorActions

    local docsCorner = Instance.new("UICorner")
    docsCorner.CornerRadius = (theme.errorPanel and theme.errorPanel.entryCornerRadius)
        or DEFAULT_THEME.errorPanel.entryCornerRadius
        or UDim.new(0, 8)
    docsCorner.Parent = docsButton

    local tipLabel = createTipLabel(infoColumn, theme)
    tipLabel.LayoutOrder = 5

    local actionsRow, actionsLayout = createActionsRow(infoColumn, theme)
    actionsRow.AnchorPoint = Vector2.new(0.5, 0)
    actionsRow.Position = UDim2.new(0.5, 0, 0, 0)
    actionsRow.LayoutOrder = 6

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
    dashboardSurface.ClipsDescendants = true
    dashboardSurface.ZIndex = 3
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
    dashboardMount.AutomaticSize = Enum.AutomaticSize.Y
    dashboardMount.Size = theme.dashboardMountSize or DEFAULT_THEME.dashboardMountSize
    dashboardMount.Position = UDim2.new(0.5, 0, 0.5, 0)
    dashboardMount.AnchorPoint = Vector2.new(0.5, 0.5)
    dashboardMount.ZIndex = 4
    dashboardMount.LayoutOrder = 1
    dashboardMount.Parent = dashboardSurface

    local dashboardMountPadding = Instance.new("UIPadding")
    dashboardMountPadding.PaddingTop = UDim.new(0, 12)
    dashboardMountPadding.PaddingBottom = UDim.new(0, 12)
    dashboardMountPadding.PaddingLeft = UDim.new(0, 18)
    dashboardMountPadding.PaddingRight = UDim.new(0, 18)
    dashboardMountPadding.Parent = dashboardMount

    local dashboardLayout = Instance.new("UIListLayout")
    dashboardLayout.FillDirection = Enum.FillDirection.Vertical
    dashboardLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    dashboardLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    dashboardLayout.SortOrder = Enum.SortOrder.LayoutOrder
    dashboardLayout.Padding = UDim.new(0, 18)
    dashboardLayout.Parent = dashboardMount

    local dashboardMountConstraint = Instance.new("UISizeConstraint")
    dashboardMountConstraint.MaxSize = Vector2.new(
        theme.dashboardMaxWidth or DEFAULT_THEME.dashboardMaxWidth or 760,
        math.huge
    )
    dashboardMountConstraint.MinSize = Vector2.new(360, 0)
    dashboardMountConstraint.Parent = dashboardMount

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
        _backdropGradient = backdropGradient,
        _container = container,
        _containerScale = containerScale,
        _containerShadow = containerShadow,
        _containerShadowGradient = containerShadowGradient,
        _spinner = spinner,
        _progressBar = progressBar,
        _progressFill = progressFill,
        _statusLabel = statusLabel,
        _tipLabel = tipLabel,
        _errorPanel = errorPanel,
        _errorPanelCorner = errorCorner,
        _errorPanelStroke = errorStroke,
        _errorTitle = errorTitle,
        _errorSummary = errorSummary,
        _errorLogScroll = errorLogScroll,
        _errorLogList = errorLogList,
        _errorLogLayout = errorLogLayout,
        _errorLogPadding = errorLogPadding,
        _errorActionsFrame = errorActions,
        _errorActionsLayout = errorActionsLayout,
        _errorCopyButton = copyButton,
        _errorDocsButton = docsButton,
        _errorCopyCorner = copyCorner,
        _errorDocsCorner = docsCorner,
        _errorEntryInstances = {},
        _errorActionConnections = {},
        _currentErrorDetails = nil,
        _errorCopyText = nil,
        _errorDocsLink = nil,
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
            heroPills[1] and heroPills[1].label and heroPills[1].label.Text or "Adaptive timing engine",
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
        _dashboardLayout = dashboardLayout,
        _containerGlow = glow,
        _containerGradient = containerGradient,
        _containerPadding = containerPadding,
        _containerLayout = containerLayout,
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
        _defaultContainerHeight = (container.Size.Y.Scale == 0 and container.Size.Y.Offset) or nil,
        _defaultContentSize = contentFrame.Size,
        _defaultHeroHeight = (heroFrame.Size.Y.Scale == 0 and heroFrame.Size.Y.Offset) or nil,
        _defaultInfoSize = infoColumn.Size,
        _defaultDashboardSize = dashboardColumn.Size,
        _layoutState = nil,
    }, LoadingOverlay)

    local function updateErrorCanvas()
        self:_updateErrorCanvasSize()
    end

    if self._errorLogLayout then
        local errorLayoutConnection = self._errorLogLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateErrorCanvas)
        table.insert(self._connections, errorLayoutConnection)
        updateErrorCanvas()
    end

    self:_restyleErrorButtons()

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
    local viewportHeight = viewportSize and viewportSize.Y or ((theme.containerSize and theme.containerSize.Y.Offset) or 360) + 260

    local minWidth = responsive.minWidth or 420
    local maxWidth = responsive.maxWidth or math.max(minWidth, math.floor(viewportWidth * 0.92))
    local columnSpacing = responsive.columnSpacing or 32
    local mediumWidth = responsive.mediumWidth or 600
    local largeWidth = responsive.largeWidth or 840

    local contentLayout = self._contentLayout
    local contentFrame = self._contentFrame
    local infoColumn = self._infoColumn
    local dashboardColumn = self._dashboardColumn
    local heroFrame = self._heroFrame

    if not infoColumn or not dashboardColumn or not contentFrame or not contentLayout then
        return
    end

    local containerPadding = self._containerPadding
    local paddingTop = (containerPadding and containerPadding.PaddingTop.Offset) or 0
    local paddingBottom = (containerPadding and containerPadding.PaddingBottom.Offset) or 0
    local paddingLeft = (containerPadding and containerPadding.PaddingLeft.Offset) or 0
    local paddingRight = (containerPadding and containerPadding.PaddingRight.Offset) or 0
    local containerLayout = self._containerLayout
    local sectionGap = (containerLayout and containerLayout.Padding.Offset) or 0

    local defaultHeight = self._defaultContainerHeight
        or (theme.containerSize and theme.containerSize.Y.Offset)
        or (DEFAULT_THEME.containerSize and DEFAULT_THEME.containerSize.Y.Offset)
        or 360
    local defaultHeroHeight = self._defaultHeroHeight or 160

    local horizontalMargin = math.max(48, math.floor(viewportWidth * 0.08))
    local usableWidth = viewportWidth - horizontalMargin
    local desiredWidth = math.floor(math.clamp(usableWidth, minWidth, maxWidth))
    if viewportWidth < minWidth then
        desiredWidth = math.max(320, viewportWidth - 24)
    end

    local verticalMargin = math.max(96, math.floor(viewportHeight * 0.14))
    local heightCap = viewportHeight - verticalMargin
    heightCap = math.max(defaultHeight, heightCap)

    local aspectRatio = viewportHeight > 0 and viewportWidth / viewportHeight or 1.6

    local mode
    if desiredWidth <= mediumWidth or aspectRatio < 1.1 then
        mode = "stacked"
    elseif desiredWidth <= largeWidth or aspectRatio < 1.35 then
        mode = "hybrid"
    else
        mode = "wide"
    end

    local heroHeight
    if mode == "stacked" then
        heroHeight = math.clamp(math.floor(desiredWidth * 0.26), 132, defaultHeroHeight + 48)
    elseif mode == "hybrid" then
        heroHeight = math.clamp(math.floor(desiredWidth * 0.22), 126, defaultHeroHeight + 24)
    else
        heroHeight = math.clamp(math.floor(desiredWidth * 0.2), 120, defaultHeroHeight)
    end

    heroHeight = math.max(120, heroHeight)

    local availableContentHeight = heightCap - paddingTop - paddingBottom - sectionGap - heroHeight
    availableContentHeight = math.max(220, availableContentHeight)

    local contentHeight
    local infoHeight
    local dashboardHeight
    local fillDirection
    local horizontalAlignment
    local verticalAlignment
    local padding
    local infoSize
    local dashboardSize

    local contentWidthPixels = math.max(0, desiredWidth - paddingLeft - paddingRight)

    if mode == "stacked" then
        local stackedGap = math.max(20, math.floor(columnSpacing * 0.75))
        local infoMin = 220
        local dashMin = 260

        infoHeight = math.max(infoMin, math.floor(availableContentHeight * 0.44))
        dashboardHeight = math.max(dashMin, availableContentHeight - infoHeight - stackedGap)

        if dashboardHeight < dashMin then
            local deficit = dashMin - dashboardHeight
            dashboardHeight = dashMin
            infoHeight = math.max(infoMin, infoHeight - deficit)
        end

        contentHeight = infoHeight + dashboardHeight + stackedGap

        local containerHeight = paddingTop + heroHeight + sectionGap + contentHeight + paddingBottom
        if containerHeight > heightCap then
            local overflow = containerHeight - heightCap
            local dashReduction = math.min(overflow * 0.6, math.max(0, dashboardHeight - dashMin))
            dashboardHeight -= dashReduction
            overflow -= dashReduction

            local infoReduction = math.min(overflow, math.max(0, infoHeight - infoMin))
            infoHeight -= infoReduction
            overflow -= infoReduction

            if overflow > 0 then
                heroHeight = math.max(120, heroHeight - overflow)
            end

            contentHeight = infoHeight + dashboardHeight + stackedGap
        end

        fillDirection = Enum.FillDirection.Vertical
        horizontalAlignment = Enum.HorizontalAlignment.Center
        verticalAlignment = Enum.VerticalAlignment.Top
        padding = stackedGap
        infoSize = UDim2.new(1, -math.max(24, math.floor(columnSpacing * 0.8)), 0, math.floor(infoHeight + 0.5))
        dashboardSize = UDim2.new(1, -math.max(24, math.floor(columnSpacing * 0.8)), 0, math.floor(dashboardHeight + 0.5))
    elseif mode == "hybrid" then
        local hybridPadding = math.max(18, math.floor(columnSpacing * 0.65))
        local targetColumnHeight = math.max(240, math.min(availableContentHeight, math.floor(availableContentHeight)))

        contentHeight = targetColumnHeight
        infoHeight = targetColumnHeight
        dashboardHeight = targetColumnHeight

        fillDirection = Enum.FillDirection.Horizontal
        horizontalAlignment = Enum.HorizontalAlignment.Center
        verticalAlignment = Enum.VerticalAlignment.Top
        padding = hybridPadding
        infoSize = UDim2.new(0.5, -hybridPadding, 0, math.floor(infoHeight + 0.5))
        dashboardSize = UDim2.new(0.5, -hybridPadding, 0, math.floor(dashboardHeight + 0.5))
    else
        local wideHeight = math.max(280, math.min(availableContentHeight, math.floor(availableContentHeight)))

        contentHeight = wideHeight
        infoHeight = wideHeight
        dashboardHeight = wideHeight

        fillDirection = Enum.FillDirection.Horizontal
        horizontalAlignment = Enum.HorizontalAlignment.Center
        verticalAlignment = Enum.VerticalAlignment.Top
        padding = columnSpacing
        infoSize = UDim2.new(0.45, -columnSpacing, 0, math.floor(infoHeight + 0.5))
        dashboardSize = UDim2.new(0.55, 0, 0, math.floor(dashboardHeight + 0.5))
    end

    local containerHeight = paddingTop + heroHeight + sectionGap + contentHeight + paddingBottom
    containerHeight = math.max(defaultHeight, math.min(containerHeight, heightCap))

    local target = {
        mode = mode,
        breakpoint = mode,
        width = math.floor(desiredWidth + 0.5),
        height = math.floor(containerHeight + 0.5),
        heroHeight = math.floor(heroHeight + 0.5),
        contentHeight = math.floor(contentHeight + 0.5),
        infoHeight = math.floor(infoHeight + 0.5),
        dashboardHeight = math.floor(dashboardHeight + 0.5),
        fillDirection = fillDirection,
        horizontalAlignment = horizontalAlignment,
        verticalAlignment = verticalAlignment,
        padding = padding,
        contentSize = UDim2.new(1, 0, 0, math.floor(contentHeight + 0.5)),
        infoSize = infoSize,
        dashboardSize = dashboardSize,
        viewportWidth = math.floor(viewportWidth + 0.5),
        viewportHeight = (viewportSize and math.floor(viewportHeight + 0.5)) or scaledHeight,
    }

    if contentLayout then
        contentLayout.FillDirection = target.fillDirection
        contentLayout.HorizontalAlignment = target.horizontalAlignment
        contentLayout.VerticalAlignment = target.verticalAlignment
        contentLayout.Padding = UDim.new(0, target.padding)
    end

    if contentFrame then
        contentFrame.Size = target.contentSize
    end

    if infoColumn then
        infoColumn.Size = target.infoSize
    end

    if dashboardColumn then
        dashboardColumn.Size = target.dashboardSize
    end

    if heroFrame then
        heroFrame.Size = UDim2.new(1, 0, 0, target.heroHeight)
    end

    container.Size = UDim2.new(0, target.width, 0, target.height)

    local dashboardWidth
    if target.fillDirection == Enum.FillDirection.Vertical then
        dashboardWidth = math.max(0, contentWidthPixels + (target.dashboardSize and target.dashboardSize.X.Offset or 0))
    else
        local scale = target.dashboardSize and target.dashboardSize.X.Scale or 0
        local offset = target.dashboardSize and target.dashboardSize.X.Offset or 0
        dashboardWidth = math.max(0, math.floor(contentWidthPixels * scale + offset + 0.5))
    end

    target.contentWidth = contentWidthPixels
    target.dashboardWidth = dashboardWidth

    local scale = 1
    if viewportWidth and viewportWidth > 0 then
        local widthAllowance = viewportWidth - horizontalMargin * 0.5
        if widthAllowance > 0 then
            scale = math.min(scale, widthAllowance / target.width)
        end
    end
    if viewportHeight and viewportHeight > 0 then
        local heightAllowance = viewportHeight - verticalMargin * 0.5
        if heightAllowance > 0 then
            scale = math.min(scale, heightAllowance / target.height)
        end
    end

    local minScale = responsive.minScale or DEFAULT_THEME.responsive.minScale or 0.82
    local maxScale = responsive.maxScale or DEFAULT_THEME.responsive.maxScale or 1
    scale = math.clamp(scale, minScale, maxScale)

    if self._containerScale then
        self._containerScale.Scale = scale
    end

    local scaledWidth = math.floor(target.width * scale + 0.5)
    local scaledHeight = math.floor(target.height * scale + 0.5)
    local scaledDashboardWidth = math.floor(dashboardWidth * scale + 0.5)
    local scaledDashboardHeight = math.floor(target.dashboardHeight * scale + 0.5)
    local scaledContentWidth = math.floor(contentWidthPixels * scale + 0.5)

    local layoutBounds = {
        mode = target.mode,
        breakpoint = target.mode,
        containerWidth = scaledWidth,
        containerHeight = scaledHeight,
        width = scaledWidth,
        height = scaledHeight,
        dashboardWidth = scaledDashboardWidth,
        dashboardHeight = scaledDashboardHeight,
        contentWidth = scaledContentWidth,
        heroHeight = math.floor(target.heroHeight * scale + 0.5),
        infoHeight = math.floor(target.infoHeight * scale + 0.5),
        contentHeight = math.floor(target.contentHeight * scale + 0.5),
        viewportWidth = viewportWidth and math.floor(viewportWidth + 0.5) or scaledWidth,
        viewportHeight = viewportSize and math.floor(viewportHeight + 0.5) or nil,
        scale = scale,
        raw = target,
        rawWidth = target.width,
        rawHeight = target.height,
    }

    if self._dashboard and self._dashboard.updateLayout then
        self._dashboard:updateLayout(layoutBounds)
    end

    self._layoutState = layoutBounds
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
        if dashboard.updateLayout and self._layoutState then
            dashboard:updateLayout(self._layoutState)
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

function LoadingOverlay:_updateErrorCanvasSize()
    if not self._errorLogLayout or not self._errorLogScroll then
        return
    end

    local paddingBottom = 0
    if self._errorLogPadding and self._errorLogPadding.PaddingBottom then
        paddingBottom = self._errorLogPadding.PaddingBottom.Offset
    end

    self._errorLogScroll.CanvasSize = UDim2.new(0, 0, 0, self._errorLogLayout.AbsoluteContentSize.Y + paddingBottom)
end

function LoadingOverlay:_restyleErrorButtons()
    local copyButton = self._errorCopyButton
    local docsButton = self._errorDocsButton
    if not copyButton and not docsButton then
        return
    end

    local theme = self._theme or DEFAULT_THEME
    local errorTheme = theme.errorPanel or DEFAULT_THEME.errorPanel
    local cornerRadius = errorTheme.entryCornerRadius or DEFAULT_THEME.errorPanel.entryCornerRadius or UDim.new(0, 8)

    local function applyStyle(button, corner, variant)
        if not button then
            return
        end
        button.Font = errorTheme.actionFont or DEFAULT_THEME.errorPanel.actionFont
        button.TextSize = errorTheme.actionTextSize or DEFAULT_THEME.errorPanel.actionTextSize
        if variant == "secondary" then
            button.BackgroundColor3 = errorTheme.actionSecondaryColor or DEFAULT_THEME.errorPanel.actionSecondaryColor
            button.TextColor3 = errorTheme.actionSecondaryTextColor or DEFAULT_THEME.errorPanel.actionSecondaryTextColor
        else
            button.BackgroundColor3 = errorTheme.actionPrimaryColor or DEFAULT_THEME.errorPanel.actionPrimaryColor
            button.TextColor3 = errorTheme.actionPrimaryTextColor or DEFAULT_THEME.errorPanel.actionPrimaryTextColor
        end
        if corner then
            corner.CornerRadius = cornerRadius
        end
    end

    applyStyle(copyButton, self._errorCopyCorner, "primary")
    applyStyle(docsButton, self._errorDocsCorner, "secondary")

    if self._errorActionsLayout then
        self._errorActionsLayout.Padding = UDim.new(0, errorTheme.sectionSpacing or DEFAULT_THEME.errorPanel.sectionSpacing or 8)
    end
end

function LoadingOverlay:_clearErrorDetails()
    disconnectConnections(self._errorActionConnections)
    self._errorActionConnections = {}

    if self._errorEntryInstances then
        for _, item in ipairs(self._errorEntryInstances) do
            if item and item.Destroy then
                item:Destroy()
            end
        end
    end
    self._errorEntryInstances = {}

    if self._errorLogList then
        for _, child in ipairs(self._errorLogList:GetChildren()) do
            if child:IsA("GuiObject") then
                child:Destroy()
            end
        end
    end

    if self._errorTitle then
        self._errorTitle.Text = ""
        self._errorTitle.Visible = false
    end

    if self._errorSummary then
        self._errorSummary.Text = ""
        self._errorSummary.Visible = false
    end

    if self._errorLogScroll then
        self._errorLogScroll.Visible = false
    end

    if self._errorActionsFrame then
        self._errorActionsFrame.Visible = false
    end

    if self._errorPanel then
        self._errorPanel.Visible = false
    end

    self._errorCopyText = nil
    self._errorDocsLink = nil

    self:_updateErrorCanvasSize()
end

function LoadingOverlay:_updateErrorActions(detail)
    if not self._errorActionsFrame then
        return
    end

    disconnectConnections(self._errorActionConnections)
    self._errorActionConnections = {}

    local copyButton = self._errorCopyButton
    local docsButton = self._errorDocsButton

    local hasCopy = detail and typeof(detail.copyText) == "string" and detail.copyText ~= ""
    local copyAllowed = hasCopy and typeof(setclipboard) == "function"
    self._errorCopyText = hasCopy and detail.copyText or nil

    if copyButton then
        copyButton.Visible = hasCopy
        copyButton.Active = copyAllowed
        copyButton.AutoButtonColor = copyAllowed
        copyButton.TextTransparency = (hasCopy and not copyAllowed) and 0.35 or 0
        local copyLabel = detail and detail.copyLabel or "Copy error"
        if not copyLabel or copyLabel == "" then
            copyLabel = "Copy error"
        end
        copyButton.Text = copyLabel

        if hasCopy and copyAllowed then
            local connection = copyButton.MouseButton1Click:Connect(function()
                if self._destroyed or not self._errorCopyText then
                    return
                end

                local ok, err = pcall(setclipboard, self._errorCopyText)
                if not ok then
                    warn("AutoParry: failed to copy error payload", err)
                    return
                end

                local successLabel = (detail and detail.copySuccessLabel) or "Copied!"
                copyButton.Text = successLabel

                task.delay(2.5, function()
                    if self._destroyed or self._errorCopyButton ~= copyButton or not copyButton.Visible then
                        return
                    end
                    local resetLabel = (detail and detail.copyLabel) or "Copy error"
                    if not resetLabel or resetLabel == "" then
                        resetLabel = "Copy error"
                    end
                    copyButton.Text = resetLabel
                end)
            end)
            table.insert(self._errorActionConnections, connection)
        end
    end

    local hasDocs = detail and typeof(detail.docsLink) == "string" and detail.docsLink ~= ""
    self._errorDocsLink = hasDocs and detail.docsLink or nil

    if docsButton then
        docsButton.Visible = hasDocs
        docsButton.Active = hasDocs
        docsButton.AutoButtonColor = hasDocs
        docsButton.TextTransparency = hasDocs and 0 or 0.35
        local docsLabel = detail and detail.docsLabel or "Open docs"
        if not docsLabel or docsLabel == "" then
            docsLabel = "Open docs"
        end
        docsButton.Text = docsLabel

        if hasDocs then
            local connection = docsButton.MouseButton1Click:Connect(function()
                if self._destroyed or not self._errorDocsLink then
                    return
                end

                local ok, err = pcall(function()
                    if GuiService and GuiService.OpenBrowserWindow then
                        GuiService:OpenBrowserWindow(self._errorDocsLink)
                    else
                        warn("AutoParry: GuiService.OpenBrowserWindow unavailable")
                    end
                end)
                if not ok then
                    warn("AutoParry: failed to open documentation link", err)
                end
            end)
            table.insert(self._errorActionConnections, connection)
        end
    end

    local hasActions = false
    if copyButton and copyButton.Visible then
        hasActions = true
    end
    if docsButton and docsButton.Visible then
        hasActions = true
    end

    self._errorActionsFrame.Visible = hasActions

    self:_restyleErrorButtons()
end

local function ensureArray(value)
    if typeof(value) ~= "table" then
        return {}
    end
    local result = {}
    for index, item in ipairs(value) do
        result[index] = item
    end
    return result
end

local function coerceEntry(value)
    if value == nil then
        return nil
    end
    if typeof(value) ~= "table" then
        return { value = value }
    end
    return value
end

function LoadingOverlay:_renderErrorDetails(detail)
    if not self._errorPanel then
        return
    end

    local visible = detail.visible ~= false
    if detail.kind and detail.kind ~= "error" and detail.force ~= true then
        visible = false
    end

    if not visible then
        self:_clearErrorDetails()
        return
    end

    self._errorPanel.Visible = true

    if self._errorTitle then
        local title = detail.title or detail.name or detail.message or "AutoParry error"
        self._errorTitle.Text = title
        self._errorTitle.Visible = title ~= nil and title ~= ""
    end

    if self._errorSummary then
        local summary = detail.summary or detail.description or detail.message or ""
        self._errorSummary.Text = summary
        self._errorSummary.Visible = summary ~= nil and summary ~= ""
    end

    if not self._errorLogList or not self._errorLogScroll then
        self:_updateErrorActions(detail)
        return
    end

    for _, child in ipairs(self._errorLogList:GetChildren()) do
        if child:IsA("GuiObject") then
            child:Destroy()
        end
    end

    self._errorEntryInstances = {}

    local aggregated = {}

    for _, entry in ipairs(ensureArray(detail.entries)) do
        table.insert(aggregated, coerceEntry(entry))
    end

    if typeof(detail.logs) == "table" then
        for _, entry in ipairs(detail.logs) do
            if typeof(entry) == "table" then
                table.insert(aggregated, coerceEntry(entry))
            elseif entry ~= nil then
                table.insert(aggregated, { label = "Log", value = entry })
            end
        end
    elseif detail.log ~= nil then
        if typeof(detail.log) == "table" then
            table.insert(aggregated, coerceEntry(detail.log))
        else
            table.insert(aggregated, { label = "Log", value = detail.log })
        end
    end

    if typeof(detail.tips) == "table" then
        for _, tip in ipairs(detail.tips) do
            table.insert(aggregated, { label = "Tip", value = tip, kind = "tip" })
        end
    elseif detail.tip ~= nil then
        table.insert(aggregated, { label = "Tip", value = detail.tip, kind = "tip" })
    end

    if detail.stack or detail.stackTrace then
        table.insert(aggregated, { label = "Stack trace", value = detail.stackTrace or detail.stack, kind = "stack" })
    end

    if detail.reason and detail.includeReason ~= false then
        table.insert(aggregated, { label = "Reason", value = detail.reason })
    end

    if detail.payloadText then
        table.insert(aggregated, { label = "Payload", value = detail.payloadText, kind = "stack" })
    end

    local theme = self._theme or DEFAULT_THEME
    local errorTheme = theme.errorPanel or DEFAULT_THEME.errorPanel

    local visibleEntries = 0

    for index, entry in ipairs(aggregated) do
        entry = coerceEntry(entry)
        if entry then
            local value = entry.value or entry.text or entry.message or entry[1]
            if value ~= nil then
                if typeof(value) ~= "string" then
                    value = tostring(value)
                end
                value = value:gsub("%s+$", "")
                if value ~= "" then
                    local frame = Instance.new("Frame")
                    frame.Name = string.format("Entry%d", index)
                    frame.BackgroundTransparency = errorTheme.entryBackgroundTransparency or DEFAULT_THEME.errorPanel.entryBackgroundTransparency
                    frame.BackgroundColor3 = errorTheme.entryBackgroundColor or DEFAULT_THEME.errorPanel.entryBackgroundColor
                    frame.BorderSizePixel = 0
                    frame.AutomaticSize = Enum.AutomaticSize.Y
                    frame.Size = UDim2.new(1, 0, 0, 0)
                    frame.LayoutOrder = index
                    frame.Parent = self._errorLogList

                    local corner = Instance.new("UICorner")
                    corner.CornerRadius = errorTheme.entryCornerRadius or DEFAULT_THEME.errorPanel.entryCornerRadius or UDim.new(0, 8)
                    corner.Parent = frame

                    local padding = Instance.new("UIPadding")
                    padding.PaddingTop = UDim.new(0, 8)
                    padding.PaddingBottom = UDim.new(0, 8)
                    padding.PaddingLeft = UDim.new(0, 10)
                    padding.PaddingRight = UDim.new(0, 10)
                    padding.Parent = frame

                    local layout = Instance.new("UIListLayout")
                    layout.FillDirection = Enum.FillDirection.Vertical
                    layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
                    layout.SortOrder = Enum.SortOrder.LayoutOrder
                    layout.Padding = UDim.new(0, entry.label and entry.label ~= "" and 4 or 0)
                    layout.Parent = frame

                    if entry.label and entry.label ~= "" then
                        local labelText = Instance.new("TextLabel")
                        labelText.Name = "Label"
                        labelText.BackgroundTransparency = 1
                        labelText.AutomaticSize = Enum.AutomaticSize.Y
                        labelText.Size = UDim2.new(1, 0, 0, 0)
                        labelText.Font = errorTheme.entryLabelFont or DEFAULT_THEME.errorPanel.entryLabelFont
                        labelText.TextSize = errorTheme.entryLabelTextSize or DEFAULT_THEME.errorPanel.entryLabelTextSize
                        labelText.TextColor3 = errorTheme.entryLabelColor or DEFAULT_THEME.errorPanel.entryLabelColor
                        labelText.TextXAlignment = Enum.TextXAlignment.Left
                        labelText.TextYAlignment = Enum.TextYAlignment.Top
                        labelText.TextWrapped = true
                        labelText.Text = string.upper(entry.label)
                        labelText.LayoutOrder = 1
                        labelText.Parent = frame
                    end

                    local body = Instance.new("TextLabel")
                    body.Name = "Body"
                    body.BackgroundTransparency = 1
                    body.AutomaticSize = Enum.AutomaticSize.Y
                    body.Size = UDim2.new(1, 0, 0, 0)
                    body.Font = (entry.kind == "stack" and Enum.Font.Code)
                        or errorTheme.entryFont
                        or DEFAULT_THEME.errorPanel.entryFont
                    body.TextSize = errorTheme.entryTextSize or DEFAULT_THEME.errorPanel.entryTextSize
                    body.TextColor3 = errorTheme.entryTextColor or DEFAULT_THEME.errorPanel.entryTextColor
                    body.TextXAlignment = Enum.TextXAlignment.Left
                    body.TextYAlignment = Enum.TextYAlignment.Top
                    body.TextWrapped = true
                    body.RichText = entry.richText == true
                    body.Text = value
                    body.LayoutOrder = 2
                    body.Parent = frame

                    table.insert(self._errorEntryInstances, frame)
                    visibleEntries += 1
                end
            end
        end
    end

    self._errorLogScroll.Visible = visibleEntries > 0

    self:_updateErrorActions(detail)
    self:_updateErrorCanvasSize()

    local camera = Workspace.CurrentCamera
    if camera then
        self:_applyResponsiveLayout(camera.ViewportSize)
    else
        self:_applyResponsiveLayout(nil)
    end
end

function LoadingOverlay:setErrorDetails(detail)
    if self._destroyed then
        return
    end

    if detail == nil then
        self._currentErrorDetails = nil
        self:_clearErrorDetails()
        local camera = Workspace.CurrentCamera
        if camera or self._layoutState then
            self:_applyResponsiveLayout(camera and camera.ViewportSize or nil)
        end
        return
    end

    if typeof(detail) ~= "table" then
        self._currentErrorDetails = nil
        self:_clearErrorDetails()
        return
    end

    self._currentErrorDetails = Util.deepCopy(detail)
    self:_renderErrorDetails(detail)
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

function LoadingOverlay:setStatus(status, options)
    if self._destroyed then
        return
    end
    options = options or {}

    local detail = options.detail
    local text = status
    local dashboardPayload

    if typeof(status) == "table" then
        detail = detail or status.detail or status.details
        text = status.text or status.message or ""
        if options.force == nil and status.force ~= nil then
            options.force = status.force
        end
        dashboardPayload = Util.deepCopy(status)
        dashboardPayload.text = dashboardPayload.text or text
        dashboardPayload.detail = dashboardPayload.detail or detail
    else
        text = text or ""
        dashboardPayload = { text = text, detail = detail }
    end

    local label = self._statusLabel
    local detailChanged = detail ~= nil or (self._currentErrorDetails ~= nil and detail == nil)
    if label.Text == text and not options.force and not detailChanged then
        if self._dashboard and self._dashboard.setStatusText then
            self._dashboard:setStatusText(dashboardPayload)
        end
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
        self._dashboard:setStatusText(dashboardPayload)
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
    if self._backdropGradient then
        local backdropTheme = theme.backdropGradient or DEFAULT_THEME.backdropGradient
        if backdropTheme then
            self._backdropGradient.Color = backdropTheme.color or DEFAULT_THEME.backdropGradient.color
            self._backdropGradient.Transparency = backdropTheme.transparency or DEFAULT_THEME.backdropGradient.transparency
            self._backdropGradient.Rotation = backdropTheme.rotation or DEFAULT_THEME.backdropGradient.rotation or 0
        end
    end
    if self._container then
        self._container.Size = theme.containerSize or DEFAULT_THEME.containerSize
        self._container.BackgroundColor3 = theme.containerBackgroundColor or Color3.fromRGB(10, 14, 28)
        self._container.BackgroundTransparency = theme.containerTransparency or DEFAULT_THEME.containerTransparency or 0
    end
    if self._containerShadow then
        local shadow = theme.shadow or DEFAULT_THEME.shadow
        local paddingValue = shadow and shadow.padding or DEFAULT_THEME.shadow.padding
        local paddingX, paddingY
        if typeof(paddingValue) == "Vector2" then
            paddingX, paddingY = paddingValue.X, paddingValue.Y
        elseif typeof(paddingValue) == "number" then
            paddingX, paddingY = paddingValue, paddingValue
        else
            paddingX, paddingY = DEFAULT_THEME.shadow.padding.X, DEFAULT_THEME.shadow.padding.Y
        end
        self._containerShadow.Size = UDim2.new(1, paddingX, 1, paddingY)
        self._containerShadow.BackgroundColor3 = (shadow and shadow.color) or DEFAULT_THEME.shadow.color
        self._containerShadow.BackgroundTransparency = (shadow and shadow.transparency) or DEFAULT_THEME.shadow.transparency
        if self._containerShadowGradient then
            self._containerShadowGradient.Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0, (shadow and shadow.color) or DEFAULT_THEME.shadow.color),
                ColorSequenceKeypoint.new(1, (shadow and shadow.outerColor) or DEFAULT_THEME.shadow.outerColor or DEFAULT_THEME.shadow.color),
            })
            self._containerShadowGradient.Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, (shadow and shadow.gradientInnerTransparency) or DEFAULT_THEME.shadow.gradientInnerTransparency or 0.5),
                NumberSequenceKeypoint.new(1, 1),
            })
        end
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
    local errorTheme = theme.errorPanel or DEFAULT_THEME.errorPanel
    if self._errorPanel then
        self._errorPanel.BackgroundColor3 = errorTheme.backgroundColor or DEFAULT_THEME.errorPanel.backgroundColor
        self._errorPanel.BackgroundTransparency = errorTheme.backgroundTransparency or DEFAULT_THEME.errorPanel.backgroundTransparency
    end
    if self._errorPanelCorner then
        self._errorPanelCorner.CornerRadius = errorTheme.cornerRadius or DEFAULT_THEME.errorPanel.cornerRadius
    end
    if self._errorPanelStroke then
        self._errorPanelStroke.Color = errorTheme.strokeColor or DEFAULT_THEME.errorPanel.strokeColor
        self._errorPanelStroke.Transparency = errorTheme.strokeTransparency or DEFAULT_THEME.errorPanel.strokeTransparency
    end
    if self._errorTitle then
        self._errorTitle.Font = errorTheme.titleFont or DEFAULT_THEME.errorPanel.titleFont
        self._errorTitle.TextSize = errorTheme.titleTextSize or DEFAULT_THEME.errorPanel.titleTextSize
        self._errorTitle.TextColor3 = errorTheme.titleColor or DEFAULT_THEME.errorPanel.titleColor
        if self._currentErrorDetails and self._currentErrorDetails.title then
            self._errorTitle.Text = self._currentErrorDetails.title
        end
    end
    if self._errorSummary then
        self._errorSummary.Font = errorTheme.summaryFont or DEFAULT_THEME.errorPanel.summaryFont
        self._errorSummary.TextSize = errorTheme.summaryTextSize or DEFAULT_THEME.errorPanel.summaryTextSize
        self._errorSummary.TextColor3 = errorTheme.summaryColor or DEFAULT_THEME.errorPanel.summaryColor
    end
    if self._errorLogScroll then
        self._errorLogScroll.ScrollBarImageColor3 = errorTheme.scrollBarColor or DEFAULT_THEME.errorPanel.scrollBarColor
        self._errorLogScroll.ScrollBarImageTransparency = errorTheme.scrollBarTransparency or DEFAULT_THEME.errorPanel.scrollBarTransparency
    end
    if self._errorLogLayout then
        self._errorLogLayout.Padding = UDim.new(0, errorTheme.listSpacing or DEFAULT_THEME.errorPanel.listSpacing or 8)
    end
    if self._errorLogPadding then
        local pad = errorTheme.sectionPadding or DEFAULT_THEME.errorPanel.sectionPadding or 10
        self._errorLogPadding.PaddingTop = UDim.new(0, pad)
        self._errorLogPadding.PaddingBottom = UDim.new(0, pad)
        self._errorLogPadding.PaddingLeft = UDim.new(0, pad)
        self._errorLogPadding.PaddingRight = UDim.new(0, pad)
    end
    self:_restyleErrorButtons()
    if self._currentErrorDetails then
        self:_renderErrorDetails(Util.deepCopy(self._currentErrorDetails))
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

    disconnectConnections(self._errorActionConnections)
    self._errorActionConnections = nil
    if self._errorEntryInstances then
        for _, item in ipairs(self._errorEntryInstances) do
            if item and item.Destroy then
                item:Destroy()
            end
        end
    end
    self._errorEntryInstances = nil
    self._currentErrorDetails = nil
    self._errorCopyText = nil
    self._errorDocsLink = nil

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
        title = "Player Readiness",
        description = "Waiting for your avatar and character rig.",
        tooltip = "Ensures the LocalPlayer and character are available before continuing.",
    },
    {
        id = "remotes",
        title = "Parry Input",
        description = "Arming the local F-key press.",
        tooltip = "Ensures the virtual F-key input is configured and ready to trigger.",
    },
    {
        id = "success",
        title = "Success Feedback",
        description = "Listening for parry confirmation events.",
        tooltip = "Subscribes to ParrySuccess events so AutoParry can track every confirmation.",
    },
    {
        id = "balls",
        title = "Ball Tracking",
        description = "Tracking live balls for prediction.",
        tooltip = "Validates the balls folder to keep projectile telemetry up to date.",
    },
}

local DEFAULT_THEME = {
    accentColor = Color3.fromRGB(112, 198, 255),
    backgroundTransparency = 1,
    cardColor = Color3.fromRGB(20, 24, 32),
    cardTransparency = 0.02,
    cardStrokeColor = Color3.fromRGB(76, 118, 190),
    cardStrokeTransparency = 0.32,
    connectorColor = Color3.fromRGB(112, 198, 255),
    connectorTransparency = 0.35,
    pendingColor = Color3.fromRGB(142, 152, 188),
    activeColor = Color3.fromRGB(112, 198, 255),
    okColor = Color3.fromRGB(118, 228, 182),
    warningColor = Color3.fromRGB(255, 198, 110),
    failedColor = Color3.fromRGB(248, 110, 128),
    tooltipBackground = Color3.fromRGB(18, 22, 30),
    tooltipTransparency = 0.12,
    tooltipTextColor = Color3.fromRGB(220, 232, 252),
    titleFont = Enum.Font.GothamSemibold,
    titleTextSize = 24,
    subtitleFont = Enum.Font.Gotham,
    subtitleTextSize = 16,
    stepTitleFont = Enum.Font.GothamSemibold,
    stepTitleTextSize = 17,
    stepStatusFont = Enum.Font.Gotham,
    stepStatusTextSize = 14,
    tooltipFont = Enum.Font.Gotham,
    tooltipTextSize = 14,
    actionFont = Enum.Font.GothamSemibold,
    actionTextSize = 16,
    actionHeight = 40,
    actionCorner = UDim.new(0, 10),
    actionPrimaryColor = Color3.fromRGB(112, 198, 255),
    actionPrimaryTextColor = Color3.fromRGB(12, 16, 26),
    actionSecondaryColor = Color3.fromRGB(40, 46, 62),
    actionSecondaryTextColor = Color3.fromRGB(226, 236, 252),
    insights = {
        backgroundColor = Color3.fromRGB(14, 18, 26),
        backgroundTransparency = 0.07,
        strokeColor = Color3.fromRGB(66, 102, 172),
        strokeTransparency = 0.38,
        gradient = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(24, 30, 44)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(12, 16, 26))
        }),
        gradientTransparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.8),
            NumberSequenceKeypoint.new(1, 0.25),
        }),
        gradientRotation = 120,
        paddingTop = 18,
        paddingBottom = 18,
        paddingHorizontal = 20,
        paddingBetween = 16,
    },
    logo = {
        width = 240,
        text = "AutoParry",
        font = Enum.Font.GothamBlack,
        textSize = 28,
        textGradient = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(82, 156, 255)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(88, 206, 157)),
        }),
        textGradientRotation = 18,
        textStrokeColor = Color3.fromRGB(10, 14, 26),
        textStrokeTransparency = 0.65,
        primaryColor = Color3.fromRGB(235, 240, 248),
        tagline = "Precision parry automation",
        taglineFont = Enum.Font.Gotham,
        taglineTextSize = 15,
        taglineColor = Color3.fromRGB(188, 202, 230),
        taglineTransparency = 0.05,
        backgroundColor = Color3.fromRGB(24, 28, 36),
        backgroundTransparency = 0.1,
        strokeColor = Color3.fromRGB(94, 148, 214),
        strokeTransparency = 0.45,
        gradient = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(30, 36, 48)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(82, 156, 255)),
        }),
        gradientTransparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.6),
            NumberSequenceKeypoint.new(0.5, 0.3),
            NumberSequenceKeypoint.new(1, 0.18),
        }),
        gradientRotation = 115,
        glyphImage = "rbxassetid://12148062841",
        glyphColor = Color3.fromRGB(82, 156, 255),
        glyphTransparency = 0.15,
    },
    layout = {
        widthScale = 0.96,
        maxWidth = 720,
        minWidth = 420,
        horizontalPadding = 16,
    },
    iconography = {
        pending = "rbxassetid://6031071050",
        active = "rbxassetid://6031075929",
        check = "rbxassetid://6031068421",
        warning = "rbxassetid://6031071051",
        error = "rbxassetid://6031094678",
    },
    telemetry = {
        titleFont = Enum.Font.GothamSemibold,
        titleTextSize = 16,
        valueFont = Enum.Font.GothamBold,
        valueTextSize = 26,
        labelFont = Enum.Font.Gotham,
        labelTextSize = 13,
        cardColor = Color3.fromRGB(26, 30, 40),
        cardTransparency = 0.05,
        cardStrokeColor = Color3.fromRGB(94, 148, 214),
        cardStrokeTransparency = 0.45,
        accentColor = Color3.fromRGB(82, 156, 255),
        valueColor = Color3.fromRGB(235, 245, 255),
        hintColor = Color3.fromRGB(170, 192, 230),
        sparkColor = Color3.fromRGB(112, 198, 255),
        sparkTransparency = 0.25,
        cellSize = UDim2.new(0.5, -12, 0, 104),
        cellPadding = UDim2.new(0, 12, 0, 12),
        maxColumns = 2,
    },
    controls = {
        headerFont = Enum.Font.GothamSemibold,
        headerTextSize = 16,
        headerColor = Color3.fromRGB(226, 232, 244),
        descriptionFont = Enum.Font.Gotham,
        descriptionTextSize = 14,
        descriptionColor = Color3.fromRGB(178, 190, 214),
        toggleOnColor = Color3.fromRGB(82, 156, 255),
        toggleOffColor = Color3.fromRGB(40, 46, 62),
        toggleOnTextColor = Color3.fromRGB(12, 16, 26),
        toggleOffTextColor = Color3.fromRGB(226, 232, 244),
        toggleCorner = UDim.new(0, 12),
        toggleStrokeColor = Color3.fromRGB(82, 156, 255),
        toggleStrokeTransparency = 0.55,
        toggleBadgeFont = Enum.Font.GothamSemibold,
        toggleBadgeSize = 13,
        toggleBadgeColor = Color3.fromRGB(188, 202, 230),
        sectionBackground = Color3.fromRGB(24, 28, 36),
        sectionTransparency = 0.05,
        sectionStrokeColor = Color3.fromRGB(82, 156, 255),
        sectionStrokeTransparency = 0.5,
        sectionGradient = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(20, 24, 32)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(82, 156, 255)),
        }),
        sectionGradientTransparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.9),
            NumberSequenceKeypoint.new(1, 0.35),
        }),
        iconBackground = Color3.fromRGB(34, 40, 54),
        iconTransparency = 0.15,
        iconGradient = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(46, 58, 82)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(24, 32, 52)),
        }),
        iconSize = UDim2.new(0, 34, 0, 34),
        iconColor = Color3.fromRGB(210, 224, 255),
        iconAccentColor = Color3.fromRGB(112, 198, 255),
    },
    summary = {
        chipBackground = Color3.fromRGB(30, 36, 48),
        chipTransparency = 0.06,
        chipStrokeColor = Color3.fromRGB(94, 148, 214),
        chipStrokeTransparency = 0.5,
        labelFont = Enum.Font.Gotham,
        labelTextSize = 12,
        labelColor = Color3.fromRGB(168, 182, 210),
        valueFont = Enum.Font.GothamSemibold,
        valueTextSize = 17,
        valueColor = Color3.fromRGB(236, 244, 255),
    },
}

local DEFAULT_TELEMETRY = {
    {
        id = "latency",
        label = "Round Trip",
        value = "-- ms",
        hint = "Rolling network latency sample used for Δ.",
    },
    {
        id = "delta",
        label = "Lead Δ",
        value = "-- ms",
        hint = "Forecasted pre-fire lead from ping and activation lag.",
    },
    {
        id = "inequality",
        label = "μ + zσ",
        value = "--",
        hint = "Current PERFECT-PARRY margin; negative means ready to fire.",
    },
    {
        id = "confidence",
        label = "Confidence",
        value = "z = 2.20",
        hint = "Safety index applied to the μ + zσ trigger.",
    },
}

local CONTROL_DEFINITIONS = {
    {
        id = "adaptive",
        title = "Adaptive Timing",
        description = "Learns activation latency and tunes μ forecasts in real time.",
        default = true,
        badge = "SMART",
        icon = "rbxassetid://6031280882",
    },
    {
        id = "failsafe",
        title = "Safety Net",
        description = "Hands control back if μ + zσ behaviour looks unsafe.",
        default = true,
        badge = "SAFE",
        icon = "rbxassetid://6031280887",
    },
    {
        id = "edge",
        title = "Edge Solver",
        description = "Extends forecasts to curve/ricochet chains for team handoffs.",
        default = false,
        icon = "rbxassetid://6031229327",
    },
    {
        id = "audible",
        title = "Audio Alerts",
        description = "Play positional cues when μ + zσ crosses zero.",
        default = true,
        icon = "rbxassetid://6031280883",
    },
    {
        id = "ghost",
        title = "Trajectory Ghosts",
        description = "Pre-simulate probable ball paths to rehearse parries early.",
        default = false,
        icon = "rbxassetid://6031075931",
    },
    {
        id = "autosync",
        title = "Team Sync",
        description = "Broadcast timing cues and σ inflation notices to your squad.",
        default = true,
        badge = "TEAM",
        icon = "rbxassetid://6035202002",
    },
}

local DEFAULT_HEADER_SUMMARY = {
    {
        id = "status",
        label = "System",
        value = "Online",
    },
    {
        id = "delta",
        label = "Δ Lead",
        value = "-- ms",
    },
    {
        id = "confidence",
        label = "Confidence",
        value = "z = 2.20",
    },
}

local STATUS_STYLE = {
    pending = function(theme)
        return {
            icon = theme.iconography.pending,
            color = theme.pendingColor,
            label = "Waiting",
            strokeTransparency = 0.65,
        }
    end,
    active = function(theme)
        return {
            icon = theme.iconography.active or theme.iconography.pending,
            color = theme.activeColor,
            label = "In progress",
            strokeTransparency = 0.35,
        }
    end,
    ok = function(theme)
        return {
            icon = theme.iconography.check,
            color = theme.okColor,
            label = "Ready",
            strokeTransparency = 0.25,
        }
    end,
    warning = function(theme)
        return {
            icon = theme.iconography.warning,
            color = theme.warningColor,
            label = "Check",
            strokeTransparency = 0.3,
        }
    end,
    failed = function(theme)
        return {
            icon = theme.iconography.error,
            color = theme.failedColor,
            label = "Failed",
            strokeTransparency = 0.22,
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

local function createSummaryChip(parent, theme, definition, index)
    local summaryTheme = mergeTable(DEFAULT_THEME.summary, theme.summary or {})
    local identifier = definition.id or definition.Id or definition.key or definition.Key or definition.label or definition.title or tostring(index)

    local chip = Instance.new("Frame")
    chip.Name = string.format("%sChip", tostring(identifier):gsub("%s+", ""))
    chip.AutomaticSize = Enum.AutomaticSize.XY
    chip.Size = UDim2.new(0, 132, 0, 34)
    chip.BackgroundColor3 = summaryTheme.chipBackground or DEFAULT_THEME.summary.chipBackground
    chip.BackgroundTransparency = summaryTheme.chipTransparency or DEFAULT_THEME.summary.chipTransparency
    chip.BorderSizePixel = 0
    chip.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = chip

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1
    stroke.Color = summaryTheme.chipStrokeColor or DEFAULT_THEME.summary.chipStrokeColor
    stroke.Transparency = summaryTheme.chipStrokeTransparency or DEFAULT_THEME.summary.chipStrokeTransparency or 0.6
    stroke.Parent = chip

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 6)
    padding.PaddingBottom = UDim.new(0, 6)
    padding.PaddingLeft = UDim.new(0, 10)
    padding.PaddingRight = UDim.new(0, 10)
    padding.Parent = chip

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    layout.VerticalAlignment = Enum.VerticalAlignment.Top
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 2)
    layout.Parent = chip

    local defaultLabel = definition.label or definition.title or definition.name or definition.id or ""
    local defaultValue = definition.value
    if defaultValue == nil then
        defaultValue = definition.text or definition.display or definition.default or ""
    end

    local label = Instance.new("TextLabel")
    label.Name = "Label"
    label.BackgroundTransparency = 1
    label.Font = summaryTheme.labelFont or DEFAULT_THEME.summary.labelFont
    label.TextSize = summaryTheme.labelTextSize or DEFAULT_THEME.summary.labelTextSize
    label.TextColor3 = summaryTheme.labelColor or DEFAULT_THEME.summary.labelColor
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = string.upper(tostring(defaultLabel))
    label.Size = UDim2.new(1, 0, 0, (summaryTheme.labelTextSize or DEFAULT_THEME.summary.labelTextSize) + 2)
    label.LayoutOrder = 1
    label.Parent = chip

    local value = Instance.new("TextLabel")
    value.Name = "Value"
    value.BackgroundTransparency = 1
    value.Font = summaryTheme.valueFont or DEFAULT_THEME.summary.valueFont
    value.TextSize = summaryTheme.valueTextSize or DEFAULT_THEME.summary.valueTextSize
    value.TextColor3 = summaryTheme.valueColor or DEFAULT_THEME.summary.valueColor
    value.TextXAlignment = Enum.TextXAlignment.Left
    value.Text = tostring(defaultValue)
    value.Size = UDim2.new(1, 0, 0, (summaryTheme.valueTextSize or DEFAULT_THEME.summary.valueTextSize) + 4)
    value.LayoutOrder = 2
    value.Parent = chip

    return {
        frame = chip,
        stroke = stroke,
        label = label,
        value = value,
        definition = definition,
        id = identifier,
        defaultLabel = defaultLabel,
        defaultValue = defaultValue,
    }
end

local function createSummaryRow(parent, theme, summary)
    local container = Instance.new("Frame")
    container.Name = "Summary"
    container.BackgroundTransparency = 1
    container.AutomaticSize = Enum.AutomaticSize.Y
    container.Size = UDim2.new(1, 0, 0, 0)
    container.Parent = parent

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 2)
    padding.PaddingBottom = UDim.new(0, 2)
    padding.Parent = container

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Horizontal
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    layout.VerticalAlignment = Enum.VerticalAlignment.Center
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 12)
    layout.Parent = container

    local chips = {}
    for index, definition in ipairs(summary) do
        local chip = createSummaryChip(container, theme, definition, index)
        chip.frame.LayoutOrder = index
        chips[chip.id or definition.id or tostring(index)] = chip
    end

    return {
        frame = container,
        layout = layout,
        chips = chips,
    }
end

local function normalizeSummaryInput(summary)
    if typeof(summary) ~= "table" then
        return nil
    end

    local result = {}

    if #summary == 0 then
        local list = {}
        for key, payload in pairs(summary) do
            if typeof(payload) == "table" then
                local entry = Util.deepCopy(payload)
                entry.id = entry.id or entry.Id or entry.key or entry.Key or key
                entry.label = entry.label or entry.title or entry.name or key
                entry.value = entry.value or entry.text or entry.display or entry[1]
                table.insert(list, entry)
            elseif payload ~= nil then
                table.insert(list, {
                    id = key,
                    label = key,
                    value = payload,
                })
            end
        end
        summary = list
    end

    for _, entry in ipairs(summary) do
        if typeof(entry) == "table" then
            local id = entry.id or entry.Id or entry.key or entry.Key or entry.label or entry.title
            if id then
                result[string.lower(tostring(id))] = {
                    id = id,
                    label = entry.label or entry.title or entry.name or id,
                    value = entry.value or entry.text or entry.display or entry[1],
                }
            end
        end
    end

    if next(result) == nil then
        return nil
    end

    return result
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

local function createStep(parent, definition, theme, order, totalSteps)
    local frame = Instance.new("Frame")
    frame.Name = definition.id
    frame.Size = UDim2.new(1, 0, 0, 76)
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
    iconGlow.Transparency = 0.55
    iconGlow.Color = theme.pendingColor
    iconGlow.Parent = icon

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.AnchorPoint = Vector2.new(0, 0)
    title.Position = UDim2.new(0, 66, 0, 10)
    title.Size = UDim2.new(1, -150, 0, 24)
    title.BackgroundTransparency = 1
    title.Font = theme.stepTitleFont
    title.TextSize = theme.stepTitleTextSize
    title.TextColor3 = Color3.fromRGB(232, 238, 248)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = definition.title
    title.Parent = frame

    local metaLabel
    if order then
        metaLabel = Instance.new("TextLabel")
        metaLabel.Name = "Meta"
        metaLabel.AnchorPoint = Vector2.new(1, 0)
        metaLabel.Position = UDim2.new(1, -18, 0, 12)
        metaLabel.Size = UDim2.new(0, 86, 0, 20)
        metaLabel.BackgroundTransparency = 1
        metaLabel.Font = theme.stepStatusFont
        metaLabel.TextSize = math.max(theme.stepStatusTextSize - 1, 12)
        metaLabel.TextColor3 = Color3.fromRGB(168, 182, 210)
        if totalSteps and totalSteps > 0 then
            metaLabel.Text = string.format("Step %d/%d", order, totalSteps)
        else
            metaLabel.Text = string.format("Step %d", order)
        end
        metaLabel.TextXAlignment = Enum.TextXAlignment.Right
        metaLabel.Parent = frame
    end

    local status = Instance.new("TextLabel")
    status.Name = "Status"
    status.AnchorPoint = Vector2.new(0, 0)
    status.Position = UDim2.new(0, 66, 0, 34)
    status.Size = UDim2.new(1, -150, 0, 26)
    status.BackgroundTransparency = 1
    status.Font = theme.stepStatusFont
    status.TextSize = theme.stepStatusTextSize
    status.TextColor3 = Color3.fromRGB(184, 198, 224)
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
        meta = metaLabel,
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
    card.AutomaticSize = Enum.AutomaticSize.Y
    card.Size = UDim2.new(0, 0, 0, 104)
    card.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 12)
    corner.Parent = card

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1.1
    stroke.Transparency = telemetryTheme.cardStrokeTransparency
    stroke.Color = telemetryTheme.cardStrokeColor
    stroke.Parent = card

    local spark = Instance.new("Frame")
    spark.Name = "Spark"
    spark.AnchorPoint = Vector2.new(0, 0.5)
    spark.Position = UDim2.new(0, -3, 0.5, 0)
    spark.Size = UDim2.new(0, 6, 1, -24)
    spark.BackgroundColor3 = telemetryTheme.sparkColor or (theme.accentColor and theme.accentColor:Lerp(Color3.new(1, 1, 1), 0.2)) or theme.accentColor
    spark.BackgroundTransparency = telemetryTheme.sparkTransparency or 0.2
    spark.BorderSizePixel = 0
    spark.Parent = card

    local sparkCorner = Instance.new("UICorner")
    sparkCorner.CornerRadius = UDim.new(1, 0)
    sparkCorner.Parent = spark

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 12)
    padding.PaddingBottom = UDim.new(0, 14)
    padding.PaddingLeft = UDim.new(0, 16)
    padding.PaddingRight = UDim.new(0, 14)
    padding.Parent = card

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    layout.VerticalAlignment = Enum.VerticalAlignment.Top
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 6)
    layout.Parent = card

    local label = Instance.new("TextLabel")
    label.Name = "Label"
    label.BackgroundTransparency = 1
    label.Size = UDim2.new(1, 0, 0, 18)
    label.Font = telemetryTheme.labelFont
    label.TextSize = telemetryTheme.labelTextSize
    label.TextColor3 = (telemetryTheme.accentColor or theme.accentColor):Lerp(Color3.new(1, 1, 1), 0.35)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = string.upper(definition.label or definition.id or "Telemetry")
    label.LayoutOrder = 1
    label.Parent = card

    local value = Instance.new("TextLabel")
    value.Name = "Value"
    value.BackgroundTransparency = 1
    value.Size = UDim2.new(1, 0, 0, 32)
    value.Font = telemetryTheme.valueFont
    value.TextSize = telemetryTheme.valueTextSize
    value.TextXAlignment = Enum.TextXAlignment.Left
    value.TextColor3 = Color3.fromRGB(235, 245, 255)
    value.Text = tostring(definition.value or "--")
    value.LayoutOrder = 2
    value.Parent = card

    local hint = Instance.new("TextLabel")
    hint.Name = "Hint"
    hint.BackgroundTransparency = 1
    hint.Size = UDim2.new(1, 0, 0, 22)
    hint.Font = telemetryTheme.labelFont
    hint.TextSize = math.max((telemetryTheme.labelTextSize or 13) - 1, 10)
    hint.TextColor3 = telemetryTheme.hintColor or Color3.fromRGB(176, 196, 230)
    hint.TextTransparency = 0.18
    hint.TextWrapped = true
    hint.TextXAlignment = Enum.TextXAlignment.Left
    hint.Text = definition.hint or ""
    hint.LayoutOrder = 3
    hint.Parent = card

    return {
        frame = card,
        stroke = stroke,
        label = label,
        value = value,
        hint = hint,
        spark = spark,
        defaultValueColor = value.TextColor3,
        defaultHintColor = hint.TextColor3,
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
    button.Size = UDim2.new(0, 260, 0, 112)
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
    padding.PaddingLeft = UDim.new(0, 18)
    padding.PaddingRight = UDim.new(0, 18)
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

    local iconFrame
    local iconImage
    local iconOffset = 0
    local iconSize = controlsTheme.iconSize or DEFAULT_THEME.controls.iconSize or UDim2.new(0, 34, 0, 34)
    if typeof(definition.icon) == "string" and definition.icon ~= "" then
        iconFrame = Instance.new("Frame")
        iconFrame.Name = "Icon"
        iconFrame.BackgroundColor3 = controlsTheme.iconBackground or DEFAULT_THEME.controls.iconBackground
        iconFrame.BackgroundTransparency = controlsTheme.iconTransparency or DEFAULT_THEME.controls.iconTransparency or 0.15
        iconFrame.BorderSizePixel = 0
        iconFrame.Size = iconSize
        iconFrame.Position = UDim2.new(0, 0, 0, math.max(6, math.floor((button.Size.Y.Offset - iconSize.Y.Offset) * 0.5)))
        iconFrame.ZIndex = 2
        iconFrame.Parent = button

        local iconCorner = Instance.new("UICorner")
        iconCorner.CornerRadius = UDim.new(0, 12)
        iconCorner.Parent = iconFrame

        local iconGradient = Instance.new("UIGradient")
        iconGradient.Color = controlsTheme.iconGradient or DEFAULT_THEME.controls.iconGradient
        iconGradient.Rotation = 120
        iconGradient.Parent = iconFrame

        iconImage = Instance.new("ImageLabel")
        iconImage.Name = "Glyph"
        iconImage.AnchorPoint = Vector2.new(0.5, 0.5)
        iconImage.Position = UDim2.new(0.5, 0, 0.5, 0)
        iconImage.Size = UDim2.new(0, math.max(iconSize.X.Offset - 12, 20), 0, math.max(iconSize.Y.Offset - 12, 20))
        iconImage.BackgroundTransparency = 1
        iconImage.Image = definition.icon
        iconImage.ImageColor3 = controlsTheme.iconColor or DEFAULT_THEME.controls.iconColor
        iconImage.Parent = iconFrame

        iconOffset = iconSize.X.Offset + 18
    end

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.BackgroundTransparency = 1
    title.Size = UDim2.new(1, -iconOffset - 8, 0, 26)
    title.Position = UDim2.new(0, iconOffset, 0, 0)
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
        badge.Position = UDim2.new(1, -4, 0, 2)
        badge.Size = UDim2.new(0, 58, 0, 22)
        badge.BackgroundTransparency = 0.25
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
    description.Position = UDim2.new(0, iconOffset, 0, 32)
    description.Size = UDim2.new(1, -iconOffset - 8, 0, 46)
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
    status.Position = UDim2.new(1, -6, 1, -6)
    status.Size = UDim2.new(0, 74, 0, 20)
    status.BackgroundTransparency = 1
    status.Font = controlsTheme.descriptionFont or DEFAULT_THEME.controls.descriptionFont
    status.TextSize = math.max((controlsTheme.descriptionTextSize or DEFAULT_THEME.controls.descriptionTextSize) - 1, 11)
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
        icon = iconImage,
        iconFrame = iconFrame,
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
        toggle.badge.BackgroundTransparency = enabled and 0.12 or 0.4
    end
    if toggle.icon then
        toggle.icon.ImageColor3 = enabled and (controlsTheme.iconAccentColor or onColor) or (controlsTheme.iconColor or DEFAULT_THEME.controls.iconColor)
    end
    if toggle.iconFrame then
        toggle.iconFrame.BackgroundTransparency = enabled and 0.08 or (controlsTheme.iconTransparency or DEFAULT_THEME.controls.iconTransparency or 0.15)
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
    local layoutTheme = mergeTable(DEFAULT_THEME.layout or {}, theme.layout or {})

    local parent = options.parent
    assert(parent, "VerificationDashboard.new requires a parent frame")

    local root = Instance.new("Frame")
    root.Name = options.name or "VerificationDashboard"
    root.BackgroundTransparency = theme.backgroundTransparency
    root.BackgroundColor3 = Color3.new(0, 0, 0)
    root.Size = UDim2.new(1, 0, 0, 0)
    root.AutomaticSize = Enum.AutomaticSize.Y
    root.LayoutOrder = options.layoutOrder or 1
    root.ZIndex = options.zIndex or 1
    root.BorderSizePixel = 0
    root.ClipsDescendants = false
    root.Parent = parent

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 12)
    padding.PaddingBottom = UDim.new(0, 12)
    padding.PaddingLeft = UDim.new(0, 12)
    padding.PaddingRight = UDim.new(0, 12)
    padding.Parent = root

    local canvas = Instance.new("Frame")
    canvas.Name = "Canvas"
    canvas.AnchorPoint = Vector2.new(0.5, 0.5)
    canvas.Position = UDim2.new(0.5, 0, 0.5, 0)
    canvas.AutomaticSize = Enum.AutomaticSize.Y
    canvas.Size = UDim2.new(layoutTheme.widthScale or 1, 0, 0, 0)
    canvas.BackgroundTransparency = 1
    canvas.ZIndex = 2
    canvas.Parent = root

    local canvasPadding = Instance.new("UIPadding")
    canvasPadding.PaddingTop = UDim.new(0, 0)
    canvasPadding.PaddingBottom = UDim.new(0, 0)
    canvasPadding.PaddingLeft = UDim.new(0, layoutTheme.horizontalPadding or 0)
    canvasPadding.PaddingRight = UDim.new(0, layoutTheme.horizontalPadding or 0)
    canvasPadding.Parent = canvas

    local canvasConstraint = Instance.new("UISizeConstraint")
    canvasConstraint.MaxSize = Vector2.new(layoutTheme.maxWidth or 720, math.huge)
    canvasConstraint.MinSize = Vector2.new(layoutTheme.minWidth or 420, 0)
    canvasConstraint.Parent = canvas

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    layout.VerticalAlignment = Enum.VerticalAlignment.Top
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 18)
    layout.Parent = canvas

    local header = Instance.new("Frame")
    header.Name = "Header"
    header.BackgroundTransparency = 1
    header.Size = UDim2.new(1, 0, 0, 118)
    header.LayoutOrder = 1
    header.Parent = canvas

    local headerLayout = Instance.new("UIListLayout")
    headerLayout.FillDirection = Enum.FillDirection.Horizontal
    headerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    headerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    headerLayout.SortOrder = Enum.SortOrder.LayoutOrder
    headerLayout.Padding = UDim.new(0, 18)
    headerLayout.Parent = header

    local initialLogoWidth = (theme.logo and theme.logo.width) or DEFAULT_THEME.logo.width or 230

    local logoContainer = Instance.new("Frame")
    logoContainer.Name = "LogoContainer"
    logoContainer.BackgroundTransparency = 1
    logoContainer.Size = UDim2.new(0, initialLogoWidth, 1, 0)
    logoContainer.Parent = header

    local logoElements = createLogoBadge(logoContainer, theme)

    local textContainer = Instance.new("Frame")
    textContainer.Name = "HeaderText"
    textContainer.BackgroundTransparency = 1
    textContainer.Size = UDim2.new(1, -initialLogoWidth, 1, 0)
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
    title.Text = "PERFECT-PARRY Orchestrator"
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
    subtitle.Text = "Calibrating μ + zσ forecast pipeline…"
    subtitle.LayoutOrder = 2
    subtitle.Parent = textContainer

    local summaryDefinitions
    local shouldSortSummary = false
    if typeof(options.summary) == "table" then
        if #options.summary > 0 then
            summaryDefinitions = options.summary
        else
            summaryDefinitions = {}
            for key, payload in pairs(options.summary) do
                if typeof(payload) == "table" then
                    local entry = Util.deepCopy(payload)
                    entry.id = entry.id or entry.Id or entry.key or entry.Key or key
                    entry.label = entry.label or entry.title or entry.name or key
                    entry.value = entry.value or entry.text or entry.display or entry[1]
                    table.insert(summaryDefinitions, entry)
                elseif payload ~= nil then
                    table.insert(summaryDefinitions, {
                        id = key,
                        label = key,
                        value = payload,
                    })
                end
            end
            shouldSortSummary = true
        end
    end

    summaryDefinitions = summaryDefinitions or DEFAULT_HEADER_SUMMARY

    if shouldSortSummary then
        table.sort(summaryDefinitions, function(a, b)
            local orderA = tonumber(a.order or a.Order)
            local orderB = tonumber(b.order or b.Order)
            if orderA and orderB then
                if orderA == orderB then
                    return tostring(a.label or a.id or "") < tostring(b.label or b.id or "")
                end
                return orderA < orderB
            elseif orderA then
                return true
            elseif orderB then
                return false
            end
            return tostring(a.label or a.id or "") < tostring(b.label or b.id or "")
        end)
    end

    local insightsTheme = mergeTable(DEFAULT_THEME.insights or {}, theme.insights or {})

    local insightsCard = Instance.new("Frame")
    insightsCard.Name = "InsightsCard"
    insightsCard.BackgroundColor3 = insightsTheme.backgroundColor or theme.cardColor
    insightsCard.BackgroundTransparency = insightsTheme.backgroundTransparency or theme.cardTransparency
    insightsCard.BorderSizePixel = 0
    insightsCard.LayoutOrder = 2
    insightsCard.AutomaticSize = Enum.AutomaticSize.Y
    insightsCard.Size = UDim2.new(1, 0, 0, 0)
    insightsCard.Parent = canvas

    local insightsCorner = Instance.new("UICorner")
    insightsCorner.CornerRadius = UDim.new(0, 16)
    insightsCorner.Parent = insightsCard

    local insightsStroke = Instance.new("UIStroke")
    insightsStroke.Thickness = 1.15
    insightsStroke.Color = insightsTheme.strokeColor or theme.cardStrokeColor
    insightsStroke.Transparency = insightsTheme.strokeTransparency or theme.cardStrokeTransparency
    insightsStroke.Parent = insightsCard

    local insightsGradient
    if insightsTheme.gradient then
        insightsGradient = Instance.new("UIGradient")
        insightsGradient.Color = insightsTheme.gradient
        insightsGradient.Transparency = insightsTheme.gradientTransparency or DEFAULT_THEME.insights.gradientTransparency
        insightsGradient.Rotation = insightsTheme.gradientRotation or 120
        insightsGradient.Parent = insightsCard
    end

    local insightsPadding = Instance.new("UIPadding")
    insightsPadding.PaddingTop = UDim.new(0, insightsTheme.paddingTop or 18)
    insightsPadding.PaddingBottom = UDim.new(0, insightsTheme.paddingBottom or 18)
    insightsPadding.PaddingLeft = UDim.new(0, insightsTheme.paddingHorizontal or 20)
    insightsPadding.PaddingRight = UDim.new(0, insightsTheme.paddingHorizontal or 20)
    insightsPadding.Parent = insightsCard

    local insightsLayout = Instance.new("UIListLayout")
    insightsLayout.FillDirection = Enum.FillDirection.Vertical
    insightsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    insightsLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    insightsLayout.SortOrder = Enum.SortOrder.LayoutOrder
    insightsLayout.Padding = UDim.new(0, insightsTheme.paddingBetween or 16)
    insightsLayout.Parent = insightsCard

    local summaryRow
    if #summaryDefinitions > 0 then
        summaryRow = createSummaryRow(insightsCard, theme, summaryDefinitions)
        summaryRow.frame.LayoutOrder = 1
    end

    local telemetryFrame = Instance.new("Frame")
    telemetryFrame.Name = "Telemetry"
    telemetryFrame.BackgroundTransparency = 1
    telemetryFrame.AutomaticSize = Enum.AutomaticSize.Y
    telemetryFrame.Size = UDim2.new(1, 0, 0, 0)
    telemetryFrame.LayoutOrder = summaryRow and 2 or 1
    telemetryFrame.Parent = insightsCard

    local telemetryGrid = Instance.new("UIGridLayout")
    telemetryGrid.FillDirection = Enum.FillDirection.Horizontal
    telemetryGrid.HorizontalAlignment = Enum.HorizontalAlignment.Left
    telemetryGrid.VerticalAlignment = Enum.VerticalAlignment.Top
    telemetryGrid.SortOrder = Enum.SortOrder.LayoutOrder
    telemetryGrid.CellPadding = (theme.telemetry and theme.telemetry.cellPadding) or DEFAULT_THEME.telemetry.cellPadding
    telemetryGrid.CellSize = (theme.telemetry and theme.telemetry.cellSize) or DEFAULT_THEME.telemetry.cellSize
    telemetryGrid.FillDirectionMaxCells = (theme.telemetry and theme.telemetry.maxColumns) or DEFAULT_THEME.telemetry.maxColumns or 2
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
    controlPanel.AutomaticSize = Enum.AutomaticSize.Y
    controlPanel.Size = UDim2.new(1, 0, 0, 0)
    controlPanel.LayoutOrder = telemetryFrame.LayoutOrder + 1
    controlPanel.Parent = insightsCard

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
    controlHeader.Text = "System toggles"
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
    controlGrid.CellSize = UDim2.new(0.5, -12, 0, 112)
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
    timelineCard.LayoutOrder = 3
    timelineCard.Parent = canvas

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

    local timelineGradient = Instance.new("UIGradient")
    local baseCardColor = theme.cardColor
    local accentMix = baseCardColor:Lerp(theme.accentColor, 0.12)
    timelineGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, accentMix),
        ColorSequenceKeypoint.new(1, baseCardColor),
    })
    timelineGradient.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, math.clamp((theme.cardTransparency or 0) + 0.45, 0, 1)),
        NumberSequenceKeypoint.new(1, 1),
    })
    timelineGradient.Rotation = 125
    timelineGradient.Parent = timelineCard

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
    progressTrack.BackgroundColor3 = theme.cardColor:Lerp(theme.accentColor, 0.08)
    progressTrack.BackgroundTransparency = math.clamp((theme.cardTransparency or 0) + 0.12, 0, 1)
    progressTrack.BorderSizePixel = 0
    progressTrack.ZIndex = 2
    progressTrack.LayoutOrder = 1
    progressTrack.Parent = timelineCard

    local trackCorner = Instance.new("UICorner")
    trackCorner.CornerRadius = UDim.new(0, 6)
    trackCorner.Parent = progressTrack

    local trackStroke = Instance.new("UIStroke")
    trackStroke.Thickness = 1
    trackStroke.Color = theme.connectorColor
    trackStroke.Transparency = math.clamp((theme.connectorTransparency or 0.35) + 0.25, 0, 1)
    trackStroke.Parent = progressTrack

    local progressFill = Instance.new("Frame")
    progressFill.Name = "Fill"
    progressFill.Size = UDim2.new(0, 0, 1, 0)
    progressFill.BackgroundColor3 = theme.accentColor
    progressFill.BorderSizePixel = 0
    progressFill.ZIndex = 3
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
        local step = createStep(listFrame, definition, theme, index, #STEP_DEFINITIONS)
        step.frame.LayoutOrder = index
        if index == #STEP_DEFINITIONS then
            step.connector.Visible = false
        end
        steps[definition.id] = step
    end

    local actionsFrame = Instance.new("Frame")
    actionsFrame.Name = "Actions"
    actionsFrame.BackgroundTransparency = 1
    actionsFrame.LayoutOrder = 4
    actionsFrame.Size = UDim2.new(1, 0, 0, theme.actionHeight + 12)
    actionsFrame.Visible = false
    actionsFrame.Parent = canvas

    local actionsLayout = Instance.new("UIListLayout")
    actionsLayout.FillDirection = Enum.FillDirection.Horizontal
    actionsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    actionsLayout.SortOrder = Enum.SortOrder.LayoutOrder
    actionsLayout.Padding = UDim.new(0, 12)
    actionsLayout.Parent = actionsFrame

    local headerDefaults = {
        fillDirection = headerLayout.FillDirection,
        horizontalAlignment = headerLayout.HorizontalAlignment,
        verticalAlignment = headerLayout.VerticalAlignment,
        padding = headerLayout.Padding,
    }
    local textDefaults = {
        horizontalAlignment = textLayout.HorizontalAlignment,
        verticalAlignment = textLayout.VerticalAlignment,
    }
    local titleDefaults = {
        alignment = title.TextXAlignment,
        wrapped = title.TextWrapped,
    }
    local subtitleDefaults = {
        alignment = subtitle.TextXAlignment,
    }
    local summaryDefaults = summaryRow and {
        fillDirection = summaryRow.layout.FillDirection,
        horizontalAlignment = summaryRow.layout.HorizontalAlignment,
    } or nil
    local telemetryDefaults = {
        cellSize = telemetryGrid.CellSize,
        maxColumns = telemetryGrid.FillDirectionMaxCells,
    }
    local controlGridDefaults = {
        maxColumns = controlGrid.FillDirectionMaxCells,
    }
    local actionsDefaults = {
        fillDirection = actionsLayout.FillDirection,
        horizontalAlignment = actionsLayout.HorizontalAlignment,
        padding = actionsLayout.Padding,
    }
    local actionsFrameDefaults = {
        size = actionsFrame.Size,
        automaticSize = actionsFrame.AutomaticSize,
    }
    local logoDefaults
    if logoElements then
        logoDefaults = {
            containerSize = logoContainer.Size,
            frameAnchor = logoElements.frame.AnchorPoint,
            framePosition = logoElements.frame.Position,
            frameSize = logoElements.frame.Size,
            glyphAnchor = logoElements.glyph.AnchorPoint,
            glyphPosition = logoElements.glyph.Position,
            glyphSize = logoElements.glyph.Size,
            wordmarkAnchor = logoElements.wordmark.AnchorPoint,
            wordmarkPosition = logoElements.wordmark.Position,
            wordmarkSize = logoElements.wordmark.Size,
            wordmarkAlignment = logoElements.wordmark.TextXAlignment,
            taglineAnchor = logoElements.tagline.AnchorPoint,
            taglinePosition = logoElements.tagline.Position,
            taglineAlignment = logoElements.tagline.TextXAlignment,
        }
    end

    local headerTextDefaults = textContainer.Size

    local self = setmetatable({
        _theme = theme,
        _root = root,
        _canvas = canvas,
        _canvasPadding = canvasPadding,
        _canvasConstraint = canvasConstraint,
        _layoutTheme = layoutTheme,
        _layout = layout,
        _header = header,
        _headerLayout = headerLayout,
        _title = title,
        _subtitle = subtitle,
        _insightsCard = insightsCard,
        _insightsStroke = insightsStroke,
        _insightsGradient = insightsGradient,
        _insightsLayout = insightsLayout,
        _insightsPadding = insightsPadding,
        _summaryFrame = summaryRow and summaryRow.frame or nil,
        _summaryLayout = summaryRow and summaryRow.layout or nil,
        _summaryChips = summaryRow and summaryRow.chips or nil,
        _summaryDefinitions = Util.deepCopy(summaryDefinitions),
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
        _timelineGradient = timelineGradient,
        _progressTrack = progressTrack,
        _progressFill = progressFill,
        _progressTrackStroke = trackStroke,
        _progressTween = nil,
        _stepsFrame = listFrame,
        _steps = steps,
        _stepStates = {},
        _actionsFrame = actionsFrame,
        _actionsLayout = actionsLayout,
        _actionButtons = {},
        _actionConnections = {},
        _actions = nil,
        _headerLayoutDefaults = headerDefaults,
        _textLayout = textLayout,
        _textLayoutDefaults = textDefaults,
        _headerText = textContainer,
        _headerTextDefaults = headerTextDefaults,
        _logoContainer = logoContainer,
        _logoFrame = logoElements and logoElements.frame,
        _logoStroke = logoElements and logoElements.stroke,
        _logoGradient = logoElements and logoElements.gradient,
        _logoGlyph = logoElements and logoElements.glyph,
        _logoWordmark = logoElements and logoElements.wordmark,
        _logoWordmarkGradient = logoElements and logoElements.wordmarkGradient,
        _logoTagline = logoElements and logoElements.tagline,
        _logoDefaults = logoDefaults,
        _initialLogoWidth = initialLogoWidth,
        _titleDefaults = titleDefaults,
        _subtitleDefaults = subtitleDefaults,
        _summaryDefaults = summaryDefaults,
        _telemetryDefaults = telemetryDefaults,
        _controlGridDefaults = controlGridDefaults,
        _actionsDefaults = actionsDefaults,
        _actionsFrameDefaults = actionsFrameDefaults,
        _logoShimmerTween = nil,
        _connections = {},
        _responsiveState = {},
        _lastLayoutBounds = nil,
        _destroyed = false,
    }, VerificationDashboard)

    for _, definition in ipairs(STEP_DEFINITIONS) do
        self._stepStates[definition.id] = { status = "pending", priority = STATUS_PRIORITY.pending }
    end

    self:_applyLogoTheme()
    self:_applyInsightsTheme()
    self:_applySummaryTheme()
    self:_startLogoShimmer()
    self:setHeaderSummary(summaryDefinitions)
    self:setControls(options.controls)
    self:setTelemetry(options.telemetry)
    self:setProgress(0)

    self:_installResponsiveHandlers()
    self:updateLayout()

    return self
end

function VerificationDashboard:_installResponsiveHandlers()
    if not self._root then
        return
    end

    local connection = self._root:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
        if self._destroyed then
            return
        end
        self:updateLayout(self._lastLayoutBounds)
    end)
    table.insert(self._connections, connection)

    task.defer(function()
        if self._destroyed then
            return
        end
        self:updateLayout(self._lastLayoutBounds)
    end)
end

function VerificationDashboard:_applyResponsiveLayout(width, bounds)
    if self._destroyed then
        return
    end

    width = math.floor(tonumber(width) or 0)
    if width <= 0 then
        return
    end

    local theme = self._theme or DEFAULT_THEME
    local layoutTheme = mergeTable(DEFAULT_THEME.layout or {}, theme.layout or {})
    self._layoutTheme = layoutTheme

    local canvas = self._canvas
    if canvas then
        local widthScale = math.clamp(layoutTheme.widthScale or 1, 0.6, 1)
        canvas.Size = UDim2.new(widthScale, 0, 0, 0)
    end

    local canvasConstraint = self._canvasConstraint
    if canvasConstraint then
        local maxWidth = layoutTheme.maxWidth or width
        local minWidth = layoutTheme.minWidth or maxWidth
        if width > 0 then
            maxWidth = math.min(maxWidth, width)
            minWidth = math.min(minWidth, maxWidth)
        end
        canvasConstraint.MaxSize = Vector2.new(math.max(0, maxWidth), math.huge)
        canvasConstraint.MinSize = Vector2.new(math.max(0, minWidth), 0)
    end

    local canvasPadding = self._canvasPadding
    if canvasPadding then
        local horizontalPadding = layoutTheme.horizontalPadding or 0
        if width <= 540 then
            horizontalPadding = math.max(8, math.floor(horizontalPadding * 0.75))
        elseif width >= (layoutTheme.maxWidth or width) then
            horizontalPadding = math.max(horizontalPadding, 20)
        end
        canvasPadding.PaddingLeft = UDim.new(0, horizontalPadding)
        canvasPadding.PaddingRight = UDim.new(0, horizontalPadding)
    end

    local headerLayout = self._headerLayout
    if not headerLayout then
        return
    end

    local headerDefaults = self._headerLayoutDefaults
    if headerDefaults then
        headerLayout.FillDirection = headerDefaults.fillDirection
        headerLayout.HorizontalAlignment = headerDefaults.horizontalAlignment
        headerLayout.VerticalAlignment = headerDefaults.verticalAlignment
        headerLayout.Padding = headerDefaults.padding or headerLayout.Padding
    end

    if self._textLayout and self._textLayoutDefaults then
        self._textLayout.HorizontalAlignment = self._textLayoutDefaults.horizontalAlignment
        self._textLayout.VerticalAlignment = self._textLayoutDefaults.verticalAlignment
    end

    if self._headerText and self._headerTextDefaults then
        self._headerText.Size = self._headerTextDefaults
    end

    if self._title and self._titleDefaults then
        self._title.TextXAlignment = self._titleDefaults.alignment
        self._title.TextWrapped = self._titleDefaults.wrapped
    end

    if self._subtitle and self._subtitleDefaults then
        self._subtitle.TextXAlignment = self._subtitleDefaults.alignment
    end

    if self._summaryLayout and self._summaryDefaults then
        self._summaryLayout.FillDirection = self._summaryDefaults.fillDirection
        self._summaryLayout.HorizontalAlignment = self._summaryDefaults.horizontalAlignment
    end

    if self._telemetryGrid and self._telemetryDefaults then
        self._telemetryGrid.FillDirectionMaxCells = self._telemetryDefaults.maxColumns or self._telemetryGrid.FillDirectionMaxCells
        self._telemetryGrid.CellSize = self._telemetryDefaults.cellSize or self._telemetryGrid.CellSize
    end

    if self._controlGrid and self._controlGridDefaults then
        self._controlGrid.FillDirectionMaxCells = self._controlGridDefaults.maxColumns or self._controlGrid.FillDirectionMaxCells
    end

    if self._actionsLayout and self._actionsDefaults then
        self._actionsLayout.FillDirection = self._actionsDefaults.fillDirection
        self._actionsLayout.HorizontalAlignment = self._actionsDefaults.horizontalAlignment
        self._actionsLayout.Padding = self._actionsDefaults.padding or self._actionsLayout.Padding
    end

    if self._actionsFrame and self._actionsFrameDefaults then
        self._actionsFrame.AutomaticSize = self._actionsFrameDefaults.automaticSize or Enum.AutomaticSize.None
        self._actionsFrame.Size = self._actionsFrameDefaults.size or self._actionsFrame.Size
    end

    local logoDefaults = self._logoDefaults
    if logoDefaults then
        if self._logoContainer then
            self._logoContainer.Size = logoDefaults.containerSize
        end
        if self._logoFrame then
            self._logoFrame.AnchorPoint = logoDefaults.frameAnchor
            self._logoFrame.Position = logoDefaults.framePosition
            self._logoFrame.Size = logoDefaults.frameSize
        end
        if self._logoGlyph then
            self._logoGlyph.AnchorPoint = logoDefaults.glyphAnchor
            self._logoGlyph.Position = logoDefaults.glyphPosition
            self._logoGlyph.Size = logoDefaults.glyphSize
        end
        if self._logoWordmark then
            self._logoWordmark.AnchorPoint = logoDefaults.wordmarkAnchor
            self._logoWordmark.Position = logoDefaults.wordmarkPosition
            self._logoWordmark.Size = logoDefaults.wordmarkSize
            self._logoWordmark.TextXAlignment = logoDefaults.wordmarkAlignment
        end
        if self._logoTagline then
            self._logoTagline.AnchorPoint = logoDefaults.taglineAnchor
            self._logoTagline.Position = logoDefaults.taglinePosition
            self._logoTagline.TextXAlignment = logoDefaults.taglineAlignment
        end
    end

    local breakpoint
    if bounds and bounds.mode == "stacked" then
        breakpoint = "small"
    elseif bounds and bounds.mode == "hybrid" then
        breakpoint = "medium"
    else
        if width <= 540 then
            breakpoint = "small"
        elseif width <= 820 then
            breakpoint = "medium"
        else
            breakpoint = "large"
        end
    end

    local state = self._responsiveState or {}
    state.breakpoint = breakpoint
    state.width = width
    state.mode = bounds and bounds.mode or breakpoint
    self._responsiveState = state

    local dashboardWidth = (bounds and bounds.dashboardWidth) or width
    local logoMaxWidth = self._initialLogoWidth or ((logoDefaults and logoDefaults.containerSize and logoDefaults.containerSize.X.Offset) or 240)

    if breakpoint == "small" then
        if headerLayout then
            headerLayout.FillDirection = Enum.FillDirection.Vertical
            headerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
            headerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
            headerLayout.Padding = UDim.new(0, 12)
        end
        if self._logoContainer then
            self._logoContainer.Size = UDim2.new(1, 0, 0, 112)
        end
        if self._headerText then
            self._headerText.Size = UDim2.new(1, 0, 0, 96)
        end
        if self._logoFrame then
            self._logoFrame.AnchorPoint = Vector2.new(0.5, 0.5)
            self._logoFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
            self._logoFrame.Size = UDim2.new(1, -16, 0, 102)
        end
        if self._logoGlyph then
            self._logoGlyph.AnchorPoint = Vector2.new(0.5, 0.5)
            self._logoGlyph.Position = UDim2.new(0.5, 0, 0.5, -20)
        end
        if self._logoWordmark then
            self._logoWordmark.AnchorPoint = Vector2.new(0.5, 0.5)
            self._logoWordmark.Position = UDim2.new(0.5, 0, 0.5, 8)
            self._logoWordmark.Size = UDim2.new(1, -40, 0, self._logoWordmark.Size.Y.Offset)
            self._logoWordmark.TextXAlignment = Enum.TextXAlignment.Center
        end
        if self._logoTagline then
            self._logoTagline.AnchorPoint = Vector2.new(0.5, 0.5)
            self._logoTagline.Position = UDim2.new(0.5, 0, 0.5, 34)
            self._logoTagline.Size = UDim2.new(1, -48, 0, self._logoTagline.Size.Y.Offset)
            self._logoTagline.TextXAlignment = Enum.TextXAlignment.Center
        end
        if self._textLayout then
            self._textLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        end
        if self._title then
            self._title.TextWrapped = true
            self._title.TextXAlignment = Enum.TextXAlignment.Center
        end
        if self._subtitle then
            self._subtitle.TextXAlignment = Enum.TextXAlignment.Center
        end
        if self._summaryLayout then
            self._summaryLayout.FillDirection = Enum.FillDirection.Vertical
            self._summaryLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        end
        if self._telemetryGrid then
            self._telemetryGrid.FillDirectionMaxCells = 1
            self._telemetryGrid.CellSize = UDim2.new(1, -12, 0, 112)
        end
        if self._controlGrid then
            self._controlGrid.FillDirectionMaxCells = 1
        end
        if self._actionsLayout then
            self._actionsLayout.FillDirection = Enum.FillDirection.Vertical
            self._actionsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
            self._actionsLayout.Padding = UDim.new(0, 10)
        end
        if self._actionsFrame then
            self._actionsFrame.AutomaticSize = Enum.AutomaticSize.Y
            self._actionsFrame.Size = UDim2.new(1, 0, 0, 0)
        end
    elseif breakpoint == "medium" then
        local logoWidth = math.clamp(math.floor(dashboardWidth * 0.38), 170, logoMaxWidth)
        if self._logoContainer then
            self._logoContainer.Size = UDim2.new(0, logoWidth, 1, 0)
        end
        if self._headerText then
            self._headerText.Size = UDim2.new(1, -logoWidth, 1, 0)
        end
        if headerLayout then
            headerLayout.FillDirection = Enum.FillDirection.Horizontal
            headerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
            headerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
        end
        if self._textLayout then
            self._textLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
        end
        if self._title then
            self._title.TextWrapped = width <= 680
        end
        if self._summaryLayout then
            self._summaryLayout.FillDirection = Enum.FillDirection.Horizontal
            self._summaryLayout.HorizontalAlignment = width <= 700 and Enum.HorizontalAlignment.Center
                or Enum.HorizontalAlignment.Left
        end
        if self._telemetryGrid then
            if width <= 700 then
                self._telemetryGrid.FillDirectionMaxCells = 1
                self._telemetryGrid.CellSize = UDim2.new(1, -12, 0, 112)
            else
                self._telemetryGrid.FillDirectionMaxCells = math.min(2, self._telemetryDefaults.maxColumns or 2)
                self._telemetryGrid.CellSize = self._telemetryDefaults.cellSize or self._telemetryGrid.CellSize
            end
        end
        if self._controlGrid then
            self._controlGrid.FillDirectionMaxCells = width <= 700 and 1 or (self._controlGridDefaults.maxColumns or 2)
        end
        if self._actionsLayout then
            self._actionsLayout.FillDirection = Enum.FillDirection.Horizontal
            if width <= 700 then
                self._actionsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
                self._actionsLayout.Padding = UDim.new(0, 10)
                if self._actionsFrame then
                    self._actionsFrame.AutomaticSize = Enum.AutomaticSize.Y
                    self._actionsFrame.Size = UDim2.new(1, 0, 0, 0)
                end
            else
                self._actionsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
            end
        end
    else
        local logoWidth = math.clamp(math.floor(dashboardWidth * 0.32), 200, logoMaxWidth)
        if self._logoContainer then
            self._logoContainer.Size = UDim2.new(0, logoWidth, 1, 0)
        end
        if self._headerText then
            self._headerText.Size = UDim2.new(1, -logoWidth, 1, 0)
        end
        if self._summaryLayout then
            self._summaryLayout.FillDirection = Enum.FillDirection.Horizontal
            self._summaryLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
        end
        if self._telemetryGrid then
            self._telemetryGrid.FillDirectionMaxCells = self._telemetryDefaults.maxColumns or 2
            self._telemetryGrid.CellSize = self._telemetryDefaults.cellSize or self._telemetryGrid.CellSize
        end
        if self._controlGrid and self._controlGridDefaults then
            self._controlGrid.FillDirectionMaxCells = self._controlGridDefaults.maxColumns or self._controlGrid.FillDirectionMaxCells
        end
    end
end

function VerificationDashboard:updateLayout(bounds)
    if self._destroyed then
        return
    end

    if bounds then
        self._lastLayoutBounds = {
            mode = bounds.mode,
            containerWidth = bounds.containerWidth,
            containerHeight = bounds.containerHeight,
            dashboardWidth = bounds.dashboardWidth,
            dashboardHeight = bounds.dashboardHeight,
            contentWidth = bounds.contentWidth,
            scale = bounds.scale,
            raw = bounds.raw,
        }
    end

    local reference = bounds or self._lastLayoutBounds
    local width = reference and reference.dashboardWidth or (self._root and self._root.AbsoluteSize.X) or 0
    if width <= 0 and self._root then
        width = self._root.AbsoluteSize.X
    end
    if width <= 0 then
        return
    end

    self:_applyResponsiveLayout(width, reference)
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

function VerificationDashboard:_applyInsightsTheme()
    if self._destroyed then
        return
    end

    local theme = self._theme or DEFAULT_THEME
    local insightsTheme = mergeTable(DEFAULT_THEME.insights or {}, theme.insights or {})

    if self._insightsCard then
        self._insightsCard.BackgroundColor3 = insightsTheme.backgroundColor or theme.cardColor
        self._insightsCard.BackgroundTransparency = insightsTheme.backgroundTransparency or theme.cardTransparency
    end

    if self._insightsStroke then
        self._insightsStroke.Color = insightsTheme.strokeColor or theme.cardStrokeColor
        self._insightsStroke.Transparency = insightsTheme.strokeTransparency or theme.cardStrokeTransparency
    end

    if self._insightsGradient then
        self._insightsGradient.Color = insightsTheme.gradient or DEFAULT_THEME.insights.gradient
        self._insightsGradient.Transparency = insightsTheme.gradientTransparency or DEFAULT_THEME.insights.gradientTransparency
        self._insightsGradient.Rotation = insightsTheme.gradientRotation or 120
    end

    if self._insightsPadding then
        self._insightsPadding.PaddingTop = UDim.new(0, insightsTheme.paddingTop or DEFAULT_THEME.insights.paddingTop or 16)
        self._insightsPadding.PaddingBottom = UDim.new(0, insightsTheme.paddingBottom or DEFAULT_THEME.insights.paddingBottom or 16)
        self._insightsPadding.PaddingLeft = UDim.new(0, insightsTheme.paddingHorizontal or DEFAULT_THEME.insights.paddingHorizontal or 18)
        self._insightsPadding.PaddingRight = UDim.new(0, insightsTheme.paddingHorizontal or DEFAULT_THEME.insights.paddingHorizontal or 18)
    end

    if self._insightsLayout then
        self._insightsLayout.Padding = UDim.new(0, insightsTheme.paddingBetween or DEFAULT_THEME.insights.paddingBetween or 16)
    end
end

function VerificationDashboard:_applySummaryTheme()
    if self._destroyed or not self._summaryChips then
        return
    end

    local theme = self._theme or DEFAULT_THEME
    local summaryTheme = mergeTable(DEFAULT_THEME.summary, theme.summary or {})

    if self._summaryFrame then
        self._summaryFrame.Visible = next(self._summaryChips) ~= nil
    end

    for _, chip in pairs(self._summaryChips) do
        if chip.frame then
            chip.frame.BackgroundColor3 = summaryTheme.chipBackground or DEFAULT_THEME.summary.chipBackground
            chip.frame.BackgroundTransparency = summaryTheme.chipTransparency or DEFAULT_THEME.summary.chipTransparency
        end
        if chip.stroke then
            chip.stroke.Color = summaryTheme.chipStrokeColor or DEFAULT_THEME.summary.chipStrokeColor
            chip.stroke.Transparency = summaryTheme.chipStrokeTransparency or DEFAULT_THEME.summary.chipStrokeTransparency or 0.6
        end
        if chip.label then
            chip.label.Font = summaryTheme.labelFont or DEFAULT_THEME.summary.labelFont
            chip.label.TextSize = summaryTheme.labelTextSize or DEFAULT_THEME.summary.labelTextSize
            chip.label.TextColor3 = summaryTheme.labelColor or DEFAULT_THEME.summary.labelColor
        end
        if chip.value then
            chip.value.Font = summaryTheme.valueFont or DEFAULT_THEME.summary.valueFont
            chip.value.TextSize = summaryTheme.valueTextSize or DEFAULT_THEME.summary.valueTextSize
            chip.value.TextColor3 = summaryTheme.valueColor or DEFAULT_THEME.summary.valueColor
        end
    end
end

function VerificationDashboard:setHeaderSummary(summary)
    if self._destroyed or not self._summaryChips then
        return
    end

    if summary ~= nil and typeof(summary) == "table" then
        self._summaryDefinitions = Util.deepCopy(summary)
    end

    local source = summary
    if typeof(source) ~= "table" then
        source = self._summaryDefinitions or DEFAULT_HEADER_SUMMARY
    end

    local normalised = normalizeSummaryInput(source)
    if not normalised then
        normalised = normalizeSummaryInput(DEFAULT_HEADER_SUMMARY) or {}
    end

    for key, chip in pairs(self._summaryChips) do
        local identifier = chip.id or key
        local lookupKey = identifier and string.lower(tostring(identifier)) or nil
        local payload = lookupKey and normalised[lookupKey] or nil

        local labelText = chip.defaultLabel or identifier
        local valueText = chip.defaultValue
        if valueText == nil then
            valueText = ""
        end

        if payload then
            if payload.label ~= nil then
                labelText = payload.label
            end
            if payload.value ~= nil then
                valueText = payload.value
            end
        end

        if chip.label then
            chip.label.Text = string.upper(tostring(labelText))
        end
        if chip.value then
            chip.value.Text = tostring(valueText)
        end
    end

    self:_applySummaryTheme()
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

    if self._connections then
        for _, connection in ipairs(self._connections) do
            if connection then
                if connection.Disconnect then
                    connection:Disconnect()
                elseif connection.disconnect then
                    connection:disconnect()
                end
            end
        end
        self._connections = nil
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
    self._layoutTheme = mergeTable(DEFAULT_THEME.layout or {}, currentTheme.layout or {})

    self:_stopLogoShimmer()
    self:_applyLogoTheme()
    self:_applyInsightsTheme()
    self:_applySummaryTheme()

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

    if self._progressTrack then
        self._progressTrack.BackgroundColor3 = currentTheme.cardColor:Lerp(currentTheme.accentColor, 0.08)
        self._progressTrack.BackgroundTransparency = math.clamp((currentTheme.cardTransparency or 0) + 0.12, 0, 1)
    end

    if self._progressTrackStroke then
        self._progressTrackStroke.Color = currentTheme.connectorColor
        self._progressTrackStroke.Transparency = math.clamp((currentTheme.connectorTransparency or 0.35) + 0.25, 0, 1)
    end

    if self._progressFill then
        self._progressFill.BackgroundColor3 = currentTheme.accentColor
    end

    if self._telemetryGrid or self._telemetryCards then
        local telemetryTheme = currentTheme.telemetry or DEFAULT_THEME.telemetry
        if self._telemetryGrid then
            self._telemetryGrid.CellPadding = telemetryTheme.cellPadding or DEFAULT_THEME.telemetry.cellPadding
            self._telemetryGrid.CellSize = telemetryTheme.cellSize or DEFAULT_THEME.telemetry.cellSize
            self._telemetryGrid.FillDirectionMaxCells = telemetryTheme.maxColumns or DEFAULT_THEME.telemetry.maxColumns or 2
        end

        if self._telemetryCards then
            for _, card in pairs(self._telemetryCards) do
                if card.frame then
                    card.frame.BackgroundColor3 = telemetryTheme.cardColor
                    card.frame.BackgroundTransparency = telemetryTheme.cardTransparency
                end
                if card.stroke then
                    card.stroke.Color = telemetryTheme.cardStrokeColor
                    card.stroke.Transparency = telemetryTheme.cardStrokeTransparency
                end
                if card.spark then
                    card.spark.BackgroundColor3 = telemetryTheme.sparkColor or currentTheme.accentColor
                    card.spark.BackgroundTransparency = telemetryTheme.sparkTransparency or 0.2
                end
                if card.label then
                    card.label.Font = telemetryTheme.labelFont
                    card.label.TextSize = telemetryTheme.labelTextSize
                    card.label.TextColor3 = (telemetryTheme.accentColor or currentTheme.accentColor):Lerp(Color3.new(1, 1, 1), 0.35)
                end
                if card.value then
                    local valueColor = telemetryTheme.valueColor or Color3.fromRGB(235, 245, 255)
                    card.value.Font = telemetryTheme.valueFont
                    card.value.TextSize = telemetryTheme.valueTextSize
                    card.value.TextColor3 = valueColor
                    card.defaultValueColor = valueColor
                end
                if card.hint then
                    local hintColor = telemetryTheme.hintColor or Color3.fromRGB(176, 196, 230)
                    card.hint.Font = telemetryTheme.labelFont
                    card.hint.TextSize = math.max((telemetryTheme.labelTextSize or DEFAULT_THEME.telemetry.labelTextSize) - 1, 10)
                    card.hint.TextColor3 = hintColor
                    card.defaultHintColor = hintColor
                end
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

    if self._timelineGradient then
        self._timelineGradient.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, currentTheme.cardColor:Lerp(currentTheme.accentColor, 0.12)),
            ColorSequenceKeypoint.new(1, currentTheme.cardColor),
        })
        self._timelineGradient.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, math.clamp((currentTheme.cardTransparency or 0) + 0.45, 0, 1)),
            NumberSequenceKeypoint.new(1, 1),
        })
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
            if step.meta then
                step.meta.Font = currentTheme.stepStatusFont
                step.meta.TextSize = math.max(currentTheme.stepStatusTextSize - 1, 12)
                step.meta.TextColor3 = Color3.fromRGB(168, 182, 210)
            end
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

    self:updateLayout(self._lastLayoutBounds)
    self:_startLogoShimmer()
end

function VerificationDashboard:setStatusText(status)
    if self._destroyed then
        return
    end
    local text = status
    local detail
    local telemetry

    if typeof(status) == "table" then
        detail = status.detail or status.details
        telemetry = status.telemetry
        text = status.text or status.message or ""
    end

    if self._subtitle then
        if typeof(text) ~= "string" then
            text = tostring(text or "")
        end
        self._subtitle.Text = text or ""
    end

    if telemetry then
        self:setTelemetry(telemetry)
    end

    if detail then
        self:_applyErrorDetail(detail)
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
        local valueColor
        local hintColor
        local sparkColor
        local sparkTransparency

        if typeof(payload) == "table" then
            valueText = payload.value or payload.text or payload.display or payload[1]
            hintText = payload.hint or payload.description or payload.label
            if payload.color and typeof(payload.color) == "Color3" then
                valueColor = payload.color
                sparkColor = payload.color
            elseif payload.state then
                local statusColor = self:_resolveStatusColor(payload.state)
                if statusColor then
                    valueColor = statusColor
                    sparkColor = statusColor
                end
            end
            if payload.hintColor and typeof(payload.hintColor) == "Color3" then
                hintColor = payload.hintColor
            end
            if payload.sparkColor and typeof(payload.sparkColor) == "Color3" then
                sparkColor = payload.sparkColor
            end
            if payload.sparkTransparency ~= nil then
                sparkTransparency = payload.sparkTransparency
            end
        end

        if valueText ~= nil and card.value then
            card.value.Text = tostring(valueText)
        elseif card.definition and card.definition.value and card.value then
            card.value.Text = tostring(card.definition.value)
        end

        if card.value then
            card.value.TextColor3 = valueColor or card.defaultValueColor or card.value.TextColor3
        end

        if card.hint then
            if hintText ~= nil then
                card.hint.Text = tostring(hintText)
            elseif card.definition then
                card.hint.Text = card.definition.hint or ""
            end

            card.hint.TextColor3 = hintColor or card.defaultHintColor or card.hint.TextColor3
        end

        if card.spark then
            local theme = self._theme or DEFAULT_THEME
            local telemetryTheme = theme.telemetry or DEFAULT_THEME.telemetry
            card.spark.BackgroundColor3 = sparkColor or telemetryTheme.sparkColor or theme.accentColor
            if sparkTransparency ~= nil then
                card.spark.BackgroundTransparency = sparkTransparency
            else
                card.spark.BackgroundTransparency = telemetryTheme.sparkTransparency or 0.2
            end
        end
    end

    local errorDetail = telemetry and telemetry.errorDetail
    if errorDetail then
        self:_applyErrorDetail(errorDetail)
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
                step.iconGlow.Transparency = 0.55
            end
            step.connector.BackgroundTransparency = self._theme.connectorTransparency
            step.connector.BackgroundColor3 = self._theme.connectorColor
            if step.meta then
                step.meta.TextColor3 = Color3.fromRGB(168, 182, 210)
            end
            if step.tooltip then
                step.tooltip.Text = definition.tooltip
            end
        end
        self._stepStates[definition.id] = { status = "pending", priority = STATUS_PRIORITY.pending }
    end

    self:setProgress(0)
    self:setHeaderSummary(nil)
    self:setStatusText("Initialising AutoParry suite…")
end

local function resolveStyle(theme, status)
    local resolver = STATUS_STYLE[status]
    if resolver then
        return resolver(theme)
    end
    return STATUS_STYLE.pending(theme)
end

function VerificationDashboard:_resolveStatusColor(status)
    if not status then
        return nil
    end

    local theme = self._theme or DEFAULT_THEME
    local styleResolver = STATUS_STYLE[status]
    if styleResolver then
        local style = styleResolver(theme)
        return style and style.color or nil
    end

    return nil
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
        step.iconGlow.Transparency = style.strokeTransparency or 0.35
    end

    if step.connector then
        step.connector.BackgroundColor3 = style.color
        step.connector.BackgroundTransparency = status == "pending" and self._theme.connectorTransparency or 0.15
    end

    if step.meta then
        if status == "pending" then
            step.meta.TextColor3 = Color3.fromRGB(168, 182, 210)
        else
            local accentBase = style.color or self._theme.accentColor
            step.meta.TextColor3 = accentBase:Lerp(Color3.fromRGB(230, 236, 248), 0.45)
        end
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
        self:_applyStepState("remotes", "ok", string.format("%s (%s)", snapshot.remoteName or "Virtual input", snapshot.remoteVariant or "F key"))
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
        elseif reason == "parry-remote" or reason == "parry-input" or target == "remote" then
            self:_applyStepState("remotes", "failed", "F-key input unavailable")
        elseif reason == "balls-folder" then
            self:_applyStepState("balls", "warning", "Balls folder not found")
        end
        return
    end

    if stage == "error" then
        if target == "remote" then
            self:_applyStepState("remotes", "failed", snapshot.message or "Virtual input unavailable")
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
                local name = snapshot.remoteName or "Virtual input"
                local variant = snapshot.remoteVariant or "F key"
                self:_applyStepState("remotes", "ok", string.format("%s (%s)", name, variant))
            elseif status == "waiting" or status == "pending" then
                self:_applyStepState("remotes", "active", "Preparing F-key parry input…")
            end
        end
        return
    end

    if stage == "parry-input" then
        if status == "ok" then
            local name = snapshot.remoteName or "Virtual input"
            local variant = snapshot.remoteVariant or "F key"
            self:_applyStepState("remotes", "ok", string.format("%s (%s)", name, variant))
        else
            self:_applyStepState("remotes", "active", "Arming F-key parry input…")
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

function VerificationDashboard:_applyErrorDetail(detail)
    if not detail or self._destroyed then
        return
    end

    local function applyEntry(entry)
        if typeof(entry) == "table" then
            local id = entry.id or entry.stage or entry.step or entry.target
            if id then
                local status = entry.status or entry.state or "failed"
                local message = entry.message or entry.text or detail.summary or detail.message
                local tooltip = entry.tooltip or entry.hint
                self:_applyStepState(id, status, message, tooltip)
            end
        elseif typeof(entry) == "string" then
            local message = detail.summary or detail.message
            self:_applyStepState(entry, detail.timelineStatus or detail.status or "failed", message)
        end
    end

    local timeline = detail.timeline or detail.steps or detail.failingStages
    if typeof(timeline) == "table" then
        if timeline[1] ~= nil then
            for _, entry in ipairs(timeline) do
                applyEntry(entry)
            end
        else
            for _, entry in pairs(timeline) do
                applyEntry(entry)
            end
        end
    elseif typeof(detail.failingStage) == "string" then
        applyEntry({ id = detail.failingStage, status = detail.status or "failed", message = detail.summary or detail.message })
    end

    if detail.meta and self._steps then
        for id, text in pairs(detail.meta) do
            local step = self._steps[id]
            if step and step.meta then
                step.meta.Text = tostring(text)
            end
        end
    end
end

function VerificationDashboard:_applyError(errorState)
    if not errorState then
        return
    end

    local reason, payload = extractErrorReason(errorState)
    local message = errorState.message or "Verification error"

    if reason == "local-player" then
        self:_applyStepState("player", "failed", message)
    elseif reason == "remotes-folder" or reason == "parry-remote" or reason == "parry-input" or reason == "remote" then
        self:_applyStepState("remotes", "failed", message)
    elseif reason == "balls-folder" or reason == "balls" then
        self:_applyStepState("balls", "warning", message)
    else
        self:_applyStepState("success", "warning", message)
    end

    if payload and payload.elapsed then
        self:setStatusText({
            text = string.format("Failed after %s", formatElapsed(payload.elapsed) or "0 s"),
            detail = errorState.detail,
        })
    else
        self:setStatusText({ text = message, detail = errorState.detail })
    end

    if errorState.detail then
        self:_applyErrorDetail(errorState.detail)
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
        self:updateLayout(self._lastLayoutBounds)
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

    self:updateLayout(self._lastLayoutBounds)
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

    self:updateLayout(self._lastLayoutBounds)
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
