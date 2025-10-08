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
local VirtualInputManager = game:FindService("VirtualInputManager")
local CoreGui = game:GetService("CoreGui")

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
    remoteQueueGuards = { "SyncDragonSpirit", "SecondaryEndCD" },
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
    remoteEstimatorActive = false,
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
local remoteQueueGuardConnections: { [string]: { remote: Instance?, connection: RBXScriptConnection?, destroying: RBXScriptConnection?, nameChanged: RBXScriptConnection? } } = {}
local remoteQueueGuardWatchers: { RBXScriptConnection? }?
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
local pendingParryRelease = false
local sendParryKeyEvent
local setStage
local updateStatusLabel
local virtualInputWarningIssued = false
local virtualInputUnavailable = false
local virtualInputRetryAt = 0

local function noteVirtualInputFailure(delay)
    virtualInputUnavailable = true
    if typeof(delay) == "number" and delay > 0 then
        virtualInputRetryAt = os.clock() + delay
    else
        virtualInputRetryAt = os.clock() + 1.5
    end

    if state.enabled then
        setStage("waiting-input", { reason = "virtual-input" })
        updateStatusLabel({ "Auto-Parry F", "Status: waiting for input permissions" })
    end
end

local function noteVirtualInputSuccess()
    if virtualInputUnavailable then
        virtualInputUnavailable = false
        virtualInputRetryAt = 0

        if state.enabled and initProgress.stage == "waiting-input" then
            publishReadyStatus()
        end

        if pendingParryRelease then
            pendingParryRelease = false
            if not sendParryKeyEvent(false) then
                pendingParryRelease = true
            end
        end
    end
end

local immortalController = ImmortalModule and ImmortalModule.new({}) or nil
local immortalMissingMethodWarnings = {}

local function resolveVirtualInputManager()
    if VirtualInputManager then
        return VirtualInputManager
    end

    local ok, manager = pcall(game.GetService, game, "VirtualInputManager")
    if ok and manager then
        VirtualInputManager = manager
        return VirtualInputManager
    end

    ok, manager = pcall(game.FindService, game, "VirtualInputManager")
    if ok and manager then
        VirtualInputManager = manager
        return VirtualInputManager
    end

    return nil
end

local function warnOnceImmortalMissing(methodName)
    if immortalMissingMethodWarnings[methodName] then
        return
    end

    immortalMissingMethodWarnings[methodName] = true
    warn(("AutoParry: Immortal controller missing '%s' support; disabling Immortal features."):format(tostring(methodName)))
end

local function disableImmortalSupport()
    if not state.immortalEnabled then
        return false
    end

    state.immortalEnabled = false
    updateImmortalButton()
    syncGlobalSettings()
    immortalStateChanged:fire(false)
    return true
end

local function callImmortalController(methodName, ...)
    if not immortalController then
        return false
    end

    local method = immortalController[methodName]
    if typeof(method) ~= "function" then
        warnOnceImmortalMissing(methodName)
        disableImmortalSupport()
        return false
    end

    local ok, result = pcall(method, immortalController, ...)
    if not ok then
        warn(("AutoParry: Immortal controller '%s' call failed: %s"):format(tostring(methodName), tostring(result)))
        disableImmortalSupport()
        return false
    end

    return true, result
end

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

local function cubeRoot(value: number)
    if value >= 0 then
        return value ^ (1 / 3)
    end

    return -((-value) ^ (1 / 3))
end

local function smallestPositiveQuadraticRoot(a: number, b: number, c: number)
    if math.abs(a) < EPSILON then
        if math.abs(b) < EPSILON then
            return nil
        end

        local root = -c / b
        if isFiniteNumber(root) and root > EPSILON then
            return root
        end

        return nil
    end

    local discriminant = b * b - 4 * a * c
    if discriminant < -EPSILON then
        return nil
    end

    discriminant = math.max(discriminant, 0)
    local sqrtDiscriminant = math.sqrt(discriminant)
    local q = -0.5 * (b + (b >= 0 and sqrtDiscriminant or -sqrtDiscriminant))

    local candidates = {
        q / a,
    }

    if math.abs(q) > EPSILON then
        candidates[#candidates + 1] = c / q
    else
        candidates[#candidates + 1] = (-b - sqrtDiscriminant) / (2 * a)
    end

    local best: number?
    for _, root in ipairs(candidates) do
        if isFiniteNumber(root) and root > EPSILON then
            if not best or root < best then
                best = root
            end
        end
    end

    return best
end

local function smallestPositiveCubicRoot(a: number, b: number, c: number, d: number)
    if math.abs(a) < EPSILON then
        return smallestPositiveQuadraticRoot(b, c, d)
    end

    local invA = 1 / a
    local A = b * invA
    local B = c * invA
    local C = d * invA

    local sqA = A * A
    local p = B - sqA / 3
    local q = (2 * A * sqA) / 27 - (A * B) / 3 + C

    local discriminant = (q * q) / 4 + (p * p * p) / 27
    local roots = {}

    if discriminant > EPSILON then
        local sqrtDiscriminant = math.sqrt(discriminant)
        local u = cubeRoot(-q / 2 + sqrtDiscriminant)
        local v = cubeRoot(-q / 2 - sqrtDiscriminant)
        roots[1] = u + v - A / 3
    elseif discriminant >= -EPSILON then
        local u = cubeRoot(-q / 2)
        roots[1] = 2 * u - A / 3
        roots[2] = -u - A / 3
    else
        local negPOver3 = -p / 3
        if negPOver3 <= 0 then
            roots[1] = -A / 3
        else
            local sqp = math.sqrt(negPOver3)
            if sqp < EPSILON then
                roots[1] = -A / 3
            else
                local angle = math.acos(math.clamp((-q / 2) / (sqp * sqp * sqp), -1, 1))
                local twoSqp = 2 * sqp
                roots[1] = twoSqp * math.cos(angle / 3) - A / 3
                roots[2] = twoSqp * math.cos((angle + 2 * math.pi) / 3) - A / 3
                roots[3] = twoSqp * math.cos((angle + 4 * math.pi) / 3) - A / 3
            end
        end
    end

    local best: number?
    for _, root in ipairs(roots) do
        if isFiniteNumber(root) and root > EPSILON then
            if not best or root < best then
                best = root
            end
        end
    end

    return best
end

local function solveRadialImpactTime(d0: number, vr: number, ar: number, jr: number)
    if not (isFiniteNumber(d0) and isFiniteNumber(vr) and isFiniteNumber(ar) and isFiniteNumber(jr)) then
        return nil
    end

    local a = jr / 6
    local b = ar / 2
    local c = vr
    local d = d0

    return smallestPositiveCubicRoot(a, b, c, d)
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

local MAX_LATENCY_SAMPLE_SECONDS = 2
local PENDING_LATENCY_MAX_AGE = 5

local latencySamples = {
    lastSample = nil,
    lastLocalSample = nil,
    lastRemoteSample = nil,
}

local pendingLatencyPresses = {}

local function publishLatencyTelemetry()
    local settings = GlobalEnv.Paws
    if typeof(settings) ~= "table" then
        settings = {}
        GlobalEnv.Paws = settings
    end

    settings.ActivationLatency = activationLatencyEstimate
    settings.LatencySamples = latencySamples
    settings.RemoteLatencyActive = state.remoteEstimatorActive
end

local function recordLatencySample(
    sample: number?,
    source: string?,
    ballId: string?,
    telemetry: TelemetryState?,
    now: number?
)
    if not isFiniteNumber(sample) or not sample or sample <= 0 or sample > MAX_LATENCY_SAMPLE_SECONDS then
        return false
    end

    activationLatencyEstimate = emaScalar(activationLatencyEstimate, sample, ACTIVATION_LATENCY_ALPHA)
    if activationLatencyEstimate < 0 then
        activationLatencyEstimate = 0
    end

    if telemetry then
        telemetry.latencySampled = true
    end

    local timestamp = now or os.clock()
    local entry = {
        value = sample,
        source = source or "unknown",
        ballId = ballId,
        time = timestamp,
    }

    latencySamples.lastSample = entry
    if source == "remote" then
        latencySamples.lastRemoteSample = entry
    elseif source == "local" then
        latencySamples.lastLocalSample = entry
    end

    publishLatencyTelemetry()
    return true
end

local function prunePendingLatencyPresses(now: number)
    if #pendingLatencyPresses == 0 then
        return
    end

    for index = #pendingLatencyPresses, 1, -1 do
        local entry = pendingLatencyPresses[index]
        if not entry or not entry.time or now - entry.time > PENDING_LATENCY_MAX_AGE then
            table.remove(pendingLatencyPresses, index)
        end
    end
end

local function handleParrySuccessLatency(...)
    local now = os.clock()
    if #pendingLatencyPresses == 0 then
        return
    end

    for index = #pendingLatencyPresses, 1, -1 do
        local entry = pendingLatencyPresses[index]
        table.remove(pendingLatencyPresses, index)
        if entry and entry.time then
            local elapsed = now - entry.time
            local telemetry = entry.ballId and telemetryStates[entry.ballId] or nil
            if recordLatencySample(elapsed, "remote", entry.ballId, telemetry, now) then
                return
            end
        end
    end
end

parrySuccessSignal:connect(handleParrySuccessLatency)

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
    latencySamples.lastSample = nil
    latencySamples.lastLocalSample = nil
    latencySamples.lastRemoteSample = nil
    pendingLatencyPresses = {}
    publishLatencyTelemetry()
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

local remoteQueueGuardTargets: { [string]: boolean } = {}

local function rebuildRemoteQueueGuardTargets()
    for name in pairs(remoteQueueGuardTargets) do
        remoteQueueGuardTargets[name] = nil
    end

    local defaults = DEFAULT_CONFIG.remoteQueueGuards
    if typeof(defaults) == "table" then
        for _, entry in pairs(defaults) do
            if typeof(entry) == "string" and entry ~= "" then
                remoteQueueGuardTargets[entry] = true
            end
        end
    end

    local overrides = config.remoteQueueGuards
    if typeof(overrides) == "table" then
        for _, entry in pairs(overrides) do
            if typeof(entry) == "string" and entry ~= "" then
                remoteQueueGuardTargets[entry] = true
            end
        end
    end
end

rebuildRemoteQueueGuardTargets()

local function clearRemoteQueueGuards()
    if remoteQueueGuardWatchers then
        disconnectConnections(remoteQueueGuardWatchers)
        remoteQueueGuardWatchers = nil
    end

    for name, guard in pairs(remoteQueueGuardConnections) do
        safeDisconnect(guard.connection)
        safeDisconnect(guard.destroying)
        safeDisconnect(guard.nameChanged)
        remoteQueueGuardConnections[name] = nil
    end
end

local function dropRemoteQueueGuard(remote)
    if not remote then
        return
    end

    local name = remote.Name
    local guard = remoteQueueGuardConnections[name]
    if guard and guard.remote == remote then
        safeDisconnect(guard.connection)
        safeDisconnect(guard.destroying)
        safeDisconnect(guard.nameChanged)
        remoteQueueGuardConnections[name] = nil
    end
end

local function attachRemoteQueueGuard(remote)
    if not remote or not remoteQueueGuardTargets[remote.Name] then
        return
    end

    local okClass, isEvent = pcall(function()
        return remote:IsA("RemoteEvent")
    end)

    if not okClass or not isEvent then
        return
    end

    local name = remote.Name
    local existing = remoteQueueGuardConnections[name]
    if existing and existing.remote == remote and existing.connection then
        return
    end

    if existing then
        safeDisconnect(existing.connection)
        safeDisconnect(existing.destroying)
        safeDisconnect(existing.nameChanged)
        remoteQueueGuardConnections[name] = nil
    end

    local okSignal, signal = pcall(function()
        return remote.OnClientEvent
    end)

    if not okSignal or signal == nil then
        return
    end

    local okConnect, connection = pcall(function()
        return signal:Connect(function() end)
    end)

    if not okConnect or not connection then
        return
    end

    local destroyingConnection = connectInstanceEvent(remote, "Destroying", function()
        dropRemoteQueueGuard(remote)
    end)

    local nameChangedConnection = connectPropertyChangedSignal(remote, "Name", function()
        local newName = remote.Name
        if not remoteQueueGuardTargets[newName] then
            dropRemoteQueueGuard(remote)
            return
        end

        local existingGuard = remoteQueueGuardConnections[newName]
        if existingGuard and existingGuard.remote ~= remote then
            dropRemoteQueueGuard(existingGuard.remote)
        end

        local currentGuard = remoteQueueGuardConnections[name]
        if currentGuard and currentGuard.remote == remote then
            remoteQueueGuardConnections[name] = nil
            remoteQueueGuardConnections[newName] = currentGuard
        end

        name = newName
    end)

    remoteQueueGuardConnections[name] = {
        remote = remote,
        connection = connection,
        destroying = destroyingConnection,
        nameChanged = nameChangedConnection,
    }
end

local function setRemoteQueueGuardFolder(folder)
    clearRemoteQueueGuards()

    if not folder then
        return
    end

    for name in pairs(remoteQueueGuardTargets) do
        local remote = folder:FindFirstChild(name)
        if remote then
            attachRemoteQueueGuard(remote)
        end
    end

    local watchers = {}

    local addedConnection = folder.ChildAdded:Connect(function(child)
        attachRemoteQueueGuard(child)
    end)
    table.insert(watchers, addedConnection)

    local removedConnection = folder.ChildRemoved:Connect(function(child)
        dropRemoteQueueGuard(child)
    end)
    table.insert(watchers, removedConnection)

    local destroyingConnection = connectInstanceEvent(folder, "Destroying", function()
        clearRemoteQueueGuards()
    end)
    if destroyingConnection then
        table.insert(watchers, destroyingConnection)
    end

    remoteQueueGuardWatchers = watchers
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
    if state.remoteEstimatorActive then
        state.remoteEstimatorActive = false
        publishLatencyTelemetry()
    end
end

local function clearRemoteState()
    disconnectVerificationWatchers()
    disconnectSuccessListeners()
    ParryInputInfo = nil
    RemotesFolder = nil
    clearRemoteQueueGuards()
    if ballsFolderConnections then
        disconnectConnections(ballsFolderConnections)
        ballsFolderConnections = nil
    end
    BallsFolder = nil
    watchedBallsFolder = nil
    pendingBallsFolderSearch = false
    ballsFolderStatusSnapshot = nil
    pendingLatencyPresses = {}
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

    state.remoteEstimatorActive = status.ParrySuccess == true
    publishLatencyTelemetry()

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

setStage = function(stage, extra)
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
    settings.LatencySamples = latencySamples
    settings.RemoteLatencyActive = state.remoteEstimatorActive
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

updateStatusLabel = function(lines)
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

    local okContext = callImmortalController("setContext", {
        player = LocalPlayer,
        character = Character,
        humanoid = Humanoid,
        rootPart = RootPart,
        ballsFolder = BallsFolder,
    })

    if not okContext then
        return
    end

    if not callImmortalController("setBallsFolder", BallsFolder) then
        return
    end

    callImmortalController("setEnabled", state.immortalEnabled)
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

sendParryKeyEvent = function(isPressed)
    local manager = resolveVirtualInputManager()
    if not manager then
        if not virtualInputWarningIssued then
            virtualInputWarningIssued = true
            warn("AutoParry: VirtualInputManager unavailable; cannot issue parry input.")
        end
        noteVirtualInputFailure(3)
        return false
    end

    local okMethod, method = pcall(function()
        return manager.SendKeyEvent
    end)

    if not okMethod or typeof(method) ~= "function" then
        if not virtualInputWarningIssued then
            virtualInputWarningIssued = true
            warn("AutoParry: VirtualInputManager.SendKeyEvent missing; cannot issue parry input.")
        end
        noteVirtualInputFailure(3)
        return false
    end

    local success, result = pcall(method, manager, isPressed, Enum.KeyCode.F, false, game)
    if not success then
        if not virtualInputWarningIssued then
            virtualInputWarningIssued = true
            warn("AutoParry: failed to send parry input via VirtualInputManager:", result)
        end
        noteVirtualInputFailure(2)
        return false
    end

    if virtualInputWarningIssued then
        virtualInputWarningIssued = false
    end

    noteVirtualInputSuccess()

    return true
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


local function pressParry(ball: BasePart?, ballId: string?, force: boolean?)
    local forcing = force == true
    if virtualInputUnavailable and virtualInputRetryAt > os.clock() and not forcing then
        return false
    end

    if parryHeld then
        local sameBall = parryHeldBallId == ballId
        if sameBall and not forcing then
            return false
        end

        -- release the existing hold before pressing again or for a new ball
        if virtualInputUnavailable and virtualInputRetryAt > os.clock() then
            pendingParryRelease = true
        else
            if not sendParryKeyEvent(false) then
                pendingParryRelease = true
            else
                pendingParryRelease = false
            end
        end
        parryHeld = false
        parryHeldBallId = nil
    end

    if not sendParryKeyEvent(true) then
        return false
    end

    pendingParryRelease = false

    parryHeld = true
    parryHeldBallId = ballId

    local now = os.clock()
    state.lastParry = now
    prunePendingLatencyPresses(now)
    pendingLatencyPresses[#pendingLatencyPresses + 1] = { time = now, ballId = ballId }

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
    if virtualInputUnavailable and virtualInputRetryAt > os.clock() then
        pendingParryRelease = true
    else
        if not sendParryKeyEvent(false) then
            pendingParryRelease = true
        else
            pendingParryRelease = false
        end
    end

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
    callImmortalController("handleHumanoidDied")
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
        setRemoteQueueGuardFolder(RemotesFolder)

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
    prunePendingLatencyPresses(now)

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
    local timeToImpactFallback = math.huge
    local timeToImpactPolynomial: number?
    local timeToImpact = math.huge
    if approaching then
        local speed = math.max(approachSpeed, EPSILON)
        timeToImpactFallback = distance / speed

        local impactRadial = filteredD
        local polynomial = solveRadialImpactTime(impactRadial, filteredVr, filteredAr, filteredJr)
        if polynomial and polynomial > EPSILON then
            timeToImpactPolynomial = polynomial
            timeToImpact = polynomial
        elseif isFiniteNumber(timeToImpactFallback) and timeToImpactFallback >= 0 then
            timeToImpact = timeToImpactFallback
        end
    end

    local responseWindowBase = math.max(delta + PROXIMITY_PRESS_GRACE, PROXIMITY_PRESS_GRACE)
    if approaching and timeToImpactPolynomial then
        responseWindowBase = math.max(math.min(responseWindowBase, timeToImpactPolynomial), PROXIMITY_PRESS_GRACE)
    end
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

    local timeToPressRadiusFallback = math.huge
    local timeToHoldRadiusFallback = math.huge
    local timeToPressRadiusPolynomial: number?
    local timeToHoldRadiusPolynomial: number?
    local timeToPressRadius = math.huge
    local timeToHoldRadius = math.huge
    if approaching then
        local speed = math.max(approachSpeed, EPSILON)
        timeToPressRadiusFallback = math.max(distance - pressRadius, 0) / speed
        timeToHoldRadiusFallback = math.max(distance - holdRadius, 0) / speed

        local radialToPress = filteredD + safeRadius - pressRadius
        local radialToHold = filteredD + safeRadius - holdRadius

        local pressPolynomial = solveRadialImpactTime(radialToPress, filteredVr, filteredAr, filteredJr)
        if pressPolynomial and pressPolynomial > EPSILON then
            timeToPressRadiusPolynomial = pressPolynomial
            timeToPressRadius = pressPolynomial
        else
            timeToPressRadius = timeToPressRadiusFallback
        end

        local holdPolynomial = solveRadialImpactTime(radialToHold, filteredVr, filteredAr, filteredJr)
        if holdPolynomial and holdPolynomial > EPSILON then
            timeToHoldRadiusPolynomial = holdPolynomial
            timeToHoldRadius = holdPolynomial
        else
            timeToHoldRadius = timeToHoldRadiusFallback
        end
    end

    local holdWindow = responseWindow + PROXIMITY_HOLD_GRACE
    if approaching and timeToHoldRadiusPolynomial then
        local refinedHoldWindow = math.max(timeToHoldRadiusPolynomial, PROXIMITY_HOLD_GRACE)
        holdWindow = math.min(holdWindow, refinedHoldWindow)
        if holdWindow < responseWindow then
            holdWindow = responseWindow
        end
    end
    holdWindow = math.max(holdWindow, PROXIMITY_HOLD_GRACE)

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
        if triggerTime and telemetry and not telemetry.latencySampled then
            local sample = now - triggerTime
            if sample > 0 and sample <= MAX_LATENCY_SAMPLE_SECONDS then
                recordLatencySample(sample, "local", ballId, telemetry, now)
            elseif sample > PENDING_LATENCY_MAX_AGE then
                telemetry.latencySampled = true
            end
        end
    end

    if parryHeld then
        if (not shouldHold) or (parryHeldBallId and parryHeldBallId ~= ballId) then
            releaseParry()
            released = true
        end
    end

    local latencyEntry = latencySamples.lastSample
    local latencyText = "none"
    if latencyEntry and isFiniteNumber(latencyEntry.value) then
        local ageMs = 0
        if latencyEntry.time then
            ageMs = math.max((now - latencyEntry.time) * 1000, 0)
        end
        latencyText = string.format(
            "%s %.3f (%dms)",
            latencyEntry.source or "?",
            latencyEntry.value,
            math.floor(ageMs + 0.5)
        )
    end

    local timeToImpactPolyText = "n/a"
    if timeToImpactPolynomial then
        timeToImpactPolyText = string.format("%.3f", timeToImpactPolynomial)
    end
    local timeToImpactFallbackText = "n/a"
    if isFiniteNumber(timeToImpactFallback) and timeToImpactFallback < math.huge then
        timeToImpactFallbackText = string.format("%.3f", timeToImpactFallback)
    end

    local debugLines = {
        "Auto-Parry F",
        string.format("Ball: %s", ball.Name),
        string.format("d0: %.3f | vr: %.3f", filteredD, filteredVr),
        string.format("ar: %.3f | jr: %.3f", filteredAr, filteredJr),
        string.format("μ: %.3f | σ: %.3f | z: %.2f", mu, sigma, z),
        string.format("μ+zσ: %.3f | μ−zσ: %.3f", muPlus, muMinus),
        string.format("Δ: %.3f | ping: %.3f | act: %.3f", delta, ping, activationLatencyEstimate),
        string.format("Latency sample: %s | remoteActive: %s", latencyText, tostring(state.remoteEstimatorActive)),
        string.format("TTI(poly|fb): %s | %s", timeToImpactPolyText, timeToImpactFallbackText),
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
        string.format("Targeting: %s", tostring(targetingMe)),
        string.format(
            "Osc: trig %s | flips %d | freq %.2f | dΔ %.3f | spam %s",
            tostring(telemetry.oscillationActive),
            telemetry.lastOscillationCount or 0,
            telemetry.lastOscillationFrequency or 0,
            telemetry.lastOscillationDelta or 0,
            tostring(spamFallback)
        ),
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
    remoteQueueGuards = function(value)
        if value == nil then
            return true
        end

        if typeof(value) ~= "table" then
            return false
        end

        for _, entry in pairs(value) do
            if typeof(entry) ~= "string" or entry == "" then
                return false
            end
        end

        return true
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
    local before = state.immortalEnabled

    state.immortalEnabled = desired
    syncImmortalContext()

    local after = state.immortalEnabled
    updateImmortalButton()
    syncGlobalSettings()

    if before ~= after then
        immortalStateChanged:fire(after)
    end

    return after
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
    elseif key == "remoteQueueGuards" then
        rebuildRemoteQueueGuardTargets()
        setRemoteQueueGuardFolder(RemotesFolder)
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
    rebuildRemoteQueueGuardTargets()
    setRemoteQueueGuardFolder(RemotesFolder)
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
    callImmortalController("destroy")

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
