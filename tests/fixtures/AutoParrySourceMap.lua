-- Auto-generated source map for AutoParry tests
return {
    ['src/core/autoparry.lua'] = [===[
-- src/core/autoparry.lua (sha1: 129a82cc5ffebe996e2694c561ba9513714c6131)
-- mikkel32/AutoParry : src/core/autoparry.lua
-- selene: allow(global_usage)
-- Auto-parry implementation that mirrors the "Auto-Parry (F-Key Proximity)" logic
-- shared by the user: it presses the local "F" key via VirtualInputManager when a
-- tracked projectile is about to reach the player. The module keeps the public
-- AutoParry API that the rest of the experience relies on (configure, signals,
-- destroy, etc.) while swapping the internal behaviour for the requested
-- proximity/TTI based approach.

local Require = rawget(_G, "ARequire")
local Util = Require and Require("src/shared/util.lua") or require(script.Parent.Parent.shared.util)

local Signal = Util.Signal
local Verification = Require and Require("src/core/verification.lua") or require(script.Parent.verification)
local ImmortalModule = Require and Require("src/core/immortal.lua") or require(script.Parent.immortal)

local Helpers = {}

local emitTelemetryEvent
local telemetryDispatcher: ((string, { [string]: any }?) -> any)? = nil
local pendingTelemetryEvents = {}
local MAX_PENDING_TELEMETRY_EVENTS = 128
local MIN_TRANSIENT_RETRY_COOLDOWN = 1 / 60

local function queueTelemetryEvent(eventType: string, payload: { [string]: any }?)
    pendingTelemetryEvents[#pendingTelemetryEvents + 1] = {
        eventType = eventType,
        payload = payload,
    }

    if #pendingTelemetryEvents > MAX_PENDING_TELEMETRY_EVENTS then
        table.remove(pendingTelemetryEvents, 1)
    end
end

local function flushPendingTelemetryEvents()
    if typeof(telemetryDispatcher) ~= "function" then
        return
    end

    if #pendingTelemetryEvents == 0 then
        return
    end

    local queued = pendingTelemetryEvents
    pendingTelemetryEvents = {}

    for _, entry in ipairs(queued) do
        telemetryDispatcher(entry.eventType, entry.payload)
    end
end

emitTelemetryEvent = function(eventType: string, payload: { [string]: any }?)
    if typeof(telemetryDispatcher) == "function" then
        return telemetryDispatcher(eventType, payload)
    end

    queueTelemetryEvent(eventType, payload)
    return nil
end

local Services = (function()
    local players = game:GetService("Players")
    local runService = game:GetService("RunService")
    local workspaceService = game:GetService("Workspace")
    local stats = game:FindService("Stats")
    local vim = game:FindService("VirtualInputManager")
    local coreGui = game:GetService("CoreGui")

    return {
        Players = players,
        RunService = runService,
        Workspace = workspaceService,
        Stats = stats,
        VirtualInputManager = vim,
        CoreGui = coreGui,
    }
end)()

local Defaults = (function()
    local smartTuning = {
        enabled = true,
        minSlack = 0.008,
        maxSlack = 0.04,
        sigmaLead = 1.15,
        slackAlpha = 0.5,
        minConfidence = 0.025,
        maxConfidence = 0.26,
        sigmaConfidence = 0.85,
        confidenceAlpha = 0.45,
        reactionLatencyShare = 0.5,
        overshootShare = 0.28,
        reactionAlpha = 0.45,
        minReactionBias = 0.008,
        maxReactionBias = 0.16,
        deltaAlpha = 0.35,
        pingAlpha = 0.45,
        overshootAlpha = 0.4,
        sigmaFloor = 0.0025,
        commitP99Target = 0.01,
        commitReactionGain = 1.35,
        commitSlackGain = 0.85,
        lookaheadGoal = 0.9,
        lookaheadQuantile = 0.1,
        lookaheadReactionGain = 0.65,
        lookaheadSlackGain = 0.4,
        enforceBaseSlack = true,
        enforceBaseConfidence = true,
        enforceBaseReaction = true,
    }

    local autoTuning = {
        enabled = false,
        intervalSeconds = 30,
        minSamples = 9,
        allowWhenSmartTuning = false,
        dryRun = false,
        leadGain = 0.75,
        slackGain = 0.65,
        latencyGain = 0.65,
        leadTolerance = 0.004,
        waitTolerance = 0.0025,
        maxReactionBias = 0.24,
        maxScheduleSlack = 0.08,
        maxActivationLatency = 0.35,
        minDelta = 0.0003,
        maxAdjustmentsPerRun = 3,
    }

    local configDefaults = {
        cooldown = 0.1,
        minSpeed = 10,
        pingOffset = 0.05,
        minTTI = 0.12,
        maxTTI = 0.55,
        safeRadius = 10,
        curvatureLeadScale = 0.12,
        curvatureHoldBoost = 0.5,
        confidenceZ = 2.2,
        activationLatency = 0.12,
        pressReactionBias = 0.02,
        pressScheduleSlack = 0.015,
        pressMaxLookahead = 1.2,
        pressLookaheadGoal = 0.9,
        pressConfidencePadding = 0.08,
        pressMinDetectionTime = 0,
        targetHighlightName = "Highlight",
        ballsFolderName = "Balls",
        playerTimeout = 10,
        remotesTimeout = 10,
        ballsFolderTimeout = 5,
        verificationRetryInterval = 0,
        remoteQueueGuards = { "SyncDragonSpirit", "SecondaryEndCD" },
        oscillationFrequency = 3,
        oscillationDistanceDelta = 0.35,
        oscillationSpamCooldown = 0.15,
        oscillationMaxLookahead = 0.45,
        oscillationSpamBurstPresses = 2,
        oscillationSpamBurstGap = 0.05,
        oscillationSpamBurstWindow = 0.28,
        oscillationSpamBurstLookahead = 0.6,
        oscillationSpamMinGap = 1 / 180,
        oscillationSpamPanicTightness = 0.72,
        oscillationSpamPanicGapScale = 0.42,
        oscillationSpamPanicWindowScale = 1.35,
        oscillationSpamPanicLookaheadBoost = 0.2,
        oscillationSpamPanicSpeedDelta = 40,
        oscillationSpamPanicSlack = 0.012,
        oscillationSpamRecoverySeconds = 0.18,
        oscillationSpamCooldownTightnessGain = 0.55,
        oscillationSpamCooldownPanicScale = 0.4,
    }

    configDefaults.smartTuning = smartTuning
    configDefaults.autoTuning = autoTuning

    return {
        SMART_TUNING = smartTuning,
        AUTO_TUNING = autoTuning,
        CONFIG = configDefaults,
    }
end)()

function Helpers.getGlobalTable()
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

local GlobalEnv = Helpers.getGlobalTable()
GlobalEnv.Paws = GlobalEnv.Paws or {}
GlobalEnv.LastPressEvent = GlobalEnv.LastPressEvent or nil

local function ensurePressEventProxy()
    if typeof(GlobalEnv.PressEventProxy) == "table" then
        return GlobalEnv.PressEventProxy
    end

    local proxy = {}
    local defaults = {
        reactionTime = 0,
        decisionTime = 0,
        decisionToPressTime = 0,
    }

    setmetatable(proxy, {
        __index = function(_, key)
            local last = GlobalEnv.LastPressEvent
            if typeof(last) == "table" then
                local value = last[key]
                if value ~= nil then
                    return value
                end
            end
            return defaults[key]
        end,
        __newindex = function(_, key, value)
            if typeof(GlobalEnv.LastPressEvent) ~= "table" then
                GlobalEnv.LastPressEvent = {}
            end
            GlobalEnv.LastPressEvent[key] = value
        end,
    })

    GlobalEnv.PressEventProxy = proxy
    if typeof(_G) == "table" then
        _G.pressEvent = proxy
        _G.AutoParryLastPressEvent = proxy
    end

    return proxy
end

ensurePressEventProxy()

local config = Util.deepCopy(Defaults.CONFIG)

local Constants = {
    EPSILON = 1e-6,
    SMOOTH_ALPHA = 0.25,
    KAPPA_ALPHA = 0.3,
    DKAPPA_ALPHA = 0.3,
    ACTIVATION_LATENCY_ALPHA = 0.2,
    VR_SIGN_EPSILON = 1e-3,
    OSCILLATION_HISTORY_SECONDS = 0.6,
    TARGETING_GRACE_SECONDS = 0.2,
    SIMULATION_MIN_STEPS = 12,
    SIMULATION_MAX_STEPS = 72,
    SIMULATION_RESOLUTION = 1 / 180,
    BALLISTIC_CACHE_MAX_AGE = 0.05,
    BALLISTIC_CACHE_TOLERANCE = {
        safe = 0.03,
        distance = 0.045,
        vr = 1.6,
        ar = 12,
        jr = 150,
        curvature = 0.45,
        curvatureRate = 12,
        horizon = 0.03,
        maxHorizon = 0.06,
        speed = 1.2,
    },
    BALLISTIC_CACHE_RELATIVE = {
        safe = 0.02,
        distance = 0.025,
        vr = 0.04,
        ar = 0.06,
        jr = 0.12,
        curvature = 0.18,
        curvatureRate = 0.22,
        horizon = 0.08,
        maxHorizon = 0.1,
        speed = 0.05,
    },
    BALLISTIC_CACHE_QUANTIZE = {
        safe = 0.02,
        distance = 0.03,
        vr = 1,
        ar = 8,
        jr = 120,
        curvature = 0.3,
        curvatureRate = 8,
        horizon = 0.02,
        maxHorizon = 0.04,
        speed = 0.75,
    },
    THREAT_SPECTRUM_MIN_DT = 1 / 240,
    THREAT_SPECTRUM_MAX_DT = 0.75,
    THREAT_SPECTRUM_FAST_ALPHA = 0.55,
    THREAT_SPECTRUM_MEDIUM_ALPHA = 0.35,
    THREAT_SPECTRUM_SLOW_ALPHA = 0.18,
    THREAT_SPECTRUM_LOAD_ALPHA = 0.45,
    THREAT_SPECTRUM_ACCEL_ALPHA = 0.5,
    THREAT_SPECTRUM_JERK_ALPHA = 0.35,
    THREAT_SPECTRUM_DETECTION_MAX_BONUS = 0.45,
    THREAT_SPECTRUM_DETECTION_LOAD_WEIGHT = 0.38,
    THREAT_SPECTRUM_DETECTION_ACCEL_WEIGHT = 0.22,
    THREAT_SPECTRUM_DETECTION_TEMPO_WEIGHT = 0.18,
    THREAT_SPECTRUM_DETECTION_URGENCY_WEIGHT = 0.14,
    THREAT_SPECTRUM_SCORE_LOGISTIC_WEIGHT = 0.42,
    THREAT_SPECTRUM_SCORE_INTENSITY_WEIGHT = 0.23,
    THREAT_SPECTRUM_SCORE_CONFIDENCE_WEIGHT = 0.18,
    THREAT_SPECTRUM_SCORE_LOAD_WEIGHT = 0.12,
    THREAT_SPECTRUM_SCORE_TEMPO_WEIGHT = 0.05,
    THREAT_SPECTRUM_CONFIDENCE_LOGISTIC_WEIGHT = 0.45,
    THREAT_SPECTRUM_CONFIDENCE_INTENSITY_WEIGHT = 0.2,
    THREAT_SPECTRUM_CONFIDENCE_CONFIDENCE_WEIGHT = 0.2,
    THREAT_SPECTRUM_CONFIDENCE_LOAD_WEIGHT = 0.15,
    THREAT_SPECTRUM_READY_THRESHOLD = 0.32,
    THREAT_SPECTRUM_READY_CONFIDENCE = 0.82,
    THREAT_THRESHOLDS = {
        { status = "critical", threshold = 0.85 },
        { status = "high", threshold = 0.65 },
        { status = "medium", threshold = 0.4 },
        { status = "low", threshold = 0.2 },
        { status = "idle", threshold = 0 },
    },
    THREAT_EVENT_MIN_INTERVAL = 1 / 40,
    THREAT_EVENT_MIN_DELTA = 0.04,
    THREAT_MOMENTUM_ALPHA = 0.6,
    THREAT_VOLATILITY_ALPHA = 0.45,
    THREAT_STABILITY_ALPHA = 0.35,
    THREAT_CONFIDENCE_ALPHA = 0.55,
    DETECTION_CONFIDENCE_GRACE = 0.02,
    SIGMA_FLOORS = {
        d = 0.01,
        vr = 1.5,
        ar = 10,
        jr = 80,
    },
    PHYSICS_LIMITS = {
        curvature = 5,
        curvatureRate = 120,
        radialAcceleration = 650,
        radialJerk = 20000,
    },
}

local SPAM_MIN_GAP = 1 / 120
local SPAM_EXPIRY_MARGIN = 0.045
local SPAM_LOOKAHEAD_BONUS = 0.22
local SPAM_WINDOW_EXTENSION = 0.3
local TARGETING_PRESSURE_WINDOW = 1.4
local TARGETING_PRESSURE_RATE_THRESHOLD = 1.55
local TARGETING_PRESSURE_INTERVAL_THRESHOLD = 0.3
local TARGETING_PRESSURE_PRESS_WINDOW = 0.42
local TARGETING_PRESSURE_GAP_THRESHOLD = 0.18
local TARGETING_PRESSURE_SPEED_DELTA = 55
local TARGETING_PRESSURE_LOOKAHEAD_BOOST = 0.24
local TARGETING_PRESSURE_REARM = 0.06
local TARGETING_MEMORY_SCALE = 0.12
local TARGETING_MEMORY_HALF_LIFE = 0.65
local TARGETING_MOMENTUM_HALF_LIFE = 1.8
local TARGETING_MEMORY_RECENT_PRESS = 0.32
local TARGETING_MEMORY_RETARGET_WINDOW = 0.55
local TARGETING_MEMORY_SPEED_DELTA = 65
local TARGETING_MEMORY_IMPACT_WINDOW = 0.5
local TARGETING_PRESSURE_MEMORY_THRESHOLD = 1.25
local TARGETING_PRESSURE_MOMENTUM_THRESHOLD = 0.8
local state = {
    enabled = false,
    connection = nil,
    lastParry = 0,
    lastSuccess = 0,
    lastBroadcast = 0,
    immortalEnabled = false,
    remoteEstimatorActive = false,
    virtualInputRetry = {
        failureCount = 0,
        min = 0.05,
        max = 0.25,
        base = 0.12,
        growth = 1.5,
    },
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
local telemetrySignal = Signal.new()

local Context = {
    player = {
        LocalPlayer = nil :: Player?,
        Character = nil :: Model?,
        RootPart = nil :: BasePart?,
        Humanoid = nil :: Humanoid?,
        BallsFolder = nil :: Instance?,
        WatchedBallsFolder = nil :: Instance?,
        RemotesFolder = nil :: Instance?,
        ParryInputInfo = nil :: { [string]: any }?,
    },
    watchers = {
        verification = {} :: { { RBXScriptConnection? } },
        success = {} :: { RBXScriptConnection? },
        successSnapshot = nil :: { [string]: boolean }?,
        ballsSnapshot = nil :: { [string]: any }?,
        ballsConnections = nil :: { RBXScriptConnection? }?,
        remoteQueueGuards = {} :: {
            [string]: {
                remote: Instance?,
                connection: RBXScriptConnection?,
                destroying: RBXScriptConnection?,
                nameChanged: RBXScriptConnection?,
            }
        },
        remoteQueueGuardWatchers = nil :: { RBXScriptConnection? }?,
    },
    runtime = {
        restartPending = false,
        scheduleRestart = nil,
        syncImmortalContext = function() end,
        targetingGraceUntil = 0,
        trackedBall = nil :: BasePart?,
        parryHeld = false,
        parryHeldBallId = nil :: string?,
        pendingParryRelease = false,
        virtualInputWarningIssued = false,
        virtualInputUnavailable = false,
        virtualInputRetryAt = 0,
        telemetrySummary = nil,
        telemetrySummaryTrend = nil,
        targetingHighlightPresent = false,
        targetingHighlightGraceActive = false,
        targetingHighlightPulseQueue = nil :: { number }?,
        targetingHighlightDropQueue = nil :: { number }?,
        targetingSpamSuspendedUntil = 0,
        transientRetryActive = false,
        transientRetryCount = 0,
        transientRetryCooldown = 0,
        transientRetryCooldownBallId = nil :: string?,
        spamBurst = {
            active = false,
            ballId = nil :: string?,
            remaining = 0,
            nextPressAt = 0,
            expireAt = 0,
            gap = 0,
            dynamicGap = 0,
            dynamicLookahead = math.huge,
            window = 0,
            maxLookahead = math.huge,
            startedAt = 0,
            lastPressAt = 0,
            failures = 0,
            reason = nil :: string?,
            initialDecision = nil :: { [string]: any }?,
            baseSettings = nil :: { presses: number, gap: number, window: number, lookahead: number }?,
            tightness = 0,
            predictedImpact = nil :: number?,
            panicUntil = 0,
            panicActive = false,
            panicReason = nil :: string?,
            mode = "idle",
            statsAggression = 0,
            statsSamples = 0,
            triggerOptions = nil :: { [string]: any }?,
        },
    },
    ui = {
        Root = nil :: ScreenGui?,
        ToggleButton = nil :: TextButton?,
        ImmortalButton = nil :: TextButton?,
        RemoveButton = nil :: TextButton?,
        StatusLabel = nil :: TextLabel?,
        BallHighlight = nil :: Highlight?,
        BallBillboard = nil :: BillboardGui?,
        BallStatsLabel = nil :: TextLabel?,
    },
    connections = {
        loop = nil :: RBXScriptConnection?,
        humanoidDied = nil :: RBXScriptConnection?,
        characterAdded = nil :: RBXScriptConnection?,
        characterRemoving = nil :: RBXScriptConnection?,
    },
    telemetry = {
        historyLimit = 200,
        history = {} :: { { [string]: any } },
        sequence = 0,
    },
    hooks = {
        sendParryKeyEvent = nil,
        publishReadyStatus = nil,
        setStage = nil,
        updateStatusLabel = nil,
    },
    scheduledPressState = {
        ballId = nil :: string?,
        pressAt = 0,
        predictedImpact = math.huge,
        lead = 0,
        slack = 0,
        reason = nil :: string?,
        lastUpdate = 0,
        immediate = false,
        lastSnapshot = nil,
    },
    smartPress = {
        triggerGrace = 0.01,
        staleSeconds = 0.75,
    },
}

function Helpers.isFiniteNumber(value: number?)
    return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function Helpers.newAggregate()
    return { count = 0, sum = 0, sumSquares = 0, min = nil, max = nil }
end

function Helpers.updateAggregate(target, value)
    if not target or not Helpers.isFiniteNumber(value) then
        return
    end

    local count = target.count or 0
    local sum = target.sum or 0
    local sumSquares = target.sumSquares or 0

    count += 1
    sum += value
    sumSquares += value * value

    target.count = count
    target.sum = sum
    target.sumSquares = sumSquares

    if target.min == nil or value < target.min then
        target.min = value
    end
    if target.max == nil or value > target.max then
        target.max = value
    end
end

function Helpers.summariseAggregate(source)
    if typeof(source) ~= "table" then
        return { count = 0 }
    end

    local count = source.count or 0
    if count <= 0 then
        return { count = 0 }
    end

    local sum = source.sum or 0
    local mean = sum / count
    local variance = 0
    if source.sumSquares then
        variance = math.max((source.sumSquares / count) - mean * mean, 0)
    end

    return {
        count = count,
        min = source.min,
        max = source.max,
        mean = mean,
        stdDev = math.sqrt(variance),
    }
end

function Helpers.newQuantileEstimator(targetQuantile, maxSamples)
    local quantile = targetQuantile
    if not Helpers.isFiniteNumber(quantile) then
        quantile = 0.5
    end
    quantile = math.clamp(quantile, 0, 1)

    local capacity = maxSamples
    if not Helpers.isFiniteNumber(capacity) or capacity < 3 then
        capacity = 256
    end
    capacity = math.floor(capacity + 0.5)
    if capacity < 3 then
        capacity = 3
    end

    return {
        quantile = quantile,
        maxSamples = capacity,
        samples = {},
        queue = {},
    }
end

function Helpers.quantileBinaryInsert(samples, value)
    local low = 1
    local high = #samples
    while low <= high do
        local mid = math.floor((low + high) / 2)
        local current = samples[mid]
        if value < current then
            high = mid - 1
        else
            low = mid + 1
        end
    end

    table.insert(samples, low, value)
end

function Helpers.quantileRemoveValue(samples, value)
    local low = 1
    local high = #samples
    while low <= high do
        local mid = math.floor((low + high) / 2)
        local current = samples[mid]
        if math.abs(current - value) <= 1e-9 then
            table.remove(samples, mid)
            return true
        elseif value < current then
            high = mid - 1
        else
            low = mid + 1
        end
    end

    for index = 1, #samples do
        if math.abs(samples[index] - value) <= 1e-9 then
            table.remove(samples, index)
            return true
        end
    end

    return false
end

function Helpers.updateQuantileEstimator(estimator, value)
    if typeof(estimator) ~= "table" or not Helpers.isFiniteNumber(value) then
        return
    end

    local samples = estimator.samples
    if typeof(samples) ~= "table" then
        samples = {}
        estimator.samples = samples
    end

    local queue = estimator.queue
    if typeof(queue) ~= "table" then
        queue = {}
        estimator.queue = queue
    end

    Helpers.quantileBinaryInsert(samples, value)
    queue[#queue + 1] = value

    local capacity = estimator.maxSamples
    if not Helpers.isFiniteNumber(capacity) or capacity < 3 then
        capacity = 256
        estimator.maxSamples = capacity
    end

    capacity = math.floor(capacity + 0.5)
    if capacity < 3 then
        capacity = 3
        estimator.maxSamples = capacity
    end

    while #queue > capacity do
        local oldest = table.remove(queue, 1)
        if oldest ~= nil then
            Helpers.quantileRemoveValue(samples, oldest)
        end
    end
end

function Helpers.summariseQuantileEstimator(estimator)
    if typeof(estimator) ~= "table" then
        return { count = 0 }
    end

    local samples = estimator.samples
    if typeof(samples) ~= "table" or #samples == 0 then
        return { count = 0 }
    end

    local count = #samples
    local quantile = estimator.quantile
    if not Helpers.isFiniteNumber(quantile) then
        quantile = 0.5
    end
    quantile = math.clamp(quantile, 0, 1)

    local index = math.floor(quantile * (count - 1) + 1.5)
    index = math.clamp(index, 1, count)

    return {
        count = count,
        value = samples[index],
        min = samples[1],
        max = samples[count],
    }
end

function Helpers.getQuantileValue(estimator)
    local summary = Helpers.summariseQuantileEstimator(estimator)
    if typeof(summary) ~= "table" then
        return nil
    end

    return summary.value
end

function Helpers.cloneCounts(source)
    local result = {}
    if typeof(source) ~= "table" then
        return result
    end

    for key, value in pairs(source) do
        result[key] = value
    end

    return result
end

function Helpers.incrementCount(container, key, delta)
    if typeof(container) ~= "table" then
        return
    end

    local current = container[key]
    if typeof(current) ~= "number" then
        current = 0
    end

    container[key] = current + (delta or 1)
end

function Helpers.clearTable(target)
    if typeof(target) ~= "table" then
        return
    end

    for key in pairs(target) do
        target[key] = nil
    end
end

function Helpers.significantDelta(previous, current, absoluteTolerance, relativeTolerance)
    if not Helpers.isFiniteNumber(previous) or not Helpers.isFiniteNumber(current) then
        return true
    end

    local delta = math.abs(previous - current)
    if absoluteTolerance and absoluteTolerance > 0 and delta <= absoluteTolerance then
        return false
    end

    if relativeTolerance and relativeTolerance > 0 then
        local scale = math.max(math.abs(previous), math.abs(current), 1)
        if delta <= scale * relativeTolerance then
            return false
        end
    end

    if (not absoluteTolerance or absoluteTolerance <= 0) and (not relativeTolerance or relativeTolerance <= 0) then
        return delta > 0
    end

    return true
end

function Helpers.ensureBallisticCache(telemetry)
    if typeof(telemetry) ~= "table" then
        return nil
    end

    local cache = telemetry.ballisticCache
    if typeof(cache) ~= "table" then
        cache = {
            inputs = {},
            result = {},
            timestamp = 0,
            reuseCount = 0,
        }
        telemetry.ballisticCache = cache
    else
        if typeof(cache.inputs) ~= "table" then
            cache.inputs = {}
        end
        if typeof(cache.result) ~= "table" then
            cache.result = {}
        end
        cache.reuseCount = cache.reuseCount or 0
        cache.hitStreak = cache.hitStreak or 0
    end

    return cache
end

function Helpers.quantizeBallisticInputs(inputs)
    if typeof(inputs) ~= "table" then
        return nil
    end

    local quantize = Constants.BALLISTIC_CACHE_QUANTIZE
    if typeof(quantize) ~= "table" then
        return nil
    end

    local components = {}
    for key, step in pairs(quantize) do
        local value = inputs[key]
        if Helpers.isFiniteNumber(value) and Helpers.isFiniteNumber(step) and step > 0 then
            local quantized = math.floor(value / step + 0.5)
            components[#components + 1] = string.format("%s:%d", key, quantized)
        elseif value ~= nil then
            components[#components + 1] = string.format("%s:%s", key, tostring(value))
        end
    end

    table.sort(components)
    if #components == 0 then
        return nil
    end

    return table.concat(components, "|")
end

function Helpers.shouldRefreshBallisticCache(cache, inputs, now)
    local quantizedKey = Helpers.quantizeBallisticInputs(inputs)

    if typeof(cache) ~= "table" or typeof(cache.inputs) ~= "table" then
        return true, quantizedKey
    end

    local tolerance = Constants.BALLISTIC_CACHE_TOLERANCE or {}
    local relative = Constants.BALLISTIC_CACHE_RELATIVE or {}

    local timestamp = cache.timestamp
    local maxAge = Constants.BALLISTIC_CACHE_MAX_AGE or 0
    if Helpers.isFiniteNumber(now) and Helpers.isFiniteNumber(timestamp) and maxAge > 0 then
        if now - timestamp > maxAge then
            return true, quantizedKey
        end
    end

    if quantizedKey and cache.quantizedKey == quantizedKey then
        cache.hitStreak = (cache.hitStreak or 0) + 1
        return false, quantizedKey
    end

    local previous = cache.inputs

    if Helpers.significantDelta(previous.safe, inputs.safe, tolerance.safe, relative.safe) then
        return true, quantizedKey
    end
    if Helpers.significantDelta(previous.distance, inputs.distance, tolerance.distance, relative.distance) then
        return true, quantizedKey
    end
    if Helpers.significantDelta(previous.vr, inputs.vr, tolerance.vr, relative.vr) then
        return true, quantizedKey
    end
    if Helpers.significantDelta(previous.ar, inputs.ar, tolerance.ar, relative.ar) then
        return true, quantizedKey
    end
    if Helpers.significantDelta(previous.jr, inputs.jr, tolerance.jr, relative.jr) then
        return true, quantizedKey
    end
    if Helpers.significantDelta(previous.curvature, inputs.curvature, tolerance.curvature, relative.curvature) then
        return true, quantizedKey
    end
    if Helpers.significantDelta(previous.curvatureRate, inputs.curvatureRate, tolerance.curvatureRate, relative.curvatureRate) then
        return true, quantizedKey
    end
    if Helpers.significantDelta(previous.speed, inputs.speed, tolerance.speed, relative.speed) then
        return true, quantizedKey
    end
    if Helpers.significantDelta(previous.horizon, inputs.horizon, tolerance.horizon, relative.horizon) then
        return true, quantizedKey
    end
    if Helpers.significantDelta(previous.maxHorizon, inputs.maxHorizon, tolerance.maxHorizon, relative.maxHorizon) then
        return true, quantizedKey
    end

    cache.hitStreak = 0

    return false, quantizedKey
end

function Helpers.emaScalar(previous: number?, sample: number, alpha: number)
    if previous == nil then
        return sample
    end
    return previous + (sample - previous) * alpha
end

function Helpers.emaVector(previous: Vector3?, sample: Vector3, alpha: number)
    if previous == nil then
        return sample
    end
    return previous + (sample - previous) * alpha
end

function Helpers.simulateBallisticProximity(options)
    if typeof(options) ~= "table" then
        options = {}
    end

    local reuse = options.reuse or options.result
    local result
    if typeof(reuse) == "table" then
        Helpers.clearTable(reuse)
        result = reuse
    else
        result = {}
    end

    local pressGrace = PROXIMITY_PRESS_GRACE or 0.05

    local safe = math.max(options.safe or 0, Constants.EPSILON)
    local horizon = options.horizon
    if not Helpers.isFiniteNumber(horizon) or horizon <= 0 then
        horizon = pressGrace * 6
    end

    local maxHorizon = options.maxHorizon
    if Helpers.isFiniteNumber(maxHorizon) and maxHorizon > 0 then
        horizon = math.min(horizon, maxHorizon)
    end

    horizon = math.max(horizon, pressGrace)

    local resolution = options.resolution
    if not Helpers.isFiniteNumber(resolution) or resolution <= 0 then
        resolution = Constants.SIMULATION_RESOLUTION
    end
    if resolution <= 0 then
        resolution = pressGrace / Constants.SIMULATION_MIN_STEPS
    end

    local steps = math.floor(horizon / resolution + 0.5)
    steps = math.clamp(steps, Constants.SIMULATION_MIN_STEPS, Constants.SIMULATION_MAX_STEPS)
    local dt = horizon / math.max(steps, 1)

    local d0 = options.distance or safe
    local vr = options.vr or 0
    local ar = options.ar or 0
    local jr = options.jr or 0
    local curvature = options.curvature or 0
    local curvatureRate = options.curvatureRate or 0
    local curvatureJerk = options.curvatureJerk or 0
    local speed = math.abs(options.speed or vr or 0)

    local minRelative = math.huge
    local peakIntrusion = 0
    local weightedIntrusion = 0
    local signedDistanceSum = 0
    local intrusionArea = 0
    local ballisticEnergy = 0
    local curvatureEnergy = 0
    local velocityImprint = 0
    local crossingTime = nil

    local previousRelative = d0 - safe
    local lastSampleTime = 0
    for step = 1, steps do
        local t = dt * step
        lastSampleTime = t
        local t2 = t * t
        local t3 = t2 * t

        local radial = d0 + vr * t + 0.5 * ar * t2 + (1 / 6) * jr * t3
        local relative = radial - safe
        if relative < minRelative then
            minRelative = relative
        end

        local intrusion = math.max(-relative, 0)
        if intrusion > peakIntrusion then
            peakIntrusion = intrusion
        end

        local weight = 1 - math.cos((math.pi * step) / (steps + 1))
        weightedIntrusion += intrusion * weight * dt
        intrusionArea += intrusion * dt
        signedDistanceSum += math.max(relative, 0) * dt

        if not crossingTime and ((previousRelative > 0 and relative <= 0) or intrusion > 0) then
            crossingTime = t
        end

        local curvatureAt = curvature + curvatureRate * t + 0.5 * curvatureJerk * t2
        curvatureEnergy += math.abs(curvatureAt) * dt

        local radialSpeed = vr + ar * t + 0.5 * jr * t2
        velocityImprint += math.abs(radialSpeed) * intrusion * dt

        local radialGap = math.max(safe - radial, 0)
        ballisticEnergy += radialGap * radialGap * dt

        previousRelative = relative
    end

    if crossingTime == nil and minRelative < 0 then
        crossingTime = horizon
    end

    local effectiveHorizon = horizon
    if lastSampleTime > 0 and lastSampleTime < horizon then
        effectiveHorizon = math.max(lastSampleTime, pressGrace)
    end

    local horizonInv = 1 / math.max(effectiveHorizon, Constants.EPSILON)
    local safeEps = math.max(safe, Constants.EPSILON)

    local normalizedPeakIntrusion = peakIntrusion / safeEps
    local normalizedWeightedIntrusion = (weightedIntrusion * horizonInv) / safeEps
    local normalizedIntrusionArea = (intrusionArea * horizonInv) / safeEps

    local normalizedBallistic = math.sqrt(ballisticEnergy * horizonInv) / safeEps

    local velocityScale = math.max(speed, Constants.EPSILON)
    local velocitySignature = velocityImprint / (velocityScale * safeEps * math.max(horizon, Constants.EPSILON))
    velocitySignature = math.clamp(velocitySignature, 0, 4)

    local urgency = 0
    if crossingTime then
        urgency = math.max((horizon - crossingTime) * horizonInv, 0)
    end

    local densityScore = math.clamp(
        (steps - Constants.SIMULATION_MIN_STEPS)
            / math.max(Constants.SIMULATION_MAX_STEPS - Constants.SIMULATION_MIN_STEPS, 1),
        0,
        1
    )
    local resolutionScore = math.clamp(
        (Constants.SIMULATION_RESOLUTION or dt) / math.max(dt, Constants.EPSILON),
        0,
        1
    )
    local quality = math.clamp(densityScore * 0.6 + resolutionScore * 0.4, 0, 1)

    local curvatureSignature = curvatureEnergy * horizonInv
    local averageDistance = signedDistanceSum * horizonInv

    result.horizon = horizon
    result.effectiveHorizon = effectiveHorizon
    result.steps = steps
    result.dt = dt
    result.coverage = math.clamp(lastSampleTime / math.max(horizon, Constants.EPSILON), 0, 1)
    result.minDistance = minRelative
    result.peakIntrusion = peakIntrusion
    result.normalizedPeakIntrusion = normalizedPeakIntrusion
    result.weightedIntrusion = weightedIntrusion
    result.normalizedWeightedIntrusion = normalizedWeightedIntrusion
    result.normalizedIntrusionArea = normalizedIntrusionArea
    result.ballisticEnergy = ballisticEnergy
    result.normalizedBallisticEnergy = normalizedBallistic
    result.curvatureEnergy = curvatureEnergy
    result.curvatureSignature = curvatureSignature
    result.velocitySignature = velocitySignature
    result.urgency = urgency
    result.crossingTime = crossingTime
    result.averageDistance = averageDistance
    result.quality = quality

    return result
end

function Helpers.ensureThreatEnvelope(container)
    if typeof(container) ~= "table" then
        return nil
    end

    local envelope = container.threatEnvelope
    if typeof(envelope) ~= "table" then
        envelope = {
            fast = 0,
            medium = 0,
            slow = 0,
            load = 0,
            acceleration = 0,
            jerk = 0,
            lastFast = 0,
            lastAcceleration = 0,
            updated = nil,
        }
        container.threatEnvelope = envelope
    else
        envelope.fast = envelope.fast or 0
        envelope.medium = envelope.medium or 0
        envelope.slow = envelope.slow or 0
        envelope.load = envelope.load or 0
        envelope.acceleration = envelope.acceleration or 0
        envelope.jerk = envelope.jerk or 0
        envelope.lastFast = envelope.lastFast or envelope.fast or 0
        envelope.lastAcceleration = envelope.lastAcceleration or envelope.acceleration or 0
    end

    return envelope
end

function Helpers.updateThreatEnvelope(stateContainer, telemetry, params)
    if typeof(stateContainer) ~= "table" then
        return nil
    end

    local envelope = Helpers.ensureThreatEnvelope(stateContainer)
    if telemetry and typeof(telemetry) == "table" then
        telemetry.threatEnvelope = envelope
    end

    params = params or {}
    local now = params.now
    local dt = params.dt
    if not Helpers.isFiniteNumber(dt) then
        if Helpers.isFiniteNumber(now) and Helpers.isFiniteNumber(envelope.updated) then
            dt = now - envelope.updated
        end
    end

    local minDt = Constants.THREAT_SPECTRUM_MIN_DT or Constants.SIMULATION_RESOLUTION or 1 / 240
    local maxDt = Constants.THREAT_SPECTRUM_MAX_DT or 0.75
    if not Helpers.isFiniteNumber(dt) or dt <= 0 then
        dt = minDt
    end
    dt = math.clamp(dt, minDt, maxDt)

    local logistic = math.clamp(params.logistic or 0, 0, 1)
    local intensity = math.clamp(params.intensity or logistic, 0, 1)
    local severity = math.clamp(params.severity or intensity, 0, 1)
    local sample = params.sample
    if not Helpers.isFiniteNumber(sample) then
        sample = math.max(severity, logistic, intensity)
    end
    sample = math.clamp(sample or 0, 0, 1)
    local composite = math.max(sample, 0.65 * logistic + 0.35 * intensity, severity)

    local fastAlpha = Helpers.clampNumber(Constants.THREAT_SPECTRUM_FAST_ALPHA or 0.55, 0, 1) or 0.55
    local mediumAlpha = Helpers.clampNumber(Constants.THREAT_SPECTRUM_MEDIUM_ALPHA or 0.35, 0, 1) or 0.35
    local slowAlpha = Helpers.clampNumber(Constants.THREAT_SPECTRUM_SLOW_ALPHA or 0.18, 0, 1) or 0.18
    local loadAlpha = Helpers.clampNumber(Constants.THREAT_SPECTRUM_LOAD_ALPHA or 0.45, 0, 1) or 0.45
    local accelAlpha = Helpers.clampNumber(Constants.THREAT_SPECTRUM_ACCEL_ALPHA or 0.5, 0, 1) or 0.5
    local jerkAlpha = Helpers.clampNumber(Constants.THREAT_SPECTRUM_JERK_ALPHA or 0.35, 0, 1) or 0.35

    local fast = Helpers.emaScalar(envelope.fast, composite, fastAlpha)
    local medium = Helpers.emaScalar(envelope.medium, composite, mediumAlpha)
    local slow = Helpers.emaScalar(envelope.slow, composite, slowAlpha)
    envelope.fast = fast
    envelope.medium = medium
    envelope.slow = slow

    local loadInstant = math.clamp(0.5 * fast + 0.3 * medium + 0.2 * slow, 0, 1)
    local load = Helpers.emaScalar(envelope.load, loadInstant, loadAlpha)
    envelope.load = load

    local lastFast = envelope.lastFast
    if not Helpers.isFiniteNumber(lastFast) then
        lastFast = fast
    end
    local accelerationSample = (fast - lastFast) / math.max(dt, Constants.EPSILON)
    local acceleration = Helpers.emaScalar(envelope.acceleration, accelerationSample, accelAlpha)
    envelope.acceleration = acceleration

    local lastAcceleration = envelope.lastAcceleration
    if not Helpers.isFiniteNumber(lastAcceleration) then
        lastAcceleration = acceleration
    end
    local jerkSample = (acceleration - lastAcceleration) / math.max(dt, Constants.EPSILON)
    local jerk = Helpers.emaScalar(envelope.jerk, jerkSample, jerkAlpha)
    envelope.jerk = jerk

    envelope.lastFast = fast
    envelope.lastAcceleration = acceleration
    if Helpers.isFiniteNumber(now) then
        envelope.updated = now
    end

    local detectionConfidence = math.clamp(params.detectionConfidence or 0, 0, 1)
    local tempo = math.clamp(params.tempo or 0, 0, 1)
    local speedComponent = math.clamp(params.speedComponent or 0, 0, 1)
    local urgency = math.clamp(params.urgency or 0, 0, 1)

    local tempoBlend = math.max(tempo, speedComponent)

    local loadWeight = Constants.THREAT_SPECTRUM_DETECTION_LOAD_WEIGHT or 0.38
    local accelWeight = Constants.THREAT_SPECTRUM_DETECTION_ACCEL_WEIGHT or 0.22
    local tempoWeight = Constants.THREAT_SPECTRUM_DETECTION_TEMPO_WEIGHT or 0.18
    local urgencyWeight = Constants.THREAT_SPECTRUM_DETECTION_URGENCY_WEIGHT or 0.14

    local detectionBoost = loadWeight * load
        + accelWeight * math.max(acceleration, 0)
        + tempoWeight * tempoBlend
        + urgencyWeight * math.max(urgency, severity)
    detectionBoost = math.max(detectionBoost, 0)
    detectionBoost = math.min(detectionBoost, Constants.THREAT_SPECTRUM_DETECTION_MAX_BONUS or 0.45)

    detectionConfidence = math.clamp(detectionConfidence + detectionBoost, 0, 1)

    local score = (Constants.THREAT_SPECTRUM_SCORE_LOGISTIC_WEIGHT or 0.42) * logistic
        + (Constants.THREAT_SPECTRUM_SCORE_INTENSITY_WEIGHT or 0.23) * intensity
        + (Constants.THREAT_SPECTRUM_SCORE_CONFIDENCE_WEIGHT or 0.18) * detectionConfidence
        + (Constants.THREAT_SPECTRUM_SCORE_LOAD_WEIGHT or 0.12) * load
        + (Constants.THREAT_SPECTRUM_SCORE_TEMPO_WEIGHT or 0.05) * tempoBlend
    score = math.clamp(score, 0, 1)

    local confidence = (Constants.THREAT_SPECTRUM_CONFIDENCE_LOGISTIC_WEIGHT or 0.45) * logistic
        + (Constants.THREAT_SPECTRUM_CONFIDENCE_INTENSITY_WEIGHT or 0.2) * intensity
        + (Constants.THREAT_SPECTRUM_CONFIDENCE_CONFIDENCE_WEIGHT or 0.2) * detectionConfidence
        + (Constants.THREAT_SPECTRUM_CONFIDENCE_LOAD_WEIGHT or 0.15) * load
    confidence = math.clamp(confidence, 0, 1)

    local instantReady = detectionConfidence >= (Constants.THREAT_SPECTRUM_READY_CONFIDENCE or 0.82)
        and detectionBoost >= (Constants.THREAT_SPECTRUM_READY_THRESHOLD or 0.32)

    return {
        fast = fast,
        medium = medium,
        slow = slow,
        load = load,
        acceleration = acceleration,
        jerk = jerk,
        detectionBoost = detectionBoost,
        detectionConfidence = detectionConfidence,
        score = score,
        confidence = confidence,
        instantReady = instantReady,
        tempo = tempoBlend,
        dt = dt,
    }
end

local TelemetryAnalytics = {}

function Helpers.resolveThreatStatus(score)
    score = math.clamp(score or 0, 0, 1)
    local thresholds = Constants.THREAT_THRESHOLDS
    if typeof(thresholds) ~= "table" or #thresholds == 0 then
        if score >= 0.85 then
            return "critical"
        elseif score >= 0.65 then
            return "high"
        elseif score >= 0.4 then
            return "medium"
        elseif score >= 0.2 then
            return "low"
        end
        return "idle"
    end

    for _, entry in ipairs(thresholds) do
        local threshold = entry.threshold or 0
        if score >= threshold then
            return entry.status or "idle"
        end
    end

    return "idle"
end

function Helpers.updateThreatTelemetry(telemetry, state, kinematics, now, ballId)
    if typeof(telemetry) ~= "table" then
        return nil, nil
    end

    local threat = telemetry.threat
    if typeof(threat) ~= "table" then
        threat = {
            status = "idle",
            score = 0,
            severity = 0,
            urgency = 0,
            logistic = 0,
            lastEmit = 0,
            transitions = 0,
        }
        telemetry.threat = threat
    end

    local score = math.clamp(state.threatScore or 0, 0, 1)
    local severity = math.clamp(state.threatSeverity or 0, 0, 1)
    local intensity = math.clamp(state.threatIntensity or severity, 0, 1)
    local urgency = math.clamp(state.proximitySimulationUrgency or 0, 0, 1)
    local logistic = math.clamp(state.proximityLogistic or 0, 0, 1)
    local detectionReady = state.detectionReady and true or false
    local detectionAge = state.detectionAge or 0
    local detectionMin = state.minDetectionTime or 0
    local detectionConfidence = Helpers.clampNumber(state.detectionConfidence or 0, 0, 1) or 0
    local distance = (kinematics and kinematics.distance) or 0
    local speed = state.approachSpeed or 0
    local timeToImpact = state.timeToImpact
    local timeUntilPress = state.timeUntilPress
    local shouldPress = state.shouldPress and true or false
    local shouldHold = state.shouldHold and true or false
    local withinLookahead = state.withinLookahead and true or false

    local spectralFast = math.clamp(state.threatSpectralFast or math.max(severity, logistic), 0, 1)
    local spectralMedium = math.clamp(state.threatSpectralMedium or spectralFast, 0, 1)
    local spectralSlow = math.clamp(state.threatSpectralSlow or spectralMedium, 0, 1)
    local load = math.clamp(state.threatLoad or math.max(severity, logistic, intensity), 0, 1)
    local acceleration = state.threatAcceleration or 0
    if not Helpers.isFiniteNumber(acceleration) then
        acceleration = 0
    end
    local jerk = state.threatJerk or 0
    if not Helpers.isFiniteNumber(jerk) then
        jerk = 0
    end
    local detectionBoost = math.max(state.threatBoost or 0, 0)
    local tempoBlend = math.clamp(state.threatTempo or 0, 0, 1)
    local threatBudget = state.threatBudget
    local budgetRatio = Helpers.clampNumber(state.threatBudgetRatio or 0, -1, 1) or 0
    local budgetPressure = math.clamp(state.threatBudgetPressure or 0, 0, 1)
    local budgetReady = state.threatBudgetReady and true or false
    local budgetInstantReady = state.threatBudgetInstantReady and true or false
    local readinessScore = Helpers.clampNumber(state.threatReadinessScore or detectionConfidence, 0, 1) or 0
    local latencyGapSample = state.threatLatencyGap
    if not Helpers.isFiniteNumber(latencyGapSample) then
        latencyGapSample = 0
    end
    local budgetHorizon = state.threatBudgetHorizon
    if not Helpers.isFiniteNumber(budgetHorizon) then
        budgetHorizon = 0
    end
    local budgetConfidenceGain = math.clamp(state.threatBudgetConfidenceGain or 0, 0, 1)
    local scheduleSlackScale = Helpers.clampNumber(state.scheduleSlackScale or 1, 0, math.huge) or 1
    local detectionMomentumBoost = Helpers.clampNumber(state.detectionMomentumBoost or 0, -1, 1) or 0
    local readinessMomentum = math.clamp(state.threatReadinessMomentum or 0, 0, 1)
    local momentumReady = state.threatMomentumReady and true or false
    local momentumBoost = math.clamp(state.threatMomentumBoost or 0, 0, 1)
    local volatilityPenalty = math.max(state.threatVolatilityPenalty or 0, 0)
    local stabilityBoost = math.max(state.threatStabilityBoost or 0, 0)
    local loadBoost = math.max(state.threatLoadBoost or 0, 0)

    local previousScore = threat.score or 0
    local previousMomentum = threat.momentum
    local previousVolatility = threat.volatility
    local previousStability = threat.stability
    local previousConfidence = threat.confidence
    local previousDetectionConfidence = threat.detectionConfidence or detectionConfidence
    local lastUpdated = threat.updated

    local delta = score - previousScore

    local dt
    if Helpers.isFiniteNumber(now) and Helpers.isFiniteNumber(lastUpdated) then
        dt = now - lastUpdated
    end
    if not Helpers.isFiniteNumber(dt) or dt <= 0 then
        dt = Constants.THREAT_EVENT_MIN_INTERVAL or Constants.SIMULATION_RESOLUTION or 1 / 60
    end
    local derivative = 0
    if Helpers.isFiniteNumber(delta) then
        derivative = delta / math.max(dt, Constants.EPSILON)
    end

    local momentumAlpha = Helpers.clampNumber(Constants.THREAT_MOMENTUM_ALPHA or 0.6, 0, 1) or 0.6
    local volatilityAlpha = Helpers.clampNumber(Constants.THREAT_VOLATILITY_ALPHA or 0.45, 0, 1) or 0.45
    local stabilityAlpha = Helpers.clampNumber(Constants.THREAT_STABILITY_ALPHA or 0.35, 0, 1) or 0.35
    local confidenceAlpha = Helpers.clampNumber(Constants.THREAT_CONFIDENCE_ALPHA or 0.55, 0, 1) or 0.55

    local momentum = Helpers.emaScalar(previousMomentum, derivative, momentumAlpha)
    local volatility = Helpers.emaScalar(previousVolatility, math.abs(derivative), volatilityAlpha)
    local clampedVolatility = Helpers.clampNumber(volatility or 0, 0, 1) or 0
    local stabilitySample = math.max(1 - clampedVolatility, 0)
    local stability = Helpers.emaScalar(previousStability, stabilitySample, stabilityAlpha)
    local confidenceSample = Helpers.clampNumber(state.threatConfidence or score, 0, 1) or 0
    local confidence = Helpers.emaScalar(previousConfidence, confidenceSample, confidenceAlpha)
    local detectionTrend = detectionConfidence - previousDetectionConfidence

    local status = Helpers.resolveThreatStatus(score)

    threat.score = score
    threat.severity = severity
    threat.intensity = intensity
    threat.urgency = urgency
    threat.logistic = logistic
    threat.status = status
    threat.distance = distance
    threat.speed = speed
    threat.updated = now
    threat.detectionReady = detectionReady
    threat.detectionAge = detectionAge
    threat.detectionMin = detectionMin
    threat.detectionConfidence = detectionConfidence
    threat.confidence = confidence
    threat.momentum = momentum
    threat.volatility = volatility
    threat.stability = stability
    threat.spectralFast = spectralFast
    threat.spectralMedium = spectralMedium
    threat.spectralSlow = spectralSlow
    threat.load = load
    threat.acceleration = acceleration
    threat.jerk = jerk
    threat.detectionBoost = detectionBoost
    threat.tempo = tempoBlend
    threat.budget = threatBudget
    threat.budgetRatio = budgetRatio
    threat.budgetPressure = budgetPressure
    threat.budgetReady = budgetReady or budgetInstantReady
    threat.readiness = readinessScore
    threat.latencyGap = latencyGapSample
    threat.horizon = budgetHorizon
    threat.budgetConfidenceGain = budgetConfidenceGain
    threat.scheduleSlackScale = scheduleSlackScale
    threat.detectionMomentumBoost = detectionMomentumBoost
    threat.readinessMomentum = readinessMomentum
    threat.momentumReady = momentumReady or budgetInstantReady
    threat.momentumBoost = momentumBoost
    threat.volatilityPenalty = volatilityPenalty
    threat.stabilityBoost = stabilityBoost
    threat.loadBoost = loadBoost
    threat.timeToImpact = timeToImpact
    threat.timeUntilPress = timeUntilPress
    threat.shouldPress = shouldPress
    threat.shouldHold = shouldHold
    threat.withinLookahead = withinLookahead

    local readyConfidence = Constants.THREAT_SPECTRUM_READY_CONFIDENCE or 0.82
    local readyThreshold = Constants.THREAT_SPECTRUM_READY_THRESHOLD or 0.32
    local instantReady = detectionConfidence >= readyConfidence and detectionBoost >= readyThreshold

    local analytics = {
        delta = delta,
        derivative = derivative,
        momentum = momentum,
        volatility = volatility,
        stability = stability,
        confidence = confidence,
        detectionConfidence = detectionConfidence,
        detectionTrend = detectionTrend,
        load = load,
        spectralFast = spectralFast,
        spectralMedium = spectralMedium,
        spectralSlow = spectralSlow,
        acceleration = acceleration,
        jerk = jerk,
        detectionBoost = detectionBoost,
        tempo = tempoBlend,
        instantReady = instantReady,
        budget = threatBudget,
        budgetRatio = budgetRatio,
        budgetPressure = budgetPressure,
        budgetReady = budgetReady or budgetInstantReady,
        readiness = readinessScore,
        latencyGap = latencyGapSample,
        horizon = budgetHorizon,
        budgetConfidenceGain = budgetConfidenceGain,
        scheduleSlackScale = scheduleSlackScale,
        detectionMomentumBoost = detectionMomentumBoost,
        readinessMomentum = readinessMomentum,
        momentumReady = momentumReady or budgetInstantReady,
        momentumBoost = momentumBoost,
        volatilityPenalty = volatilityPenalty,
        stabilityBoost = stabilityBoost,
        loadBoost = loadBoost,
    }

    local minInterval = Constants.THREAT_EVENT_MIN_INTERVAL or 0
    local minDelta = Constants.THREAT_EVENT_MIN_DELTA or 0
    local sinceLast = math.huge
    if Helpers.isFiniteNumber(threat.lastEmit) and Helpers.isFiniteNumber(now) then
        sinceLast = now - threat.lastEmit
    end

    local transitioned = status ~= threat.lastStatus
    local shouldEmit = transitioned
        or (sinceLast >= minInterval and math.abs(delta) >= minDelta)

    if not shouldEmit then
        return status, analytics
    end

    threat.lastEmit = now
    if transitioned then
        threat.lastStatus = status
        threat.transitions = (threat.transitions or 0) + 1
    end

    local event = {
        ballId = ballId,
        score = score,
        severity = severity,
        intensity = intensity,
        urgency = urgency,
        logistic = logistic,
        status = status,
        delta = delta,
        derivative = derivative,
        detectionReady = detectionReady,
        detectionAge = detectionAge,
        detectionMin = detectionMin,
        detectionConfidence = detectionConfidence,
        detectionTrend = detectionTrend,
        confidence = confidence,
        momentum = momentum,
        volatility = volatility,
        stability = stability,
        spectralFast = spectralFast,
        spectralMedium = spectralMedium,
        spectralSlow = spectralSlow,
        load = load,
        acceleration = acceleration,
        jerk = jerk,
        detectionBoost = detectionBoost,
        boostedConfidence = detectionConfidence,
        tempo = tempoBlend,
        instantReady = instantReady,
        budget = threatBudget,
        budgetRatio = budgetRatio,
        budgetPressure = budgetPressure,
        budgetReady = budgetReady or budgetInstantReady,
        readiness = readinessScore,
        latencyGap = latencyGapSample,
        horizon = budgetHorizon,
        budgetConfidenceGain = budgetConfidenceGain,
        timeToImpact = timeToImpact,
        timeUntilPress = timeUntilPress,
        distance = distance,
        speed = speed,
        shouldPress = shouldPress,
        shouldHold = shouldHold,
        withinLookahead = withinLookahead,
        targeting = state.targetingMe and true or false,
        transitions = threat.transitions,
        coverage = state.proximitySimulation and state.proximitySimulation.coverage or 1,
        horizon = state.responseWindow,
        holdWindow = state.holdWindow,
    }

    local metrics = TelemetryAnalytics.metrics
    if typeof(metrics) == "table" then
        Helpers.incrementCounter("threat", 1)
        local threatMetrics = metrics.threat
        if typeof(threatMetrics) == "table" then
            if Helpers.isFiniteNumber(score) then
                Helpers.updateAggregate(threatMetrics.score, score)
            end
            if Helpers.isFiniteNumber(severity) then
                Helpers.updateAggregate(threatMetrics.severity, severity)
            end
            if Helpers.isFiniteNumber(intensity) then
                Helpers.updateAggregate(threatMetrics.intensity, intensity)
            end
            if Helpers.isFiniteNumber(urgency) then
                Helpers.updateAggregate(threatMetrics.urgency, urgency)
            end
            if Helpers.isFiniteNumber(logistic) then
                Helpers.updateAggregate(threatMetrics.logistic, logistic)
            end
            if Helpers.isFiniteNumber(distance) then
                Helpers.updateAggregate(threatMetrics.distance, distance)
            end
            if Helpers.isFiniteNumber(speed) then
                Helpers.updateAggregate(threatMetrics.speed, speed)
            end
            if Helpers.isFiniteNumber(confidence) then
                Helpers.updateAggregate(threatMetrics.confidence, confidence)
            end
            if Helpers.isFiniteNumber(detectionConfidence) then
                Helpers.updateAggregate(threatMetrics.detectionConfidence, detectionConfidence)
            end
            if Helpers.isFiniteNumber(load) then
                Helpers.updateAggregate(threatMetrics.load, load)
            end
            if Helpers.isFiniteNumber(spectralFast) then
                Helpers.updateAggregate(threatMetrics.spectralFast, spectralFast)
            end
            if Helpers.isFiniteNumber(spectralMedium) then
                Helpers.updateAggregate(threatMetrics.spectralMedium, spectralMedium)
            end
            if Helpers.isFiniteNumber(spectralSlow) then
                Helpers.updateAggregate(threatMetrics.spectralSlow, spectralSlow)
            end
            if Helpers.isFiniteNumber(momentum) then
                Helpers.updateAggregate(threatMetrics.momentum, momentum)
            end
            if Helpers.isFiniteNumber(volatility) then
                Helpers.updateAggregate(threatMetrics.volatility, volatility)
            end
            if Helpers.isFiniteNumber(stability) then
                Helpers.updateAggregate(threatMetrics.stability, stability)
            end
            if Helpers.isFiniteNumber(acceleration) then
                Helpers.updateAggregate(threatMetrics.acceleration, acceleration)
            end
            if Helpers.isFiniteNumber(jerk) then
                Helpers.updateAggregate(threatMetrics.jerk, jerk)
            end
            if Helpers.isFiniteNumber(detectionBoost) then
                Helpers.updateAggregate(threatMetrics.detectionBoost, detectionBoost)
            end
            if Helpers.isFiniteNumber(tempoBlend) then
                Helpers.updateAggregate(threatMetrics.tempo, tempoBlend)
            end
            if Helpers.isFiniteNumber(threatBudget) then
                Helpers.updateAggregate(threatMetrics.budget, threatBudget)
            end
            if Helpers.isFiniteNumber(budgetHorizon) then
                Helpers.updateAggregate(threatMetrics.horizon, budgetHorizon)
            end
            Helpers.updateAggregate(threatMetrics.budgetPressure, budgetPressure)
            Helpers.updateAggregate(threatMetrics.budgetRatio, budgetRatio)
            Helpers.updateAggregate(threatMetrics.readiness, readinessScore)
            Helpers.updateAggregate(threatMetrics.budgetConfidenceGain, budgetConfidenceGain)
            if Helpers.isFiniteNumber(latencyGapSample) then
                Helpers.updateAggregate(threatMetrics.latencyGap, latencyGapSample)
            end
            Helpers.updateAggregate(threatMetrics.budgetReady, (budgetReady or budgetInstantReady) and 1 or 0)

            threatMetrics.statusCounts = threatMetrics.statusCounts or {}
            threatMetrics.statusCounts[status] = (threatMetrics.statusCounts[status] or 0) + 1
            threatMetrics.transitions = math.max(threatMetrics.transitions or 0, threat.transitions or 0)
        end
    end

    emitTelemetryEvent("threat", event)
    return status, analytics
end

local function resolveConfigNumber(configSnapshot, key, fallback)
    local value = configSnapshot[key]
    if value == nil then
        value = fallback
    end
    if not Helpers.isFiniteNumber(value) then
        value = fallback
    end
    return value
end

local function addAdjustmentReason(adjustments, message)
    if message then
        table.insert(adjustments.reasons, message)
    end
end

local function applyAdjustmentUpdate(context, key, currentValue, newValue)
    if not Helpers.isFiniteNumber(newValue) then
        return nil
    end

    local delta = newValue - currentValue
    if math.abs(delta) < 1e-4 then
        return nil
    end

    local adjustments = context.adjustments
    adjustments.updates[key] = newValue
    adjustments.deltas[key] = delta

    return delta
end

local function prepareAdjustmentContext(stats, summary, configSnapshot, options)
    if typeof(options) ~= "table" then
        options = {}
    end
    stats = stats or TelemetryAnalytics.clone()
    summary = summary or TelemetryAnalytics.computeSummary(stats)
    configSnapshot = configSnapshot or {}

    local minSamples = options.minSamples
    if not Helpers.isFiniteNumber(minSamples) or minSamples < 0 then
        minSamples = TELEMETRY_ADJUSTMENT_MIN_SAMPLES or 4
    end

    local adjustments = {
        updates = {},
        deltas = {},
        reasons = {},
        stats = stats,
        summary = summary,
        minSamples = minSamples,
    }

    local pressCount = summary.pressCount or 0
    if pressCount < adjustments.minSamples then
        adjustments.status = "insufficient"
        addAdjustmentReason(
            adjustments,
            string.format(
                "Need at least %d presses (observed %d) before telemetry-based tuning can stabilise.",
                adjustments.minSamples,
                pressCount
            )
        )
        return { adjustments = adjustments, finished = true }
    end

    if smartTuningState and smartTuningState.enabled and not options.allowWhenSmartTuning then
        adjustments.status = "skipped"
        addAdjustmentReason(adjustments, "Smart tuning is enabled; skipping direct telemetry adjustments.")
        return { adjustments = adjustments, finished = true }
    end

    local reaction = math.max(resolveConfigNumber(configSnapshot, "pressReactionBias", Defaults.CONFIG.pressReactionBias or 0), 0)
    local slack = math.max(resolveConfigNumber(configSnapshot, "pressScheduleSlack", Defaults.CONFIG.pressScheduleSlack or 0), 0)
    local lookaheadFallback =
        configSnapshot.pressLookaheadGoal
        or Defaults.CONFIG.pressMaxLookahead
        or Defaults.CONFIG.pressLookaheadGoal
        or Defaults.SMART_TUNING.lookaheadGoal
        or 0
    local lookahead = resolveConfigNumber(configSnapshot, "pressMaxLookahead", lookaheadFallback or 0)
    local latency = math.max(resolveConfigNumber(configSnapshot, "activationLatency", Defaults.CONFIG.activationLatency or 0.12), 0)

    local commitTarget = options.commitTarget
    if not Helpers.isFiniteNumber(commitTarget) or commitTarget <= 0 then
        commitTarget = Defaults.SMART_TUNING.commitP99Target or 0.01
    end

    local lookaheadGoal = options.lookaheadGoal
    if not Helpers.isFiniteNumber(lookaheadGoal) or lookaheadGoal <= 0 then
        lookaheadGoal = configSnapshot.pressLookaheadGoal
        if not Helpers.isFiniteNumber(lookaheadGoal) or lookaheadGoal <= 0 then
            lookaheadGoal = Defaults.CONFIG.pressLookaheadGoal or Defaults.SMART_TUNING.lookaheadGoal or 0
        end
    end

    local commitMinSamples = options.commitMinSamples
    if not Helpers.isFiniteNumber(commitMinSamples) or commitMinSamples < 0 then
        commitMinSamples = 6
    end

    local lookaheadMinSamples = options.lookaheadMinSamples
    if not Helpers.isFiniteNumber(lookaheadMinSamples) or lookaheadMinSamples < 0 then
        lookaheadMinSamples = 4
    end

    local leadTolerance = options.leadTolerance
    if not Helpers.isFiniteNumber(leadTolerance) or leadTolerance < 0 then
        leadTolerance = TELEMETRY_ADJUSTMENT_LEAD_TOLERANCE or 0.004
    end

    local waitTolerance = options.waitTolerance
    if not Helpers.isFiniteNumber(waitTolerance) or waitTolerance < 0 then
        waitTolerance = TELEMETRY_ADJUSTMENT_WAIT_TOLERANCE or 0.003
    end

    return {
        adjustments = adjustments,
        summary = summary,
        options = options,
        config = configSnapshot,
        current = {
            reaction = reaction,
            slack = slack,
            lookahead = lookahead,
            latency = latency,
        },
        leadTolerance = leadTolerance,
        waitTolerance = waitTolerance,
        commit = {
            target = commitTarget,
            samples = summary.commitLatencySampleCount or 0,
            p99 = summary.commitLatencyP99,
            minSamples = commitMinSamples,
        },
        lookahead = {
            goal = lookaheadGoal,
            samples = summary.scheduleLookaheadSampleCount or 0,
            p10 = summary.scheduleLookaheadP10,
            minSamples = lookaheadMinSamples,
        },
        latency = {
            observed = summary.averageActivationLatency,
        },
        leadDelta = summary.leadDeltaMean,
        waitDelta = summary.averageWaitDelta,
    }
end

local function finalizeAdjustmentStatus(context)
    local adjustments = context.adjustments
    if next(adjustments.updates) then
        adjustments.status = "updates"
        return
    end

    adjustments.status = adjustments.status or "stable"
    if #adjustments.reasons == 0 then
        addAdjustmentReason(adjustments, "Telemetry averages are within tolerance; no config changes suggested.")
    end
end

local function applyLeadAdjustment(context)
    local leadDelta = context.leadDelta
    if not Helpers.isFiniteNumber(leadDelta) then
        return
    end

    if math.abs(leadDelta) <= (context.leadTolerance or 0) then
        return
    end

    local leadGain = context.options.leadGain
    if not Helpers.isFiniteNumber(leadGain) then
        leadGain = TELEMETRY_ADJUSTMENT_LEAD_GAIN or 0.6
    end

    local change = Helpers.clampNumber(-leadDelta * leadGain, -0.05, 0.05)
    if not change or math.abs(change) < 1e-4 then
        return
    end

    local currentReaction = context.current.reaction
    local maxReaction = context.options.maxReactionBias
        or math.max(TELEMETRY_ADJUSTMENT_MAX_REACTION or 0.24, Defaults.CONFIG.pressReactionBias or 0)
    maxReaction = math.max(maxReaction, currentReaction)

    local newReaction = Helpers.clampNumber(currentReaction + change, 0, maxReaction)
    local delta = applyAdjustmentUpdate(context, "pressReactionBias", currentReaction, newReaction)
    if not delta then
        return
    end

    context.current.reaction = newReaction
    addAdjustmentReason(
        context.adjustments,
        string.format(
            "Adjusted reaction bias by %.1f ms to offset the %.1f ms average lead delta.",
            delta * 1000,
            leadDelta * 1000
        )
    )
end

local function applySlackAdjustment(context)
    local waitDelta = context.waitDelta
    if not Helpers.isFiniteNumber(waitDelta) then
        return
    end

    if math.abs(waitDelta) <= (context.waitTolerance or 0) then
        return
    end

    local slackGain = context.options.slackGain
    if not Helpers.isFiniteNumber(slackGain) then
        slackGain = TELEMETRY_ADJUSTMENT_SLACK_GAIN or 0.5
    end

    local change = Helpers.clampNumber(waitDelta * slackGain, -0.03, 0.03)
    if not change or math.abs(change) < 1e-4 then
        return
    end

    local currentSlack = context.current.slack
    local maxSlack = context.options.maxScheduleSlack
        or math.max(TELEMETRY_ADJUSTMENT_MAX_SLACK or 0.08, Defaults.CONFIG.pressScheduleSlack or 0)
    maxSlack = math.max(maxSlack, currentSlack)

    local newSlack = Helpers.clampNumber(currentSlack + change, 0, maxSlack)
    local delta = applyAdjustmentUpdate(context, "pressScheduleSlack", currentSlack, newSlack)
    if not delta then
        return
    end

    context.current.slack = newSlack
    addAdjustmentReason(
        context.adjustments,
        string.format(
            "Adjusted schedule slack by %.1f ms based on the %.1f ms average wait delta.",
            delta * 1000,
            waitDelta * 1000
        )
    )
end

local function applyCommitAdjustments(context)
    local commit = context.commit
    if not commit or commit.target <= 0 then
        return
    end

    if commit.samples < (commit.minSamples or 0) then
        return
    end

    if not Helpers.isFiniteNumber(commit.p99) then
        return
    end

    local overshoot = commit.p99 - commit.target
    if overshoot > 0 then
        local reactionGain = context.options.commitReactionGain
        if not Helpers.isFiniteNumber(reactionGain) then
            reactionGain = Defaults.SMART_TUNING.commitReactionGain or 0
        end
        if reactionGain > 0 then
            local currentReaction = context.current.reaction
            local maxReaction = context.options.maxReactionBias
                or math.max(TELEMETRY_ADJUSTMENT_MAX_REACTION or 0.24, Defaults.CONFIG.pressReactionBias or 0)
            maxReaction = math.max(maxReaction, currentReaction)

            local boost = Helpers.clampNumber(overshoot * reactionGain, 0, maxReaction - currentReaction)
            if boost and boost >= 1e-4 then
                local newReaction = Helpers.clampNumber(currentReaction + boost, 0, maxReaction)
                local delta = applyAdjustmentUpdate(context, "pressReactionBias", currentReaction, newReaction)
                if delta then
                    context.current.reaction = newReaction
                    addAdjustmentReason(
                        context.adjustments,
                        string.format(
                            "Raised reaction bias by %.1f ms to chase the %.0f ms commit target (P99=%.1f ms).",
                            delta * 1000,
                            commit.target * 1000,
                            commit.p99 * 1000
                        )
                    )
                end
            end
        end

        local slackGain = context.options.commitSlackGain
        if not Helpers.isFiniteNumber(slackGain) then
            slackGain = Defaults.SMART_TUNING.commitSlackGain or 0
        end
        if slackGain > 0 then
            local currentSlack = context.current.slack
            local maxSlack = context.options.maxScheduleSlack
                or math.max(TELEMETRY_ADJUSTMENT_MAX_SLACK or 0.08, Defaults.CONFIG.pressScheduleSlack or 0)
            maxSlack = math.max(maxSlack, currentSlack)
            local minSlack = context.options.minScheduleSlack or 0

            local newSlack = Helpers.clampNumber(currentSlack - overshoot * slackGain, minSlack, maxSlack)
            local delta = applyAdjustmentUpdate(context, "pressScheduleSlack", currentSlack, newSlack)
            if delta then
                context.current.slack = newSlack
                addAdjustmentReason(
                    context.adjustments,
                    string.format(
                        "Adjusted schedule slack by %.1f ms to curb commit latency overshoot (P99 %.1f ms).",
                        delta * 1000,
                        commit.p99 * 1000
                    )
                )
            end
        end
    end
end

local function applyLookaheadAdjustment(context)
    local lookahead = context.lookahead
    if not lookahead then
        return
    end

    local goal = lookahead.goal
    if not Helpers.isFiniteNumber(goal) or goal <= 0 then
        return
    end

    if lookahead.samples < (lookahead.minSamples or 0) then
        return
    end

    local p10 = lookahead.p10
    if not Helpers.isFiniteNumber(p10) or p10 >= goal then
        return
    end

    local currentLookahead = context.adjustments.updates.pressMaxLookahead or context.current.lookahead
    if not Helpers.isFiniteNumber(currentLookahead) then
        currentLookahead = goal
    end
    currentLookahead = math.max(currentLookahead, goal)

    local lookaheadGain = context.options.lookaheadGain
    if not Helpers.isFiniteNumber(lookaheadGain) then
        lookaheadGain = 0.5
    end

    local maxLookaheadDelta = context.options.maxPressLookaheadDelta
    if not Helpers.isFiniteNumber(maxLookaheadDelta) or maxLookaheadDelta < 0 then
        maxLookaheadDelta = 0.75
    end

    local delta = Helpers.clampNumber((goal - p10) * lookaheadGain, 0, maxLookaheadDelta)
    if not delta or delta < 1e-4 then
        return
    end

    local maxLookahead = context.options.maxPressLookahead
    if not Helpers.isFiniteNumber(maxLookahead) or maxLookahead <= 0 then
        maxLookahead = math.max(currentLookahead, goal) + 0.6
    end
    local newLookahead = Helpers.clampNumber(currentLookahead + delta, goal, maxLookahead)
    local appliedDelta = applyAdjustmentUpdate(context, "pressMaxLookahead", currentLookahead, newLookahead)
    if not appliedDelta then
        return
    end

    context.current.lookahead = newLookahead
    addAdjustmentReason(
        context.adjustments,
        string.format(
            "Raised pressMaxLookahead by %.0f ms to meet the %.0f ms lookahead goal (P10=%.0f ms).",
            appliedDelta * 1000,
            goal * 1000,
            p10 * 1000
        )
    )
end

local function applyLatencyAdjustment(context)
    local observed = context.latency and context.latency.observed
    if not Helpers.isFiniteNumber(observed) or observed <= 0 then
        return
    end

    local currentLatency = context.current.latency
    if not Helpers.isFiniteNumber(currentLatency) then
        currentLatency = 0
    end
    local maxLatency = context.options.maxActivationLatency
    if not Helpers.isFiniteNumber(maxLatency) or maxLatency <= 0 then
        maxLatency = TELEMETRY_ADJUSTMENT_MAX_LATENCY or 0.35
    end
    if not Helpers.isFiniteNumber(maxLatency) then
        maxLatency = 0.35
    end
    maxLatency = math.max(maxLatency, currentLatency)

    local target = Helpers.clampNumber(observed, 0, maxLatency)
    local latencyGain = context.options.latencyGain
    if not Helpers.isFiniteNumber(latencyGain) then
        latencyGain = TELEMETRY_ADJUSTMENT_LATENCY_GAIN or 0.5
    end
    local blended = Helpers.clampNumber(currentLatency + (target - currentLatency) * latencyGain, 0, maxLatency)

    local delta = applyAdjustmentUpdate(context, "activationLatency", currentLatency, blended)
    if not delta then
        return
    end

    context.current.latency = blended
    addAdjustmentReason(
        context.adjustments,
        string.format(
            "Blended activation latency by %.1f ms toward the %.1f ms observed latency sample.",
            delta * 1000,
            observed * 1000
        )
    )
end

local TELEMETRY_ADAPTIVE_ALPHA = 0.45
local TELEMETRY_ADAPTIVE_MIN = -0.03
local TELEMETRY_ADAPTIVE_MAX = 0.08

local TELEMETRY_ADJUSTMENT_MIN_SAMPLES = 4
local TELEMETRY_ADJUSTMENT_LEAD_GAIN = 0.6
local TELEMETRY_ADJUSTMENT_SLACK_GAIN = 0.5
local TELEMETRY_ADJUSTMENT_LATENCY_GAIN = 0.5
local TELEMETRY_ADJUSTMENT_LEAD_TOLERANCE = 0.004
local TELEMETRY_ADJUSTMENT_WAIT_TOLERANCE = 0.003
local TELEMETRY_ADJUSTMENT_MAX_REACTION = 0.24
local TELEMETRY_ADJUSTMENT_MAX_SLACK = 0.08
local TELEMETRY_ADJUSTMENT_MAX_LATENCY = 0.35

function Helpers.clampAdaptive(value)
    if not Helpers.isFiniteNumber(value) then
        return 0
    end

    if value < TELEMETRY_ADAPTIVE_MIN then
        return TELEMETRY_ADAPTIVE_MIN
    end
    if value > TELEMETRY_ADAPTIVE_MAX then
        return TELEMETRY_ADAPTIVE_MAX
    end
    return value
end

function Helpers.clampNumber(value, minValue, maxValue)
    if value == nil then
        return nil
    end

    if minValue ~= nil and value < minValue then
        value = minValue
    end
    if maxValue ~= nil and value > maxValue then
        value = maxValue
    end

    return value
end

function Helpers.incrementCounter(name, delta)
    local metrics = TelemetryAnalytics.metrics
    local counters = metrics and metrics.counters
    if typeof(counters) ~= "table" then
        return
    end

    local current = counters[name]
    if typeof(current) ~= "number" then
        current = 0
    end

    counters[name] = current + (delta or 1)
end

function TelemetryAnalytics.resetMetrics(resetCount)
    TelemetryAnalytics.metrics = {
        counters = {
            schedule = 0,
            scheduleCleared = 0,
            press = 0,
            success = 0,
            latency = 0,
            latencyAccepted = 0,
            latencyRejected = 0,
            latencyLocal = 0,
            latencyRemote = 0,
            threat = 0,
            resets = resetCount or 0,
        },
        schedule = {
            lead = Helpers.newAggregate(),
            slack = Helpers.newAggregate(),
            eta = Helpers.newAggregate(),
            predictedImpact = Helpers.newAggregate(),
            adaptiveBias = Helpers.newAggregate(),
            reasons = {},
            smartLead = Helpers.newAggregate(),
            smartReaction = Helpers.newAggregate(),
            smartSlack = Helpers.newAggregate(),
            smartConfidence = Helpers.newAggregate(),
        },
        press = {
            waitDelta = Helpers.newAggregate(),
            actualWait = Helpers.newAggregate(),
            activationLatency = Helpers.newAggregate(),
            adaptiveBias = Helpers.newAggregate(),
            reactionTime = Helpers.newAggregate(),
            decisionTime = Helpers.newAggregate(),
            decisionToPressTime = Helpers.newAggregate(),
            immediateCount = 0,
            forcedCount = 0,
            scheduledCount = 0,
            unscheduledCount = 0,
            scheduledReasons = {},
            smartLatency = Helpers.newAggregate(),
            smartReaction = Helpers.newAggregate(),
            smartSlack = Helpers.newAggregate(),
            smartConfidence = Helpers.newAggregate(),
        },
        latency = {
            accepted = Helpers.newAggregate(),
            localAccepted = Helpers.newAggregate(),
            remoteAccepted = Helpers.newAggregate(),
            activation = Helpers.newAggregate(),
        },
        success = {
            latency = Helpers.newAggregate(),
            acceptedCount = 0,
        },
        cancellations = {
            total = 0,
            stale = 0,
            reasonCounts = {},
        },
        timeline = {
            scheduleLifetime = Helpers.newAggregate(),
            achievedLead = Helpers.newAggregate(),
            leadDelta = Helpers.newAggregate(),
        },
        threat = {
            score = Helpers.newAggregate(),
            severity = Helpers.newAggregate(),
            intensity = Helpers.newAggregate(),
            urgency = Helpers.newAggregate(),
            logistic = Helpers.newAggregate(),
            distance = Helpers.newAggregate(),
            speed = Helpers.newAggregate(),
            confidence = Helpers.newAggregate(),
            detectionConfidence = Helpers.newAggregate(),
            load = Helpers.newAggregate(),
            spectralFast = Helpers.newAggregate(),
            spectralMedium = Helpers.newAggregate(),
            spectralSlow = Helpers.newAggregate(),
            momentum = Helpers.newAggregate(),
            volatility = Helpers.newAggregate(),
            stability = Helpers.newAggregate(),
            acceleration = Helpers.newAggregate(),
            jerk = Helpers.newAggregate(),
            detectionBoost = Helpers.newAggregate(),
            tempo = Helpers.newAggregate(),
            momentumBoost = Helpers.newAggregate(),
            readinessMomentum = Helpers.newAggregate(),
            detectionMomentumBoost = Helpers.newAggregate(),
            scheduleSlackScale = Helpers.newAggregate(),
            momentumReady = Helpers.newAggregate(),
            volatilityPenalty = Helpers.newAggregate(),
            stabilityBoost = Helpers.newAggregate(),
            loadBoost = Helpers.newAggregate(),
            budget = Helpers.newAggregate(),
            budgetPressure = Helpers.newAggregate(),
            budgetRatio = Helpers.newAggregate(),
            readiness = Helpers.newAggregate(),
            latencyGap = Helpers.newAggregate(),
            horizon = Helpers.newAggregate(),
            budgetConfidenceGain = Helpers.newAggregate(),
            budgetReady = Helpers.newAggregate(),
            statusCounts = {},
            transitions = 0,
        },
        quantiles = {
            commitLatency = Helpers.newQuantileEstimator(0.99, 512),
            scheduleLookahead = Helpers.newQuantileEstimator(Defaults.SMART_TUNING.lookaheadQuantile or 0.1, 512),
        },
        inFlight = {},
    }
end

function TelemetryAnalytics.resetAdaptive()
    TelemetryAnalytics.adaptiveState = {
        reactionBias = 0,
        lastUpdate = 0,
    }
end

TelemetryAnalytics.resetMetrics(0)
TelemetryAnalytics.resetAdaptive()

function TelemetryAnalytics.clone()
    local metrics = TelemetryAnalytics.metrics
    if typeof(metrics) ~= "table" then
        return {
            counters = {},
            schedule = {},
            press = {},
            latency = {},
            success = {},
            cancellations = {},
            timeline = {},
            threat = {},
            adaptiveState = {
                reactionBias = TelemetryAnalytics.adaptiveState and TelemetryAnalytics.adaptiveState.reactionBias or 0,
                lastUpdate = TelemetryAnalytics.adaptiveState and TelemetryAnalytics.adaptiveState.lastUpdate or 0,
            },
        }
    end

    local counters = Helpers.cloneCounts(metrics.counters)

    local result = {
        counters = counters,
        schedule = {
            lead = Helpers.summariseAggregate(metrics.schedule.lead),
            slack = Helpers.summariseAggregate(metrics.schedule.slack),
            eta = Helpers.summariseAggregate(metrics.schedule.eta),
            predictedImpact = Helpers.summariseAggregate(metrics.schedule.predictedImpact),
            adaptiveBias = Helpers.summariseAggregate(metrics.schedule.adaptiveBias),
            reasons = Helpers.cloneCounts(metrics.schedule.reasons),
            smart = {
                lead = Helpers.summariseAggregate(metrics.schedule.smartLead),
                reactionBias = Helpers.summariseAggregate(metrics.schedule.smartReaction),
                scheduleSlack = Helpers.summariseAggregate(metrics.schedule.smartSlack),
                confidencePadding = Helpers.summariseAggregate(metrics.schedule.smartConfidence),
            },
        },
        press = {
            waitDelta = Helpers.summariseAggregate(metrics.press.waitDelta),
            actualWait = Helpers.summariseAggregate(metrics.press.actualWait),
            activationLatency = Helpers.summariseAggregate(metrics.press.activationLatency),
            adaptiveBias = Helpers.summariseAggregate(metrics.press.adaptiveBias),
            reactionTime = Helpers.summariseAggregate(metrics.press.reactionTime),
            decisionTime = Helpers.summariseAggregate(metrics.press.decisionTime),
            decisionToPressTime = Helpers.summariseAggregate(metrics.press.decisionToPressTime),
            immediateCount = metrics.press.immediateCount,
            forcedCount = metrics.press.forcedCount,
            scheduledCount = metrics.press.scheduledCount,
            unscheduledCount = metrics.press.unscheduledCount,
            scheduledReasons = Helpers.cloneCounts(metrics.press.scheduledReasons),
            smart = {
                latency = Helpers.summariseAggregate(metrics.press.smartLatency),
                reactionBias = Helpers.summariseAggregate(metrics.press.smartReaction),
                scheduleSlack = Helpers.summariseAggregate(metrics.press.smartSlack),
                confidencePadding = Helpers.summariseAggregate(metrics.press.smartConfidence),
            },
        },
        latency = {
            accepted = Helpers.summariseAggregate(metrics.latency.accepted),
            localAccepted = Helpers.summariseAggregate(metrics.latency.localAccepted),
            remoteAccepted = Helpers.summariseAggregate(metrics.latency.remoteAccepted),
            activation = Helpers.summariseAggregate(metrics.latency.activation),
            counters = {
                accepted = counters.latencyAccepted or 0,
                rejected = counters.latencyRejected or 0,
                localSamples = counters.latencyLocal or 0,
                remoteSamples = counters.latencyRemote or 0,
            },
        },
        success = {
            latency = Helpers.summariseAggregate(metrics.success.latency),
            acceptedCount = metrics.success.acceptedCount,
        },
        cancellations = {
            total = metrics.cancellations.total,
            stale = metrics.cancellations.stale,
            reasonCounts = Helpers.cloneCounts(metrics.cancellations.reasonCounts),
        },
        timeline = {
            scheduleLifetime = Helpers.summariseAggregate(metrics.timeline.scheduleLifetime),
            achievedLead = Helpers.summariseAggregate(metrics.timeline.achievedLead),
            leadDelta = Helpers.summariseAggregate(metrics.timeline.leadDelta),
        },
        threat = {
            score = Helpers.summariseAggregate(metrics.threat and metrics.threat.score),
            severity = Helpers.summariseAggregate(metrics.threat and metrics.threat.severity),
            intensity = Helpers.summariseAggregate(metrics.threat and metrics.threat.intensity),
            urgency = Helpers.summariseAggregate(metrics.threat and metrics.threat.urgency),
            logistic = Helpers.summariseAggregate(metrics.threat and metrics.threat.logistic),
            distance = Helpers.summariseAggregate(metrics.threat and metrics.threat.distance),
            speed = Helpers.summariseAggregate(metrics.threat and metrics.threat.speed),
            confidence = Helpers.summariseAggregate(metrics.threat and metrics.threat.confidence),
            detectionConfidence = Helpers.summariseAggregate(metrics.threat and metrics.threat.detectionConfidence),
            load = Helpers.summariseAggregate(metrics.threat and metrics.threat.load),
            spectralFast = Helpers.summariseAggregate(metrics.threat and metrics.threat.spectralFast),
            spectralMedium = Helpers.summariseAggregate(metrics.threat and metrics.threat.spectralMedium),
            spectralSlow = Helpers.summariseAggregate(metrics.threat and metrics.threat.spectralSlow),
            momentum = Helpers.summariseAggregate(metrics.threat and metrics.threat.momentum),
            volatility = Helpers.summariseAggregate(metrics.threat and metrics.threat.volatility),
            stability = Helpers.summariseAggregate(metrics.threat and metrics.threat.stability),
            acceleration = Helpers.summariseAggregate(metrics.threat and metrics.threat.acceleration),
            jerk = Helpers.summariseAggregate(metrics.threat and metrics.threat.jerk),
            detectionBoost = Helpers.summariseAggregate(metrics.threat and metrics.threat.detectionBoost),
            tempo = Helpers.summariseAggregate(metrics.threat and metrics.threat.tempo),
            momentumBoost = Helpers.summariseAggregate(metrics.threat and metrics.threat.momentumBoost),
            readinessMomentum = Helpers.summariseAggregate(metrics.threat and metrics.threat.readinessMomentum),
            detectionMomentumBoost = Helpers.summariseAggregate(metrics.threat and metrics.threat.detectionMomentumBoost),
            scheduleSlackScale = Helpers.summariseAggregate(metrics.threat and metrics.threat.scheduleSlackScale),
            momentumReady = Helpers.summariseAggregate(metrics.threat and metrics.threat.momentumReady),
            volatilityPenalty = Helpers.summariseAggregate(metrics.threat and metrics.threat.volatilityPenalty),
            stabilityBoost = Helpers.summariseAggregate(metrics.threat and metrics.threat.stabilityBoost),
            loadBoost = Helpers.summariseAggregate(metrics.threat and metrics.threat.loadBoost),
            budget = Helpers.summariseAggregate(metrics.threat and metrics.threat.budget),
            budgetPressure = Helpers.summariseAggregate(metrics.threat and metrics.threat.budgetPressure),
            budgetRatio = Helpers.summariseAggregate(metrics.threat and metrics.threat.budgetRatio),
            readiness = Helpers.summariseAggregate(metrics.threat and metrics.threat.readiness),
            latencyGap = Helpers.summariseAggregate(metrics.threat and metrics.threat.latencyGap),
            horizon = Helpers.summariseAggregate(metrics.threat and metrics.threat.horizon),
            budgetConfidenceGain = Helpers.summariseAggregate(metrics.threat and metrics.threat.budgetConfidenceGain),
            budgetReady = Helpers.summariseAggregate(metrics.threat and metrics.threat.budgetReady),
            statusCounts = Helpers.cloneCounts(metrics.threat and metrics.threat.statusCounts),
            transitions = metrics.threat and metrics.threat.transitions or 0,
        },
        quantiles = {
            commitLatency = Helpers.summariseQuantileEstimator(metrics.quantiles and metrics.quantiles.commitLatency),
            scheduleLookahead = Helpers.summariseQuantileEstimator(metrics.quantiles and metrics.quantiles.scheduleLookahead),
        },
        adaptiveState = {
            reactionBias = TelemetryAnalytics.adaptiveState and TelemetryAnalytics.adaptiveState.reactionBias or 0,
            lastUpdate = TelemetryAnalytics.adaptiveState and TelemetryAnalytics.adaptiveState.lastUpdate or 0,
        },
    }

    return result
end

function TelemetryAnalytics.adjust(leadDelta)
    local adaptive = TelemetryAnalytics.adaptiveState
    if not adaptive then
        return
    end

    local desired = 0
    if smartTuningState and smartTuningState.enabled then
        desired = 0
    elseif Helpers.isFiniteNumber(leadDelta) then
        desired = Helpers.clampAdaptive(-leadDelta)
    end

    adaptive.reactionBias = Helpers.emaScalar(adaptive.reactionBias, desired, TELEMETRY_ADAPTIVE_ALPHA)
    adaptive.lastUpdate = os.clock()
end

function TelemetryAnalytics.recordSchedule(event)
    local metrics = TelemetryAnalytics.metrics
    if typeof(event) ~= "table" or typeof(metrics) ~= "table" then
        return
    end

    Helpers.incrementCounter("schedule", 1)

    Helpers.updateAggregate(metrics.schedule.lead, event.lead)
    Helpers.updateAggregate(metrics.schedule.slack, event.slack)
    Helpers.updateAggregate(metrics.schedule.eta, event.eta)
    Helpers.updateAggregate(metrics.schedule.predictedImpact, event.predictedImpact)
    Helpers.updateAggregate(metrics.schedule.adaptiveBias, event.adaptiveBias)

    if metrics.quantiles then
        Helpers.updateQuantileEstimator(metrics.quantiles.scheduleLookahead, event.eta)
    end

    if event.reason then
        Helpers.incrementCount(metrics.schedule.reasons, event.reason, 1)
    end

    if Helpers.isFiniteNumber(event.activationLatency) then
        Helpers.updateAggregate(metrics.latency.activation, event.activationLatency)
    end

    if typeof(event.smartTuning) == "table" then
        if Helpers.isFiniteNumber(event.smartTuning.scheduleLead) then
            Helpers.updateAggregate(metrics.schedule.smartLead, event.smartTuning.scheduleLead)
        end

        local applied = event.smartTuning.applied
        if typeof(applied) == "table" then
            Helpers.updateAggregate(metrics.schedule.smartReaction, applied.reactionBias)
            Helpers.updateAggregate(metrics.schedule.smartSlack, applied.scheduleSlack)
            Helpers.updateAggregate(metrics.schedule.smartConfidence, applied.confidencePadding)
        end
    end

    local inFlight = metrics.inFlight
    if typeof(inFlight) == "table" and event.ballId then
        inFlight[event.ballId] = {
            time = event.time,
            pressAt = event.pressAt,
            lead = event.lead,
            slack = event.slack,
            predictedImpact = event.predictedImpact,
            eta = event.eta,
            reason = event.reason,
            adaptiveBias = event.adaptiveBias,
            immediate = event.immediate == true or event.reason == "immediate-press",
        }
    end
end

function TelemetryAnalytics.recordScheduleCleared(event)
    Helpers.incrementCounter("scheduleCleared", 1)
    local metrics = TelemetryAnalytics.metrics
    if typeof(event) ~= "table" or typeof(metrics) ~= "table" then
        return
    end

    local ballId = event.ballId
    if ballId then
        local inFlight = metrics.inFlight
        local entry = typeof(inFlight) == "table" and inFlight[ballId] or nil
        if entry then
            local eventTime = event.time or os.clock()
            if Helpers.isFiniteNumber(eventTime) and Helpers.isFiniteNumber(entry.time) then
                Helpers.updateAggregate(metrics.timeline.scheduleLifetime, eventTime - entry.time)
            elseif Helpers.isFiniteNumber(event.timeSinceUpdate) then
                Helpers.updateAggregate(metrics.timeline.scheduleLifetime, event.timeSinceUpdate)
            end
            inFlight[ballId] = nil
        elseif Helpers.isFiniteNumber(event.timeSinceUpdate) then
            Helpers.updateAggregate(metrics.timeline.scheduleLifetime, event.timeSinceUpdate)
        end
    elseif Helpers.isFiniteNumber(event.timeSinceUpdate) then
        Helpers.updateAggregate(metrics.timeline.scheduleLifetime, event.timeSinceUpdate)
    end

    if event.reason ~= "pressed" then
        metrics.cancellations.total += 1
        Helpers.incrementCount(metrics.cancellations.reasonCounts, event.reason or "unknown", 1)

        if Helpers.isFiniteNumber(event.timeSinceUpdate) and event.timeSinceUpdate >= Context.smartPress.staleSeconds then
            metrics.cancellations.stale += 1
        end
    end
end

function TelemetryAnalytics.formatLatencyText(seconds: number?, pending: boolean?)
    if not Helpers.isFiniteNumber(seconds) then
        return "n/a"
    end

    local millis = math.floor(math.max(seconds, 0) * 1000 + 0.5)
    if pending then
        return string.format("%dms*", millis)
    end

    return string.format("%dms", millis)
end

function TelemetryAnalytics.computeLatencyReadouts(telemetry: TelemetryState?, now: number)
    if not telemetry then
        return "n/a", "n/a", "n/a"
    end

    local reactionLatency
    local reactionPending = false
    if telemetry.targetDetectedAt then
        reactionLatency = math.max(now - telemetry.targetDetectedAt, 0)
        reactionPending = true
    elseif Helpers.isFiniteNumber(telemetry.lastReactionLatency) then
        reactionLatency = telemetry.lastReactionLatency
    end

    local decisionLatency
    local decisionPending = false
    if telemetry.targetDetectedAt and telemetry.decisionAt then
        decisionLatency = math.max(telemetry.decisionAt - telemetry.targetDetectedAt, 0)
        decisionPending = telemetry.lastDecisionLatency == nil
    elseif Helpers.isFiniteNumber(telemetry.lastDecisionLatency) then
        decisionLatency = telemetry.lastDecisionLatency
    end

    local commitLatency
    local commitPending = false
    if telemetry.decisionAt then
        commitLatency = math.max(now - telemetry.decisionAt, 0)
        commitPending = telemetry.lastDecisionToPressLatency == nil
    elseif Helpers.isFiniteNumber(telemetry.lastDecisionToPressLatency) then
        commitLatency = telemetry.lastDecisionToPressLatency
    end

    return TelemetryAnalytics.formatLatencyText(reactionLatency, reactionPending),
        TelemetryAnalytics.formatLatencyText(decisionLatency, decisionPending),
        TelemetryAnalytics.formatLatencyText(commitLatency, commitPending)
end

function TelemetryAnalytics.applyPressLatencyTelemetry(telemetry: TelemetryState?, pressEvent, now: number)
    if not telemetry then
        if pressEvent then
            if pressEvent.reactionTime == nil then
                pressEvent.reactionTime = 0
            end
            if pressEvent.decisionTime == nil then
                pressEvent.decisionTime = 0
            end
            if pressEvent.decisionToPressTime == nil then
                pressEvent.decisionToPressTime = 0
            end
        end
        return
    end

    local detectionAt = telemetry.targetDetectedAt
    local decisionAt = telemetry.decisionAt

    local reactionLatency = 0
    if detectionAt then
        reactionLatency = math.max(now - detectionAt, 0)
    end

    telemetry.lastReactionLatency = reactionLatency
    telemetry.lastReactionTimestamp = now
    pressEvent.reactionTime = reactionLatency

    if decisionAt and detectionAt then
        local decisionLatency = math.max(decisionAt - detectionAt, 0)
        telemetry.lastDecisionLatency = decisionLatency
        pressEvent.decisionTime = decisionLatency
    end

    if decisionAt then
        local decisionToPress = math.max(now - decisionAt, 0)
        telemetry.lastDecisionToPressLatency = decisionToPress
        pressEvent.decisionToPressTime = decisionToPress
    end

    telemetry.targetDetectedAt = nil
    telemetry.decisionAt = nil
end

function TelemetryAnalytics.recordLatency(event)
    Helpers.incrementCounter("latency", 1)
    local metrics = TelemetryAnalytics.metrics
    if typeof(event) ~= "table" or typeof(metrics) ~= "table" then
        return
    end

    if event.source == "remote" then
        Helpers.incrementCounter("latencyRemote", 1)
    elseif event.source == "local" then
        Helpers.incrementCounter("latencyLocal", 1)
    end

    if event.accepted then
        Helpers.incrementCounter("latencyAccepted", 1)
        Helpers.updateAggregate(metrics.latency.accepted, event.value)

        if event.source == "remote" then
            Helpers.updateAggregate(metrics.latency.remoteAccepted, event.value)
        elseif event.source == "local" then
            Helpers.updateAggregate(metrics.latency.localAccepted, event.value)
        end
    else
        Helpers.incrementCounter("latencyRejected", 1)
    end

    if Helpers.isFiniteNumber(event.activationLatency) then
        Helpers.updateAggregate(metrics.latency.activation, event.activationLatency)
    end
end

function TelemetryAnalytics.recordSuccess(event)
    Helpers.incrementCounter("success", 1)
    local metrics = TelemetryAnalytics.metrics
    if typeof(event) ~= "table" or typeof(metrics) ~= "table" then
        return
    end

    if event.accepted and Helpers.isFiniteNumber(event.latency) then
        metrics.success.acceptedCount += 1
        Helpers.updateAggregate(metrics.success.latency, event.latency)
    end
end

function TelemetryAnalytics.recordThreat(event)
    Helpers.incrementCounter("threat", 1)
    local metrics = TelemetryAnalytics.metrics
    if typeof(event) ~= "table" or typeof(metrics) ~= "table" then
        return
    end

    local threat = metrics.threat
    if typeof(threat) ~= "table" then
        return
    end

    if Helpers.isFiniteNumber(event.score) then
        Helpers.updateAggregate(threat.score, event.score)
    end
    if Helpers.isFiniteNumber(event.severity) then
        Helpers.updateAggregate(threat.severity, event.severity)
    end
    if Helpers.isFiniteNumber(event.intensity) then
        Helpers.updateAggregate(threat.intensity, event.intensity)
    elseif Helpers.isFiniteNumber(event.score) then
        Helpers.updateAggregate(threat.intensity, math.clamp(event.score, 0, 1))
    end
    if Helpers.isFiniteNumber(event.urgency) then
        Helpers.updateAggregate(threat.urgency, event.urgency)
    end
    if Helpers.isFiniteNumber(event.logistic) then
        Helpers.updateAggregate(threat.logistic, event.logistic)
    end
    if Helpers.isFiniteNumber(event.distance) then
        Helpers.updateAggregate(threat.distance, event.distance)
    end
    if Helpers.isFiniteNumber(event.speed) then
        Helpers.updateAggregate(threat.speed, event.speed)
    end
    if Helpers.isFiniteNumber(event.confidence) then
        Helpers.updateAggregate(threat.confidence, event.confidence)
    end
    if Helpers.isFiniteNumber(event.detectionConfidence) then
        Helpers.updateAggregate(threat.detectionConfidence, event.detectionConfidence)
    end
    if Helpers.isFiniteNumber(event.load) then
        Helpers.updateAggregate(threat.load, event.load)
    end
    if Helpers.isFiniteNumber(event.spectralFast) then
        Helpers.updateAggregate(threat.spectralFast, event.spectralFast)
    end
    if Helpers.isFiniteNumber(event.spectralMedium) then
        Helpers.updateAggregate(threat.spectralMedium, event.spectralMedium)
    end
    if Helpers.isFiniteNumber(event.spectralSlow) then
        Helpers.updateAggregate(threat.spectralSlow, event.spectralSlow)
    end
    if Helpers.isFiniteNumber(event.momentum) then
        Helpers.updateAggregate(threat.momentum, event.momentum)
    end
    if Helpers.isFiniteNumber(event.volatility) then
        Helpers.updateAggregate(threat.volatility, event.volatility)
    end
    if Helpers.isFiniteNumber(event.stability) then
        Helpers.updateAggregate(threat.stability, event.stability)
    end
    if Helpers.isFiniteNumber(event.acceleration) then
        Helpers.updateAggregate(threat.acceleration, event.acceleration)
    end
    if Helpers.isFiniteNumber(event.jerk) then
        Helpers.updateAggregate(threat.jerk, event.jerk)
    end
    if Helpers.isFiniteNumber(event.detectionBoost) then
        Helpers.updateAggregate(threat.detectionBoost, event.detectionBoost)
    end
    if Helpers.isFiniteNumber(event.tempo) then
        Helpers.updateAggregate(threat.tempo, event.tempo)
    end
    if Helpers.isFiniteNumber(event.momentumBoost) then
        Helpers.updateAggregate(threat.momentumBoost, event.momentumBoost)
    end
    if Helpers.isFiniteNumber(event.readinessMomentum) then
        Helpers.updateAggregate(threat.readinessMomentum, event.readinessMomentum)
    end
    if Helpers.isFiniteNumber(event.detectionMomentumBoost) then
        Helpers.updateAggregate(threat.detectionMomentumBoost, event.detectionMomentumBoost)
    end
    if Helpers.isFiniteNumber(event.scheduleSlackScale) then
        Helpers.updateAggregate(threat.scheduleSlackScale, event.scheduleSlackScale)
    end
    if Helpers.isFiniteNumber(event.volatilityPenalty) then
        Helpers.updateAggregate(threat.volatilityPenalty, event.volatilityPenalty)
    end
    if Helpers.isFiniteNumber(event.stabilityBoost) then
        Helpers.updateAggregate(threat.stabilityBoost, event.stabilityBoost)
    end
    if Helpers.isFiniteNumber(event.loadBoost) then
        Helpers.updateAggregate(threat.loadBoost, event.loadBoost)
    end
    Helpers.updateAggregate(threat.momentumReady, event.momentumReady and 1 or 0)
    if Helpers.isFiniteNumber(event.budget) then
        Helpers.updateAggregate(threat.budget, event.budget)
    end
    if Helpers.isFiniteNumber(event.horizon) then
        Helpers.updateAggregate(threat.horizon, event.horizon)
    end
    if Helpers.isFiniteNumber(event.latencyGap) then
        Helpers.updateAggregate(threat.latencyGap, event.latencyGap)
    end
    Helpers.updateAggregate(threat.budgetPressure, event.budgetPressure or 0)
    Helpers.updateAggregate(threat.budgetRatio, event.budgetRatio or 0)
    Helpers.updateAggregate(threat.readiness, event.readiness or 0)
    Helpers.updateAggregate(threat.budgetConfidenceGain, event.budgetConfidenceGain or 0)
    Helpers.updateAggregate(threat.budgetReady, event.budgetReady and 1 or 0)

    if event.status then
        threat.statusCounts[event.status] = (threat.statusCounts[event.status] or 0) + 1
    end

    if Helpers.isFiniteNumber(event.transitions) then
        threat.transitions = math.max(threat.transitions or 0, event.transitions)
    end
end

function TelemetryAnalytics.recordPress(event, scheduledSnapshot)
    Helpers.incrementCounter("press", 1)
    local metrics = TelemetryAnalytics.metrics
    if typeof(event) ~= "table" or typeof(metrics) ~= "table" then
        return
    end

    if event.forced then
        metrics.press.forcedCount += 1
    end

    local isImmediate = false
    if event.scheduledReason == "immediate-press" or event.immediate == true then
        isImmediate = true
    end

    local leadDelta

    if typeof(scheduledSnapshot) == "table" then
        metrics.press.scheduledCount += 1

        if scheduledSnapshot.reason then
            Helpers.incrementCount(metrics.press.scheduledReasons, scheduledSnapshot.reason, 1)
            if scheduledSnapshot.reason == "immediate-press" then
                isImmediate = true
            end
        end

        local eventTime = event.time or os.clock()
        local scheduleTime = scheduledSnapshot.scheduleTime
        if not Helpers.isFiniteNumber(scheduleTime) then
            scheduleTime = eventTime
        end

        local pressAt = scheduledSnapshot.pressAt
        if not Helpers.isFiniteNumber(pressAt) then
            pressAt = scheduleTime
        end

        local actualWait = nil
        if Helpers.isFiniteNumber(eventTime) and Helpers.isFiniteNumber(scheduleTime) then
            actualWait = eventTime - scheduleTime
            Helpers.updateAggregate(metrics.press.actualWait, actualWait)
            Helpers.updateAggregate(metrics.timeline.scheduleLifetime, actualWait)
        end

        local expectedWait = 0
        if Helpers.isFiniteNumber(pressAt) and Helpers.isFiniteNumber(scheduleTime) then
            expectedWait = math.max(pressAt - scheduleTime, 0)
        end

        if actualWait ~= nil then
            local waitDelta = actualWait - expectedWait
            Helpers.updateAggregate(metrics.press.waitDelta, waitDelta)
        end

        local predictedImpact = scheduledSnapshot.predictedImpact
        if Helpers.isFiniteNumber(predictedImpact) and actualWait ~= nil then
            local achievedLead = predictedImpact - actualWait
            Helpers.updateAggregate(metrics.timeline.achievedLead, achievedLead)
            leadDelta = achievedLead - (scheduledSnapshot.lead or 0)
            Helpers.updateAggregate(metrics.timeline.leadDelta, leadDelta)
        end

        if scheduledSnapshot.ballId then
            local inFlight = metrics.inFlight
            if typeof(inFlight) == "table" then
                inFlight[scheduledSnapshot.ballId] = nil
            end
        end
    else
        metrics.press.unscheduledCount += 1
    end

    if isImmediate then
        metrics.press.immediateCount += 1
    end

    if Helpers.isFiniteNumber(event.activationLatency) then
        Helpers.updateAggregate(metrics.press.activationLatency, event.activationLatency)
        Helpers.updateAggregate(metrics.latency.activation, event.activationLatency)
    end

    if Helpers.isFiniteNumber(event.adaptiveBias) then
        Helpers.updateAggregate(metrics.press.adaptiveBias, event.adaptiveBias)
    end

    if Helpers.isFiniteNumber(event.reactionTime) then
        Helpers.updateAggregate(metrics.press.reactionTime, event.reactionTime)
    end

    if Helpers.isFiniteNumber(event.decisionTime) then
        Helpers.updateAggregate(metrics.press.decisionTime, event.decisionTime)
    end

    if Helpers.isFiniteNumber(event.decisionToPressTime) then
        Helpers.updateAggregate(metrics.press.decisionToPressTime, event.decisionToPressTime)
    end

    if metrics.quantiles and Helpers.isFiniteNumber(event.decisionToPressTime) then
        Helpers.updateQuantileEstimator(metrics.quantiles.commitLatency, event.decisionToPressTime)
    end

    if typeof(event.smartTuning) == "table" then
        if Helpers.isFiniteNumber(event.smartTuning.latency) then
            Helpers.updateAggregate(metrics.press.smartLatency, event.smartTuning.latency)
        end

        local applied = event.smartTuning.applied
        if typeof(applied) == "table" then
            Helpers.updateAggregate(metrics.press.smartReaction, applied.reactionBias)
            Helpers.updateAggregate(metrics.press.smartSlack, applied.scheduleSlack)
            Helpers.updateAggregate(metrics.press.smartConfidence, applied.confidencePadding)
        end
    end

    TelemetryAnalytics.adjust(leadDelta)
end

function TelemetryAnalytics.aggregateMean(aggregate)
    if typeof(aggregate) == "table" then
        return aggregate.mean
    end
    return nil
end

function TelemetryAnalytics.selectTopReason(counts)
    local bestKey = nil
    local bestCount = 0
    if typeof(counts) ~= "table" then
        return bestKey, bestCount
    end

    for key, value in pairs(counts) do
        if typeof(value) == "number" and value > bestCount then
            bestKey = key
            bestCount = value
        end
    end

    return bestKey, bestCount
end

function TelemetryAnalytics.computeSummary(stats)
    local summary = {}
    local counters = stats.counters or {}
    summary.pressCount = counters.press or 0
    summary.scheduleCount = counters.schedule or 0
    summary.latencyCount = counters.latency or 0
    summary.threatCount = counters.threat or 0
    summary.immediateCount = stats.press and stats.press.immediateCount or 0
    if summary.pressCount > 0 then
        summary.immediateRate = summary.immediateCount / summary.pressCount
    else
        summary.immediateRate = 0
    end
    summary.averageWaitDelta = TelemetryAnalytics.aggregateMean(stats.press and stats.press.waitDelta)
    summary.averageActivationLatency = TelemetryAnalytics.aggregateMean(stats.latency and stats.latency.activation)
    summary.averageLatency = TelemetryAnalytics.aggregateMean(stats.latency and stats.latency.accepted)
    local reactionAggregate = Helpers.summariseAggregate(stats.press and stats.press.reactionTime)
    summary.averageReactionTime = reactionAggregate.mean
    summary.reactionStdDev = reactionAggregate.stdDev
    summary.reactionMin = reactionAggregate.min
    summary.reactionMax = reactionAggregate.max

    local decisionAggregate = Helpers.summariseAggregate(stats.press and stats.press.decisionTime)
    summary.averageDecisionTime = decisionAggregate.mean
    summary.decisionStdDev = decisionAggregate.stdDev
    summary.decisionMin = decisionAggregate.min
    summary.decisionMax = decisionAggregate.max

    local decisionToPressAggregate = Helpers.summariseAggregate(stats.press and stats.press.decisionToPressTime)
    summary.averageDecisionToPressTime = decisionToPressAggregate.mean
    summary.decisionToPressStdDev = decisionToPressAggregate.stdDev
    summary.decisionToPressMin = decisionToPressAggregate.min
    summary.decisionToPressMax = decisionToPressAggregate.max
    summary.leadDeltaMean = TelemetryAnalytics.aggregateMean(stats.timeline and stats.timeline.leadDelta)
    summary.achievedLeadMean = TelemetryAnalytics.aggregateMean(stats.timeline and stats.timeline.achievedLead)
    summary.scheduleLifetimeMean = TelemetryAnalytics.aggregateMean(stats.timeline and stats.timeline.scheduleLifetime)
    summary.adaptiveBias = stats.adaptiveState and stats.adaptiveState.reactionBias or 0
    summary.cancellationCount = stats.cancellations and stats.cancellations.total or 0
    summary.topCancellationReason, summary.topCancellationCount = TelemetryAnalytics.selectTopReason(stats.cancellations and stats.cancellations.reasonCounts)

    local successAccepted = stats.success and stats.success.acceptedCount or 0
    local successEvents = counters.success or successAccepted
    summary.successAccepted = successAccepted
    summary.successSamples = successEvents
    if summary.pressCount > 0 then
        summary.successRate = successAccepted / summary.pressCount
    elseif successEvents > 0 then
        summary.successRate = successAccepted / successEvents
    else
        summary.successRate = 0
    end
    summary.pressMissCount = math.max(summary.pressCount - successAccepted, 0)
    summary.averageThreatScore = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.score)
    summary.averageThreatSeverity = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.severity)
    summary.averageThreatIntensity = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.intensity)
    summary.averageThreatUrgency = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.urgency)
    summary.averageThreatLogistic = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.logistic)
    summary.averageThreatDistance = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.distance)
    summary.averageThreatSpeed = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.speed)
    summary.averageThreatConfidence = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.confidence)
    summary.averageDetectionConfidence = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.detectionConfidence)
    summary.averageThreatLoad = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.load)
    summary.averageThreatSpectralFast = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.spectralFast)
    summary.averageThreatSpectralMedium = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.spectralMedium)
    summary.averageThreatSpectralSlow = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.spectralSlow)
    summary.averageThreatMomentum = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.momentum)
    summary.averageThreatVolatility = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.volatility)
    summary.averageThreatStability = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.stability)
    summary.averageThreatAcceleration = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.acceleration)
    summary.averageThreatJerk = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.jerk)
    summary.averageThreatBoost = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.detectionBoost)
    summary.averageThreatTempo = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.tempo)
    summary.averageThreatBudget = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.budget)
    summary.averageThreatBudgetPressure = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.budgetPressure)
    summary.averageThreatBudgetRatio = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.budgetRatio)
    summary.averageThreatReadiness = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.readiness)
    summary.averageThreatLatencyGap = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.latencyGap)
    summary.averageThreatHorizon = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.horizon)
    summary.averageThreatBudgetConfidenceGain = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.budgetConfidenceGain)
    summary.averageThreatBudgetReadyRate = TelemetryAnalytics.aggregateMean(stats.threat and stats.threat.budgetReady)
    local reactionTarget = Defaults.SMART_TUNING.reactionGoal or Defaults.CONFIG.pressReactionBias or 0
    if not Helpers.isFiniteNumber(reactionTarget) or reactionTarget <= 0 then
        reactionTarget = math.max(Defaults.CONFIG.oscillationSpamMinGap or SPAM_MIN_GAP, SPAM_MIN_GAP) * 2.2
    end
    local commitTarget = Defaults.SMART_TUNING.commitP99Target or Defaults.CONFIG.pressScheduleSlack or 0
    if not Helpers.isFiniteNumber(commitTarget) or commitTarget <= 0 then
        commitTarget = math.max(Defaults.CONFIG.oscillationSpamMinGap or SPAM_MIN_GAP, SPAM_MIN_GAP) * 1.8
    end

    if reactionAggregate.count >= 6 then
        local focusScore = 0
        local meanReaction = reactionAggregate.mean or reactionTarget
        local minReaction = reactionAggregate.min or meanReaction
        local reactionStdDev = reactionAggregate.stdDev or 0
        if Helpers.isFiniteNumber(meanReaction) and reactionTarget > 0 then
            focusScore += math.clamp((reactionTarget - meanReaction) / reactionTarget, -1.6, 1.6) * 0.55
        end
        if Helpers.isFiniteNumber(minReaction) and reactionTarget > 0 then
            focusScore += math.clamp((reactionTarget * 0.65 - minReaction) / math.max(reactionTarget * 0.65, 0.004), -1.5, 1.5)
                * 0.3
        end
        if Helpers.isFiniteNumber(reactionStdDev) then
            focusScore += math.clamp((0.006 - reactionStdDev) / 0.006, -1.4, 1.4) * 0.35
        end
        if Helpers.isFiniteNumber(summary.successRate) then
            focusScore += math.clamp((summary.successRate or 0) - 0.95, -0.4, 0.4) * 1.1
        end
        if Helpers.isFiniteNumber(summary.immediateRate) then
            focusScore += math.clamp(0.2 - (summary.immediateRate or 0), -0.35, 0.35) * 0.85
        end
        summary.reactionFocusScore = math.clamp(focusScore, -2.5, 2.5)
    end

    if decisionToPressAggregate.count >= 6 then
        local loadScore = 0
        local decisionMean = decisionToPressAggregate.mean or commitTarget
        local decisionStdDev = decisionToPressAggregate.stdDev or 0
        local decisionMin = decisionToPressAggregate.min or decisionMean
        if Helpers.isFiniteNumber(decisionMean) and commitTarget > 0 then
            loadScore += math.clamp((decisionMean - commitTarget) / commitTarget, -1.5, 2.4) * 0.75
        end
        if Helpers.isFiniteNumber(decisionStdDev) then
            loadScore += math.clamp(decisionStdDev / math.max(commitTarget * 0.8, 0.004) - 1, -1.2, 2.2) * 0.6
        end
        if Helpers.isFiniteNumber(decisionMin) and commitTarget > 0 then
            loadScore += math.clamp((decisionMin - commitTarget * 0.55) / math.max(commitTarget * 0.55, 0.0035), -1.2, 2) * 0.35
        end
        if Helpers.isFiniteNumber(reactionAggregate.stdDev) then
            loadScore += math.clamp(reactionAggregate.stdDev / math.max(reactionTarget * 0.35, 0.004) - 1, -1, 1.8) * 0.45
        end
        if Helpers.isFiniteNumber(summary.cancellationCount) then
            loadScore += math.clamp((summary.cancellationCount or 0) / math.max(summary.pressCount or 1, 1) - 0.05, -0.4, 0.6)
                * 0.5
        end
        summary.cognitiveLoadScore = math.clamp(loadScore, -2, 3)
    end

    if reactionAggregate.count >= 4 and decisionAggregate.count >= 4 then
        local blend = 0
        if Helpers.isFiniteNumber(reactionAggregate.stdDev) then
            blend += math.clamp((0.005 - (reactionAggregate.stdDev or 0)) / 0.005, -1.5, 1.5) * 0.4
        end
        if Helpers.isFiniteNumber(decisionAggregate.stdDev) then
            blend += math.clamp((0.007 - (decisionAggregate.stdDev or 0)) / 0.007, -1.4, 1.4) * 0.35
        end
        if Helpers.isFiniteNumber(summary.successRate) then
            blend += math.clamp((summary.successRate or 0) - 0.93, -0.4, 0.4) * 0.9
        end
        summary.neuroTempoScore = math.clamp(blend, -2.2, 2.2)
    end
    summary.topThreatStatus, summary.topThreatStatusCount = TelemetryAnalytics.selectTopReason(stats.threat and stats.threat.statusCounts)
    summary.threatTransitions = stats.threat and stats.threat.transitions or 0

    if stats.quantiles then
        local commit = stats.quantiles.commitLatency
        if typeof(commit) == "table" then
            summary.commitLatencyP99 = commit.value
            summary.commitLatencySampleCount = commit.count
        end

        local lookahead = stats.quantiles.scheduleLookahead
        if typeof(lookahead) == "table" then
            summary.scheduleLookaheadP10 = lookahead.value
            summary.scheduleLookaheadMin = lookahead.min
            summary.scheduleLookaheadSampleCount = lookahead.count
        end
    end

    return summary
end

function TelemetryAnalytics.buildRecommendations(stats, summary)
    local recommendations = {}
    local pressCount = summary.pressCount or 0

    if pressCount <= 0 then
        table.insert(recommendations, "No parry presses have been recorded yet; run a telemetry scenario to capture data.")
        return recommendations
    end

    local waitDelta = summary.averageWaitDelta or 0
    if math.abs(waitDelta) > 0.01 then
        table.insert(
            recommendations,
            string.format(
                "Average press wait delta is %.1f ms (actual vs scheduled); adjust pressScheduleSlack or reaction bias.",
                waitDelta * 1000
            )
        )
    end

    local leadDelta = summary.leadDeltaMean or 0
    if math.abs(leadDelta) > 0.01 then
        table.insert(
            recommendations,
            string.format(
                "Achieved press lead differs from target by %.1f ms; review latency estimates and adaptive tuning.",
                leadDelta * 1000
            )
        )
    end

    local immediateRate = summary.immediateRate or 0
    if immediateRate > 0.25 then
        table.insert(
            recommendations,
            string.format(
                "%.0f%% of presses were immediate; consider expanding pressMaxLookahead or tuning detection thresholds.",
                immediateRate * 100
            )
        )
    end

    local commitP99 = summary.commitLatencyP99
    local commitTarget = Defaults.SMART_TUNING.commitP99Target or 0.01
    if Helpers.isFiniteNumber(commitP99) and commitP99 > commitTarget then
        table.insert(
            recommendations,
            string.format(
                "Commit latency P99 is %.1f ms (target %.0f ms); tighten pressScheduleSlack or increase reaction bias.",
                commitP99 * 1000,
                commitTarget * 1000
            )
        )
    end

    local lookaheadGoal = Defaults.SMART_TUNING.lookaheadGoal or Defaults.CONFIG.pressLookaheadGoal or 0
    local lookaheadP10 = summary.scheduleLookaheadP10
    if Helpers.isFiniteNumber(lookaheadGoal) and lookaheadGoal > 0 and Helpers.isFiniteNumber(lookaheadP10) and lookaheadP10 < lookaheadGoal then
        table.insert(
            recommendations,
            string.format(
                "Lookahead P10 is %.1f ms below the %.0f ms target; expand pressMaxLookahead or ease reaction bias.",
                (lookaheadGoal - lookaheadP10) * 1000,
                lookaheadGoal * 1000
            )
        )
    end

    local averageLatency = summary.averageLatency or 0
    if averageLatency > 0.18 then
        table.insert(
            recommendations,
            string.format(
                "Average activation latency is %.0f ms; consider increasing pressReactionBias or enabling remote latency estimation.",
                averageLatency * 1000
            )
        )
    end

    if summary.cancellationCount and summary.cancellationCount > 0 then
        local topReason = summary.topCancellationReason
        if topReason then
            table.insert(
                recommendations,
                string.format(
                    "%d schedules were cancelled (most often '%s'); inspect schedule-cleared telemetry for root causes.",
                    summary.cancellationCount,
                    tostring(topReason)
                )
            )
        else
            table.insert(
                recommendations,
                string.format("%d schedules were cancelled; inspect schedule-cleared telemetry for details.", summary.cancellationCount)
            )
        end
    end

    if not (smartTuningState and smartTuningState.enabled) and math.abs(summary.adaptiveBias or 0) > 0.001 then
        table.insert(
            recommendations,
            string.format(
                "Adaptive reaction bias settled at %.3f s; fold this into pressReactionBias or enable smart tuning.",
                summary.adaptiveBias
            )
        )
    end

    return recommendations
end

function TelemetryAnalytics.computeInsights(stats, summary, adjustments, options)
    options = options or {}
    stats = stats or TelemetryAnalytics.clone()
    summary = summary or TelemetryAnalytics.computeSummary(stats)

    local minSamples = options.minSamples
    if not Helpers.isFiniteNumber(minSamples) or minSamples < 0 then
        minSamples = TELEMETRY_ADJUSTMENT_MIN_SAMPLES or 4
    end

    local leadTolerance = options.leadTolerance
    if not Helpers.isFiniteNumber(leadTolerance) or leadTolerance < 0 then
        leadTolerance = TELEMETRY_ADJUSTMENT_LEAD_TOLERANCE or 0.004
    end

    local waitTolerance = options.waitTolerance
    if not Helpers.isFiniteNumber(waitTolerance) or waitTolerance < 0 then
        waitTolerance = TELEMETRY_ADJUSTMENT_WAIT_TOLERANCE or 0.003
    end

    local counters = stats.counters or {}
    local pressCount = summary.pressCount or 0
    local successAccepted = stats.success and stats.success.acceptedCount or 0
    local successEvents = counters.success or successAccepted
    local successRate = 0
    if pressCount > 0 then
        successRate = successAccepted / pressCount
    elseif successEvents > 0 then
        successRate = successAccepted / successEvents
    end

    local cancellationRate = 0
    if pressCount > 0 and summary.cancellationCount then
        cancellationRate = summary.cancellationCount / pressCount
    end

    local insights = {
        samples = {
            press = pressCount,
            schedule = summary.scheduleCount or 0,
            latency = summary.latencyCount or 0,
            success = successEvents,
        },
        metrics = {
            averageLatency = summary.averageLatency,
            averageActivationLatency = summary.averageActivationLatency,
            averageWaitDelta = summary.averageWaitDelta,
            leadDeltaMean = summary.leadDeltaMean,
            achievedLeadMean = summary.achievedLeadMean,
            scheduleLifetimeMean = summary.scheduleLifetimeMean,
            adaptiveBias = summary.adaptiveBias,
            immediateRate = summary.immediateRate,
            cancellationCount = summary.cancellationCount or 0,
            cancellationRate = cancellationRate,
            successRate = successRate,
            commitLatencyP99 = summary.commitLatencyP99,
            scheduleLookaheadP10 = summary.scheduleLookaheadP10,
            scheduleLookaheadMin = summary.scheduleLookaheadMin,
        },
        statuses = {},
        severity = "info",
        recommendations = TelemetryAnalytics.buildRecommendations(stats, summary),
    }

    local severityRank = { info = 1, warning = 2, critical = 3 }

    local function addStatus(name, level, message, payload)
        insights.statuses[name] = {
            level = level,
            message = message,
            payload = payload,
        }
        if severityRank[level] and severityRank[level] > (severityRank[insights.severity] or 0) then
            insights.severity = level
        end
    end

    if pressCount < minSamples then
        addStatus(
            "dataset",
            "warning",
            string.format("Only %d presses captured; need %d for confident adjustments.", pressCount, minSamples),
            { pressCount = pressCount, minSamples = minSamples }
        )
    else
        addStatus("dataset", "info", "Telemetry sample size is sufficient for tuning.", { pressCount = pressCount })
    end

    local leadDelta = summary.leadDeltaMean or 0
    if pressCount >= minSamples and Helpers.isFiniteNumber(leadDelta) then
        local magnitude = math.abs(leadDelta)
        if magnitude <= leadTolerance then
            addStatus("timing", "info", "Press lead aligns with configured targets.", { leadDelta = leadDelta })
        else
            local severity = "warning"
            if magnitude >= math.max(leadTolerance * 3, 0.015) then
                severity = "critical"
            end
            local direction = if leadDelta > 0 then "late" else "early"
            addStatus(
                "timing",
                severity,
                string.format("Presses are %.1f ms %s on average.", magnitude * 1000, direction),
                { leadDelta = leadDelta }
            )
        end
    end

    local waitDelta = summary.averageWaitDelta or 0
    if pressCount >= minSamples and Helpers.isFiniteNumber(waitDelta) then
        local magnitude = math.abs(waitDelta)
        if magnitude <= waitTolerance then
            addStatus("slack", "info", "Schedule slack is balanced with observed waits.", { waitDelta = waitDelta })
        else
            local severity = "warning"
            if magnitude >= math.max(waitTolerance * 3, 0.012) then
                severity = "critical"
            end
            local direction = if waitDelta > 0 then "longer" else "shorter"
            addStatus(
                "slack",
                severity,
                string.format("Actual waits are %.1f ms %s than scheduled.", magnitude * 1000, direction),
                { waitDelta = waitDelta }
            )
        end
    end

    local averageLatency = summary.averageLatency or 0
    if Helpers.isFiniteNumber(averageLatency) and averageLatency > 0 then
        local latencySeverity = "info"
        local message = string.format("Average activation latency is %.0f ms.", averageLatency * 1000)
        if averageLatency >= 0.22 then
            latencySeverity = "critical"
            message = string.format("Average activation latency is %.0f ms; presses may be blocked by ping.", averageLatency * 1000)
        elseif averageLatency >= 0.16 then
            latencySeverity = "warning"
            message = string.format("Average activation latency is %.0f ms; consider adding more reaction slack.", averageLatency * 1000)
        end
        addStatus("latency", latencySeverity, message, { averageLatency = averageLatency })
    end

    if pressCount >= minSamples then
        local level = "info"
        local message = string.format("%.0f%% of presses confirmed successfully.", successRate * 100)
        if successRate < 0.6 then
            level = "critical"
            message = string.format("Only %.0f%% of presses confirmed; investigate detection accuracy.", successRate * 100)
        elseif successRate < 0.8 then
            level = "warning"
            message = string.format("%.0f%% of presses confirmed; tighten timing or review cancellations.", successRate * 100)
        end
        addStatus("success", level, message, { successRate = successRate })
    end

    if cancellationRate > 0.15 then
        addStatus(
            "cancellations",
            "warning",
            string.format("%.0f%% of schedules were cancelled; check telemetry timeline for churn.", cancellationRate * 100),
            { cancellationRate = cancellationRate, cancellationCount = summary.cancellationCount }
        )
    elseif cancellationRate > 0 then
        addStatus(
            "cancellations",
            "info",
            string.format("%.0f%% of schedules cancelled during evaluation.", cancellationRate * 100),
            { cancellationRate = cancellationRate, cancellationCount = summary.cancellationCount }
        )
    end

    if summary.immediateRate and summary.immediateRate > 0.25 then
        addStatus(
            "immediates",
            "warning",
            string.format("%.0f%% of presses fired immediately; consider increasing lookahead.", summary.immediateRate * 100),
            { immediateRate = summary.immediateRate }
        )
    end

    local commitTarget = options.commitTarget or Defaults.SMART_TUNING.commitP99Target or 0.01
    local commitSamples = summary.commitLatencySampleCount or 0
    local commitP99 = summary.commitLatencyP99
    if commitSamples > 0 and Helpers.isFiniteNumber(commitP99) and commitTarget > 0 then
        local level = "info"
        local message = string.format("Commit latency P99 is %.0f ms (target %.0f ms).", commitP99 * 1000, commitTarget * 1000)
        if commitP99 > commitTarget then
            level = "warning"
            if commitP99 >= commitTarget * 1.8 then
                level = "critical"
            end
        end
        addStatus("commit-latency", level, message, { commitP99 = commitP99, target = commitTarget, samples = commitSamples })
    end

    local lookaheadGoal = options.lookaheadGoal or Defaults.SMART_TUNING.lookaheadGoal or Defaults.CONFIG.pressLookaheadGoal or 0
    local lookaheadSamples = summary.scheduleLookaheadSampleCount or 0
    local lookaheadP10 = summary.scheduleLookaheadP10
    if lookaheadSamples > 0 and Helpers.isFiniteNumber(lookaheadGoal) and lookaheadGoal > 0 and Helpers.isFiniteNumber(lookaheadP10) then
        local level = "info"
        local message = string.format("Lookahead P10 is %.0f ms (goal %.0f ms).", lookaheadP10 * 1000, lookaheadGoal * 1000)
        if lookaheadP10 < lookaheadGoal then
            level = "warning"
            if lookaheadP10 <= lookaheadGoal * 0.7 then
                level = "critical"
            end
        end
        addStatus(
            "lookahead",
            level,
            message,
            { goal = lookaheadGoal, lookaheadP10 = lookaheadP10, samples = lookaheadSamples }
        )
    end

    if typeof(adjustments) == "table" then
        insights.adjustments = {
            status = adjustments.status,
            updates = typeof(adjustments.updates) == "table" and Util.deepCopy(adjustments.updates) or {},
            deltas = typeof(adjustments.deltas) == "table" and Util.deepCopy(adjustments.deltas) or {},
            reasons = typeof(adjustments.reasons) == "table" and Util.deepCopy(adjustments.reasons) or {},
            minSamples = adjustments.minSamples,
        }
    else
        insights.adjustments = {
            status = "none",
            updates = {},
            deltas = {},
            reasons = {},
            minSamples = minSamples,
        }
    end

    insights.summary = summary
    insights.stats = stats
    return insights
end

local smartTuningState = {
    enabled = false,
    lastUpdate = 0,
    lastBallId = nil :: string?,
    baseReactionBias = 0,
    baseScheduleSlack = 0,
    baseConfidencePadding = 0,
    targetReactionBias = 0,
    targetScheduleSlack = 0,
    targetConfidencePadding = 0,
    reactionBias = nil :: number?,
    scheduleSlack = nil :: number?,
    confidencePadding = nil :: number?,
    sigma = 0,
    mu = 0,
    muPlus = 0,
    muMinus = 0,
    delta = 0,
    ping = 0,
    overshoot = 0,
    scheduleLead = 0,
    updateCount = 0,
}

local autoTuningState = {
    enabled = false,
    intervalSeconds = Defaults.AUTO_TUNING.intervalSeconds,
    minSamples = Defaults.AUTO_TUNING.minSamples,
    allowWhenSmartTuning = Defaults.AUTO_TUNING.allowWhenSmartTuning,
    dryRun = Defaults.AUTO_TUNING.dryRun,
    leadGain = Defaults.AUTO_TUNING.leadGain,
    slackGain = Defaults.AUTO_TUNING.slackGain,
    latencyGain = Defaults.AUTO_TUNING.latencyGain,
    leadTolerance = Defaults.AUTO_TUNING.leadTolerance,
    waitTolerance = Defaults.AUTO_TUNING.waitTolerance,
    maxReactionBias = Defaults.AUTO_TUNING.maxReactionBias,
    maxScheduleSlack = Defaults.AUTO_TUNING.maxScheduleSlack,
    maxActivationLatency = Defaults.AUTO_TUNING.maxActivationLatency,
    minDelta = Defaults.AUTO_TUNING.minDelta,
    maxAdjustmentsPerRun = Defaults.AUTO_TUNING.maxAdjustmentsPerRun,
    lastRun = 0,
    lastStatus = nil :: string?,
    lastAdjustments = nil :: { [string]: any }?,
    lastResult = nil :: { [string]: any }?,
    lastError = nil :: string?,
    lastSummary = nil :: { [string]: any }?,
}

function Helpers.normalizeAutoTuningConfig(value)
    if value == false then
        return false
    end

    local base = Util.deepCopy(Defaults.AUTO_TUNING)

    if value == nil then
        return base
    end

    if value == true then
        base.enabled = true
        return base
    end

    if typeof(value) ~= "table" then
        error("AutoParry.configure: autoTuning expects a table, boolean, or nil", 0)
    end

    for key, entry in pairs(value) do
        if entry ~= nil then
            base[key] = entry
        end
    end

    if base.intervalSeconds ~= nil then
        if not Helpers.isFiniteNumber(base.intervalSeconds) or base.intervalSeconds < 0 then
            base.intervalSeconds = Defaults.AUTO_TUNING.intervalSeconds
        end
    end
    if base.minSamples ~= nil then
        if not Helpers.isFiniteNumber(base.minSamples) or base.minSamples < 1 then
            base.minSamples = Defaults.AUTO_TUNING.minSamples
        end
    end
    if base.minDelta ~= nil and (not Helpers.isFiniteNumber(base.minDelta) or base.minDelta < 0) then
        base.minDelta = Defaults.AUTO_TUNING.minDelta
    end
    if base.maxAdjustmentsPerRun ~= nil then
        if not Helpers.isFiniteNumber(base.maxAdjustmentsPerRun) or base.maxAdjustmentsPerRun < 0 then
            base.maxAdjustmentsPerRun = Defaults.AUTO_TUNING.maxAdjustmentsPerRun
        end
    end

    base.enabled = base.enabled ~= false
    base.allowWhenSmartTuning = base.allowWhenSmartTuning == true
    base.dryRun = base.dryRun == true

    return base
end

function Helpers.syncAutoTuningState()
    local normalized = Helpers.normalizeAutoTuningConfig(config.autoTuning)
    config.autoTuning = normalized

    if normalized == false then
        autoTuningState.enabled = false
        autoTuningState.intervalSeconds = Defaults.AUTO_TUNING.intervalSeconds
        autoTuningState.minSamples = Defaults.AUTO_TUNING.minSamples
        autoTuningState.allowWhenSmartTuning = Defaults.AUTO_TUNING.allowWhenSmartTuning
        autoTuningState.dryRun = Defaults.AUTO_TUNING.dryRun
        autoTuningState.leadGain = Defaults.AUTO_TUNING.leadGain
        autoTuningState.slackGain = Defaults.AUTO_TUNING.slackGain
        autoTuningState.latencyGain = Defaults.AUTO_TUNING.latencyGain
        autoTuningState.leadTolerance = Defaults.AUTO_TUNING.leadTolerance
        autoTuningState.waitTolerance = Defaults.AUTO_TUNING.waitTolerance
        autoTuningState.maxReactionBias = Defaults.AUTO_TUNING.maxReactionBias
        autoTuningState.maxScheduleSlack = Defaults.AUTO_TUNING.maxScheduleSlack
        autoTuningState.maxActivationLatency = Defaults.AUTO_TUNING.maxActivationLatency
        autoTuningState.minDelta = Defaults.AUTO_TUNING.minDelta
        autoTuningState.maxAdjustmentsPerRun = Defaults.AUTO_TUNING.maxAdjustmentsPerRun
        return
    end

    local spec = normalized or Defaults.AUTO_TUNING
    autoTuningState.enabled = spec.enabled ~= false
    autoTuningState.intervalSeconds = spec.intervalSeconds or Defaults.AUTO_TUNING.intervalSeconds
    if not Helpers.isFiniteNumber(autoTuningState.intervalSeconds) or autoTuningState.intervalSeconds < 0 then
        autoTuningState.intervalSeconds = Defaults.AUTO_TUNING.intervalSeconds
    end
    autoTuningState.minSamples = spec.minSamples or Defaults.AUTO_TUNING.minSamples
    if not Helpers.isFiniteNumber(autoTuningState.minSamples) or autoTuningState.minSamples < 1 then
        autoTuningState.minSamples = Defaults.AUTO_TUNING.minSamples
    end
    autoTuningState.minSamples = math.floor(autoTuningState.minSamples + 0.5)
    if autoTuningState.minSamples < 1 then
        autoTuningState.minSamples = 1
    end
    autoTuningState.allowWhenSmartTuning = spec.allowWhenSmartTuning == true
    autoTuningState.dryRun = spec.dryRun == true
    autoTuningState.leadGain = spec.leadGain or Defaults.AUTO_TUNING.leadGain
    autoTuningState.slackGain = spec.slackGain or Defaults.AUTO_TUNING.slackGain
    autoTuningState.latencyGain = spec.latencyGain or Defaults.AUTO_TUNING.latencyGain
    autoTuningState.leadTolerance = spec.leadTolerance or Defaults.AUTO_TUNING.leadTolerance
    autoTuningState.waitTolerance = spec.waitTolerance or Defaults.AUTO_TUNING.waitTolerance
    autoTuningState.maxReactionBias = spec.maxReactionBias or Defaults.AUTO_TUNING.maxReactionBias
    autoTuningState.maxScheduleSlack = spec.maxScheduleSlack or Defaults.AUTO_TUNING.maxScheduleSlack
    autoTuningState.maxActivationLatency = spec.maxActivationLatency or Defaults.AUTO_TUNING.maxActivationLatency
    autoTuningState.minDelta = spec.minDelta or Defaults.AUTO_TUNING.minDelta
    if autoTuningState.minDelta < 0 then
        autoTuningState.minDelta = 0
    end
    autoTuningState.maxAdjustmentsPerRun = spec.maxAdjustmentsPerRun or Defaults.AUTO_TUNING.maxAdjustmentsPerRun
    if autoTuningState.maxAdjustmentsPerRun < 0 then
        autoTuningState.maxAdjustmentsPerRun = 0
    end
end

function TelemetryAnalytics.computeAdjustments(stats, summary, configSnapshot, options)
    local context = prepareAdjustmentContext(stats, summary, configSnapshot, options)
    local adjustments = context.adjustments

    if context.finished then
        return adjustments
    end

    applyLeadAdjustment(context)
    applySlackAdjustment(context)
    applyCommitAdjustments(context)
    applyLookaheadAdjustment(context)
    applyLatencyAdjustment(context)
    finalizeAdjustmentStatus(context)

    return adjustments
end

function Helpers.ensurePawsSettings()
    local settings = GlobalEnv.Paws
    if typeof(settings) ~= "table" then
        settings = {}
        GlobalEnv.Paws = settings
    end
    return settings
end

function Helpers.noteVirtualInputFailure(delay)
    Context.runtime.virtualInputUnavailable = true
    Helpers.resetSpamBurst("virtual-input-failure")
    Context.runtime.transientRetryActive = true
    Context.runtime.transientRetryCount = 0
    Context.runtime.transientRetryCooldown = 0
    Context.runtime.transientRetryCooldownBallId = nil
    local retry = state.virtualInputRetry
    if typeof(retry) ~= "table" then
        retry = { failureCount = 0, min = 0.05, max = 0.25, base = 0.12, growth = 1.5 }
        state.virtualInputRetry = retry
    end

    retry.failureCount = (retry.failureCount or 0) + 1

    local requested = nil
    if typeof(delay) == "number" and delay > 0 then
        requested = delay
    end

    local base = retry.base or 0.12
    if requested then
        if requested > 1 then
            base = requested * 0.05
        else
            base = requested
        end
    end

    local minDelay = retry.min or 0.05
    local maxDelay = retry.max or 0.25
    base = math.clamp(base, minDelay, maxDelay)

    local exponent = math.max((retry.failureCount or 0) - 1, 0)
    local growth = minDelay * ((retry.growth or 1.5) ^ exponent)
    local finalDelay = math.max(base, growth)

    if finalDelay > maxDelay then
        finalDelay = maxDelay
    end

    if finalDelay <= 0 then
        finalDelay = minDelay
    end

    Context.runtime.virtualInputRetryAt = os.clock() + finalDelay
    Context.runtime.targetingSpamSuspendedUntil = Context.runtime.virtualInputRetryAt + 0.2

    if state.enabled then
        Context.hooks.setStage("waiting-input", { reason = "virtual-input" })
        Context.hooks.updateStatusLabel({ "Auto-Parry F", "Status: waiting for input permissions" })
    end
end

function Helpers.noteVirtualInputSuccess()
    if Context.runtime.virtualInputUnavailable then
        Context.runtime.virtualInputUnavailable = false
        Context.runtime.virtualInputRetryAt = 0
        Context.runtime.targetingSpamSuspendedUntil = 0
        Context.runtime.transientRetryActive = false
        Context.runtime.transientRetryCount = 0
        Context.runtime.transientRetryCooldownBallId = nil
        local retry = state.virtualInputRetry
        if typeof(retry) == "table" then
            retry.failureCount = 0
        end

        if state.enabled and initProgress.stage == "waiting-input" then
            Context.hooks.publishReadyStatus()
        end

        if Context.runtime.pendingParryRelease then
            Context.runtime.pendingParryRelease = false
            if not Context.hooks.sendParryKeyEvent(false) then
                Context.runtime.pendingParryRelease = true
            end
        end
    end
end

local immortalController = ImmortalModule and ImmortalModule.new({}) or nil
local immortalMissingMethodWarnings = {}

function Helpers.resolveVirtualInputManager()
    if Services.VirtualInputManager then
        return Services.VirtualInputManager
    end

    local ok, manager = pcall(game.GetService, game, "VirtualInputManager")
    if ok and manager then
        Services.VirtualInputManager = manager
        return Services.VirtualInputManager
    end

    ok, manager = pcall(game.FindService, game, "VirtualInputManager")
    if ok and manager then
        Services.VirtualInputManager = manager
        return Services.VirtualInputManager
    end

    return nil
end

function Helpers.warnOnceImmortalMissing(methodName)
    if immortalMissingMethodWarnings[methodName] then
        return
    end

    immortalMissingMethodWarnings[methodName] = true
    warn(("AutoParry: Immortal controller missing '%s' support; disabling Immortal features."):format(tostring(methodName)))
end

function Helpers.disableImmortalSupport()
    if not state.immortalEnabled then
        return false
    end

    state.immortalEnabled = false
    Helpers.updateImmortalButton()
    Helpers.syncGlobalSettings()
    immortalStateChanged:fire(false)
    return true
end

function Helpers.callImmortalController(methodName, ...)
    if not immortalController then
        return false
    end

    local method = immortalController[methodName]
    if typeof(method) ~= "function" then
        Helpers.warnOnceImmortalMissing(methodName)
        Helpers.disableImmortalSupport()
        return false
    end

    local ok, result = pcall(method, immortalController, ...)
    if not ok then
        warn(("AutoParry: Immortal controller '%s' call failed: %s"):format(tostring(methodName), tostring(result)))
        Helpers.disableImmortalSupport()
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
    targetDetectedAt: number?,
    decisionAt: number?,
    lastReactionLatency: number?,
    lastReactionTimestamp: number?,
    lastDecisionLatency: number?,
    lastDecisionToPressLatency: number?,
}

local telemetryStates: { [string]: TelemetryState } = {}
local telemetryTimeoutSeconds = 3
local activationLatencyEstimate = Defaults.CONFIG.activationLatency
local perfectParrySnapshot = {
    mu = 0,
    sigma = 0,
    delta = 0,
    z = Defaults.CONFIG.confidenceZ,
}

local pingSample = { value = 0, time = 0 }
local PING_REFRESH_INTERVAL = 0.1
local PROXIMITY_PRESS_GRACE = 0.05
local PROXIMITY_HOLD_GRACE = 0.1

function Helpers.newRollingStat(): RollingStat
    return { count = 0, mean = 0, m2 = 0 }
end

function Helpers.cubeRoot(value: number)
    if value >= 0 then
        return value ^ (1 / 3)
    end

    return -((-value) ^ (1 / 3))
end

function Helpers.smallestPositiveQuadraticRoot(a: number, b: number, c: number)
    if math.abs(a) < Constants.EPSILON then
        if math.abs(b) < Constants.EPSILON then
            return nil
        end

        local root = -c / b
        if Helpers.isFiniteNumber(root) and root > Constants.EPSILON then
            return root
        end

        return nil
    end

    local discriminant = b * b - 4 * a * c
    if discriminant < -Constants.EPSILON then
        return nil
    end

    discriminant = math.max(discriminant, 0)
    local sqrtDiscriminant = math.sqrt(discriminant)
    local q = -0.5 * (b + (b >= 0 and sqrtDiscriminant or -sqrtDiscriminant))

    local candidates = {
        q / a,
    }

    if math.abs(q) > Constants.EPSILON then
        candidates[#candidates + 1] = c / q
    else
        candidates[#candidates + 1] = (-b - sqrtDiscriminant) / (2 * a)
    end

    local best: number?
    for _, root in ipairs(candidates) do
        if Helpers.isFiniteNumber(root) and root > Constants.EPSILON then
            if not best or root < best then
                best = root
            end
        end
    end

    return best
end

function Helpers.smallestPositiveCubicRoot(a: number, b: number, c: number, d: number)
    if math.abs(a) < Constants.EPSILON then
        return Helpers.smallestPositiveQuadraticRoot(b, c, d)
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

    if discriminant > Constants.EPSILON then
        local sqrtDiscriminant = math.sqrt(discriminant)
        local u = Helpers.cubeRoot(-q / 2 + sqrtDiscriminant)
        local v = Helpers.cubeRoot(-q / 2 - sqrtDiscriminant)
        roots[1] = u + v - A / 3
    elseif discriminant >= -Constants.EPSILON then
        local u = Helpers.cubeRoot(-q / 2)
        roots[1] = 2 * u - A / 3
        roots[2] = -u - A / 3
    else
        local negPOver3 = -p / 3
        if negPOver3 <= 0 then
            roots[1] = -A / 3
        else
            local sqp = math.sqrt(negPOver3)
            if sqp < Constants.EPSILON then
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
        if Helpers.isFiniteNumber(root) and root > Constants.EPSILON then
            if not best or root < best then
                best = root
            end
        end
    end

    return best
end

function Helpers.solveRadialImpactTime(d0: number, vr: number, ar: number, jr: number)
    if not (Helpers.isFiniteNumber(d0) and Helpers.isFiniteNumber(vr) and Helpers.isFiniteNumber(ar) and Helpers.isFiniteNumber(jr)) then
        return nil
    end

    local a = jr / 6
    local b = ar / 2
    local c = vr
    local d = d0

    return Helpers.smallestPositiveCubicRoot(a, b, c, d)
end

function Helpers.updateRollingStat(stat: RollingStat, sample: number)
    if not stat then
        return
    end

    if not Helpers.isFiniteNumber(sample) then
        return
    end

    local count = stat.count + 1
    stat.count = count
    local delta = sample - stat.mean
    stat.mean += delta / count
    local delta2 = sample - stat.mean
    stat.m2 += delta * delta2
end

function Helpers.trimHistory(history, cutoff)
    if not history then
        return
    end

    while #history > 0 and history[1].time < cutoff do
        table.remove(history, 1)
    end
end

function Helpers.evaluateOscillation(telemetry: TelemetryState?, now: number)
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
    local span = math.max(latest - earliest, Constants.EPSILON)
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

function Helpers.shouldForceOscillationPress(decision, telemetry, now, config)
    if not telemetry then
        return false
    end

    local fallbackCooldown = config.oscillationSpamCooldown
    if fallbackCooldown == nil then
        fallbackCooldown = Defaults.CONFIG.oscillationSpamCooldown
    end
    if not Helpers.isFiniteNumber(fallbackCooldown) or fallbackCooldown < 0 then
        fallbackCooldown = 0
    end

    local fallbackLookahead = config.oscillationMaxLookahead
    if fallbackLookahead == nil then
        fallbackLookahead = Defaults.CONFIG.oscillationMaxLookahead
    end
    if not Helpers.isFiniteNumber(fallbackLookahead) or fallbackLookahead <= 0 then
        fallbackLookahead = math.huge
    end

    local predictedImpact = decision and decision.predictedImpact or math.huge
    if not Helpers.isFiniteNumber(predictedImpact) or predictedImpact < 0 then
        predictedImpact = math.huge
    end
    local dynamicLookahead = fallbackLookahead
    if Helpers.isFiniteNumber(predictedImpact) then
        dynamicLookahead = fallbackLookahead + SPAM_LOOKAHEAD_BONUS * math.clamp(
            math.max(fallbackLookahead - math.max(predictedImpact - activationLatencyEstimate, 0), 0)
                / math.max(fallbackLookahead, Constants.EPSILON),
            0,
            1
        )
    end

    if predictedImpact > dynamicLookahead then
        return false
    end

    local detectionGate = true
    if decision and decision.targetingMe then
        local detectionAge = decision.detectionAge
        if not Helpers.isFiniteNumber(detectionAge) and telemetry.targetDetectedAt then
            detectionAge = math.max(now - telemetry.targetDetectedAt, 0)
        end
        local minDetectionTime = decision and decision.minDetectionTime or 0
        if detectionAge then
            detectionGate = detectionAge >= minDetectionTime
        else
            detectionGate = minDetectionTime <= 0
        end
    end
    if not detectionGate then
        return false
    end

    local closeness = 0
    if Helpers.isFiniteNumber(predictedImpact) then
        local windowBase = config.oscillationSpamBurstWindow or Defaults.CONFIG.oscillationSpamBurstWindow
        if not Helpers.isFiniteNumber(windowBase) or windowBase <= 0 then
            windowBase = Defaults.CONFIG.oscillationSpamBurstWindow
        end
        local denominator = math.max(windowBase, dynamicLookahead, Constants.EPSILON)
        local remaining = math.max(predictedImpact - activationLatencyEstimate, 0)
        closeness = math.clamp(1 - remaining / denominator, 0, 1)
    end

    if telemetry then
        telemetry.lastOscillationTightness = closeness
    end

    local lastApplied = telemetry.lastOscillationApplied or 0

    local tightnessGain = config.oscillationSpamCooldownTightnessGain
    if tightnessGain == nil then
        tightnessGain = Defaults.CONFIG.oscillationSpamCooldownTightnessGain
    end
    if not Helpers.isFiniteNumber(tightnessGain) or tightnessGain < 0 then
        tightnessGain = Defaults.CONFIG.oscillationSpamCooldownTightnessGain
    end
    tightnessGain = math.clamp(tightnessGain, 0, 1)

    local panicScale = config.oscillationSpamCooldownPanicScale
    if panicScale == nil then
        panicScale = Defaults.CONFIG.oscillationSpamCooldownPanicScale
    end
    if not Helpers.isFiniteNumber(panicScale) or panicScale <= 0 then
        panicScale = 1
    else
        panicScale = math.clamp(panicScale, 0.05, 1)
    end

    local minSpacing = fallbackCooldown
    if not Helpers.isFiniteNumber(minSpacing) or minSpacing <= 0 then
        minSpacing = Defaults.CONFIG.oscillationSpamCooldown
    end

    local tightnessFactor = 1 - tightnessGain * closeness
    if tightnessFactor < 0.15 then
        tightnessFactor = 0.15
    end
    minSpacing = minSpacing * tightnessFactor

    if telemetry and telemetry.lastOscillationBurst and telemetry.lastOscillationBurst.panic then
        minSpacing = minSpacing * panicScale
    end

    minSpacing = math.max(minSpacing, SPAM_MIN_GAP)
    if now - lastApplied < minSpacing then
        return false
    end

    return true
end

function Helpers.updateTargetingAggressionMemory(
    telemetry,
    decision,
    kinematics,
    configSnapshot,
    now
)
    if not telemetry or not decision then
        return
    end

    now = now or os.clock()

    local aggression = telemetry.targetingAggression or 0
    local momentum = telemetry.targetingMomentum or 0
    local lastUpdate = telemetry.targetingAggressionUpdatedAt
    if Helpers.isFiniteNumber(lastUpdate) then
        local dt = math.max(now - lastUpdate, 0)
        if dt > 0 then
            if TARGETING_MEMORY_HALF_LIFE > 0 then
                local decay = 0.5 ^ (dt / TARGETING_MEMORY_HALF_LIFE)
                aggression *= decay
            else
                aggression = 0
            end
            if TARGETING_MOMENTUM_HALF_LIFE > 0 then
                local momentumDecay = 0.5 ^ (dt / TARGETING_MOMENTUM_HALF_LIFE)
                momentum *= momentumDecay
            else
                momentum = 0
            end
        end
    end
    telemetry.targetingAggressionUpdatedAt = now

    local speedUrgency = telemetry.targetingSpeedUrgency or 0
    local lastSpeedUpdate = telemetry.targetingSpeedUpdatedAt
    if Helpers.isFiniteNumber(lastSpeedUpdate) then
        local dt = math.max(now - lastSpeedUpdate, 0)
        if dt > 0 and TARGETING_MOMENTUM_HALF_LIFE > 0 then
            local decay = 0.5 ^ (dt / TARGETING_MOMENTUM_HALF_LIFE)
            speedUrgency *= decay
        end
    end

    local configSource = configSnapshot or config or Defaults.CONFIG

    local lastDrop = telemetry.lastTargetingDrop
    local recentDrop = false
    if Helpers.isFiniteNumber(lastDrop) then
        local elapsed = now - lastDrop
        if Helpers.isFiniteNumber(elapsed) and elapsed >= 0 and elapsed <= TARGETING_MEMORY_RETARGET_WINDOW then
            local weight = (TARGETING_MEMORY_RETARGET_WINDOW - elapsed) / TARGETING_MEMORY_RETARGET_WINDOW
            momentum += weight * 0.65
            if weight > 0 then
                recentDrop = true
            end
        end
    end

    local lastPress = telemetry.lastPressAt
    if Helpers.isFiniteNumber(lastPress) then
        local elapsed = now - lastPress
        if Helpers.isFiniteNumber(elapsed) and elapsed >= 0 and elapsed <= TARGETING_MEMORY_RECENT_PRESS then
            local weight = (TARGETING_MEMORY_RECENT_PRESS - elapsed) / TARGETING_MEMORY_RECENT_PRESS
            aggression += weight * 1.15
            momentum += weight * 0.85
        end
    end

    local burstCount = telemetry.targetingBurstCount or 0
    if not Helpers.isFiniteNumber(burstCount) or burstCount < 0 then
        burstCount = 0
    else
        burstCount = math.floor(burstCount + 0.5)
    end

    if decision.targetingMe then
        local pulseIntensity = 1

        local lastPulse = telemetry.lastTargetingPulse
        local newPulse = false
        if Helpers.isFiniteNumber(lastPulse) then
            local interval = now - lastPulse
            if Helpers.isFiniteNumber(interval) and interval >= 0 then
                local intervalGain = math.clamp(
                    (TARGETING_PRESSURE_INTERVAL_THRESHOLD - interval) / TARGETING_PRESSURE_INTERVAL_THRESHOLD,
                    0,
                    1.1
                )
                pulseIntensity += intervalGain * 0.9
            end

            local pulseStamp = telemetry.targetingAggressionPulseStamp
            if not Helpers.isFiniteNumber(pulseStamp) or lastPulse > pulseStamp then
                newPulse = true
                telemetry.targetingAggressionPulseStamp = lastPulse
            end
        end

        if Helpers.isFiniteNumber(telemetry.targetingBurstRate) and telemetry.targetingBurstRate > 0 then
            local rateExcess = telemetry.targetingBurstRate - TARGETING_PRESSURE_RATE_THRESHOLD
            if rateExcess > 0 then
                pulseIntensity += math.min(rateExcess / TARGETING_PRESSURE_RATE_THRESHOLD, 1.2) * 0.6
            end
        end

        local velocityMagnitude = kinematics and kinematics.velocityMagnitude
        if not Helpers.isFiniteNumber(velocityMagnitude) then
            local relativeFiltered = decision.relativeFilteredVr or 0
            local relativeRaw = decision.relativeRawVr or 0
            velocityMagnitude = math.max(relativeFiltered, relativeRaw, 0)
        end

        local minSpeed = Defaults.CONFIG.minSpeed
        if configSource and configSource.minSpeed then
            minSpeed = configSource.minSpeed
        end
        local speedDelta = (velocityMagnitude or 0) - (minSpeed or 0)
        if Helpers.isFiniteNumber(speedDelta) and speedDelta > 0 then
            local speedGain = math.clamp(speedDelta / math.max(TARGETING_MEMORY_SPEED_DELTA, 1), 0, 2)
            pulseIntensity += speedGain * 0.85
            momentum += speedGain * 0.6
            speedUrgency = math.max(speedUrgency, speedGain)
        end

        local predictedImpact = decision.predictedImpact
        if not Helpers.isFiniteNumber(predictedImpact) or predictedImpact < 0 then
            predictedImpact = decision.timeToImpact
        end
        if not Helpers.isFiniteNumber(predictedImpact) or predictedImpact < 0 then
            predictedImpact = decision.timeToImpactFallback
        end
        if Helpers.isFiniteNumber(predictedImpact) and predictedImpact >= 0 then
            local urgency = math.clamp(
                (TARGETING_MEMORY_IMPACT_WINDOW - math.min(predictedImpact, TARGETING_MEMORY_IMPACT_WINDOW))
                    / math.max(TARGETING_MEMORY_IMPACT_WINDOW, Constants.EPSILON),
                0,
                1.5
            )
            if urgency > 0 then
                pulseIntensity += urgency
                momentum += urgency * 0.8
            end
        end

        local shouldIntegrate = newPulse or recentDrop or burstCount >= 2
        if not shouldIntegrate then
            local lastPress = telemetry.lastPressAt
            if Helpers.isFiniteNumber(lastPress) then
                local elapsed = now - lastPress
                if Helpers.isFiniteNumber(elapsed) and elapsed >= 0 and elapsed <= TARGETING_MEMORY_RECENT_PRESS then
                    shouldIntegrate = true
                end
            end
        end

        if not shouldIntegrate then
            local pressGap = telemetry.lastPressGap
            if Helpers.isFiniteNumber(pressGap) and pressGap <= TARGETING_PRESSURE_GAP_THRESHOLD then
                shouldIntegrate = true
            end
        end

        if shouldIntegrate then
            aggression += pulseIntensity
            momentum += pulseIntensity * 0.45
            telemetry.targetingLastAggressionSpike = now
        end
    end

    if aggression < 0 then
        aggression = 0
    end
    if momentum < 0 then
        momentum = 0
    end
    if speedUrgency < 0 then
        speedUrgency = 0
    end

    aggression = math.min(aggression, 12)
    momentum = math.min(momentum, 12)
    speedUrgency = math.min(speedUrgency, 4)

    telemetry.targetingAggression = aggression
    telemetry.targetingMomentum = momentum
    telemetry.targetingSpeedUrgency = speedUrgency
    telemetry.targetingSpeedUpdatedAt = now
end

function Helpers.evaluateTargetingSpam(decision, telemetry, now, config, kinematics, ballId)
    if not telemetry or not decision or decision.targetingMe ~= true then
        return nil
    end

    if Context.runtime.virtualInputUnavailable and Context.runtime.virtualInputRetryAt > now then
        return nil
    end

    if Context.runtime.targetingSpamSuspendedUntil and Context.runtime.targetingSpamSuspendedUntil > now then
        return nil
    end

    local metrics = Helpers.resolveTargetingPressureMetrics(telemetry, now)
    if not metrics then
        return nil
    end

    local pulseCount = metrics.pulses or 0
    local rate = metrics.rate or 0
    local minInterval = metrics.minInterval
    local lastInterval = metrics.lastInterval
    local targetingFreshness = metrics.freshness or math.huge
    local sinceDrop = metrics.sinceDrop or math.huge
    local sincePress = metrics.sincePress or math.huge
    local pressGap = metrics.pressGap or math.huge
    local pressRate = metrics.pressRate or 0
    local targetingPressure = metrics.pressure or 0
    local memory = metrics.memory or 0
    local aggression = metrics.aggression or 0
    local momentum = metrics.momentum or 0
    local sinceAggression = metrics.sinceAggression or math.huge
    local speedUrgency = metrics.speedUrgency or 0

    local timeToImpact = decision.timeToImpact or decision.predictedImpact or math.huge
    if not Helpers.isFiniteNumber(timeToImpact) or timeToImpact < 0 then
        timeToImpact = math.huge
    end

    local minSpeed = config.minSpeed or Defaults.CONFIG.minSpeed or 0
    local velocityMagnitude = kinematics and kinematics.velocityMagnitude or 0
    if not Helpers.isFiniteNumber(velocityMagnitude) or velocityMagnitude < 0 then
        velocityMagnitude = 0
    end

    local fastBall = velocityMagnitude >= minSpeed + TARGETING_PRESSURE_SPEED_DELTA or speedUrgency >= 0.75
    local freshTarget = targetingFreshness <= TARGETING_PRESSURE_PRESS_WINDOW
    local recentDrop = sinceDrop <= TARGETING_PRESSURE_PRESS_WINDOW * 0.75
    local freshRetarget = recentDrop
    if not freshRetarget and pulseCount >= 2 then
        freshRetarget = freshTarget
    end

    local pressPressure = sincePress <= TARGETING_PRESSURE_PRESS_WINDOW
        or pressGap <= TARGETING_PRESSURE_GAP_THRESHOLD
        or pressRate >= TARGETING_PRESSURE_RATE_THRESHOLD * 0.9

    local urgentImpact = timeToImpact <= TARGETING_PRESSURE_PRESS_WINDOW * 1.6

    local interval = minInterval or lastInterval
    local intervalPressure = 0
    if interval ~= nil then
        intervalPressure = math.clamp(
            (TARGETING_PRESSURE_INTERVAL_THRESHOLD - interval) / TARGETING_PRESSURE_INTERVAL_THRESHOLD,
            0,
            1.4
        )
    end
    local rapidRetarget = rate >= TARGETING_PRESSURE_RATE_THRESHOLD
        or (interval ~= nil and interval <= TARGETING_PRESSURE_INTERVAL_THRESHOLD)
        or (recentDrop and freshTarget)
        or targetingPressure >= 0.6

    local memoryPressure = memory >= TARGETING_PRESSURE_MEMORY_THRESHOLD
        or momentum >= TARGETING_PRESSURE_MOMENTUM_THRESHOLD
        or (sinceAggression <= TARGETING_PRESSURE_PRESS_WINDOW * 1.4 and aggression >= TARGETING_PRESSURE_MEMORY_THRESHOLD * 0.6)

    local memoryReady = memoryPressure and (recentDrop or pressPressure or pulseCount >= 2)

    local gapPressure = 0
    if pressGap <= TARGETING_PRESSURE_GAP_THRESHOLD then
        gapPressure = math.clamp(
            (TARGETING_PRESSURE_GAP_THRESHOLD - pressGap) / TARGETING_PRESSURE_GAP_THRESHOLD,
            0,
            1.2
        )
    end

    local demand = 0
    demand += math.clamp(targetingPressure, 0, 3) * 0.45
    demand += math.clamp(memory, 0, 4) * 0.25
    demand += math.clamp(momentum, 0, 4) * 0.2
    demand += math.clamp(speedUrgency, 0, 4) * 0.35
    if rapidRetarget then
        demand += 1.1
    end
    if pressPressure then
        demand += 0.95
    end
    if memoryReady then
        demand += 0.7
    end
    if urgentImpact then
        demand += 0.85
    end
    if fastBall then
        demand += 0.6
    end
    demand += intervalPressure * 0.85
    demand += gapPressure * 0.65
    if sincePress <= TARGETING_PRESSURE_PRESS_WINDOW * 0.6 then
        demand += 0.5
    end
    if pulseCount >= 3 then
        demand += 0.4 + math.min((pulseCount - 3) * 0.12, 1.2)
    end
    if rate >= TARGETING_PRESSURE_RATE_THRESHOLD * 1.25 then
        demand += math.min((rate / TARGETING_PRESSURE_RATE_THRESHOLD - 1.25) * 0.7, 1.4)
    end
    if pressRate >= TARGETING_PRESSURE_RATE_THRESHOLD then
        demand += math.min((pressRate / TARGETING_PRESSURE_RATE_THRESHOLD - 1) * 0.6, 1.2)
    end
    if demand < 0 then
        demand = 0
    elseif demand > 12 then
        demand = 12
    end

    if pulseCount < 2 and not (memoryReady or pressPressure or recentDrop) then
        return nil
    end

    local burstState = Context.runtime.spamBurst
    if burstState and burstState.active and burstState.ballId == ballId then
        if burstState.reason == "retarget" and now - (burstState.startedAt or 0) < TARGETING_PRESSURE_REARM then
            return nil
        end
    end

    local lastTrigger = telemetry.lastTargetingSpam
    if Helpers.isFiniteNumber(lastTrigger) and now - lastTrigger < TARGETING_PRESSURE_REARM then
        return nil
    end

    if not (rapidRetarget or freshRetarget or pressPressure or memoryReady) then
        return nil
    end

    telemetry.lastTargetingSpam = now

    telemetry.targetingDemand = demand
    telemetry.targetingDemandUpdatedAt = now

    local shouldForce = false
    if Context.runtime.parryHeld and Context.runtime.parryHeldBallId == ballId then
        shouldForce = pressPressure or urgentImpact or freshRetarget or memoryPressure
    end

    local lookaheadBoost = TARGETING_PRESSURE_LOOKAHEAD_BOOST + math.clamp(speedUrgency * 0.08, 0, 0.12)

    local hyperDemand = demand >= 2.4
        or (interval ~= nil and interval <= TARGETING_PRESSURE_INTERVAL_THRESHOLD * 0.3)
        or pressRate >= TARGETING_PRESSURE_RATE_THRESHOLD * 1.6
        or rate >= TARGETING_PRESSURE_RATE_THRESHOLD * 1.45
        or urgentImpact
        or gapPressure >= 0.9
    if hyperDemand then
        telemetry.targetingHyperActive = now
    end

    return {
        triggered = true,
        reason = "retarget",
        startBurst = true,
        forcePress = shouldForce,
        panic = pressPressure or urgentImpact or fastBall or memoryReady,
        lookaheadBoost = lookaheadBoost,
        rate = rate,
        interval = interval,
        pulses = pulseCount,
        fresh = freshRetarget,
        memory = memory,
        aggression = aggression,
        momentum = momentum,
        speedUrgency = speedUrgency,
        pressure = targetingPressure,
        demand = demand,
        hyper = hyperDemand,
        pressRate = pressRate,
        minInterval = minInterval,
        lastInterval = lastInterval,
        timeToImpact = timeToImpact,
        velocity = velocityMagnitude,
        freshness = targetingFreshness,
        sincePress = sincePress,
        sinceDrop = sinceDrop,
    }
end

function Helpers.resolveTargetingPressureMetrics(telemetry, now)
    if not telemetry then
        return nil
    end

    now = now or os.clock()

    local pulses = telemetry.targetingBurstCount or 0
    if not Helpers.isFiniteNumber(pulses) or pulses < 0 then
        pulses = 0
    else
        pulses = math.floor(pulses + 0.5)
    end

    local rate = telemetry.targetingBurstRate or 0
    if not Helpers.isFiniteNumber(rate) or rate < 0 then
        rate = 0
    end

    local minInterval = telemetry.targetingMinInterval
    if not Helpers.isFiniteNumber(minInterval) or minInterval < 0 then
        minInterval = nil
    end

    local lastInterval = telemetry.targetingLastInterval
    if not Helpers.isFiniteNumber(lastInterval) or lastInterval < 0 then
        lastInterval = nil
    end

    local lastTarget = telemetry.lastTargetingPulse
    local freshness = math.huge
    if Helpers.isFiniteNumber(lastTarget) then
        freshness = now - lastTarget
        if not Helpers.isFiniteNumber(freshness) then
            freshness = math.huge
        end
    end

    local lastDrop = telemetry.lastTargetingDrop
    local sinceDrop = math.huge
    if Helpers.isFiniteNumber(lastDrop) then
        sinceDrop = now - lastDrop
        if not Helpers.isFiniteNumber(sinceDrop) then
            sinceDrop = math.huge
        end
    end

    local lastPress = telemetry.lastPressAt
    local sincePress = math.huge
    if Helpers.isFiniteNumber(lastPress) then
        sincePress = now - lastPress
        if not Helpers.isFiniteNumber(sincePress) then
            sincePress = math.huge
        end
    end

    local pressGap = telemetry.lastPressGap
    if not Helpers.isFiniteNumber(pressGap) or pressGap < 0 then
        pressGap = math.huge
    end

    local pressRate = telemetry.pressRate or 0
    if not Helpers.isFiniteNumber(pressRate) or pressRate < 0 then
        pressRate = 0
    end

    local targetingPressure = 0
    if pulses > 0 then
        local rateComponent = 0
        if pulses >= 2 and rate > 0 then
            rateComponent = math.clamp(rate / TARGETING_PRESSURE_RATE_THRESHOLD - 0.6, 0, 1.6)
        end

        local intervalComponent = 0
        local interval = minInterval or lastInterval
        if pulses >= 2 and interval ~= nil then
            intervalComponent = math.clamp(
                (TARGETING_PRESSURE_INTERVAL_THRESHOLD - interval) / TARGETING_PRESSURE_INTERVAL_THRESHOLD,
                0,
                1.4
            )
        end

        local freshnessComponent = 0
        if freshness <= TARGETING_PRESSURE_PRESS_WINDOW then
            freshnessComponent = math.clamp(
                (TARGETING_PRESSURE_PRESS_WINDOW - freshness) / TARGETING_PRESSURE_PRESS_WINDOW,
                0,
                1
            )
        end

        local pressComponent = 0
        if sincePress <= TARGETING_PRESSURE_PRESS_WINDOW then
            pressComponent = math.clamp(
                (TARGETING_PRESSURE_PRESS_WINDOW - sincePress) / TARGETING_PRESSURE_PRESS_WINDOW,
                0,
                1
            )
        elseif pressGap <= TARGETING_PRESSURE_GAP_THRESHOLD then
            pressComponent = math.clamp(
                (TARGETING_PRESSURE_GAP_THRESHOLD - pressGap) / TARGETING_PRESSURE_GAP_THRESHOLD,
                0,
                1
            )
        end

        local dropComponent = 0
        if sinceDrop <= TARGETING_PRESSURE_PRESS_WINDOW then
            dropComponent = math.clamp(
                (TARGETING_PRESSURE_PRESS_WINDOW - sinceDrop) / TARGETING_PRESSURE_PRESS_WINDOW,
                0,
                1
            )
        end

        targetingPressure = math.min(rateComponent + intervalComponent + freshnessComponent + pressComponent + dropComponent, 3)
    end

    local aggression = telemetry.targetingAggression or 0
    if not Helpers.isFiniteNumber(aggression) or aggression < 0 then
        aggression = 0
    end

    local momentum = telemetry.targetingMomentum or 0
    if not Helpers.isFiniteNumber(momentum) or momentum < 0 then
        momentum = 0
    end

    local speedUrgency = telemetry.targetingSpeedUrgency or 0
    if not Helpers.isFiniteNumber(speedUrgency) or speedUrgency < 0 then
        speedUrgency = 0
    end

    local lastAggressionSpike = telemetry.targetingLastAggressionSpike
    local sinceAggression = math.huge
    if Helpers.isFiniteNumber(lastAggressionSpike) then
        sinceAggression = now - lastAggressionSpike
        if not Helpers.isFiniteNumber(sinceAggression) then
            sinceAggression = math.huge
        end
    end

    local memory = (aggression + 0.6 * momentum) * TARGETING_MEMORY_SCALE

    return {
        pulses = pulses,
        rate = rate,
        minInterval = minInterval,
        lastInterval = lastInterval,
        freshness = freshness,
        sincePress = sincePress,
        pressGap = pressGap,
        pressRate = pressRate,
        sinceDrop = sinceDrop,
        pressure = targetingPressure,
        aggression = aggression,
        momentum = momentum,
        memory = memory,
        sinceAggression = sinceAggression,
        speedUrgency = speedUrgency,
    }
end

local function resolveOscillationSpamSettings()
    local presses = config.oscillationSpamBurstPresses
    if presses == nil then
        presses = Defaults.CONFIG.oscillationSpamBurstPresses
    end
    if not Helpers.isFiniteNumber(presses) then
        presses = 0
    end
    presses = math.max(math.floor(presses + 0.5), 0)

    local gap = config.oscillationSpamBurstGap
    if gap == nil then
        gap = Defaults.CONFIG.oscillationSpamBurstGap
    end
    if not Helpers.isFiniteNumber(gap) or gap <= 0 then
        gap = 1 / 30
    else
        gap = math.max(gap, 1 / 120)
    end

    local window = config.oscillationSpamBurstWindow
    if window == nil then
        window = Defaults.CONFIG.oscillationSpamBurstWindow
    end
    if not Helpers.isFiniteNumber(window) or window <= 0 then
        window = gap * math.max(presses, 1) * 2
    end
    window = math.max(window, gap * math.max(presses, 1))

    local lookahead = config.oscillationSpamBurstLookahead
    if lookahead == nil then
        lookahead = config.oscillationMaxLookahead or Defaults.CONFIG.oscillationSpamBurstLookahead
    end
    if not Helpers.isFiniteNumber(lookahead) or lookahead <= 0 then
        lookahead = Defaults.CONFIG.oscillationSpamBurstLookahead
    end

    local minGap = config.oscillationSpamMinGap
    if minGap == nil then
        minGap = Defaults.CONFIG.oscillationSpamMinGap or SPAM_MIN_GAP
    end
    if not Helpers.isFiniteNumber(minGap) or minGap <= 0 then
        minGap = SPAM_MIN_GAP
    end
    minGap = math.max(minGap, SPAM_MIN_GAP)

    local panicTightness = config.oscillationSpamPanicTightness
    if panicTightness == nil then
        panicTightness = Defaults.CONFIG.oscillationSpamPanicTightness
    end
    if not Helpers.isFiniteNumber(panicTightness) then
        panicTightness = Defaults.CONFIG.oscillationSpamPanicTightness
    end
    panicTightness = math.clamp(panicTightness, 0, 1)

    local panicGapScale = config.oscillationSpamPanicGapScale
    if panicGapScale == nil then
        panicGapScale = Defaults.CONFIG.oscillationSpamPanicGapScale
    end
    if not Helpers.isFiniteNumber(panicGapScale) or panicGapScale <= 0 then
        panicGapScale = Defaults.CONFIG.oscillationSpamPanicGapScale
    end
    panicGapScale = math.clamp(panicGapScale, 0.05, 1)

    local panicWindowScale = config.oscillationSpamPanicWindowScale
    if panicWindowScale == nil then
        panicWindowScale = Defaults.CONFIG.oscillationSpamPanicWindowScale
    end
    if not Helpers.isFiniteNumber(panicWindowScale) or panicWindowScale <= 0 then
        panicWindowScale = Defaults.CONFIG.oscillationSpamPanicWindowScale
    end
    panicWindowScale = math.max(panicWindowScale, 1)

    local panicLookaheadBoost = config.oscillationSpamPanicLookaheadBoost
    if panicLookaheadBoost == nil then
        panicLookaheadBoost = Defaults.CONFIG.oscillationSpamPanicLookaheadBoost
    end
    if not Helpers.isFiniteNumber(panicLookaheadBoost) or panicLookaheadBoost < 0 then
        panicLookaheadBoost = Defaults.CONFIG.oscillationSpamPanicLookaheadBoost
    end
    if panicLookaheadBoost < 0 then
        panicLookaheadBoost = 0
    end

    local panicSpeedDelta = config.oscillationSpamPanicSpeedDelta
    if panicSpeedDelta == nil then
        panicSpeedDelta = Defaults.CONFIG.oscillationSpamPanicSpeedDelta
    end
    if not Helpers.isFiniteNumber(panicSpeedDelta) or panicSpeedDelta < 0 then
        panicSpeedDelta = Defaults.CONFIG.oscillationSpamPanicSpeedDelta
    end
    if panicSpeedDelta < 0 then
        panicSpeedDelta = 0
    end

    local panicSlack = config.oscillationSpamPanicSlack
    if panicSlack == nil then
        panicSlack = Defaults.CONFIG.oscillationSpamPanicSlack
    end
    if not Helpers.isFiniteNumber(panicSlack) or panicSlack < 0 then
        panicSlack = Defaults.CONFIG.oscillationSpamPanicSlack
    end
    if panicSlack < 0 then
        panicSlack = 0
    end

    local recoverySeconds = config.oscillationSpamRecoverySeconds
    if recoverySeconds == nil then
        recoverySeconds = Defaults.CONFIG.oscillationSpamRecoverySeconds
    end
    if not Helpers.isFiniteNumber(recoverySeconds) or recoverySeconds < 0 then
        recoverySeconds = Defaults.CONFIG.oscillationSpamRecoverySeconds
    end
    if recoverySeconds < 0 then
        recoverySeconds = 0
    end

    return {
        presses = presses,
        gap = gap,
        window = window,
        lookahead = lookahead,
        minGap = minGap,
        panicTightness = panicTightness,
        panicGapScale = panicGapScale,
        panicWindowScale = panicWindowScale,
        panicLookaheadBoost = panicLookaheadBoost,
        panicSpeedDelta = panicSpeedDelta,
        panicSlack = panicSlack,
        recoverySeconds = recoverySeconds,
    }
end

function Helpers.computeSpamBurstTuning(
    settings: { presses: number, gap: number, window: number, lookahead: number },
    decision: { [string]: any }?,
    kinematics: BallKinematics.Kinematics?,
    fallbackDecision: { [string]: any }?,
    telemetrySummary: { [string]: any }?,
    telemetry: TelemetryState?,
    now: number?,
    mode: string?,
    options: { [string]: any }?
)
    local presses = math.max(settings.presses or 0, 0)
    local baseGap = settings.gap or Defaults.CONFIG.oscillationSpamBurstGap
    local baseWindow = settings.window or Defaults.CONFIG.oscillationSpamBurstWindow
    local baseLookahead = settings.lookahead or Defaults.CONFIG.oscillationSpamBurstLookahead

    local minGap = math.max(settings.minGap or SPAM_MIN_GAP, SPAM_MIN_GAP)
    local demandScore = 0
    local hyperDemand = false
    local optionPressRate = 0
    local optionRate = 0
    local optionInterval = nil
    local optionTimeToImpact = nil
    local optionFreshness = nil
    local optionSincePress = nil
    local optionSinceDrop = nil
    local rateOverdrive = 0

    if typeof(options) == "table" then
        local memory = 0
        if Helpers.isFiniteNumber(options.memory) and options.memory > 0 then
            memory = options.memory
        elseif Helpers.isFiniteNumber(options.aggression) and options.aggression > 0 then
            memory = options.aggression
        end

        local optionMomentum = 0
        if Helpers.isFiniteNumber(options.momentum) and options.momentum > 0 then
            optionMomentum = options.momentum
        end

        local optionSpeed = 0
        if Helpers.isFiniteNumber(options.speedUrgency) and options.speedUrgency > 0 then
            optionSpeed = options.speedUrgency
        end

        if Helpers.isFiniteNumber(options.demand) and options.demand > 0 then
            demandScore = math.clamp(options.demand, 0, 12)
        end
        if options.hyper == true then
            hyperDemand = true
        end
        if Helpers.isFiniteNumber(options.pressRate) and options.pressRate > 0 then
            optionPressRate = options.pressRate
        end
        if Helpers.isFiniteNumber(options.rate) and options.rate > 0 then
            optionRate = options.rate
        end
        if Helpers.isFiniteNumber(options.interval) and options.interval > 0 then
            optionInterval = options.interval
        elseif Helpers.isFiniteNumber(options.minInterval) and options.minInterval > 0 then
            optionInterval = options.minInterval
        elseif Helpers.isFiniteNumber(options.lastInterval) and options.lastInterval > 0 then
            optionInterval = options.lastInterval
        end
        if Helpers.isFiniteNumber(options.timeToImpact) and options.timeToImpact >= 0 then
            optionTimeToImpact = options.timeToImpact
        end
        if Helpers.isFiniteNumber(options.freshness) and options.freshness >= 0 then
            optionFreshness = options.freshness
        end
        if Helpers.isFiniteNumber(options.sincePress) and options.sincePress >= 0 then
            optionSincePress = options.sincePress
        end
        if Helpers.isFiniteNumber(options.sinceDrop) and options.sinceDrop >= 0 then
            optionSinceDrop = options.sinceDrop
        end

        local spamDemand = math.min(memory + 0.65 * optionMomentum + 0.9 * optionSpeed, 6)
        if optionRate > 0 then
            rateOverdrive = math.max(rateOverdrive, optionRate / TARGETING_PRESSURE_RATE_THRESHOLD - 1)
        end
        if optionPressRate > 0 then
            rateOverdrive = math.max(rateOverdrive, optionPressRate / TARGETING_PRESSURE_RATE_THRESHOLD - 1)
        end
        if rateOverdrive < 0 then
            rateOverdrive = 0
        end
        rateOverdrive = math.clamp(rateOverdrive, 0, 2.5)

        local combinedDemand = math.min(spamDemand + demandScore, 12)
        if combinedDemand > 0 then
            local extraPresses = math.clamp(memory * 0.6 + optionMomentum * 0.45 + optionSpeed * 0.5, 0, 4.5)
            local demandExtra = math.clamp(demandScore * 1.05 + rateOverdrive * 1.8, 0, 6)
            presses = math.max(presses, math.floor(presses + extraPresses + demandExtra + 0.5))

            local tighten = math.clamp(combinedDemand * 0.22 + rateOverdrive * 0.18, 0, 0.88)
            minGap = math.max(minGap * (1 - tighten * 0.55), SPAM_MIN_GAP)
            baseGap = math.max(baseGap * (1 - tighten), minGap)

            local windowScale = 1 + math.clamp(combinedDemand * 0.14 + rateOverdrive * 0.35, 0, 2.5)
            baseWindow = math.max(baseWindow, baseGap * math.max(presses, 1) * windowScale)

            local lookaheadFloor = baseGap * math.max(presses, 1) + activationLatencyEstimate
            if optionTimeToImpact and Helpers.isFiniteNumber(optionTimeToImpact) then
                lookaheadFloor = math.max(lookaheadFloor, optionTimeToImpact + activationLatencyEstimate * 0.35)
            end
            baseLookahead = math.max(baseLookahead, lookaheadFloor)
        elseif demandScore > 0 then
            local lookaheadFloor = baseGap * math.max(presses, 1) + activationLatencyEstimate
            baseLookahead = math.max(baseLookahead, lookaheadFloor)
        end

        if optionInterval ~= nil then
            local intervalBoost = math.clamp(
                (TARGETING_PRESSURE_INTERVAL_THRESHOLD - optionInterval) / TARGETING_PRESSURE_INTERVAL_THRESHOLD,
                0,
                1.6
            )
            if intervalBoost > 0 then
                local tighten = math.clamp(intervalBoost * 0.45, 0, 0.9)
                minGap = math.max(minGap * (1 - tighten * 0.5), SPAM_MIN_GAP)
                baseGap = math.max(baseGap * (1 - tighten * 0.6), minGap)
            end
        end

        local pulseCountOption = 0
        if Helpers.isFiniteNumber(options.pulses) and options.pulses > 0 then
            pulseCountOption = options.pulses
        end
        if pulseCountOption < 2 then
            presses = 1
        end
    end

    local panicTightness = math.clamp(settings.panicTightness or Defaults.CONFIG.oscillationSpamPanicTightness, 0, 1)
    local panicGapScale = math.clamp(settings.panicGapScale or Defaults.CONFIG.oscillationSpamPanicGapScale, 0.05, 1)
    local panicWindowScale = math.max(settings.panicWindowScale or Defaults.CONFIG.oscillationSpamPanicWindowScale, 1)
    local panicLookaheadBoost = math.max(settings.panicLookaheadBoost or Defaults.CONFIG.oscillationSpamPanicLookaheadBoost, 0)
    local panicSpeedDelta = math.max(settings.panicSpeedDelta or Defaults.CONFIG.oscillationSpamPanicSpeedDelta, 0)
    local panicSlack = math.max(settings.panicSlack or Defaults.CONFIG.oscillationSpamPanicSlack, 0)
    local recoverySeconds = math.max(settings.recoverySeconds or Defaults.CONFIG.oscillationSpamRecoverySeconds, 0)

    telemetrySummary = telemetrySummary or Context.runtime.telemetrySummary
    telemetry = telemetry or nil
    now = now or os.clock()
    mode = mode or "oscillation"
    if options == nil then
        options = {}
    end
    local commitTarget, lookaheadGoalTarget, reactionGoalTarget = Helpers.resolvePerformanceTargets()

    local statsAggression = 0
    local statsSamples = 0
    local statsWaitDelta
    local statsLeadDelta
    local statsCommitPressure
    local statsAverageLatency
    local statsCancellationRate
    local statsImmediateRate
    local statsSpeedPressure
    local statsLookaheadPressure
    local statsTempoPressure
    local statsVolatilityPressure
    local statsAverageReactionTime
    local statsReactionStdDev
    local statsReactionPressure
    local statsAverageDecisionToPress
    local statsDecisionStdDev
    local statsDecisionToPressStdDev
    local statsDecisionPressure
    local statsSuccessRate
    local statsMissPressure
    local statsPressMissCount
    local summaryPressCount = 0
    local statsReactionFocus
    local statsCognitiveLoad
    local statsNeuroTempo
    local statsTargetingPressure
    local statsTargetingRate
    local statsTargetingInterval
    local statsTargetingSincePress
    local statsTargetingAggression
    local statsTargetingMomentum
    local statsTargetingSpeedUrgency

    local targetingPressure = 0
    local targetingRate
    local targetingInterval
    local targetingSincePress = math.huge
    local targetingFreshness = math.huge
    local targetingPressGap = math.huge
    local targetingPressRate = 0
    local targetingSinceDrop = math.huge

    local function accumulateAggression(value, scale, clampLimit)
        if not Helpers.isFiniteNumber(value) then
            return
        end
        if not Helpers.isFiniteNumber(scale) or scale <= 0 then
            return
        end

        local normalized = value / scale
        if clampLimit then
            normalized = math.clamp(normalized, -clampLimit, clampLimit)
        else
            normalized = math.clamp(normalized, -3, 3)
        end

        statsAggression += normalized
        statsSamples += 1
    end

    if telemetry then
        local metrics = Helpers.resolveTargetingPressureMetrics(telemetry, now)
        if metrics then
            targetingPressure = metrics.pressure or 0
            targetingRate = metrics.rate or 0
            targetingInterval = metrics.minInterval
            if targetingInterval == nil then
                targetingInterval = metrics.lastInterval
            end
            targetingFreshness = metrics.freshness or math.huge
            targetingSincePress = metrics.sincePress or math.huge
            targetingPressGap = metrics.pressGap or math.huge
            targetingPressRate = metrics.pressRate or 0
            targetingSinceDrop = metrics.sinceDrop or math.huge
            statsTargetingAggression = metrics.memory or metrics.aggression or statsTargetingAggression
            statsTargetingMomentum = metrics.momentum or statsTargetingMomentum
            statsTargetingSpeedUrgency = metrics.speedUrgency or statsTargetingSpeedUrgency
        end
    end

    if targetingPressure > 0 then
        statsTargetingPressure = targetingPressure
        statsTargetingRate = targetingRate
        statsTargetingInterval = targetingInterval
        statsTargetingSincePress = targetingSincePress
        accumulateAggression(targetingPressure, 0.6, 2.4)
        if statsTargetingAggression and Helpers.isFiniteNumber(statsTargetingAggression) then
            accumulateAggression(statsTargetingAggression, 1.2, 2)
        end
        if statsTargetingMomentum and Helpers.isFiniteNumber(statsTargetingMomentum) then
            accumulateAggression(statsTargetingMomentum, 1.2, 2)
        end
        if statsTargetingSpeedUrgency and Helpers.isFiniteNumber(statsTargetingSpeedUrgency) then
            accumulateAggression(statsTargetingSpeedUrgency, 1.2, 2)
        end
    end

    local lookaheadBoostExtra = 0
    if typeof(options) == "table" and Helpers.isFiniteNumber(options.lookaheadBoost) then
        lookaheadBoostExtra = math.max(options.lookaheadBoost, 0)
    elseif targetingPressure > 0 then
        lookaheadBoostExtra = TARGETING_PRESSURE_LOOKAHEAD_BOOST * math.clamp(targetingPressure, 0, 1.8)
    end
    if demandScore > 0 then
        lookaheadBoostExtra = math.max(lookaheadBoostExtra, math.min(demandScore * 0.04, 0.18))
    end

    if telemetrySummary then
        local pressCount = telemetrySummary.pressCount or 0
        summaryPressCount = pressCount
        local scheduleCount = telemetrySummary.scheduleCount or pressCount

        if pressCount >= 6 then
            statsWaitDelta = telemetrySummary.averageWaitDelta
            accumulateAggression(statsWaitDelta or 0, 0.0075, 2.4)
        end

        if scheduleCount >= 4 then
            statsLeadDelta = telemetrySummary.leadDeltaMean
            if Helpers.isFiniteNumber(statsLeadDelta) then
                accumulateAggression(-statsLeadDelta, 0.0075, 2)
            end
        end

        local commitSamples = telemetrySummary.commitLatencySampleCount or 0
        if commitSamples >= 4 and Helpers.isFiniteNumber(telemetrySummary.commitLatencyP99) then
            if Helpers.isFiniteNumber(commitTarget) and commitTarget > 0 then
                statsCommitPressure = (telemetrySummary.commitLatencyP99 - commitTarget) / commitTarget
                accumulateAggression(statsCommitPressure, 0.35, 2.5)
            end
        end

        if pressCount >= 6 and Helpers.isFiniteNumber(telemetrySummary.averageLatency) then
            statsAverageLatency = telemetrySummary.averageLatency
            accumulateAggression((statsAverageLatency or 0) - activationLatencyEstimate, 0.02, 1.8)
        end

        if pressCount >= 6 and Helpers.isFiniteNumber(telemetrySummary.averageReactionTime) then
            statsAverageReactionTime = telemetrySummary.averageReactionTime
            local reactionReference = reactionGoalTarget
            if not Helpers.isFiniteNumber(reactionReference) or reactionReference <= 0 then
                reactionReference = activationLatencyEstimate * 0.55
            end
            reactionReference = math.max(reactionReference, SPAM_MIN_GAP * 3, baseGap * 0.7)
            local reactionDelta = (statsAverageReactionTime or 0) - reactionReference
            if Helpers.isFiniteNumber(reactionDelta) then
                statsReactionPressure = reactionDelta / math.max(reactionReference, 0.01)
                accumulateAggression(reactionDelta, math.max(reactionReference * 0.75, 0.01), 2.2)
            end
        end

        if pressCount >= 6 and Helpers.isFiniteNumber(telemetrySummary.reactionStdDev) then
            statsReactionStdDev = telemetrySummary.reactionStdDev
            local spreadTarget = math.max(baseGap * 0.45, SPAM_MIN_GAP * 1.4)
            accumulateAggression(spreadTarget - statsReactionStdDev, math.max(spreadTarget, 0.01), 2.2)
        end

        if pressCount >= 6 and Helpers.isFiniteNumber(telemetrySummary.averageDecisionToPressTime) then
            statsAverageDecisionToPress = telemetrySummary.averageDecisionToPressTime
            local decisionReference = commitTarget
            if not Helpers.isFiniteNumber(decisionReference) or decisionReference <= 0 then
                decisionReference = activationLatencyEstimate * 0.6
            end
            decisionReference = math.max(decisionReference, SPAM_MIN_GAP * 2.5)
            local decisionDelta = (statsAverageDecisionToPress or 0) - decisionReference
            if Helpers.isFiniteNumber(decisionDelta) then
                statsDecisionPressure = decisionDelta / math.max(decisionReference, 0.01)
                accumulateAggression(decisionDelta, math.max(decisionReference * 0.8, 0.01), 2.2)
            end
        end

        if pressCount >= 6 and Helpers.isFiniteNumber(telemetrySummary.decisionStdDev) then
            statsDecisionStdDev = telemetrySummary.decisionStdDev
            local spreadTarget = math.max(baseGap * 0.55, SPAM_MIN_GAP * 1.8)
            accumulateAggression(spreadTarget - statsDecisionStdDev, math.max(spreadTarget, 0.01), 2.2)
        end

        if pressCount >= 6 and Helpers.isFiniteNumber(telemetrySummary.decisionToPressStdDev) then
            statsDecisionToPressStdDev = telemetrySummary.decisionToPressStdDev
            local spreadTarget = math.max(baseGap * 0.5, SPAM_MIN_GAP * 1.6)
            accumulateAggression(spreadTarget - statsDecisionToPressStdDev, math.max(spreadTarget, 0.01), 2.2)
        end

        if pressCount >= 6 and Helpers.isFiniteNumber(telemetrySummary.cancellationCount) then
            statsCancellationRate = telemetrySummary.cancellationCount / math.max(pressCount, 1)
            if statsCancellationRate > 0 then
                accumulateAggression(-statsCancellationRate, 0.18, 2)
            end
        end

        if pressCount >= 6 and Helpers.isFiniteNumber(telemetrySummary.immediateRate) then
            statsImmediateRate = telemetrySummary.immediateRate
            accumulateAggression((statsImmediateRate or 0) - 0.18, 0.12, 1.6)
        end

        if pressCount >= 6 then
            local successRate = telemetrySummary.successRate
            if not Helpers.isFiniteNumber(successRate) then
                local successAccepted = telemetrySummary.successAccepted
                if Helpers.isFiniteNumber(successAccepted) and pressCount > 0 then
                    successRate = successAccepted / pressCount
                end
            end
            if Helpers.isFiniteNumber(successRate) then
                statsSuccessRate = math.clamp(successRate, 0, 1)
                local successDeficit = 0.92 - statsSuccessRate
                if successDeficit ~= 0 then
                    accumulateAggression(successDeficit, 0.18, 2.4)
                end
                statsMissPressure = successDeficit
            end
            if Helpers.isFiniteNumber(telemetrySummary.pressMissCount) then
                statsPressMissCount = telemetrySummary.pressMissCount
            end
        end

        local lookaheadReference = lookaheadGoalTarget
        if not Helpers.isFiniteNumber(lookaheadReference) or lookaheadReference <= 0 then
            lookaheadReference = baseLookahead
        end
        lookaheadReference = math.max(lookaheadReference, activationLatencyEstimate + baseGap * 1.2)

        if scheduleCount >= 4 then
            if Helpers.isFiniteNumber(telemetrySummary.scheduleLookaheadP10) then
                local lookaheadP10 = telemetrySummary.scheduleLookaheadP10
                local deficit = lookaheadReference - lookaheadP10
                if Helpers.isFiniteNumber(deficit) then
                    statsLookaheadPressure = deficit
                    accumulateAggression(deficit, math.max(lookaheadReference, 0.04), 2.2)
                end
            end

            if Helpers.isFiniteNumber(telemetrySummary.scheduleLookaheadMin) then
                local lookaheadMin = telemetrySummary.scheduleLookaheadMin
                local minTarget = math.max(
                    minGap * math.max(presses, 1) + activationLatencyEstimate * 0.5,
                    SPAM_MIN_GAP * 1.2
                )
                local minDeficit = minTarget - lookaheadMin
                if Helpers.isFiniteNumber(minDeficit) and minDeficit > 0 then
                    if statsLookaheadPressure then
                        statsLookaheadPressure += minDeficit * 0.5
                    else
                        statsLookaheadPressure = minDeficit * 0.5
                    end
                    accumulateAggression(minDeficit, math.max(minTarget, 0.02), 2.5)
                end
            end
        end

        local threatCount = telemetrySummary.threatCount or 0
        if threatCount >= 3 and Helpers.isFiniteNumber(telemetrySummary.averageThreatSpeed) then
            local minSpeed = config.minSpeed or Defaults.CONFIG.minSpeed
            if Helpers.isFiniteNumber(minSpeed) and minSpeed > 0 then
                statsSpeedPressure = (telemetrySummary.averageThreatSpeed - minSpeed) / math.max(minSpeed, 1)
                accumulateAggression(statsSpeedPressure * 0.5, 0.55, 1.8)
            end
        end

        if threatCount >= 3 and Helpers.isFiniteNumber(telemetrySummary.averageThreatTempo) then
            local tempo = telemetrySummary.averageThreatTempo
            local tempoNormalized = tempo * math.max(baseGap, SPAM_MIN_GAP)
            statsTempoPressure = tempoNormalized - 1
            accumulateAggression(statsTempoPressure, 0.4, 2.2)
        end

        if threatCount >= 3 and Helpers.isFiniteNumber(telemetrySummary.averageThreatVolatility) then
            local volatility = telemetrySummary.averageThreatVolatility
            local stability = telemetrySummary.averageThreatStability
            local volatilityRatio = volatility
            if Helpers.isFiniteNumber(stability) and stability > 0 then
                volatilityRatio = volatility / stability
            end
            statsVolatilityPressure = volatilityRatio - 1
            accumulateAggression(statsVolatilityPressure, 0.75, 2)
        end

        if threatCount >= 3 and Helpers.isFiniteNumber(telemetrySummary.averageThreatHorizon) then
            local horizon = telemetrySummary.averageThreatHorizon
            local horizonReference = math.max(lookaheadReference, baseLookahead)
            local surplus = horizon - horizonReference
            if Helpers.isFiniteNumber(surplus) then
                accumulateAggression(-surplus, math.max(horizonReference, 0.12), 1.8)
            end
        end

        if pressCount >= 6 and Helpers.isFiniteNumber(telemetrySummary.reactionFocusScore) then
            statsReactionFocus = math.clamp(telemetrySummary.reactionFocusScore, -2.5, 2.5)
            accumulateAggression(statsReactionFocus, 1.6, 2.5)
        end

        if pressCount >= 6 and Helpers.isFiniteNumber(telemetrySummary.cognitiveLoadScore) then
            statsCognitiveLoad = math.clamp(telemetrySummary.cognitiveLoadScore, -2, 3)
            accumulateAggression(-statsCognitiveLoad, 1.4, 2.5)
        end

        if pressCount >= 6 and Helpers.isFiniteNumber(telemetrySummary.neuroTempoScore) then
            statsNeuroTempo = math.clamp(telemetrySummary.neuroTempoScore, -2.2, 2.2)
            accumulateAggression(statsNeuroTempo, 1.5, 2.2)
        end
    end

    local statsAggressionScore = 0
    if statsSamples > 0 then
        statsAggressionScore = math.clamp(statsAggression / statsSamples, -1.8, 1.8)
    end
    local statsTighten = math.max(statsAggressionScore, 0)
    local statsRelax = math.max(-statsAggressionScore, 0)

    if targetingPressure > 0 then
        statsTighten = math.min(statsTighten + targetingPressure * 0.55, 3)
    end

    local statsTrend = 0
    local trend = Context.runtime.telemetrySummaryTrend
    if trend and Helpers.isFiniteNumber(trend.momentum) then
        local stale = trend.updatedAt and os.clock() - trend.updatedAt > 5
        if not stale and (trend.samples or 0) >= 2 then
            statsTrend = math.clamp(trend.momentum, -1.5, 1.5)
            if statsTrend > 0 then
                statsTighten = math.min(statsTighten + statsTrend * 0.5, 2.5)
            elseif statsTrend < 0 then
                statsRelax = math.min(statsRelax + (-statsTrend) * 0.35, 2.5)
            end
        end
    end

    if statsReactionFocus and Helpers.isFiniteNumber(statsReactionFocus) then
        if statsReactionFocus > 0 then
            statsTighten = math.min(statsTighten + statsReactionFocus * 0.45, 3)
        elseif statsReactionFocus < 0 then
            statsRelax = math.min(statsRelax + (-statsReactionFocus) * 0.4, 3)
        end
    end

    if statsNeuroTempo and Helpers.isFiniteNumber(statsNeuroTempo) then
        if statsNeuroTempo > 0 then
            statsTighten = math.min(statsTighten + statsNeuroTempo * 0.35, 3)
        elseif statsNeuroTempo < 0 then
            statsRelax = math.min(statsRelax + (-statsNeuroTempo) * 0.25, 3)
        end
    end

    if statsCognitiveLoad and Helpers.isFiniteNumber(statsCognitiveLoad) then
        if statsCognitiveLoad > 0 then
            statsRelax = math.min(statsRelax + statsCognitiveLoad * 0.45, 3)
        elseif statsCognitiveLoad < 0 then
            statsTighten = math.min(statsTighten + (-statsCognitiveLoad) * 0.4, 3)
        end
    end

    local basePresses = presses
    local statsPressureBoost = 0

    if statsReactionPressure and Helpers.isFiniteNumber(statsReactionPressure) then
        if statsReactionPressure > 0 then
            statsPressureBoost += math.min(statsReactionPressure, 1.8) * 0.65
        else
            statsRelax = math.min(statsRelax + (-statsReactionPressure) * 0.35, 3)
        end
    end

    if targetingPressure > 0 then
        statsPressureBoost += math.min(targetingPressure, 2.2) * 0.65
    end

    if statsReactionFocus and Helpers.isFiniteNumber(statsReactionFocus) and statsReactionFocus > 1.1 then
        statsPressureBoost += math.min(statsReactionFocus - 1.1, 1.6) * 0.55
    end

    if statsNeuroTempo and Helpers.isFiniteNumber(statsNeuroTempo) and statsNeuroTempo > 0.9 then
        statsPressureBoost += math.min(statsNeuroTempo - 0.9, 1.4) * 0.45
    end

    if statsCognitiveLoad and Helpers.isFiniteNumber(statsCognitiveLoad) and statsCognitiveLoad < -0.6 then
        statsPressureBoost += math.min(-statsCognitiveLoad - 0.6, 1.6) * 0.5
    end

    if statsDecisionPressure and Helpers.isFiniteNumber(statsDecisionPressure) then
        if statsDecisionPressure > 0 then
            statsPressureBoost += math.min(statsDecisionPressure, 1.6) * 0.45
        else
            statsRelax = math.min(statsRelax + (-statsDecisionPressure) * 0.3, 3)
        end
    end

    if statsMissPressure and Helpers.isFiniteNumber(statsMissPressure) then
        if statsMissPressure > 0 then
            statsPressureBoost += math.min(statsMissPressure, 1.5) * 0.9
        else
            statsRelax = math.min(statsRelax + (-statsMissPressure) * 0.4, 3)
        end
    end

    if statsPressMissCount and Helpers.isFiniteNumber(statsPressMissCount) and statsPressMissCount > 0 then
        local missRatio = statsPressMissCount / math.max(summaryPressCount, 1)
        statsPressureBoost += math.clamp(missRatio * 1.5, 0, 1.2)
    end

    if statsSuccessRate and Helpers.isFiniteNumber(statsSuccessRate) and statsSuccessRate > 0.97 then
        statsRelax = math.min(statsRelax + (statsSuccessRate - 0.97) * 1.4, 3)
    end

    if
        statsAverageReactionTime
        and Helpers.isFiniteNumber(statsAverageReactionTime)
        and Helpers.isFiniteNumber(reactionGoalTarget)
        and reactionGoalTarget > 0
        and statsAverageReactionTime < reactionGoalTarget * 0.85
    then
        local surplus = math.max(reactionGoalTarget * 0.85 - statsAverageReactionTime, 0)
        statsRelax = math.min(statsRelax + surplus / math.max(reactionGoalTarget, 0.01) * 0.6, 3)
    end

    if statsPressureBoost > 0 then
        presses = math.max(math.ceil(basePresses + statsPressureBoost), basePresses)
        presses = math.min(presses, basePresses + 2)
    else
        presses = math.max(basePresses, presses)
    end

    if targetingPressure > 0 then
        local extra = math.min(math.ceil(targetingPressure * 1.3), 3)
        presses = math.max(presses, basePresses + extra)
    end

    local dynamicPanicTightness = panicTightness
    local dynamicPanicSlack = panicSlack
    local dynamicPanicSpeedDelta = panicSpeedDelta
    if statsTighten > 0 then
        dynamicPanicTightness = math.max(panicTightness - statsTighten * 0.22, 0.25)
        dynamicPanicSlack = math.max(panicSlack * (1 - statsTighten * 0.35), minGap * 0.8)
        dynamicPanicSpeedDelta = math.max(panicSpeedDelta * (1 - statsTighten * 0.45), 0)
    elseif statsRelax > 0 then
        dynamicPanicTightness = math.min(panicTightness + statsRelax * 0.18, 0.98)
        dynamicPanicSlack = panicSlack * (1 + statsRelax * 0.4)
        dynamicPanicSpeedDelta = panicSpeedDelta * (1 + statsRelax * 0.25)
    end

    if statsTrend > 0 then
        dynamicPanicTightness = math.max(dynamicPanicTightness - statsTrend * 0.12, 0.2)
        dynamicPanicSlack = math.max(dynamicPanicSlack * (1 - statsTrend * 0.18), minGap * 0.75)
        dynamicPanicSpeedDelta = math.max(dynamicPanicSpeedDelta * (1 - statsTrend * 0.2), 0)
    elseif statsTrend < 0 then
        local relaxTrend = -statsTrend
        dynamicPanicTightness = math.min(dynamicPanicTightness + relaxTrend * 0.1, 0.99)
        dynamicPanicSlack = dynamicPanicSlack * (1 + relaxTrend * 0.15)
        dynamicPanicSpeedDelta = dynamicPanicSpeedDelta * (1 + relaxTrend * 0.18)
    end

    if statsReactionFocus and Helpers.isFiniteNumber(statsReactionFocus) then
        if statsReactionFocus > 0 then
            dynamicPanicTightness = math.max(dynamicPanicTightness - statsReactionFocus * 0.08, 0.18)
            dynamicPanicSlack = math.max(dynamicPanicSlack * (1 - statsReactionFocus * 0.14), minGap * 0.7)
            dynamicPanicSpeedDelta = math.max(dynamicPanicSpeedDelta * (1 - statsReactionFocus * 0.12), 0)
        elseif statsReactionFocus < 0 then
            local relaxFocus = -statsReactionFocus
            dynamicPanicTightness = math.min(dynamicPanicTightness + relaxFocus * 0.07, 0.99)
            dynamicPanicSlack = dynamicPanicSlack * (1 + relaxFocus * 0.16)
            dynamicPanicSpeedDelta = dynamicPanicSpeedDelta * (1 + relaxFocus * 0.12)
        end
    end

    if statsCognitiveLoad and Helpers.isFiniteNumber(statsCognitiveLoad) then
        if statsCognitiveLoad > 0 then
            dynamicPanicTightness = math.min(dynamicPanicTightness + statsCognitiveLoad * 0.09, 0.99)
            dynamicPanicSlack = dynamicPanicSlack * (1 + statsCognitiveLoad * 0.2)
            dynamicPanicSpeedDelta = dynamicPanicSpeedDelta * (1 + statsCognitiveLoad * 0.12)
        elseif statsCognitiveLoad < 0 then
            local lighten = -statsCognitiveLoad
            dynamicPanicTightness = math.max(dynamicPanicTightness - lighten * 0.1, 0.18)
            dynamicPanicSlack = math.max(dynamicPanicSlack * (1 - lighten * 0.16), minGap * 0.7)
            dynamicPanicSpeedDelta = math.max(dynamicPanicSpeedDelta * (1 - lighten * 0.1), 0)
        end
    end

    if not Helpers.isFiniteNumber(baseGap) or baseGap <= 0 then
        baseGap = Defaults.CONFIG.oscillationSpamBurstGap
    end
    if not Helpers.isFiniteNumber(baseWindow) or baseWindow <= 0 then
        baseWindow = math.max(baseGap * math.max(presses, 1) * 2, baseGap)
    end
    if not Helpers.isFiniteNumber(baseLookahead) or baseLookahead <= 0 then
        baseLookahead = Defaults.CONFIG.oscillationSpamBurstLookahead
    end

    local reference = decision or fallbackDecision
    local predictedImpact = nil
    local timeUntilPress = nil
    local decisionConfidence = nil
    local scheduleSlack = nil
    local detectionAge = nil
    local minDetectionTime = nil
    if reference then
        predictedImpact = reference.predictedImpact or reference.timeUntilPress or reference.timeToImpact
        timeUntilPress = reference.timeUntilPress or reference.timeToImpact or reference.predictedImpact
    end
    if decision then
        decisionConfidence = decision.confidence
        scheduleSlack = decision.scheduleSlack
        detectionAge = decision.detectionAge
        minDetectionTime = decision.minDetectionTime
    end
    if not Helpers.isFiniteNumber(predictedImpact) or predictedImpact < 0 then
        predictedImpact = nil
    end
    if not Helpers.isFiniteNumber(timeUntilPress) or timeUntilPress < 0 then
        timeUntilPress = predictedImpact
    end

    local gap = baseGap
    local window = baseWindow
    local lookahead = baseLookahead
    local tightness = 0
    local panic = false
    local panicReason = nil
    local panicGap = math.max(baseGap * panicGapScale, minGap)
    local panicWindow = math.max(baseWindow * panicWindowScale, baseWindow)
    local panicLookahead = math.max(baseLookahead + panicLookaheadBoost, baseLookahead)

    if predictedImpact then
        local activationBudget = math.max(predictedImpact - activationLatencyEstimate, 0)
        local baseDenominator = math.max(baseWindow, baseGap * math.max(presses, 1), Constants.EPSILON)
        tightness = math.clamp(1 - activationBudget / baseDenominator, 0, 1)

        if timeUntilPress then
            local scheduleBudget = math.max(timeUntilPress - activationLatencyEstimate, 0)
            local scheduleDenominator = math.max(baseWindow + activationLatencyEstimate, Constants.EPSILON)
            local scheduleTightness = 1 - scheduleBudget / scheduleDenominator
            if Helpers.isFiniteNumber(scheduleTightness) then
                tightness = math.max(tightness, math.clamp(scheduleTightness, 0, 1))
            end
        end

        local speedFactor = 0
        if kinematics and Helpers.isFiniteNumber(kinematics.velocityMagnitude) then
            local minSpeed = config.minSpeed or Defaults.CONFIG.minSpeed
            local speedDenominator = math.max(minSpeed, Constants.EPSILON)
            local normalized = (kinematics.velocityMagnitude - minSpeed) / speedDenominator
            speedFactor = math.clamp(normalized * 0.5, 0, 1)
        end

        local tighten = math.max(tightness, speedFactor)
        if decisionConfidence and Helpers.isFiniteNumber(decisionConfidence) then
            local normalizedConfidence = math.clamp((decisionConfidence - 0.5) / 0.45, 0, 1)
            tighten = math.max(tighten, normalizedConfidence * 0.6)
        end
        if statsTighten > 0 then
            tighten = math.min(tighten + statsTighten * 0.35, 1.25)
        elseif statsRelax > 0 then
            tighten = math.max(tighten - statsRelax * 0.25, 0)
        end

        if statsReactionPressure and Helpers.isFiniteNumber(statsReactionPressure) then
            if statsReactionPressure > 0 then
                tighten = math.min(tighten + math.min(statsReactionPressure, 1.6) * 0.3, 1.4)
            else
                tighten = math.max(tighten + statsReactionPressure * 0.22, 0)
            end
        end

        if statsDecisionPressure and Helpers.isFiniteNumber(statsDecisionPressure) and statsDecisionPressure > 0 then
            tighten = math.min(tighten + math.min(statsDecisionPressure, 1.5) * 0.25, 1.45)
        end

        if statsMissPressure and Helpers.isFiniteNumber(statsMissPressure) then
            if statsMissPressure > 0 then
                tighten = math.min(tighten + math.min(statsMissPressure, 1.4) * 0.45, 1.5)
            else
                tighten = math.max(tighten + statsMissPressure * 0.25, 0)
            end
        end

        if demandScore > 0 then
            tighten = math.min(tighten + math.min(demandScore, 6) * 0.05, 1.5)
        end
        if hyperDemand then
            tighten = math.min(tighten + 0.18, 1.6)
        end

        if statsTempoPressure and Helpers.isFiniteNumber(statsTempoPressure) then
            local tempoNormalized = math.clamp(statsTempoPressure, -1.5, 1.5)
            if tempoNormalized > 0 then
                tighten = math.min(tighten + tempoNormalized * 0.22, 1.3)
            else
                tighten = math.max(tighten + tempoNormalized * 0.18, 0)
            end
        end

        if statsVolatilityPressure and Helpers.isFiniteNumber(statsVolatilityPressure) then
            local volatilityNormalized = math.clamp(statsVolatilityPressure, -1.5, 1.5)
            if volatilityNormalized > 0 then
                tighten = math.min(tighten + volatilityNormalized * 0.28, 1.35)
            else
                tighten = math.max(tighten + volatilityNormalized * 0.2, 0)
            end
        end

        local lookaheadNormalized
        if statsLookaheadPressure and Helpers.isFiniteNumber(statsLookaheadPressure) then
            lookaheadNormalized = statsLookaheadPressure / math.max(baseGap + activationLatencyEstimate, 0.04)
            lookaheadNormalized = math.clamp(lookaheadNormalized, -2, 2)
            if lookaheadNormalized > 0 then
                tighten = math.min(tighten + lookaheadNormalized * 0.35, 1.35)
            else
                tighten = math.max(tighten + lookaheadNormalized * 0.25, 0)
            end
        end

        tightness = math.max(tightness, math.clamp(tighten, 0, 1))

        local tightenScale = 0.55 + statsTighten * 0.25
        gap = math.max(baseGap * (1 - tightenScale * tighten), SPAM_MIN_GAP)
        if statsTighten > 0 then
            gap = math.max(gap * (1 - 0.2 * statsTighten), minGap)
        elseif statsRelax > 0 then
            gap = math.min(gap * (1 + 0.15 * statsRelax), baseGap * (1 + 0.35 * statsRelax))
        end

        if targetingPressure > 0 then
            local tightenFactor = math.clamp(targetingPressure * 0.28, 0, 0.85)
            gap = math.max(gap * (1 - tightenFactor), minGap)
        end

        if statsTempoPressure and Helpers.isFiniteNumber(statsTempoPressure) then
            local tempoNormalized = math.clamp(statsTempoPressure, -1.5, 1.5)
            if tempoNormalized > 0 then
                gap = math.max(gap * (1 - 0.12 * tempoNormalized), minGap)
            elseif tempoNormalized < 0 then
                local relaxTempo = -tempoNormalized
                gap = math.min(gap * (1 + 0.1 * relaxTempo), baseGap * (1 + 0.25 * relaxTempo))
            end
        end

        if statsReactionPressure and Helpers.isFiniteNumber(statsReactionPressure) then
            if statsReactionPressure > 0 then
                gap = math.max(gap * (1 - 0.22 * math.min(statsReactionPressure, 1.6)), minGap)
            else
                gap = math.min(gap * (1 - statsReactionPressure * 0.15), baseGap * 1.3)
            end
        end

        if statsMissPressure and Helpers.isFiniteNumber(statsMissPressure) then
            if statsMissPressure > 0 then
                gap = math.max(gap * (1 - 0.28 * math.min(statsMissPressure, 1.3)), minGap)
            else
                local relaxMiss = -statsMissPressure
                gap = math.min(gap * (1 + 0.18 * relaxMiss), baseGap * 1.3)
            end
        end

        if statsVolatilityPressure and Helpers.isFiniteNumber(statsVolatilityPressure) then
            local volatilityNormalized = math.clamp(statsVolatilityPressure, -1.5, 1.5)
            if volatilityNormalized > 0 then
                gap = math.max(gap * (1 - 0.1 * volatilityNormalized), minGap)
            elseif volatilityNormalized < 0 then
                local relaxVolatility = -volatilityNormalized
                gap = math.min(gap * (1 + 0.08 * relaxVolatility), baseGap * (1 + 0.2 * relaxVolatility))
            end
        end

        if lookaheadNormalized and lookaheadNormalized ~= 0 then
            if lookaheadNormalized > 0 then
                gap = math.max(gap * (1 - 0.18 * lookaheadNormalized), minGap)
            else
                local relaxLookahead = -lookaheadNormalized
                gap = math.min(gap * (1 + 0.12 * relaxLookahead), baseGap * (1 + 0.3 * relaxLookahead))
            end
        end

        if statsReactionStdDev and Helpers.isFiniteNumber(statsReactionStdDev) then
            local targetSpread = math.max(baseGap * 0.45, SPAM_MIN_GAP * 1.4)
            local normalized = math.clamp((targetSpread - statsReactionStdDev) / math.max(targetSpread, 0.01), -1.6, 1.6)
            if normalized > 0 then
                gap = math.max(gap * (1 - 0.08 * normalized), minGap * 0.95)
            elseif normalized < 0 then
                local relax = -normalized
                gap = math.min(gap * (1 + 0.06 * relax), baseGap * (1 + 0.28 * relax))
            end
        end

        if statsDecisionToPressStdDev and Helpers.isFiniteNumber(statsDecisionToPressStdDev) then
            local targetSpread = math.max(baseGap * 0.5, SPAM_MIN_GAP * 1.6)
            local normalized = math.clamp((targetSpread - statsDecisionToPressStdDev) / math.max(targetSpread, 0.01), -1.5, 1.5)
            if normalized < 0 then
                local relax = -normalized
                gap = math.min(gap * (1 + 0.05 * relax), baseGap * (1 + 0.22 * relax))
            else
                gap = math.max(gap * (1 - 0.05 * normalized), minGap)
            end
        end

        if statsReactionFocus and Helpers.isFiniteNumber(statsReactionFocus) then
            if statsReactionFocus > 0 then
                gap = math.max(gap * (1 - 0.14 * math.min(statsReactionFocus, 1.8)), minGap * 0.9)
            elseif statsReactionFocus < 0 then
                local relaxFocus = -statsReactionFocus
                gap = math.min(gap * (1 + 0.1 * relaxFocus), baseGap * (1 + 0.35 * relaxFocus))
            end
        end

        if statsCognitiveLoad and Helpers.isFiniteNumber(statsCognitiveLoad) then
            if statsCognitiveLoad > 0 then
                gap = math.min(gap * (1 + 0.08 * math.min(statsCognitiveLoad, 1.8)), baseGap * (1 + 0.35 * math.min(statsCognitiveLoad, 1.8)))
            elseif statsCognitiveLoad < 0 then
                local lighten = -statsCognitiveLoad
                gap = math.max(gap * (1 - 0.1 * math.min(lighten, 1.6)), minGap)
            end
        end

        if decision and Helpers.isFiniteNumber(decision.scheduleSlack) and decision.scheduleSlack > 0 then
            gap = math.min(gap, math.max(decision.scheduleSlack * 0.5, SPAM_MIN_GAP))
        end

        local minimumWindow = gap * math.max(presses, 1) + SPAM_EXPIRY_MARGIN + activationLatencyEstimate * 0.5
        local closenessWindow = predictedImpact + activationLatencyEstimate + SPAM_EXPIRY_MARGIN
        local extension = baseWindow * SPAM_WINDOW_EXTENSION * tighten
        if statsTighten > 0 then
            extension += baseWindow * 0.3 * statsTighten
        elseif statsRelax > 0 then
            extension -= baseWindow * 0.2 * statsRelax
        end

        if lookaheadNormalized and lookaheadNormalized ~= 0 then
            if lookaheadNormalized > 0 then
                extension += baseWindow * 0.35 * lookaheadNormalized
            else
                extension -= baseWindow * 0.22 * (-lookaheadNormalized)
            end
        end

        if statsReactionStdDev and Helpers.isFiniteNumber(statsReactionStdDev) then
            local targetSpread = math.max(baseGap * 0.45, SPAM_MIN_GAP * 1.4)
            local normalized = math.clamp((targetSpread - statsReactionStdDev) / math.max(targetSpread, 0.01), -1.4, 1.4)
            extension -= baseWindow * 0.08 * normalized
        end

        if statsDecisionStdDev and Helpers.isFiniteNumber(statsDecisionStdDev) then
            local targetSpread = math.max(baseGap * 0.55, SPAM_MIN_GAP * 1.8)
            local normalized = math.clamp((targetSpread - statsDecisionStdDev) / math.max(targetSpread, 0.01), -1.3, 1.3)
            extension -= baseWindow * 0.06 * normalized
        end

        if statsReactionPressure and Helpers.isFiniteNumber(statsReactionPressure) then
            if statsReactionPressure > 0 then
                extension += baseWindow * 0.18 * math.min(statsReactionPressure, 1.2)
            elseif statsReactionPressure < 0 then
                extension -= baseWindow * 0.12 * math.min(-statsReactionPressure, 1.2)
            end
        end

        if statsReactionFocus and Helpers.isFiniteNumber(statsReactionFocus) then
            extension -= baseWindow * 0.12 * statsReactionFocus
        end

        if statsMissPressure and Helpers.isFiniteNumber(statsMissPressure) then
            if statsMissPressure > 0 then
                extension += baseWindow * 0.22 * math.min(statsMissPressure, 1.1)
            else
                extension -= baseWindow * 0.15 * math.min(-statsMissPressure, 1.1)
            end
        end

        if statsCognitiveLoad and Helpers.isFiniteNumber(statsCognitiveLoad) then
            extension += baseWindow * 0.1 * statsCognitiveLoad
        end

        if statsTempoPressure and Helpers.isFiniteNumber(statsTempoPressure) then
            local tempoNormalized = math.clamp(statsTempoPressure, -1.5, 1.5)
            if tempoNormalized > 0 then
                extension += baseWindow * 0.12 * tempoNormalized
            elseif tempoNormalized < 0 then
                extension -= baseWindow * 0.08 * (-tempoNormalized)
            end
        end

        if targetingPressure > 0 then
            extension += baseWindow * 0.3 * math.clamp(targetingPressure, 0, 1.2)
        end

        if statsVolatilityPressure and Helpers.isFiniteNumber(statsVolatilityPressure) then
            local volatilityNormalized = math.clamp(statsVolatilityPressure, -1.5, 1.5)
            if volatilityNormalized > 0 then
                extension += baseWindow * 0.15 * volatilityNormalized
            end
        end

        window = math.max(baseWindow + extension + lookaheadBoostExtra * 0.5, closenessWindow, minimumWindow)
        if statsRelax > 0 then
            window = math.max(window, baseWindow)
        end
        window = math.min(window, baseWindow + 0.45 + statsTighten * 0.1 + math.max(lookaheadNormalized or 0, 0) * 0.15)

        local lookaheadBoost = SPAM_LOOKAHEAD_BONUS * math.max(tighten, 0.35)
        if statsTighten > 0 then
            lookaheadBoost += 0.08 * statsTighten
        end
        if statsTempoPressure and Helpers.isFiniteNumber(statsTempoPressure) then
            local tempoNormalized = math.clamp(statsTempoPressure, -1.5, 1.5)
            if tempoNormalized > 0 then
                lookaheadBoost += 0.05 * tempoNormalized
            end
        end
        if statsReactionPressure and Helpers.isFiniteNumber(statsReactionPressure) and statsReactionPressure > 0 then
            lookaheadBoost += 0.06 * math.min(statsReactionPressure, 1.2)
        end
        if statsMissPressure and Helpers.isFiniteNumber(statsMissPressure) and statsMissPressure > 0 then
            lookaheadBoost += 0.09 * math.min(statsMissPressure, 1.1)
        end
        if statsReactionFocus and Helpers.isFiniteNumber(statsReactionFocus) then
            if statsReactionFocus > 0 then
                lookaheadBoost += 0.07 * math.min(statsReactionFocus, 1.8)
            else
                lookaheadBoost -= 0.05 * math.min(-statsReactionFocus, 1.6)
            end
        end
        if statsCognitiveLoad and Helpers.isFiniteNumber(statsCognitiveLoad) then
            if statsCognitiveLoad < 0 then
                lookaheadBoost += 0.05 * math.min(-statsCognitiveLoad, 1.6)
            else
                lookaheadBoost -= 0.04 * math.min(statsCognitiveLoad, 1.5)
            end
        end
        if statsReactionStdDev and Helpers.isFiniteNumber(statsReactionStdDev) then
            local targetSpread = math.max(baseGap * 0.45, SPAM_MIN_GAP * 1.4)
            local normalized = math.clamp((targetSpread - statsReactionStdDev) / math.max(targetSpread, 0.01), -1.4, 1.4)
            lookaheadBoost += 0.03 * normalized
        end
        if statsDecisionToPressStdDev and Helpers.isFiniteNumber(statsDecisionToPressStdDev) then
            local targetSpread = math.max(baseGap * 0.5, SPAM_MIN_GAP * 1.6)
            local normalized = math.clamp((targetSpread - statsDecisionToPressStdDev) / math.max(targetSpread, 0.01), -1.3, 1.3)
            lookaheadBoost += 0.025 * normalized
        end
        if lookaheadNormalized and lookaheadNormalized > 0 then
            lookaheadBoost += 0.12 * lookaheadNormalized
        end

        lookaheadBoost += lookaheadBoostExtra

        lookahead = math.max(baseLookahead, predictedImpact + activationLatencyEstimate + gap)
        lookahead = math.min(lookahead + lookaheadBoost, baseLookahead + 0.4 + statsTighten * 0.1 + math.max(lookaheadNormalized or 0, 0) * 0.12)

        if Helpers.isFiniteNumber(scheduleSlack) and scheduleSlack > 0 then
            panicGap = math.min(panicGap, math.max(scheduleSlack * 0.45, minGap))
        end

        if statsTighten > 0 then
            panicGap = math.min(panicGap, math.max(gap * (1 - 0.2 * statsTighten), minGap))
        elseif statsRelax > 0 then
            panicGap = math.max(panicGap, gap * (1 + 0.05 * statsRelax))
        end

        if statsTempoPressure and Helpers.isFiniteNumber(statsTempoPressure) and statsTempoPressure > 0 then
            panicGap = math.max(panicGap * (1 - 0.08 * math.min(statsTempoPressure, 1.2)), minGap)
        end

        if statsReactionPressure and Helpers.isFiniteNumber(statsReactionPressure) and statsReactionPressure > 0 then
            panicGap = math.max(panicGap * (1 - 0.16 * math.min(statsReactionPressure, 1.2)), minGap)
        end

        if statsMissPressure and Helpers.isFiniteNumber(statsMissPressure) and statsMissPressure > 0 then
            panicGap = math.max(panicGap * (1 - 0.2 * math.min(statsMissPressure, 1.1)), minGap)
        end

        if statsVolatilityPressure and Helpers.isFiniteNumber(statsVolatilityPressure) and statsVolatilityPressure > 0 then
            panicGap = math.max(panicGap * (1 - 0.1 * math.min(statsVolatilityPressure, 1.2)), minGap)
        end

        if targetingPressure > 0 then
            panicGap = math.max(panicGap * (1 - 0.18 * math.min(targetingPressure, 1.2)), minGap)
        end

        if kinematics and Helpers.isFiniteNumber(kinematics.velocityMagnitude) then
            local minSpeed = config.minSpeed or Defaults.CONFIG.minSpeed
            panicGap = math.min(
                panicGap,
                math.max(baseGap * (1 - 0.35 * math.clamp((kinematics.velocityMagnitude - minSpeed) / math.max(minSpeed, Constants.EPSILON), 0, 1)), minGap)
            )
        end

        panicGap = math.max(panicGap, minGap)
        panicWindow = math.max(
            panicWindow,
            gap * math.max(presses, 1) + SPAM_EXPIRY_MARGIN + activationLatencyEstimate * 0.5,
            predictedImpact + activationLatencyEstimate + SPAM_EXPIRY_MARGIN
        )
        if statsTighten > 0 then
            panicWindow = panicWindow * (1 + 0.35 * statsTighten)
        end
        if statsVolatilityPressure and Helpers.isFiniteNumber(statsVolatilityPressure) and statsVolatilityPressure > 0 then
            panicWindow = panicWindow * (1 + 0.25 * math.min(statsVolatilityPressure, 1.2))
        end
        if statsReactionPressure and Helpers.isFiniteNumber(statsReactionPressure) and statsReactionPressure > 0 then
            panicWindow = panicWindow * (1 + 0.18 * math.min(statsReactionPressure, 1.2))
        end
        if statsMissPressure and Helpers.isFiniteNumber(statsMissPressure) then
            if statsMissPressure > 0 then
                panicWindow = panicWindow * (1 + 0.3 * math.min(statsMissPressure, 1.1))
            else
                panicWindow = panicWindow * (1 + statsMissPressure * 0.15)
            end
        end
        if lookaheadNormalized and lookaheadNormalized > 0 then
            panicWindow = panicWindow * (1 + 0.3 * lookaheadNormalized)
        end
        if targetingPressure > 0 then
            panicWindow = panicWindow * (1 + 0.22 * math.min(targetingPressure, 1.2))
        end
        panicWindow = math.min(panicWindow, baseWindow + 0.6 + statsTighten * 0.15 + math.max(lookaheadNormalized or 0, 0) * 0.2)
        panicLookahead = math.max(panicLookahead, predictedImpact + activationLatencyEstimate + panicGap + lookaheadBoostExtra)
        if statsMissPressure and Helpers.isFiniteNumber(statsMissPressure) and statsMissPressure > 0 then
            panicLookahead = math.max(
                panicLookahead,
                predictedImpact + activationLatencyEstimate + panicGap + statsMissPressure * 0.05
            )
        end
        if statsReactionPressure and Helpers.isFiniteNumber(statsReactionPressure) and statsReactionPressure > 0 then
            panicLookahead = math.max(
                panicLookahead,
                predictedImpact + activationLatencyEstimate + panicGap + statsReactionPressure * 0.04
            )
        end
        panicLookahead = math.min(
            panicLookahead,
            baseLookahead + panicLookaheadBoost + lookaheadBoostExtra + 0.45 + statsTighten * 0.12
                + math.max(lookaheadNormalized or 0, 0) * 0.15
        )

        if tighten >= dynamicPanicTightness then
            panic = true
            panicReason = "tightness"
        end

        if not panic and targetingPressure > 1.1 then
            panic = true
            panicReason = panicReason or "retarget"
        end

        if
            not panic
            and Helpers.isFiniteNumber(scheduleSlack)
            and scheduleSlack > 0
            and scheduleSlack <= math.max(dynamicPanicSlack, minGap * 1.1)
        then
            panic = true
            panicReason = "slack"
        end

        if
            not panic
            and kinematics
            and Helpers.isFiniteNumber(kinematics.velocityMagnitude)
            and Helpers.isFiniteNumber(config.minSpeed)
            and kinematics.velocityMagnitude >= (config.minSpeed or Defaults.CONFIG.minSpeed) + dynamicPanicSpeedDelta
        then
            panic = true
            panicReason = "speed"
        end

        if not panic and lookaheadNormalized and lookaheadNormalized >= dynamicPanicTightness then
            panic = true
            panicReason = panicReason or "lookahead"
        end

        if not panic and statsMissPressure and Helpers.isFiniteNumber(statsMissPressure) and statsMissPressure > 0.35 then
            panic = true
            panicReason = panicReason or "reliability"
        end

        if not panic and statsReactionPressure and Helpers.isFiniteNumber(statsReactionPressure) and statsReactionPressure > 0.5 then
            panic = true
            panicReason = panicReason or "reaction"
        end

        if
            not panic
            and statsPressMissCount
            and Helpers.isFiniteNumber(statsPressMissCount)
            and summaryPressCount >= 6
        then
            local missRatio = statsPressMissCount / math.max(summaryPressCount, 1)
            if missRatio >= 0.25 then
                panic = true
                panicReason = panicReason or "misses"
            end
        end

        if
            not panic
            and fallbackDecision
            and Helpers.isFiniteNumber(fallbackDecision.predictedImpact or fallbackDecision.timeUntilPress)
        then
            local fallbackImpact = fallbackDecision.predictedImpact or fallbackDecision.timeUntilPress
            if fallbackImpact and fallbackImpact <= (predictedImpact or fallbackImpact) + dynamicPanicSlack then
                panic = true
                panicReason = "fallback"
            end
        end

        if
            not panic
            and Helpers.isFiniteNumber(detectionAge)
            and Helpers.isFiniteNumber(minDetectionTime)
            and minDetectionTime > 0
            and detectionAge >= 0
        then
            local detectionSlack = detectionAge - minDetectionTime
            if detectionSlack >= 0 and detectionSlack <= dynamicPanicSlack * 0.5 then
                panic = true
                panicReason = "detection"
            end
        end

        if not panic and hyperDemand then
            panic = true
            panicReason = panicReason or "demand"
        end
    end

    if hyperDemand then
        gap = math.max(gap * 0.75, minGap)
        window = math.max(window, gap * math.max(presses, 1) * 1.3)
        lookahead = math.max(lookahead, gap * math.max(presses, 1) + activationLatencyEstimate * 0.5)
        panicGap = math.max(minGap, math.min(panicGap, gap))
        panicWindow = math.max(panicWindow, window * 1.35)
        panicLookahead = math.max(panicLookahead, lookahead + activationLatencyEstimate * 0.35)
    end

    gap = math.max(gap, minGap)
    window = math.max(window, gap * math.max(presses, 1) + SPAM_EXPIRY_MARGIN + activationLatencyEstimate * 0.25)
    lookahead = math.max(lookahead, gap + activationLatencyEstimate)
    panicGap = math.max(panicGap, minGap)
    panicWindow = math.max(panicWindow, window)
    panicLookahead = math.max(panicLookahead, lookahead)

    return {
        presses = presses,
        gap = gap,
        window = window,
        lookahead = lookahead,
        tightness = tightness,
        predictedImpact = predictedImpact,
        panic = panic,
        panicReason = panicReason,
        panicGap = panicGap,
        panicWindow = panicWindow,
        panicLookahead = panicLookahead,
        recoverySeconds = recoverySeconds,
        statsAggression = statsAggressionScore,
        statsSamples = statsSamples,
        statsWaitDelta = statsWaitDelta,
        statsLeadDelta = statsLeadDelta,
        statsCommitPressure = statsCommitPressure,
        statsAverageLatency = statsAverageLatency,
        statsCancellationRate = statsCancellationRate,
        statsImmediateRate = statsImmediateRate,
        statsSpeedPressure = statsSpeedPressure,
        statsLookaheadPressure = statsLookaheadPressure,
        statsTempoPressure = statsTempoPressure,
        statsVolatilityPressure = statsVolatilityPressure,
        statsAverageReactionTime = statsAverageReactionTime,
        statsReactionStdDev = statsReactionStdDev,
        statsReactionPressure = statsReactionPressure,
        statsAverageDecisionToPress = statsAverageDecisionToPress,
        statsDecisionStdDev = statsDecisionStdDev,
        statsDecisionToPressStdDev = statsDecisionToPressStdDev,
        statsDecisionPressure = statsDecisionPressure,
        statsSuccessRate = statsSuccessRate,
        statsMissPressure = statsMissPressure,
        statsPressMissCount = statsPressMissCount,
        statsTrend = statsTrend,
        statsReactionFocus = statsReactionFocus,
        statsCognitiveLoad = statsCognitiveLoad,
        statsNeuroTempo = statsNeuroTempo,
        statsTargetingPressure = statsTargetingPressure,
        statsTargetingRate = statsTargetingRate,
        statsTargetingInterval = statsTargetingInterval,
        statsTargetingSincePress = statsTargetingSincePress,
        statsTargetingAggression = statsTargetingAggression,
        statsTargetingMomentum = statsTargetingMomentum,
        statsTargetingSpeedUrgency = statsTargetingSpeedUrgency,
        targetingDemand = demandScore,
        targetingRateOverdrive = rateOverdrive,
        targetingInterval = optionInterval,
        targetingPressRate = optionPressRate,
        targetingFreshness = optionFreshness,
        targetingSincePress = optionSincePress,
        targetingSinceDrop = optionSinceDrop,
        hyperDemand = hyperDemand,
        panicTightnessThreshold = dynamicPanicTightness,
        panicSlackLimit = dynamicPanicSlack,
        panicSpeedDelta = dynamicPanicSpeedDelta,
        triggerMode = mode,
    }
end

function Helpers.applySpamBurstTuning(
    burstState,
    tuning,
    now,
    telemetry: TelemetryState?,
    settings: { presses: number, gap: number, window: number, lookahead: number, minGap: number }?
)
    if not burstState or not tuning then
        return
    end

    local presses = math.max(settings and settings.presses or burstState.remaining or 0, 0)
    local minGap = math.max(settings and settings.minGap or SPAM_MIN_GAP, SPAM_MIN_GAP)
    local gap = math.max(tuning.gap or minGap, minGap)
    local window = math.max(tuning.window or 0, gap * math.max(presses, 1))
    local lookahead = math.max(tuning.lookahead or gap + activationLatencyEstimate, gap + activationLatencyEstimate)

    local panicActive = false
    local panicReason = tuning.panicReason
    local recoverySeconds = math.max(tuning.recoverySeconds or 0, 0)
    local panicGap = math.max(tuning.panicGap or gap, minGap)
    local panicWindow = math.max(tuning.panicWindow or window, window)
    local panicLookahead = math.max(tuning.panicLookahead or lookahead, lookahead)

    if tuning.panic then
        burstState.panicUntil = math.max(burstState.panicUntil or 0, now + recoverySeconds)
        panicActive = true
    elseif burstState.panicUntil and burstState.panicUntil > now then
        panicActive = true
        panicReason = burstState.panicReason
    else
        burstState.panicUntil = 0
        burstState.panicReason = nil
    end

    if panicActive then
        gap = math.max(panicGap, minGap)
        window = math.max(panicWindow, window)
        lookahead = math.max(panicLookahead, lookahead)
        burstState.panicReason = panicReason or burstState.panicReason
    end

    burstState.gap = gap
    burstState.dynamicGap = gap
    burstState.window = math.max(burstState.window or 0, window)
    burstState.dynamicLookahead = lookahead
    burstState.maxLookahead = math.max(
        burstState.maxLookahead or lookahead,
        lookahead,
        panicLookahead,
        settings and settings.lookahead or lookahead
    )
    burstState.tightness = tuning.tightness
    burstState.predictedImpact = tuning.predictedImpact
    burstState.panicActive = panicActive
    burstState.mode = panicActive and "panic" or "normal"
    burstState.statsAggression = tuning.statsAggression
    burstState.statsSamples = tuning.statsSamples

    if telemetry then
        telemetry.lastOscillationBurst = telemetry.lastOscillationBurst or {}
        telemetry.lastOscillationBurst.gap = gap
        telemetry.lastOscillationBurst.window = burstState.window
        telemetry.lastOscillationBurst.lookahead = burstState.dynamicLookahead
        telemetry.lastOscillationBurst.tightness = tuning.tightness
        telemetry.lastOscillationBurst.predictedImpact = tuning.predictedImpact
        telemetry.lastOscillationBurst.panic = panicActive
        telemetry.lastOscillationBurst.panicReason = burstState.panicReason
        telemetry.lastOscillationBurst.statsAggression = tuning.statsAggression
        telemetry.lastOscillationBurst.statsSamples = tuning.statsSamples
        telemetry.lastOscillationBurst.statsWaitDelta = tuning.statsWaitDelta
        telemetry.lastOscillationBurst.statsLeadDelta = tuning.statsLeadDelta
        telemetry.lastOscillationBurst.statsCommitPressure = tuning.statsCommitPressure
        telemetry.lastOscillationBurst.statsAverageLatency = tuning.statsAverageLatency
        telemetry.lastOscillationBurst.statsCancellationRate = tuning.statsCancellationRate
        telemetry.lastOscillationBurst.statsImmediateRate = tuning.statsImmediateRate
        telemetry.lastOscillationBurst.statsSpeedPressure = tuning.statsSpeedPressure
        telemetry.lastOscillationBurst.statsLookaheadPressure = tuning.statsLookaheadPressure
        telemetry.lastOscillationBurst.statsTempoPressure = tuning.statsTempoPressure
        telemetry.lastOscillationBurst.statsVolatilityPressure = tuning.statsVolatilityPressure
        telemetry.lastOscillationBurst.statsAverageReactionTime = tuning.statsAverageReactionTime
        telemetry.lastOscillationBurst.statsReactionStdDev = tuning.statsReactionStdDev
        telemetry.lastOscillationBurst.statsReactionPressure = tuning.statsReactionPressure
        telemetry.lastOscillationBurst.statsAverageDecisionToPress = tuning.statsAverageDecisionToPress
        telemetry.lastOscillationBurst.statsDecisionStdDev = tuning.statsDecisionStdDev
        telemetry.lastOscillationBurst.statsDecisionToPressStdDev = tuning.statsDecisionToPressStdDev
        telemetry.lastOscillationBurst.statsDecisionPressure = tuning.statsDecisionPressure
        telemetry.lastOscillationBurst.statsSuccessRate = tuning.statsSuccessRate
        telemetry.lastOscillationBurst.statsMissPressure = tuning.statsMissPressure
        telemetry.lastOscillationBurst.statsPressMissCount = tuning.statsPressMissCount
        telemetry.lastOscillationBurst.statsTrend = tuning.statsTrend
        telemetry.lastOscillationBurst.statsReactionFocus = tuning.statsReactionFocus
        telemetry.lastOscillationBurst.statsCognitiveLoad = tuning.statsCognitiveLoad
        telemetry.lastOscillationBurst.statsNeuroTempo = tuning.statsNeuroTempo
        telemetry.lastOscillationBurst.statsTargetingPressure = tuning.statsTargetingPressure
        telemetry.lastOscillationBurst.statsTargetingRate = tuning.statsTargetingRate
        telemetry.lastOscillationBurst.statsTargetingInterval = tuning.statsTargetingInterval
        telemetry.lastOscillationBurst.statsTargetingSincePress = tuning.statsTargetingSincePress
        telemetry.lastOscillationBurst.statsTargetingAggression = tuning.statsTargetingAggression
        telemetry.lastOscillationBurst.statsTargetingMomentum = tuning.statsTargetingMomentum
        telemetry.lastOscillationBurst.statsTargetingSpeedUrgency = tuning.statsTargetingSpeedUrgency
        telemetry.lastOscillationBurst.targetingDemand = tuning.targetingDemand
        telemetry.lastOscillationBurst.targetingRateOverdrive = tuning.targetingRateOverdrive
        telemetry.lastOscillationBurst.targetingInterval = tuning.targetingInterval
        telemetry.lastOscillationBurst.targetingPressRate = tuning.targetingPressRate
        telemetry.lastOscillationBurst.targetingFreshness = tuning.targetingFreshness
        telemetry.lastOscillationBurst.targetingSincePress = tuning.targetingSincePress
        telemetry.lastOscillationBurst.targetingSinceDrop = tuning.targetingSinceDrop
        telemetry.lastOscillationBurst.hyperDemand = tuning.hyperDemand
        telemetry.lastOscillationBurst.panicTightness = tuning.panicTightnessThreshold
        telemetry.lastOscillationBurst.panicSlackLimit = tuning.panicSlackLimit
        telemetry.lastOscillationBurst.panicSpeedDelta = tuning.panicSpeedDelta
        telemetry.lastOscillationBurst.mode = burstState.reason
        telemetry.lastOscillationBurst.updatedAt = now
    end

    return gap, window, lookahead, panicActive
end

function Helpers.resetSpamBurst(reason: string?)
    local burstState = Context.runtime.spamBurst
    if not burstState then
        return
    end

    burstState.active = false
    burstState.ballId = nil
    burstState.remaining = 0
    burstState.nextPressAt = 0
    burstState.expireAt = 0
    burstState.gap = 0
    burstState.dynamicGap = 0
    burstState.dynamicLookahead = math.huge
    burstState.window = 0
    burstState.maxLookahead = math.huge
    burstState.startedAt = 0
    burstState.lastPressAt = 0
    burstState.failures = 0
    burstState.reason = reason
    burstState.initialDecision = nil
    burstState.baseSettings = nil
    burstState.tightness = 0
    burstState.predictedImpact = nil
    burstState.panicUntil = 0
    burstState.panicActive = false
    burstState.panicReason = nil
    burstState.mode = "idle"
    burstState.statsAggression = 0
    burstState.statsSamples = 0
    burstState.triggerOptions = nil
end

function Helpers.startSpamBurst(
    ballId: string?,
    now: number,
    decision: { [string]: any }?,
    telemetry: TelemetryState?,
    kinematics: BallKinematics.Kinematics?,
    mode: string?,
    options: { [string]: any }?
)
    if not ballId then
        return
    end

    local settings = resolveOscillationSpamSettings()
    if settings.presses <= 0 then
        Helpers.resetSpamBurst("disabled")
        return
    end

    local burstState = Context.runtime.spamBurst
    local modeTag = mode or "oscillation"
    if burstState.active and burstState.ballId == ballId and burstState.reason == modeTag then
        burstState.triggerOptions = options
        return
    end
    burstState.active = true
    burstState.ballId = ballId
    burstState.remaining = settings.presses
    burstState.baseSettings = settings
    burstState.triggerOptions = options
    burstState.reason = modeTag

    local tuning = Helpers.computeSpamBurstTuning(
        settings,
        decision,
        kinematics,
        decision,
        Context.runtime.telemetrySummary,
        telemetry,
        now,
        burstState.reason,
        options
    )
    Helpers.applySpamBurstTuning(burstState, tuning, now, telemetry, settings)
    local demandOption = 0
    local rateOption = 0
    local timeToImpactOption
    if typeof(options) == "table" then
        if Helpers.isFiniteNumber(options.demand) and options.demand > 0 then
            demandOption = options.demand
        end
        if Helpers.isFiniteNumber(options.rate) and options.rate > 0 then
            rateOption = options.rate
        end
        if Helpers.isFiniteNumber(options.pressRate) and options.pressRate > 0 then
            rateOption = math.max(rateOption, options.pressRate)
        end
        if Helpers.isFiniteNumber(options.timeToImpact) and options.timeToImpact >= 0 then
            timeToImpactOption = options.timeToImpact
        end
    end
    burstState.nextPressAt = now + math.max(burstState.gap, SPAM_MIN_GAP)
    if demandOption > 0 then
        local demandClamp = math.clamp(demandOption, 0, 8)
        local reduction = math.clamp(demandClamp * 0.18, 0, 0.82)
        if rateOption > 0 then
            reduction = math.min(0.9, reduction + math.max(rateOption / TARGETING_PRESSURE_RATE_THRESHOLD - 1, 0) * 0.12)
        end
        local earliest = now + math.max(SPAM_MIN_GAP, burstState.gap * (1 - reduction))
        if earliest < burstState.nextPressAt then
            burstState.nextPressAt = earliest
        end
    end
    if timeToImpactOption and Helpers.isFiniteNumber(timeToImpactOption) then
        if timeToImpactOption <= burstState.gap * 1.5 then
            local urgentAt = now + math.max(SPAM_MIN_GAP, math.min(burstState.gap, timeToImpactOption * 0.6))
            if urgentAt < burstState.nextPressAt then
                burstState.nextPressAt = urgentAt
            end
        end
    end
    burstState.expireAt = now + math.max(burstState.window or tuning.window, 0)
    burstState.startedAt = now
    burstState.lastPressAt = now
    burstState.failures = 0
    burstState.reason = mode or burstState.reason or "oscillation"

    if telemetry then
        telemetry.lastOscillationBurst = {
            startedAt = now,
            presses = settings.presses,
            baseGap = settings.gap,
            baseWindow = settings.window,
            baseLookahead = settings.lookahead,
            gap = burstState.gap,
            window = burstState.window,
            lookahead = burstState.dynamicLookahead,
            tightness = tuning.tightness,
            predictedImpact = tuning.predictedImpact,
            panic = burstState.panicActive,
            panicReason = burstState.panicReason,
        }
    end

    if decision then
        burstState.initialDecision = {
            predictedImpact = decision.predictedImpact,
            timeToHoldRadius = decision.timeToHoldRadius,
            holdRadius = decision.holdRadius,
            shouldHold = decision.shouldHold,
            targetingMe = decision.targetingMe,
        }
    else
        burstState.initialDecision = nil
    end
end

local function spamBurstDecisionGate(decision, burstState)
    if not decision then
        return true
    end

    if decision.shouldHold or decision.shouldPress then
        return true
    end

    if decision.proximityPress or decision.inequalityPress or decision.confidencePress then
        return true
    end

    if decision.targetingMe and decision.withinLookahead then
        return true
    end

    if burstState and burstState.initialDecision then
        local baseline = burstState.initialDecision
        if baseline and baseline.targetingMe and decision.targetingMe then
            return true
        end
    end

    if burstState and Helpers.isFiniteNumber(burstState.tightness) and burstState.tightness >= 0.55 then
        return true
    end

    if
        burstState
        and Helpers.isFiniteNumber(burstState.statsAggression)
        and Helpers.isFiniteNumber(burstState.statsSamples)
        and burstState.statsSamples >= 3
        and burstState.statsAggression >= 0.35
    then
        return true
    end

    return false
end

function Helpers.processSpamBurst(
    ball: BasePart?,
    ballId: string?,
    now: number,
    decision: { [string]: any }?,
    telemetry: TelemetryState?,
    kinematics: BallKinematics.Kinematics?
)
    local burstState = Context.runtime.spamBurst
    if not burstState or not burstState.active then
        return false
    end

    if not ballId or burstState.ballId ~= ballId then
        Helpers.resetSpamBurst("ball-changed")
        return false
    end

    if burstState.remaining <= 0 then
        Helpers.resetSpamBurst("complete")
        return false
    end

    local baseSettings = burstState.baseSettings
    if not baseSettings then
        baseSettings = resolveOscillationSpamSettings()
        burstState.baseSettings = baseSettings
    end

    local tuning = Helpers.computeSpamBurstTuning(
        baseSettings,
        decision,
        kinematics,
        burstState.initialDecision,
        Context.runtime.telemetrySummary,
        telemetry,
        now,
        burstState.reason,
        burstState.triggerOptions
    )
    Helpers.applySpamBurstTuning(burstState, tuning, now, telemetry, baseSettings)
    local demandOption = 0
    local rateOption = 0
    local timeToImpactOption
    local sincePressOption
    local triggerOptions = burstState.triggerOptions
    if typeof(triggerOptions) == "table" then
        if Helpers.isFiniteNumber(triggerOptions.demand) and triggerOptions.demand > 0 then
            demandOption = triggerOptions.demand
        end
        if Helpers.isFiniteNumber(triggerOptions.rate) and triggerOptions.rate > 0 then
            rateOption = triggerOptions.rate
        end
        if Helpers.isFiniteNumber(triggerOptions.pressRate) and triggerOptions.pressRate > 0 then
            rateOption = math.max(rateOption, triggerOptions.pressRate)
        end
        if Helpers.isFiniteNumber(triggerOptions.timeToImpact) and triggerOptions.timeToImpact >= 0 then
            timeToImpactOption = triggerOptions.timeToImpact
        end
        if Helpers.isFiniteNumber(triggerOptions.sincePress) and triggerOptions.sincePress >= 0 then
            sincePressOption = triggerOptions.sincePress
        end
    end

    local minimumNext = burstState.lastPressAt + burstState.gap
    if burstState.nextPressAt < minimumNext then
        burstState.nextPressAt = minimumNext
    end
    if demandOption > 0 then
        local demandClamp = math.clamp(demandOption, 0, 8)
        local reduction = math.clamp(demandClamp * 0.18, 0, 0.82)
        if rateOption > 0 then
            reduction = math.min(0.9, reduction + math.max(rateOption / TARGETING_PRESSURE_RATE_THRESHOLD - 1, 0) * 0.12)
        end
        local earliest = burstState.lastPressAt + math.max(SPAM_MIN_GAP, burstState.gap * (1 - reduction))
        if earliest < burstState.nextPressAt then
            burstState.nextPressAt = earliest
        end
    end
    if timeToImpactOption and Helpers.isFiniteNumber(timeToImpactOption) then
        if timeToImpactOption <= burstState.gap * 1.5 then
            local urgencyWindow = math.max(SPAM_MIN_GAP, math.min(burstState.gap, timeToImpactOption * 0.6))
            local urgentAt = burstState.lastPressAt + urgencyWindow
            if urgentAt < burstState.nextPressAt then
                burstState.nextPressAt = urgentAt
            end
        end
    end
    if sincePressOption and Helpers.isFiniteNumber(sincePressOption) and sincePressOption <= TARGETING_PRESSURE_PRESS_WINDOW then
        local catchUpAt = burstState.lastPressAt + math.max(SPAM_MIN_GAP, burstState.gap * 0.45)
        if catchUpAt < burstState.nextPressAt then
            burstState.nextPressAt = catchUpAt
        end
    end

    local suspendedUntil = Context.runtime.targetingSpamSuspendedUntil or 0
    if Context.runtime.virtualInputUnavailable and Context.runtime.virtualInputRetryAt > now then
        suspendedUntil = math.max(suspendedUntil, Context.runtime.virtualInputRetryAt)
    end
    if suspendedUntil > now then
        burstState.nextPressAt = math.max(burstState.nextPressAt, suspendedUntil)
    end

    local newExpireAt = burstState.startedAt + math.max(burstState.window or tuning.window, 0)
    if newExpireAt > burstState.expireAt then
        burstState.expireAt = newExpireAt
    end

    if now > burstState.expireAt then
        Helpers.resetSpamBurst("expired")
        return false
    end

    if now < burstState.nextPressAt then
        return false
    end

    if Context.runtime.virtualInputUnavailable and Context.runtime.virtualInputRetryAt > now then
        burstState.nextPressAt = math.max(burstState.nextPressAt, Context.runtime.virtualInputRetryAt)
        return false
    end

    if Context.runtime.targetingSpamSuspendedUntil and Context.runtime.targetingSpamSuspendedUntil > now then
        burstState.nextPressAt = math.max(burstState.nextPressAt, Context.runtime.targetingSpamSuspendedUntil)
        return false
    end

    local predictedImpact = burstState.predictedImpact
    if not Helpers.isFiniteNumber(predictedImpact) or predictedImpact < 0 then
        predictedImpact = math.huge
    end
    local lookaheadLimit = burstState.dynamicLookahead or burstState.maxLookahead
    if not Helpers.isFiniteNumber(lookaheadLimit) or lookaheadLimit <= 0 then
        lookaheadLimit = burstState.maxLookahead
    end
    if not Helpers.isFiniteNumber(lookaheadLimit) or lookaheadLimit <= 0 then
        lookaheadLimit = math.huge
    end
    if predictedImpact > lookaheadLimit then
        return false
    end

    if not spamBurstDecisionGate(decision, burstState) then
        Helpers.resetSpamBurst("gate-failed")
        return false
    end

    if kinematics and Helpers.isFiniteNumber(kinematics.distance) then
        local safeRadius = decision and decision.holdRadius or 0
        if Helpers.isFiniteNumber(safeRadius) and safeRadius > 0 then
            local radial = kinematics.distance - safeRadius
            if Helpers.isFiniteNumber(radial) and radial > safeRadius * 2 then
                Helpers.resetSpamBurst("radial-clear")
                return false
            end
        end
    end

    local pressed = Helpers.pressParry(ball, ballId, true, decision)
    if pressed then
        burstState.remaining -= 1
        burstState.lastPressAt = now
        burstState.nextPressAt = now + math.max(burstState.gap, SPAM_MIN_GAP)
        burstState.failures = 0
        if telemetry then
            telemetry.lastOscillationApplied = now
            telemetry.lastOscillationBurstPress = now
        end
        Context.runtime.targetingSpamSuspendedUntil = math.max(Context.runtime.targetingSpamSuspendedUntil or 0, now + 0.25)
        if burstState.remaining <= 0 then
            Helpers.resetSpamBurst("complete")
        end
        return true
    end

    burstState.failures = (burstState.failures or 0) + 1
    burstState.nextPressAt = now + math.max(burstState.gap, SPAM_MIN_GAP)
    if burstState.failures >= 3 then
        Helpers.resetSpamBurst("failed")
    end

    return false
end

function Helpers.getRollingStd(stat: RollingStat?, floor: number)
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

local MAX_LATENCY_SAMPLE_SECONDS = 2
local PENDING_LATENCY_MAX_AGE = 5

local latencySamples = {
    lastSample = nil,
    lastLocalSample = nil,
    lastRemoteSample = nil,
}

local pendingLatencyPresses = {}

local publishTelemetryHistory

function Helpers.publishLatencyTelemetry()
    local settings = GlobalEnv.Paws
    if typeof(settings) ~= "table" then
        settings = {}
        GlobalEnv.Paws = settings
    end
    settings.ActivationLatency = activationLatencyEstimate
    settings.LatencySamples = latencySamples
    settings.RemoteLatencyActive = state.remoteEstimatorActive
    if publishTelemetryHistory then
        publishTelemetryHistory()
    end
end

function Helpers.recordLatencySample(
    sample: number?,
    source: string?,
    ballId: string?,
    telemetry: TelemetryState?,
    now: number?
)
    local timestamp = now or os.clock()
    if not Helpers.isFiniteNumber(sample) or not sample or sample <= 0 or sample > MAX_LATENCY_SAMPLE_SECONDS then
        local eventPayload = {
            ballId = ballId,
            source = source or "unknown",
            value = sample,
            accepted = false,
            reason = "invalid",
            time = timestamp,
        }
        TelemetryAnalytics.recordLatency(eventPayload)
        emitTelemetryEvent("latency-sample", eventPayload)
        return false
    end

    activationLatencyEstimate = Helpers.emaScalar(activationLatencyEstimate, sample, Constants.ACTIVATION_LATENCY_ALPHA)
    if activationLatencyEstimate < 0 then
        activationLatencyEstimate = 0
    end

    if telemetry then
        telemetry.latencySampled = true
    end

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

    Helpers.publishLatencyTelemetry()
    local eventPayload = {
        ballId = ballId,
        source = source or "unknown",
        value = sample,
        accepted = true,
        time = timestamp,
        activationLatency = activationLatencyEstimate,
        remoteLatencyActive = state.remoteEstimatorActive,
    }
    if telemetry then
        eventPayload.telemetry = {
            filteredD = telemetry.filteredD,
            filteredVr = telemetry.filteredVr,
            filteredAr = telemetry.filteredAr,
            filteredJr = telemetry.filteredJr,
        }
    end
    TelemetryAnalytics.recordLatency(eventPayload)
    emitTelemetryEvent("latency-sample", eventPayload)
    return true
end

function Helpers.prunePendingLatencyPresses(now: number)
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

function Helpers.handleParrySuccessLatency(...)
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
            local accepted = Helpers.recordLatencySample(elapsed, "remote", entry.ballId, telemetry, now)
            local successEvent = {
                ballId = entry.ballId,
                latency = elapsed,
                accepted = accepted,
                source = "remote",
                time = now,
            }
            TelemetryAnalytics.recordSuccess(successEvent)
            emitTelemetryEvent("success", successEvent)
            if accepted then
                return
            end
        end
    end
end

parrySuccessSignal:connect(Helpers.handleParrySuccessLatency)

function Helpers.clampWithOverflow(value: number, limit: number?)
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

function Helpers.ensureTelemetry(ballId: string, now: number): TelemetryState
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
        statsD = Helpers.newRollingStat(),
        statsVr = Helpers.newRollingStat(),
        statsAr = Helpers.newRollingStat(),
        statsJr = Helpers.newRollingStat(),
        lastUpdate = now,
        triggerTime = nil,
        latencySampled = true,
        targetingActive = false,
        targetingPulses = {},
        targetingBurstCount = 0,
        targetingBurstRate = 0,
        targetingMinInterval = nil,
        targetingLastInterval = nil,
        lastTargetingPulse = nil,
        lastTargetingDrop = nil,
        lastTargetingSpam = 0,
        lastTargetingApplied = 0,
        targetingAggression = 0,
        targetingMomentum = 0,
        targetingAggressionUpdatedAt = now,
        targetingLastAggressionSpike = nil,
        targetingSpeedUrgency = 0,
        targetingSpeedUpdatedAt = now,
        targetingAggressionPulseStamp = nil,
        pressHistory = {},
        pressRate = 0,
        lastPressGap = nil,
        lastPressAt = nil,
        targetDetectedAt = nil,
        decisionAt = nil,
        lastReactionLatency = nil,
        lastReactionTimestamp = nil,
        lastDecisionLatency = nil,
        lastDecisionToPressLatency = nil,
        ballisticCache = nil,
        threat = nil,
    }

    telemetryStates[ballId] = telemetry
    return telemetry
end

function Helpers.cleanupTelemetry(now: number)
    for id, telemetry in pairs(telemetryStates) do
        if now - (telemetry.lastUpdate or 0) > telemetryTimeoutSeconds then
            telemetryStates[id] = nil
        end
    end
end

function Helpers.resetActivationLatency()
    activationLatencyEstimate = config.activationLatency or Defaults.CONFIG.activationLatency or 0
    if activationLatencyEstimate < 0 then
        activationLatencyEstimate = 0
    end
    perfectParrySnapshot.mu = 0
    perfectParrySnapshot.sigma = 0
    perfectParrySnapshot.delta = 0
    perfectParrySnapshot.z = config.confidenceZ or Defaults.CONFIG.confidenceZ or perfectParrySnapshot.z
    latencySamples.lastSample = nil
    latencySamples.lastLocalSample = nil
    latencySamples.lastRemoteSample = nil
    pendingLatencyPresses = {}
    Helpers.publishLatencyTelemetry()
end

local AutoParry

function Helpers.cloneTable(tbl)
    return Util.deepCopy(tbl)
end

function Helpers.updateTelemetrySummaryTrend(summary, now)
    now = now or os.clock()

    local trend = Context.runtime.telemetrySummaryTrend
    if not trend then
        trend = { momentum = 0, samples = 0, last = nil, updatedAt = 0 }
        Context.runtime.telemetrySummaryTrend = trend
    end

    if summary == nil then
        trend.momentum = 0
        trend.samples = 0
        trend.last = nil
        trend.updatedAt = now
        return trend
    end

    trend.updatedAt = now

    local previous = trend.last
    if not previous then
        trend.momentum = 0
        trend.samples = 0
        trend.last = Helpers.cloneTable(summary)
        return trend
    end

    local deltaScore = 0
    local deltaSamples = 0

    local function accumulateDelta(current, old, scale, clampLimit)
        if not Helpers.isFiniteNumber(current) or not Helpers.isFiniteNumber(old) then
            return
        end

        local diff = current - old
        if not Helpers.isFiniteNumber(diff) then
            return
        end

        if not Helpers.isFiniteNumber(scale) or scale <= 0 then
            return
        end

        local normalized = diff / scale
        if clampLimit then
            normalized = math.clamp(normalized, -clampLimit, clampLimit)
        else
            normalized = math.clamp(normalized, -3, 3)
        end

        deltaScore += normalized
        deltaSamples += 1
    end

    accumulateDelta(summary.averageWaitDelta, previous.averageWaitDelta, 0.005, 2.5)
    accumulateDelta(summary.averageLatency, previous.averageLatency, 0.015, 2.5)
    accumulateDelta(summary.immediateRate, previous.immediateRate, 0.06, 2)
    accumulateDelta(summary.averageThreatSpeed, previous.averageThreatSpeed, 35, 2)
    accumulateDelta(summary.averageThreatTempo, previous.averageThreatTempo, 10, 2)
    accumulateDelta(summary.averageThreatVolatility, previous.averageThreatVolatility, 6, 2)
    accumulateDelta(summary.scheduleLookaheadP10, previous.scheduleLookaheadP10, 0.03, 2.5)

    local averageDelta = 0
    if deltaSamples > 0 then
        averageDelta = deltaScore / deltaSamples
    end

    trend.momentum = Helpers.emaScalar(trend.momentum or 0, math.clamp(averageDelta, -2.5, 2.5), 0.5)
    trend.samples = math.min((trend.samples or 0) + deltaSamples, 64)
    trend.last = Helpers.cloneTable(summary)

    return trend
end

function Helpers.cloneAutoTuningSnapshot()
    return {
        enabled = autoTuningState.enabled,
        intervalSeconds = autoTuningState.intervalSeconds,
        minSamples = autoTuningState.minSamples,
        allowWhenSmartTuning = autoTuningState.allowWhenSmartTuning,
        dryRun = autoTuningState.dryRun,
        leadGain = autoTuningState.leadGain,
        slackGain = autoTuningState.slackGain,
        latencyGain = autoTuningState.latencyGain,
        leadTolerance = autoTuningState.leadTolerance,
        waitTolerance = autoTuningState.waitTolerance,
        maxReactionBias = autoTuningState.maxReactionBias,
        maxScheduleSlack = autoTuningState.maxScheduleSlack,
        maxActivationLatency = autoTuningState.maxActivationLatency,
        minDelta = autoTuningState.minDelta,
        maxAdjustmentsPerRun = autoTuningState.maxAdjustmentsPerRun,
        lastRun = autoTuningState.lastRun,
        lastStatus = autoTuningState.lastStatus,
        lastError = autoTuningState.lastError,
        lastSummary = autoTuningState.lastSummary and Helpers.cloneTable(autoTuningState.lastSummary) or nil,
        lastAdjustments = autoTuningState.lastAdjustments and Helpers.cloneTable(autoTuningState.lastAdjustments) or nil,
        lastResult = autoTuningState.lastResult and Helpers.cloneTable(autoTuningState.lastResult) or nil,
    }
end

captureScheduledPressSnapshot = function(ballId)
    if not ballId or Context.scheduledPressState.ballId ~= ballId then
        return nil
    end

    local snapshot = {
        ballId = ballId,
        pressAt = Context.scheduledPressState.pressAt,
        predictedImpact = Context.scheduledPressState.predictedImpact,
        lead = Context.scheduledPressState.lead,
        slack = Context.scheduledPressState.slack,
        reason = Context.scheduledPressState.reason,
        scheduleTime = Context.scheduledPressState.lastUpdate,
        immediate = Context.scheduledPressState.immediate,
    }

    if Context.scheduledPressState.smartTuning then
        snapshot.smartTuning = Helpers.cloneTable(Context.scheduledPressState.smartTuning)
    end

    return snapshot
end

function Helpers.resetSmartTuningState()
    smartTuningState.enabled = false
    smartTuningState.lastUpdate = 0
    smartTuningState.lastBallId = nil
    smartTuningState.baseReactionBias = 0
    smartTuningState.baseScheduleSlack = 0
    smartTuningState.baseConfidencePadding = 0
    smartTuningState.targetReactionBias = 0
    smartTuningState.targetScheduleSlack = 0
    smartTuningState.targetConfidencePadding = 0
    smartTuningState.reactionBias = nil
    smartTuningState.scheduleSlack = nil
    smartTuningState.confidencePadding = nil
    smartTuningState.sigma = 0
    smartTuningState.mu = 0
    smartTuningState.muPlus = 0
    smartTuningState.muMinus = 0
    smartTuningState.delta = 0
    smartTuningState.ping = 0
    smartTuningState.overshoot = 0
    smartTuningState.scheduleLead = 0
    smartTuningState.updateCount = 0
end

function Helpers.snapshotSmartTuningState()
    return Helpers.cloneTable(smartTuningState)
end

function Helpers.normalizeSmartTuningConfig(value)
    if value == false then
        return false
    end

    local base = Util.deepCopy(Defaults.SMART_TUNING)

    if value == nil then
        return base
    end

    if value == true then
        return base
    end

    if typeof(value) ~= "table" then
        error("AutoParry.configure: smartTuning expects a table, boolean, or nil", 0)
    end

    for key, entry in pairs(value) do
        if entry ~= nil then
            base[key] = entry
        end
    end

    if value.enabled == false then
        base.enabled = false
    else
        base.enabled = base.enabled ~= false
    end

    return base
end

function Helpers.normalizeSmartTuningPayload(payload)
    if typeof(payload) ~= "table" then
        return payload
    end

    if payload.applied ~= nil and payload.base ~= nil and payload.target ~= nil then
        return payload
    end

    local normalized = {
        enabled = payload.enabled ~= false,
        delta = payload.delta,
        latency = payload.latency or payload.delta,
        scheduleLead = payload.scheduleLead,
        sigma = payload.sigma,
        mu = payload.mu,
        muPlus = payload.muPlus,
        muMinus = payload.muMinus,
        overshoot = payload.overshoot,
        ping = payload.ping,
        updateCount = payload.updateCount,
        base = {
            reactionBias = payload.baseReactionBias,
            scheduleSlack = payload.baseScheduleSlack,
            confidencePadding = payload.baseConfidencePadding,
        },
        target = {
            reactionBias = payload.targetReactionBias or payload.reactionBias,
            scheduleSlack = payload.targetScheduleSlack or payload.scheduleSlack,
            confidencePadding = payload.targetConfidencePadding or payload.confidencePadding,
            scheduleLead = payload.scheduleLead,
        },
        applied = {
            reactionBias = payload.reactionBias,
            scheduleSlack = payload.scheduleSlack,
            confidencePadding = payload.confidencePadding,
            scheduleLead = payload.scheduleLead,
        },
    }

    return normalized
end

function Helpers.getSmartTuningConfig()
    local tuning = config.smartTuning
    if tuning == false then
        return false
    end
    if typeof(tuning) == "table" then
        return tuning
    end
    return Defaults.CONFIG.smartTuning
end

function Helpers.resolvePerformanceTargets()
    local smartConfig = Helpers.getSmartTuningConfig()

    local commitTarget = Defaults.SMART_TUNING.commitP99Target or 0.01
    if smartConfig and smartConfig ~= false and Helpers.isFiniteNumber(smartConfig.commitP99Target) then
        commitTarget = smartConfig.commitP99Target
    end
    if not Helpers.isFiniteNumber(commitTarget) or commitTarget <= 0 then
        commitTarget = 0.01
    end

    local lookaheadGoal = config.pressLookaheadGoal
    if lookaheadGoal == nil then
        lookaheadGoal = Defaults.CONFIG.pressLookaheadGoal
    end
    if smartConfig and smartConfig ~= false and Helpers.isFiniteNumber(smartConfig.lookaheadGoal) then
        lookaheadGoal = smartConfig.lookaheadGoal
    end
    if not Helpers.isFiniteNumber(lookaheadGoal) then
        lookaheadGoal = Defaults.SMART_TUNING.lookaheadGoal or 0
    end
    if not Helpers.isFiniteNumber(lookaheadGoal) or lookaheadGoal < 0 then
        lookaheadGoal = 0
    end

    local reactionTarget = config.pressReactionBias
    if reactionTarget == nil then
        reactionTarget = Defaults.CONFIG.pressReactionBias
    end
    if smartConfig and smartConfig ~= false and Helpers.isFiniteNumber(smartConfig.reactionBiasTarget) then
        reactionTarget = smartConfig.reactionBiasTarget
    elseif smartConfig and smartConfig ~= false and Helpers.isFiniteNumber(smartConfig.reactionBias) then
        reactionTarget = smartConfig.reactionBias
    end
    if not Helpers.isFiniteNumber(reactionTarget) or reactionTarget < 0 then
        reactionTarget = Defaults.CONFIG.pressReactionBias or 0
    end

    return commitTarget, lookaheadGoal, reactionTarget
end

function Helpers.applySmartTuning(params)
    local tuning = Helpers.getSmartTuningConfig()
    local now = params.now or os.clock()

    if not tuning or tuning == false or tuning.enabled == false then
        if smartTuningState.enabled then
            Helpers.resetSmartTuningState()
            smartTuningState.lastUpdate = now
            smartTuningState.lastBallId = params.ballId
        end
        return nil
    end

    smartTuningState.enabled = true
    smartTuningState.lastUpdate = now
    smartTuningState.lastBallId = params.ballId

    local baseReactionBias = params.baseReactionBias or 0
    local baseScheduleSlack = params.baseScheduleSlack or 0
    local baseConfidencePadding = params.baseConfidencePadding or 0

    smartTuningState.baseReactionBias = baseReactionBias
    smartTuningState.baseScheduleSlack = baseScheduleSlack
    smartTuningState.baseConfidencePadding = baseConfidencePadding

    local sigma = params.sigma
    if not Helpers.isFiniteNumber(sigma) or sigma < 0 then
        sigma = 0
    end
    local sigmaFloor = math.max(tuning.sigmaFloor or 0, 0)
    if sigma < sigmaFloor then
        sigma = sigmaFloor
    end
    smartTuningState.sigma = sigma

    smartTuningState.mu = params.mu or 0
    smartTuningState.muPlus = params.muPlus or 0
    smartTuningState.muMinus = params.muMinus or 0

    local delta = params.delta
    if not Helpers.isFiniteNumber(delta) or delta < 0 then
        delta = 0
    end
    local deltaAlpha = math.clamp(tuning.deltaAlpha or 0.2, 0, 1)
    smartTuningState.delta = Helpers.emaScalar(smartTuningState.delta, delta, deltaAlpha)

    local ping = params.ping
    if not Helpers.isFiniteNumber(ping) or ping < 0 then
        ping = 0
    end
    local pingAlpha = math.clamp(tuning.pingAlpha or 0.3, 0, 1)
    smartTuningState.ping = Helpers.emaScalar(smartTuningState.ping, ping, pingAlpha)

    local overshoot = params.muPlus
    if not Helpers.isFiniteNumber(overshoot) or overshoot < 0 then
        overshoot = 0
    end
    local overshootAlpha = math.clamp(tuning.overshootAlpha or 0.25, 0, 1)
    smartTuningState.overshoot = Helpers.emaScalar(smartTuningState.overshoot, overshoot, overshootAlpha)

    local metrics = TelemetryAnalytics.metrics
    local commitSummary
    local lookaheadSummary
    if typeof(metrics) == "table" and typeof(metrics.quantiles) == "table" then
        commitSummary = Helpers.summariseQuantileEstimator(metrics.quantiles.commitLatency)
        lookaheadSummary = Helpers.summariseQuantileEstimator(metrics.quantiles.scheduleLookahead)
    end

    local commitP99 = commitSummary and commitSummary.value or nil
    local commitSamples = commitSummary and commitSummary.count or 0
    local lookaheadP10 = lookaheadSummary and lookaheadSummary.value or nil
    local lookaheadSamples = lookaheadSummary and lookaheadSummary.count or 0
    local commitTarget, lookaheadGoal = Helpers.resolvePerformanceTargets()
    if params and Helpers.isFiniteNumber(params.lookaheadGoal) and params.lookaheadGoal > 0 then
        lookaheadGoal = params.lookaheadGoal
    end

    local minSlack = math.max(tuning.minSlack or 0, 0)
    local maxSlack = tuning.maxSlack or math.max(minSlack, 0.08)
    if maxSlack < minSlack then
        maxSlack = minSlack
    end
    local slackTarget = math.clamp(sigma * (tuning.sigmaLead or 1), minSlack, maxSlack)

    if commitTarget > 0 and commitSamples >= 6 and Helpers.isFiniteNumber(commitP99) and commitP99 > commitTarget then
        local overshoot = commitP99 - commitTarget
        local slackGain = math.max(tuning.commitSlackGain or 0, 0)
        if slackGain > 0 then
            slackTarget = math.max(slackTarget - overshoot * slackGain, minSlack)
        end
    end

    if lookaheadGoal > 0 and lookaheadSamples >= 4 and Helpers.isFiniteNumber(lookaheadP10) and lookaheadP10 < lookaheadGoal then
        local deficit = lookaheadGoal - lookaheadP10
        local slackGain = math.max(tuning.lookaheadSlackGain or 0, 0)
        if slackGain > 0 then
            slackTarget = math.min(math.max(slackTarget + deficit * slackGain, minSlack), maxSlack)
        end
    end

    if tuning.enforceBaseSlack ~= false then
        slackTarget = math.max(slackTarget, baseScheduleSlack)
    end
    smartTuningState.targetScheduleSlack = slackTarget
    local slackAlpha = math.clamp(tuning.slackAlpha or 0.35, 0, 1)
    smartTuningState.scheduleSlack = Helpers.emaScalar(smartTuningState.scheduleSlack or baseScheduleSlack, slackTarget, slackAlpha)

    local minConfidence = math.max(tuning.minConfidence or 0, 0)
    local maxConfidence = tuning.maxConfidence or math.max(minConfidence, 0.4)
    if maxConfidence < minConfidence then
        maxConfidence = minConfidence
    end
    local confidenceTarget = math.clamp(sigma * (tuning.sigmaConfidence or 0.85), minConfidence, maxConfidence)
    if tuning.enforceBaseConfidence ~= false then
        confidenceTarget = math.max(confidenceTarget, baseConfidencePadding)
    end
    smartTuningState.targetConfidencePadding = confidenceTarget
    local confidenceAlpha = math.clamp(tuning.confidenceAlpha or 0.3, 0, 1)
    smartTuningState.confidencePadding = Helpers.emaScalar(
        smartTuningState.confidencePadding or baseConfidencePadding,
        confidenceTarget,
        confidenceAlpha
    )

    local minReaction = math.max(tuning.minReactionBias or 0, 0)
    local maxReaction = tuning.maxReactionBias or math.max(minReaction, 0.16)
    if maxReaction < minReaction then
        maxReaction = minReaction
    end
    local reactionTarget = smartTuningState.delta * (tuning.reactionLatencyShare or 0.4)
    reactionTarget += smartTuningState.overshoot * (tuning.overshootShare or 0.2)
    reactionTarget = math.clamp(reactionTarget, minReaction, maxReaction)

    if commitTarget > 0 and commitSamples >= 6 and Helpers.isFiniteNumber(commitP99) then
        local overshoot = commitP99 - commitTarget
        local reactionGain = math.max(tuning.commitReactionGain or 0, 0)
        if overshoot > 0 and reactionGain > 0 then
            reactionTarget = math.min(reactionTarget + overshoot * reactionGain, maxReaction)
        elseif overshoot < -commitTarget * 0.4 and reactionGain > 0 then
            local relief = math.min(-overshoot, commitTarget) * reactionGain * 0.5
            reactionTarget = math.max(reactionTarget - relief, minReaction)
        end
    end

    if lookaheadGoal > 0 and lookaheadSamples >= 4 and Helpers.isFiniteNumber(lookaheadP10) then
        local deficit = lookaheadGoal - lookaheadP10
        local lookaheadGain = math.max(tuning.lookaheadReactionGain or 0, 0)
        if deficit > 0 and lookaheadGain > 0 then
            reactionTarget = math.max(reactionTarget - deficit * lookaheadGain, minReaction)
        elseif deficit < -lookaheadGoal * 0.5 and lookaheadGain > 0 then
            reactionTarget = math.min(reactionTarget + (-deficit) * lookaheadGain * 0.5, maxReaction)
        end
    end

    if tuning.enforceBaseReaction ~= false then
        reactionTarget = math.max(reactionTarget, baseReactionBias)
    end
    smartTuningState.targetReactionBias = reactionTarget
    local reactionAlpha = math.clamp(tuning.reactionAlpha or 0.25, 0, 1)
    smartTuningState.reactionBias = Helpers.emaScalar(
        smartTuningState.reactionBias or baseReactionBias,
        reactionTarget,
        reactionAlpha
    )

    smartTuningState.updateCount += 1

    return {
        reactionBias = smartTuningState.reactionBias,
        scheduleSlack = smartTuningState.scheduleSlack,
        confidencePadding = smartTuningState.confidencePadding,
        telemetry = {
            enabled = true,
            base = {
                reactionBias = baseReactionBias,
                scheduleSlack = baseScheduleSlack,
                confidencePadding = baseConfidencePadding,
            },
            target = {
                reactionBias = smartTuningState.targetReactionBias,
                scheduleSlack = smartTuningState.targetScheduleSlack,
                confidencePadding = smartTuningState.targetConfidencePadding,
            },
            applied = {
                reactionBias = smartTuningState.reactionBias,
                scheduleSlack = smartTuningState.scheduleSlack,
                confidencePadding = smartTuningState.confidencePadding,
            },
            sigma = smartTuningState.sigma,
            delta = smartTuningState.delta,
            ping = smartTuningState.ping,
            overshoot = smartTuningState.overshoot,
            mu = smartTuningState.mu,
            muPlus = smartTuningState.muPlus,
            muMinus = smartTuningState.muMinus,
            updateCount = smartTuningState.updateCount,
        },
    }
end

function Helpers.ensureTelemetryStore()
    local settings = Helpers.ensurePawsSettings()
    local telemetryStore = settings.Telemetry
    if typeof(telemetryStore) ~= "table" then
        telemetryStore = {}
        settings.Telemetry = telemetryStore
    end
    return settings, telemetryStore
end

function Helpers.cloneTelemetryEvent(event)
    if typeof(event) ~= "table" then
        return event
    end
    return Helpers.cloneTable(event)
end

publishTelemetryHistory = function()
    local settings, telemetryStore = Helpers.ensureTelemetryStore()
    telemetryStore.history = Context.telemetry.history
    telemetryStore.sequence = Context.telemetry.sequence
    telemetryStore.lastEvent = Context.telemetry.history[#Context.telemetry.history]
    telemetryStore.smartTuning = Helpers.snapshotSmartTuningState()
    telemetryStore.metrics = TelemetryAnalytics.clone()
    local summary
    if telemetryStore.metrics then
        telemetryStore.adaptiveState = telemetryStore.metrics.adaptiveState
        summary = TelemetryAnalytics.computeSummary(telemetryStore.metrics)
    else
        telemetryStore.adaptiveState = {
            reactionBias = TelemetryAnalytics.adaptiveState and TelemetryAnalytics.adaptiveState.reactionBias or 0,
            lastUpdate = TelemetryAnalytics.adaptiveState and TelemetryAnalytics.adaptiveState.lastUpdate or 0,
        }
    end

    if summary then
        telemetryStore.summary = Helpers.cloneTable(summary)
        Context.runtime.telemetrySummary = Helpers.cloneTable(summary)
        Helpers.updateTelemetrySummaryTrend(summary, os.clock())
    else
        telemetryStore.summary = nil
        Context.runtime.telemetrySummary = nil
        Helpers.updateTelemetrySummaryTrend(nil, os.clock())
    end
    return settings, telemetryStore
end

telemetryDispatcher = function(eventType: string, payload: { [string]: any }?)
    Context.telemetry.sequence += 1

    local event: { [string]: any } = {}
    if typeof(payload) == "table" then
        event = Helpers.cloneTelemetryEvent(payload)
    elseif payload ~= nil then
        event.value = payload
    end

    event.type = eventType
    event.sequence = Context.telemetry.sequence
    event.time = event.time or os.clock()

    Context.telemetry.history[#Context.telemetry.history + 1] = event
    if #Context.telemetry.history > Context.telemetry.historyLimit then
        table.remove(Context.telemetry.history, 1)
    end

    publishTelemetryHistory()
    telemetrySignal:fire(Helpers.cloneTelemetryEvent(event))
    return event
end

flushPendingTelemetryEvents()

function Helpers.resetTelemetryHistory(reason: string?)
    local previousResets = 0
    if TelemetryAnalytics.metrics and TelemetryAnalytics.metrics.counters and typeof(TelemetryAnalytics.metrics.counters.resets) == "number" then
        previousResets = TelemetryAnalytics.metrics.counters.resets
    end
    TelemetryAnalytics.resetMetrics(previousResets + 1)
    TelemetryAnalytics.resetAdaptive()
    Context.telemetry.history = {}
    Context.runtime.telemetrySummary = nil
    publishTelemetryHistory()
    if reason then
        emitTelemetryEvent("telemetry-reset", { reason = reason })
    end
end

publishTelemetryHistory()

Helpers.resetActivationLatency()
Helpers.resetSmartTuningState()

function Helpers.safeCall(fn, ...)
    if typeof(fn) == "function" then
        return fn(...)
    end
end

function Helpers.safeDisconnect(connection)
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

function Helpers.disconnectConnections(connections)
    for index = #connections, 1, -1 do
        local connection = connections[index]
        Helpers.safeDisconnect(connection)
        connections[index] = nil
    end
end

function Helpers.connectSignal(signal, handler)
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

function Helpers.connectInstanceEvent(instance, eventName, handler)
    if not instance or typeof(handler) ~= "function" then
        return nil
    end

    local ok, event = pcall(function()
        return instance[eventName]
    end)

    if not ok or event == nil then
        return nil
    end

    return Helpers.connectSignal(event, handler)
end

function Helpers.connectPropertyChangedSignal(instance, propertyName, handler)
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

    return Helpers.connectSignal(signal, handler)
end

function Helpers.connectClientEvent(remote, handler)
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

function Helpers.rebuildRemoteQueueGuardTargets()
    for name in pairs(remoteQueueGuardTargets) do
        remoteQueueGuardTargets[name] = nil
    end

    local defaults = Defaults.CONFIG.remoteQueueGuards
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

Helpers.rebuildRemoteQueueGuardTargets()

function Helpers.clearRemoteQueueGuards()
    if Context.watchers.remoteQueueGuardWatchers then
        Helpers.disconnectConnections(Context.watchers.remoteQueueGuardWatchers)
        Context.watchers.remoteQueueGuardWatchers = nil
    end

    for name, guard in pairs(Context.watchers.remoteQueueGuards) do
        Helpers.safeDisconnect(guard.connection)
        Helpers.safeDisconnect(guard.destroying)
        Helpers.safeDisconnect(guard.nameChanged)
        Context.watchers.remoteQueueGuards[name] = nil
    end
end

function Helpers.dropRemoteQueueGuard(remote)
    if not remote then
        return
    end

    local name = remote.Name
    local guard = Context.watchers.remoteQueueGuards[name]
    if guard and guard.remote == remote then
        Helpers.safeDisconnect(guard.connection)
        Helpers.safeDisconnect(guard.destroying)
        Helpers.safeDisconnect(guard.nameChanged)
        Context.watchers.remoteQueueGuards[name] = nil
    end
end

function Helpers.attachRemoteQueueGuard(remote)
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
    local existing = Context.watchers.remoteQueueGuards[name]
    if existing and existing.remote == remote and existing.connection then
        return
    end

    if existing then
        Helpers.safeDisconnect(existing.connection)
        Helpers.safeDisconnect(existing.destroying)
        Helpers.safeDisconnect(existing.nameChanged)
        Context.watchers.remoteQueueGuards[name] = nil
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

    local destroyingConnection = Helpers.connectInstanceEvent(remote, "Destroying", function()
        Helpers.dropRemoteQueueGuard(remote)
    end)

    local nameChangedConnection = Helpers.connectPropertyChangedSignal(remote, "Name", function()
        local newName = remote.Name
        if not remoteQueueGuardTargets[newName] then
            Helpers.dropRemoteQueueGuard(remote)
            return
        end

        local existingGuard = Context.watchers.remoteQueueGuards[newName]
        if existingGuard and existingGuard.remote ~= remote then
            Helpers.dropRemoteQueueGuard(existingGuard.remote)
        end

        local currentGuard = Context.watchers.remoteQueueGuards[name]
        if currentGuard and currentGuard.remote == remote then
            Context.watchers.remoteQueueGuards[name] = nil
            Context.watchers.remoteQueueGuards[newName] = currentGuard
        end

        name = newName
    end)

    Context.watchers.remoteQueueGuards[name] = {
        remote = remote,
        connection = connection,
        destroying = destroyingConnection,
        nameChanged = nameChangedConnection,
    }
end

function Helpers.setRemoteQueueGuardFolder(folder)
    Helpers.clearRemoteQueueGuards()

    if not folder then
        return
    end

    for name in pairs(remoteQueueGuardTargets) do
        local remote = folder:FindFirstChild(name)
        if remote then
            Helpers.attachRemoteQueueGuard(remote)
        end
    end

    local watchers = {}

    local addedConnection = folder.ChildAdded:Connect(function(child)
        Helpers.attachRemoteQueueGuard(child)
    end)
    table.insert(watchers, addedConnection)

    local removedConnection = folder.ChildRemoved:Connect(function(child)
        Helpers.dropRemoteQueueGuard(child)
    end)
    table.insert(watchers, removedConnection)

    local destroyingConnection = Helpers.connectInstanceEvent(folder, "Destroying", function()
        Helpers.clearRemoteQueueGuards()
    end)
    if destroyingConnection then
        table.insert(watchers, destroyingConnection)
    end

    Context.watchers.remoteQueueGuardWatchers = watchers
end

function Helpers.disconnectVerificationWatchers()
    for index = #Context.watchers.verification, 1, -1 do
        local connections = Context.watchers.verification[index]
        if connections then
            Helpers.disconnectConnections(connections)
        end
        Context.watchers.verification[index] = nil
    end
end

function Helpers.disconnectSuccessListeners()
    Helpers.disconnectConnections(Context.watchers.success)
    Context.watchers.successSnapshot = nil
    if state.remoteEstimatorActive then
        state.remoteEstimatorActive = false
        Helpers.publishLatencyTelemetry()
    end
end

function Helpers.clearRemoteState()
    Helpers.disconnectVerificationWatchers()
    Helpers.disconnectSuccessListeners()
    Context.player.ParryInputInfo = nil
    Context.player.RemotesFolder = nil
    Helpers.clearRemoteQueueGuards()
    if Context.watchers.ballsConnections then
        Helpers.disconnectConnections(Context.watchers.ballsConnections)
        Context.watchers.ballsConnections = nil
    end
    Context.player.BallsFolder = nil
    Context.player.WatchedBallsFolder = nil
    pendingBallsFolderSearch = false
    Context.watchers.ballsSnapshot = nil
    pendingLatencyPresses = {}
    if Context.runtime.syncImmortalContext then
        Context.runtime.syncImmortalContext()
    end
end

function Helpers.configureSuccessListeners(successRemotes)
    Helpers.disconnectSuccessListeners()

    local status = {
        ParrySuccess = false,
        ParrySuccessAll = false,
    }

    if not successRemotes then
        Context.watchers.successSnapshot = status
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

        local connection = Helpers.connectClientEvent(remote, callback)
        if connection then
            table.insert(Context.watchers.success, connection)
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
    Helpers.publishLatencyTelemetry()

    Context.watchers.successSnapshot = status
    return status
end

function Helpers.watchResource(instance, reason)
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
        Context.runtime.scheduleRestart(reason)
    end

    local parentConnection = Helpers.connectPropertyChangedSignal(instance, "Parent", function()
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

    local ancestryConnection = Helpers.connectInstanceEvent(instance, "AncestryChanged", function(_, parent)
        if parent == nil then
            restart()
        end
    end)

    if ancestryConnection then
        table.insert(connections, ancestryConnection)
    end

    local destroyingConnection = Helpers.connectInstanceEvent(instance, "Destroying", function()
        restart()
    end)

    if destroyingConnection then
        table.insert(connections, destroyingConnection)
    end

    if #connections > 0 then
        table.insert(Context.watchers.verification, connections)
    end
end


Context.runtime.scheduleRestart = function(reason)
    if Context.runtime.restartPending or initialization.destroyed then
        return
    end

    Context.runtime.restartPending = true
    initialization.completed = false
    initialization.token += 1
    initialization.started = false
    initialization.error = nil

    local payload = { stage = "restarting", reason = reason }

    if Context.player.ParryInputInfo then
        if Context.player.ParryInputInfo.remoteName then
            payload.remoteName = Context.player.ParryInputInfo.remoteName
        end
        if Context.player.ParryInputInfo.variant then
            payload.remoteVariant = Context.player.ParryInputInfo.variant
        end
        if Context.player.ParryInputInfo.className then
            payload.remoteClass = Context.player.ParryInputInfo.className
        end
        if Context.player.ParryInputInfo.keyCode then
            payload.inputKey = Context.player.ParryInputInfo.keyCode
        end
        if Context.player.ParryInputInfo.method then
            payload.inputMethod = Context.player.ParryInputInfo.method
        end
    end

    Helpers.applyInitStatus(payload)

    task.defer(function()
        Context.runtime.restartPending = false
        if initialization.destroyed then
            return
        end

        Helpers.clearRemoteState()
        Helpers.beginInitialization()
    end)
end

function Helpers.setBallsFolderWatcher(folder)
    if Context.watchers.ballsConnections then
        Helpers.disconnectConnections(Context.watchers.ballsConnections)
        Context.watchers.ballsConnections = nil
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
        Context.runtime.scheduleRestart(reason)
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

    local parentConnection = Helpers.connectPropertyChangedSignal(folder, "Parent", function()
        if currentParent() == nil then
            restart("balls-folder-missing")
        end
    end)
    if parentConnection then
        table.insert(connections, parentConnection)
    end

    local ancestryConnection = Helpers.connectInstanceEvent(folder, "AncestryChanged", function(_, parent)
        if parent == nil then
            restart("balls-folder-missing")
        end
    end)
    if ancestryConnection then
        table.insert(connections, ancestryConnection)
    end

    local destroyingConnection = Helpers.connectInstanceEvent(folder, "Destroying", function()
        restart("balls-folder-missing")
    end)
    if destroyingConnection then
        table.insert(connections, destroyingConnection)
    end

    local nameConnection = Helpers.connectPropertyChangedSignal(folder, "Name", function()
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

    Context.watchers.ballsConnections = connections
end

function Helpers.applyInitStatus(update)
    for key in pairs(initProgress) do
        if update[key] == nil and key ~= "stage" then
            initProgress[key] = initProgress[key]
        end
    end

    for key, value in pairs(update) do
        initProgress[key] = value
    end

    initStatus:fire(Helpers.cloneTable(initProgress))
end

Context.hooks.setStage = function(stage, extra)
    local payload = { stage = stage }
    if typeof(extra) == "table" then
        for key, value in pairs(extra) do
            payload[key] = value
        end
    end
    Helpers.applyInitStatus(payload)
end

function Helpers.formatToggleText(enabled)
    return enabled and "Auto-Parry: ON" or "Auto-Parry: OFF"
end

function Helpers.formatToggleColor(enabled)
    if enabled then
        return Color3.fromRGB(0, 120, 0)
    end
    return Color3.fromRGB(40, 40, 40)
end

function Helpers.formatImmortalText(enabled)
    if enabled then
        return "IMMORTAL: ON"
    end
    return "IMMORTAL: OFF"
end

function Helpers.formatImmortalColor(enabled)
    if enabled then
        return Color3.fromRGB(0, 170, 85)
    end
    return Color3.fromRGB(40, 40, 40)
end

function Helpers.syncGlobalSettings()
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
    settings.SmartPress = {
        reactionBias = config.pressReactionBias,
        scheduleSlack = config.pressScheduleSlack,
        maxLookahead = config.pressMaxLookahead,
        confidencePadding = config.pressConfidencePadding,
    }
    settings.SmartTuning = Helpers.snapshotSmartTuningState()
    settings.AutoTuning = Helpers.cloneAutoTuningSnapshot()
end

function Helpers.updateToggleButton()
    local toggleButton = Context.ui.ToggleButton
    if not toggleButton then
        return
    end

    toggleButton.Text = Helpers.formatToggleText(state.enabled)
    toggleButton.BackgroundColor3 = Helpers.formatToggleColor(state.enabled)
end

function Helpers.updateImmortalButton()
    local immortalButton = Context.ui.ImmortalButton
    if not immortalButton then
        return
    end

    immortalButton.Text = Helpers.formatImmortalText(state.immortalEnabled)
    immortalButton.BackgroundColor3 = Helpers.formatImmortalColor(state.immortalEnabled)
end

Context.hooks.updateStatusLabel = function(lines)
    local statusLabel = Context.ui.StatusLabel
    if not statusLabel then
        return
    end

    if typeof(lines) == "table" then
        statusLabel.Text = table.concat(lines, "\n")
    else
        statusLabel.Text = tostring(lines)
    end
end

function Helpers.syncImmortalContextImpl()
    if not immortalController then
        return
    end

    local playerContext = Context.player
    local okContext = Helpers.callImmortalController("setContext", {
        player = playerContext.LocalPlayer,
        character = playerContext.Character,
        humanoid = playerContext.Humanoid,
        rootPart = playerContext.RootPart,
        ballsFolder = playerContext.BallsFolder,
    })

    if not okContext then
        return
    end

    if not Helpers.callImmortalController("setBallsFolder", playerContext.BallsFolder) then
        return
    end

    Helpers.callImmortalController("setEnabled", state.immortalEnabled)
end

Context.runtime.syncImmortalContext = Helpers.syncImmortalContextImpl

function Helpers.enterRespawnWaitState()
    local playerContext = Context.player
    local stageHook = Context.hooks.setStage
    if stageHook then
        if playerContext.LocalPlayer then
            stageHook("waiting-character", { player = playerContext.LocalPlayer.Name })
        else
            stageHook("waiting-character")
        end
    end

    Context.hooks.updateStatusLabel({ "Auto-Parry F", "Status: waiting for respawn" })
end

function Helpers.clearBallVisualsInternal()
    local ui = Context.ui
    local runtime = Context.runtime

    if ui.BallHighlight then
        ui.BallHighlight.Enabled = false
        ui.BallHighlight.Adornee = nil
    end
    if ui.BallBillboard then
        ui.BallBillboard.Enabled = false
        ui.BallBillboard.Adornee = nil
    end
    runtime.trackedBall = nil
end

function Helpers.safeClearBallVisuals()
    -- Some exploit environments aggressively nil out locals when reloading the
    -- module; guard the call so we gracefully fall back instead of throwing.
    if typeof(Helpers.clearBallVisualsInternal) == "function" then
        Helpers.clearBallVisualsInternal()
        return
    end

    local ui = Context.ui
    Context.runtime.trackedBall = nil

    if ui.BallHighlight then
        ui.BallHighlight.Enabled = false
        ui.BallHighlight.Adornee = nil
    end
    if ui.BallBillboard then
        ui.BallBillboard.Enabled = false
        ui.BallBillboard.Adornee = nil
    end
end

Context.hooks.sendParryKeyEvent = function(isPressed)
    local manager = Helpers.resolveVirtualInputManager()
    if not manager then
        if not Context.runtime.virtualInputWarningIssued then
            Context.runtime.virtualInputWarningIssued = true
            warn("AutoParry: VirtualInputManager unavailable; cannot issue parry input.")
        end
        Helpers.noteVirtualInputFailure(3)
        return false
    end

    local okMethod, method = pcall(function()
        return manager.SendKeyEvent
    end)

    if not okMethod or typeof(method) ~= "function" then
        if not Context.runtime.virtualInputWarningIssued then
            Context.runtime.virtualInputWarningIssued = true
            warn("AutoParry: VirtualInputManager.SendKeyEvent missing; cannot issue parry input.")
        end
        Helpers.noteVirtualInputFailure(3)
        return false
    end

    local success, result = pcall(method, manager, isPressed, Enum.KeyCode.F, false, game)
    if not success then
        if not Context.runtime.virtualInputWarningIssued then
            Context.runtime.virtualInputWarningIssued = true
            warn("AutoParry: failed to send parry input via VirtualInputManager:", result)
        end
        Helpers.noteVirtualInputFailure(2)
        return false
    end

    if Context.runtime.virtualInputWarningIssued then
        Context.runtime.virtualInputWarningIssued = false
    end

    Helpers.noteVirtualInputSuccess()

    return true
end

function Helpers.destroyDashboardUi()
    local coreGui = Services.CoreGui
    if not coreGui then
        return
    end

    for _, name in ipairs({ "AutoParryUI", "AutoParryLoadingOverlay" }) do
        local screen = coreGui:FindFirstChild(name)
        if screen then
            screen:Destroy()
        end
    end
end

function Helpers.removePlayerGuiUi()
    local player = Services.Players.LocalPlayer
    if not player then
        return
    end

    local playerGui
    local finder = player.FindFirstChildOfClass or player.FindFirstChildWhichIsA
    if typeof(finder) == "function" then
        local ok, result = pcall(finder, player, "PlayerGui")
        if ok then
            playerGui = result
        end
    end

    if not playerGui then
        return
    end

    if typeof(playerGui.FindFirstChild) == "function" then
        local ok, legacyScreen = pcall(playerGui.FindFirstChild, playerGui, "AutoParryF_UI")
        if ok and legacyScreen then
            legacyScreen:Destroy()
        end
    end
end

function Helpers.removeAutoParryExperience()
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
        Helpers.removePlayerGuiUi()
        Helpers.destroyDashboardUi()
    end)
    if not cleanupOk then
        warn("AutoParry: failed to clear UI:", cleanupErr)
    end
end

function Helpers.ensureUi()
    if Context.ui.Root or not Context.player.LocalPlayer then
        return
    end

    local playerGui
    if Context.player.LocalPlayer then
        local finder = Context.player.LocalPlayer.FindFirstChildOfClass or Context.player.LocalPlayer.FindFirstChildWhichIsA
        if typeof(finder) == "function" then
            local ok, result = pcall(finder, Context.player.LocalPlayer, "PlayerGui")
            if ok then
                playerGui = result
            end
        end

        if not playerGui and typeof(Context.player.LocalPlayer.WaitForChild) == "function" then
            local okWait, result = pcall(Context.player.LocalPlayer.WaitForChild, Context.player.LocalPlayer, "PlayerGui", 5)
            if okWait then
                playerGui = result
            end
        end
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
    toggleBtn.BackgroundColor3 = Helpers.formatToggleColor(state.enabled)
    toggleBtn.TextColor3 = Color3.new(1, 1, 1)
    toggleBtn.Font = Enum.Font.GothamBold
    toggleBtn.TextSize = 20
    toggleBtn.BorderSizePixel = 0
    toggleBtn.Text = Helpers.formatToggleText(state.enabled)
    toggleBtn.Parent = gui
    toggleBtn.MouseButton1Click:Connect(function()
        AutoParry.toggle()
    end)

    local immortalBtn = Instance.new("TextButton")
    immortalBtn.Size = UDim2.fromOffset(180, 34)
    immortalBtn.Position = UDim2.fromOffset(10, 54)
    immortalBtn.BackgroundColor3 = Helpers.formatImmortalColor(state.immortalEnabled)
    immortalBtn.TextColor3 = Color3.new(1, 1, 1)
    immortalBtn.Font = Enum.Font.GothamBold
    immortalBtn.TextSize = 18
    immortalBtn.BorderSizePixel = 0
    immortalBtn.Text = Helpers.formatImmortalText(state.immortalEnabled)
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
        Helpers.removeAutoParryExperience()
    end)

    local status = Instance.new("TextLabel")
    status.Name = "AutoParryStatus"
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

    Context.ui.Root = gui
    Context.ui.ToggleButton = toggleBtn
    Context.ui.ImmortalButton = immortalBtn
    Context.ui.RemoveButton = removeBtn
    Context.ui.StatusLabel = status
    Context.ui.BallHighlight = highlight
    Context.ui.BallBillboard = billboard
    Context.ui.BallStatsLabel = statsLabel

    Helpers.updateToggleButton()
    Helpers.updateImmortalButton()
    Context.hooks.updateStatusLabel({ "Auto-Parry F", "Status: initializing" })
end

function Helpers.destroyUi()
    Helpers.safeClearBallVisuals()
    if Context.ui.Root then
        Context.ui.Root:Destroy()
    end
    Context.ui.Root = nil
    Context.ui.ToggleButton = nil
    Context.ui.ImmortalButton = nil
    Context.ui.RemoveButton = nil
    Context.ui.StatusLabel = nil
    Context.ui.BallHighlight = nil
    Context.ui.BallBillboard = nil
    Context.ui.BallStatsLabel = nil
end

function Helpers.getPingTime()
    local now = os.clock()
    if now - pingSample.time < PING_REFRESH_INTERVAL then
        return pingSample.value
    end

    local seconds = pingSample.value
    if Services.Stats then
        local okStat, stat = pcall(function()
            return Services.Stats.Network.ServerStatsItem["Data Ping"]
        end)

        if okStat and stat then
            local okValue, value = pcall(stat.GetValue, stat)
            if okValue and value then
                seconds = value / 1000
            end
        end
    end

    if not Helpers.isFiniteNumber(seconds) or seconds < 0 then
        seconds = 0
    end

    pingSample.value = seconds
    pingSample.time = now

    return seconds
end

function Helpers.getPlayerRadialVelocity(unit: Vector3?)
    if typeof(unit) ~= "Vector3" then
        return 0
    end

    local root = Context.player.RootPart
    if not root then
        return 0
    end

    local velocity = root.AssemblyLinearVelocity
    if typeof(velocity) ~= "Vector3" then
        return 0
    end

    return unit:Dot(velocity)
end

function Helpers.isTargetingMe(now)
    if not Context.player.Character then
        Context.runtime.targetingGraceUntil = 0
        Context.runtime.targetingHighlightPresent = false
        Context.runtime.targetingHighlightGraceActive = false
        return false
    end

    local highlightName = config.targetHighlightName
    now = now or os.clock()

    if not highlightName or highlightName == "" then
        Context.runtime.targetingGraceUntil = math.max(Context.runtime.targetingGraceUntil, now + Constants.TARGETING_GRACE_SECONDS)
        return true
    end

    local ok, result = pcall(function()
        return Context.player.Character:FindFirstChild(highlightName)
    end)

    local runtime = Context.runtime
    local highlightPresent = ok and result ~= nil

    if highlightPresent then
        if runtime.targetingHighlightPresent ~= true then
            runtime.targetingHighlightPresent = true
            if runtime.targetingHighlightGraceActive then
                local queue = runtime.targetingHighlightPulseQueue
                if typeof(queue) ~= "table" then
                    queue = {}
                    runtime.targetingHighlightPulseQueue = queue
                end
                queue[#queue + 1] = now
            end
        end
        runtime.targetingHighlightGraceActive = false
        runtime.targetingGraceUntil = now + Constants.TARGETING_GRACE_SECONDS
        return true
    end

    if runtime.targetingHighlightPresent ~= false then
        runtime.targetingHighlightPresent = false
        local dropQueue = runtime.targetingHighlightDropQueue
        if typeof(dropQueue) ~= "table" then
            dropQueue = {}
            runtime.targetingHighlightDropQueue = dropQueue
        end
        dropQueue[#dropQueue + 1] = now
    end

    if runtime.targetingGraceUntil > now then
        runtime.targetingHighlightGraceActive = true
        return true
    end

    runtime.targetingHighlightGraceActive = false
    return false
end

function Helpers.findRealBall(folder)
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

function Helpers.isValidBallsFolder(candidate, expectedName)
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

function Helpers.ensureBallsFolder(allowYield: boolean?)
    local expectedName = config.ballsFolderName
    if typeof(expectedName) ~= "string" or expectedName == "" then
        return nil
    end

    if not Helpers.isValidBallsFolder(Context.player.BallsFolder, expectedName) then
        Context.player.BallsFolder = nil
        Context.player.WatchedBallsFolder = nil
        Helpers.setBallsFolderWatcher(nil)
        Context.runtime.syncImmortalContext()

        local found = Services.Workspace:FindFirstChild(expectedName)
        if Helpers.isValidBallsFolder(found, expectedName) then
            Context.player.BallsFolder = found
            Context.runtime.syncImmortalContext()
        end
    end

    if Context.player.BallsFolder then
        if Context.player.WatchedBallsFolder ~= Context.player.BallsFolder and initialization.completed then
            Helpers.setBallsFolderWatcher(Context.player.BallsFolder)
            Context.player.WatchedBallsFolder = Context.player.BallsFolder
            Context.hooks.publishReadyStatus()
        end

        Context.runtime.syncImmortalContext()
        return Context.player.BallsFolder
    end

    if allowYield then
        local timeout = config.ballsFolderTimeout
        local ok, result = pcall(function()
            if timeout and timeout > 0 then
                return Services.Workspace:WaitForChild(expectedName, timeout)
            end
            return Services.Workspace:WaitForChild(expectedName)
        end)

        if ok and Helpers.isValidBallsFolder(result, expectedName) then
            Context.player.BallsFolder = result

            if initialization.completed then
                Helpers.setBallsFolderWatcher(Context.player.BallsFolder)
                Context.player.WatchedBallsFolder = Context.player.BallsFolder
                Context.hooks.publishReadyStatus()
            end

            Context.runtime.syncImmortalContext()
            return Context.player.BallsFolder
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

            Helpers.ensureBallsFolder(true)
        end)
    end

    return nil
end

function Helpers.getBallsFolderLabel()
    local folderLabel = config.ballsFolderName
    local folder = Context.player.BallsFolder

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

function Context.hooks.publishReadyStatus()
    local payload = {
        stage = "ready",
        player = Context.player.LocalPlayer and Context.player.LocalPlayer.Name or "Unknown",
        ballsFolder = Helpers.getBallsFolderLabel(),
    }

    if Context.player.ParryInputInfo then
        if Context.player.ParryInputInfo.remoteName then
            payload.remoteName = Context.player.ParryInputInfo.remoteName
        end
        if Context.player.ParryInputInfo.className then
            payload.remoteClass = Context.player.ParryInputInfo.className
        end
        if Context.player.ParryInputInfo.variant then
            payload.remoteVariant = Context.player.ParryInputInfo.variant
        end
        if Context.player.ParryInputInfo.method then
            payload.remoteMethod = Context.player.ParryInputInfo.method
        end
        if Context.player.ParryInputInfo.keyCode then
            payload.inputKey = Context.player.ParryInputInfo.keyCode
        end
    end

    if Context.watchers.successSnapshot then
        payload.successEvents = Helpers.cloneTable(Context.watchers.successSnapshot)
    end

    if Context.watchers.ballsSnapshot then
        payload.ballsFolderStatus = Helpers.cloneTable(Context.watchers.ballsSnapshot)
    end

    Helpers.applyInitStatus(payload)
end

function Helpers.setBallVisuals(ball, text)
    if Context.ui.BallHighlight then
        Context.ui.BallHighlight.Adornee = ball
        Context.ui.BallHighlight.Enabled = ball ~= nil
    end
    if Context.ui.BallBillboard then
        Context.ui.BallBillboard.Adornee = ball
        Context.ui.BallBillboard.Enabled = ball ~= nil
    end
    if Context.ui.BallStatsLabel then
        Context.ui.BallStatsLabel.Text = text or ""
    end
    Context.runtime.trackedBall = ball
end

function Helpers.getBallIdentifier(ball)
    if not ball then
        return nil
    end

    local ok, id = pcall(ball.GetDebugId, ball, 0)
    if ok and typeof(id) == "string" then
        return id
    end

    return tostring(ball)
end


function Helpers.clearScheduledPress(targetBallId: string?, reason: string?, metadata: { [string]: any }?)
    if targetBallId and Context.scheduledPressState.ballId ~= targetBallId then
        return
    end

    local previousBallId = Context.scheduledPressState.ballId
    local previousPressAt = Context.scheduledPressState.pressAt
    local previousPredictedImpact = Context.scheduledPressState.predictedImpact
    local previousLead = Context.scheduledPressState.lead
    local previousSlack = Context.scheduledPressState.slack
    local previousReason = Context.scheduledPressState.reason
    local lastUpdate = Context.scheduledPressState.lastUpdate

    Context.scheduledPressState.ballId = nil
    Context.scheduledPressState.pressAt = 0
    Context.scheduledPressState.predictedImpact = math.huge
    Context.scheduledPressState.lead = 0
    Context.scheduledPressState.slack = 0
    Context.scheduledPressState.reason = nil
    Context.scheduledPressState.lastUpdate = 0
    Context.scheduledPressState.smartTuning = nil
    Context.scheduledPressState.immediate = false

    if previousBallId then
        local now = os.clock()
        local event = {
            ballId = previousBallId,
            reason = reason or "cleared",
            previousReason = previousReason,
            previousPressAt = previousPressAt,
            previousPredictedImpact = previousPredictedImpact,
            previousLead = previousLead,
            previousSlack = previousSlack,
            time = now,
        }
        if lastUpdate and lastUpdate > 0 then
            event.timeSinceUpdate = now - lastUpdate
        end
        if typeof(metadata) == "table" then
            for key, value in pairs(metadata) do
                if event[key] == nil then
                    event[key] = value
                end
            end
        end

        local snapshot = Context.scheduledPressState.lastSnapshot
        if snapshot and snapshot.ballId == previousBallId then
            snapshot.clearedReason = event.reason
            snapshot.clearedAt = now
            if typeof(metadata) == "table" then
                for key, value in pairs(metadata) do
                    if snapshot[key] == nil then
                        snapshot[key] = value
                    end
                end
            end
        end
        TelemetryAnalytics.recordScheduleCleared(event)
        emitTelemetryEvent("schedule-cleared", event)
    end
end

function Helpers.updateScheduledPress(
    ballId: string,
    predictedImpact: number,
    lead: number,
    slack: number,
    reason: string?,
    now: number,
    context: { [string]: any }?
)
    local pressDelay = math.max(predictedImpact - lead, 0)
    local pressAt = now + pressDelay

    if Context.scheduledPressState.ballId ~= ballId then
        Context.scheduledPressState.ballId = ballId
    elseif math.abs(Context.scheduledPressState.pressAt - pressAt) > Context.smartPress.triggerGrace then
        Context.scheduledPressState.ballId = ballId
    end

    Context.scheduledPressState.pressAt = pressAt
    Context.scheduledPressState.predictedImpact = predictedImpact
    Context.scheduledPressState.lead = lead
    Context.scheduledPressState.slack = slack
    Context.scheduledPressState.reason = reason
    Context.scheduledPressState.lastUpdate = now
    if typeof(context) == "table" and context.immediate ~= nil then
        Context.scheduledPressState.immediate = context.immediate == true
    else
        Context.scheduledPressState.immediate = false
    end
    if typeof(context) == "table" and context.smartTuning ~= nil then
        Context.scheduledPressState.smartTuning = Helpers.normalizeSmartTuningPayload(context.smartTuning)
    else
        Context.scheduledPressState.smartTuning = nil
    end

    local event = {
        ballId = ballId,
        predictedImpact = predictedImpact,
        lead = lead,
        slack = slack,
        reason = reason,
        pressAt = pressAt,
        eta = math.max(pressAt - now, 0),
        time = now,
        activationLatency = activationLatencyEstimate,
        remoteLatencyActive = state.remoteEstimatorActive,
    }

    if event.adaptiveBias == nil and TelemetryAnalytics.adaptiveState then
        event.adaptiveBias = TelemetryAnalytics.adaptiveState.reactionBias
    end

    if typeof(context) == "table" then
        for key, value in pairs(context) do
            if event[key] == nil then
                event[key] = value
            end
        end
    end

    Context.scheduledPressState.lastSnapshot = Helpers.cloneTable(event)

    if event.immediate == nil then
        event.immediate = Context.scheduledPressState.immediate
    end

    TelemetryAnalytics.recordSchedule(event)
    emitTelemetryEvent("schedule", event)
end


function Helpers.pressParry(ball: BasePart?, ballId: string?, force: boolean?, decisionPayload: { [string]: any }?)
    local forcing = force == true
    local now = os.clock()
    if Context.runtime.virtualInputUnavailable and Context.runtime.virtualInputRetryAt > now and not forcing then
        return false
    end

    local wasTransientRetry = Context.runtime.transientRetryActive == true
    local retryCount = Context.runtime.transientRetryCount or 0
    local priorCooldownDeadline = Context.runtime.transientRetryCooldown or 0
    local priorCooldownBallId = Context.runtime.transientRetryCooldownBallId

    local allowRetryDuringCooldown = false
    if wasTransientRetry then
        if retryCount >= 1 and not forcing then
            return false
        end
        if retryCount < 1 then
            allowRetryDuringCooldown = true
        end
    end

    local cooldownDeadline = priorCooldownDeadline
    if cooldownDeadline > now then
        local cooldownBallId = priorCooldownBallId
        local sameBall = cooldownBallId == nil or cooldownBallId == ballId
        if sameBall and not allowRetryDuringCooldown then
            return false
        end
    end

    if Context.runtime.parryHeld then
        local sameBall = Context.runtime.parryHeldBallId == ballId
        if sameBall and not forcing then
            return false
        end

        -- release the existing hold before pressing again or for a new ball
        if Context.runtime.virtualInputUnavailable and Context.runtime.virtualInputRetryAt > os.clock() then
            Context.runtime.pendingParryRelease = true
        else
            if not Context.hooks.sendParryKeyEvent(false) then
                Context.runtime.pendingParryRelease = true
            else
                Context.runtime.pendingParryRelease = false
            end
        end
        Context.runtime.parryHeld = false
        Context.runtime.parryHeldBallId = nil
    end

    if not Context.hooks.sendParryKeyEvent(true) then
        return false
    end

    Context.runtime.pendingParryRelease = false

    Context.runtime.parryHeld = true
    Context.runtime.parryHeldBallId = ballId

    now = os.clock()
    if wasTransientRetry or priorCooldownDeadline > 0 then
        if wasTransientRetry then
            Context.runtime.transientRetryCooldown = math.huge
        else
            local cooldownDuration = math.max(config.cooldown or 0, MIN_TRANSIENT_RETRY_COOLDOWN)
            Context.runtime.transientRetryCooldown = now + cooldownDuration
        end
        if ballId ~= nil or wasTransientRetry then
            Context.runtime.transientRetryCooldownBallId = ballId
        else
            Context.runtime.transientRetryCooldownBallId = priorCooldownBallId
        end
    end

    if wasTransientRetry then
        Context.runtime.transientRetryCount = (Context.runtime.transientRetryCount or 0) + 1
        if Context.runtime.transientRetryCount >= 1 then
            Context.runtime.transientRetryActive = false
        end
    end

    local now = os.clock()
    state.lastParry = now

    local smartContext = Context.scheduledPressState.smartTuning
    if smartContext == nil and smartTuningState.enabled then
        smartContext = Helpers.snapshotSmartTuningState()
    end
    local normalizedSmartContext = nil
    if smartContext ~= nil then
        normalizedSmartContext = Helpers.normalizeSmartTuningPayload(smartContext)
    end

    local scheduledSnapshot = nil
    if ballId then
        local hasSchedule = Context.scheduledPressState.ballId == ballId and Context.scheduledPressState.lastUpdate and Context.scheduledPressState.lastUpdate > 0
        if not hasSchedule then
            local immediateContext = {
                immediate = true,
                adaptiveBias = TelemetryAnalytics.adaptiveState and TelemetryAnalytics.adaptiveState.reactionBias or nil,
            }
            if normalizedSmartContext ~= nil then
                immediateContext.smartTuning = normalizedSmartContext
            end
            Helpers.updateScheduledPress(ballId, 0, 0, 0, "immediate-press", now, immediateContext)
        end
        scheduledSnapshot = captureScheduledPressSnapshot(ballId)
    end
    Helpers.prunePendingLatencyPresses(now)
    pendingLatencyPresses[#pendingLatencyPresses + 1] = { time = now, ballId = ballId }

    local telemetry = nil
    if ballId then
        telemetry = telemetryStates[ballId]
    end

    local scheduledReason = nil
    if ballId and Context.scheduledPressState.ballId == ballId then
        scheduledReason = Context.scheduledPressState.reason
    end

    local pressEvent = {
        ballId = ballId,
        forced = forcing,
        time = now,
        activationLatency = activationLatencyEstimate,
        remoteLatencyActive = state.remoteEstimatorActive,
        scheduledReason = scheduledReason,
    }

    if typeof(decisionPayload) == "table" then
        local simulationSnapshot = Helpers.cloneTelemetryEvent(decisionPayload.proximitySimulation)
        local decisionSnapshot = {
            pressRadius = decisionPayload.pressRadius,
            holdRadius = decisionPayload.holdRadius,
            baseLead = decisionPayload.proximityBaseLead,
            adaptiveLead = decisionPayload.proximityAdaptiveLead,
            manifold = decisionPayload.proximityManifold or decisionPayload.proximitySynthesis,
            synthesis = decisionPayload.proximitySynthesis,
            logistic = decisionPayload.proximityLogistic,
            threatScore = decisionPayload.threatScore,
            threatStatus = decisionPayload.threatStatus,
            threatIntensity = decisionPayload.threatIntensity,
            threatTempo = decisionPayload.threatTempo,
            threatConfidence = decisionPayload.threatConfidence,
            threatLoad = decisionPayload.threatLoad,
            threatSpectralFast = decisionPayload.threatSpectralFast,
            threatSpectralMedium = decisionPayload.threatSpectralMedium,
            threatSpectralSlow = decisionPayload.threatSpectralSlow,
            threatMomentum = decisionPayload.threatMomentum,
            threatVolatility = decisionPayload.threatVolatility,
            threatStability = decisionPayload.threatStability,
            threatAcceleration = decisionPayload.threatAcceleration,
            threatJerk = decisionPayload.threatJerk,
            threatBoost = decisionPayload.threatBoost,
            threatInstantReady = decisionPayload.threatInstantReady,
            threatBudget = decisionPayload.threatBudget,
            threatBudgetHorizon = decisionPayload.threatBudgetHorizon,
            threatBudgetRatio = decisionPayload.threatBudgetRatio,
            threatBudgetPressure = decisionPayload.threatBudgetPressure,
            threatLatencyGap = decisionPayload.threatLatencyGap,
            threatBudgetReady = decisionPayload.threatBudgetReady,
            threatReadiness = decisionPayload.threatReadiness,
            threatBudgetConfidenceGain = decisionPayload.threatBudgetConfidenceGain,
            detectionConfidence = decisionPayload.detectionConfidence,
            simulationCached = decisionPayload.proximitySimulationCached,
            simulationCacheKey = decisionPayload.proximitySimulationCacheKey,
            simulationCacheHits = decisionPayload.proximitySimulationCacheHits,
            simulationCacheStreak = decisionPayload.proximitySimulationCacheStreak,
            envelope = decisionPayload.proximityEnvelope,
            simulationEnergy = decisionPayload.proximitySimulationEnergy,
            simulationUrgency = decisionPayload.proximitySimulationUrgency,
            simulationQuality = decisionPayload.proximitySimulationQuality,
            velocitySignature = decisionPayload.proximityVelocityImprint,
            weightedIntrusion = decisionPayload.proximityWeightedIntrusion,
            ballisticGain = decisionPayload.proximityBallisticGain,
            distanceSuppression = decisionPayload.proximityDistanceSuppression,
            lookaheadGain = decisionPayload.proximityLookaheadGain,
            impactRatio = decisionPayload.proximityImpactRatio,
            responseWindow = decisionPayload.responseWindow,
            holdWindow = decisionPayload.holdWindow,
            timeToImpact = decisionPayload.timeToImpact,
            predictedImpact = decisionPayload.predictedImpact,
        }
        if simulationSnapshot ~= nil then
            decisionSnapshot.simulation = simulationSnapshot
        end
        pressEvent.decision = Helpers.cloneTelemetryEvent(decisionSnapshot)
    end

    if TelemetryAnalytics.adaptiveState then
        pressEvent.adaptiveBias = TelemetryAnalytics.adaptiveState.reactionBias
    end

    local eventSmartContext = normalizedSmartContext or Context.scheduledPressState.smartTuning
    if eventSmartContext == nil and smartTuningState.enabled then
        eventSmartContext = Helpers.normalizeSmartTuningPayload(Helpers.snapshotSmartTuningState())
    end
    if eventSmartContext ~= nil then
        if typeof(eventSmartContext) == "table" then
            pressEvent.smartTuning = Helpers.cloneTable(eventSmartContext)
        else
            pressEvent.smartTuning = eventSmartContext
        end
    end

    if ball then
        local okName, name = pcall(function()
            return ball.Name
        end)
        if okName then
            pressEvent.ballName = name
        end
        if typeof(ball.Position) == "Vector3" then
            pressEvent.position = ball.Position
        end
        if typeof(ball.AssemblyLinearVelocity) == "Vector3" then
            pressEvent.velocity = ball.AssemblyLinearVelocity
        end
    end

    if scheduledSnapshot and scheduledSnapshot.immediate then
        pressEvent.immediate = true
    elseif pressEvent.immediate == nil and scheduledReason == "immediate-press" then
        pressEvent.immediate = true
    end

    TelemetryAnalytics.applyPressLatencyTelemetry(telemetry, pressEvent, now)

    if ballId then
        if telemetry then
            pressEvent.telemetry = {
                filteredD = telemetry.filteredD,
                filteredVr = telemetry.filteredVr,
                filteredAr = telemetry.filteredAr,
                filteredJr = telemetry.filteredJr,
            }
        end
        Helpers.clearScheduledPress(ballId, "pressed", { pressedAt = now })
    else
        Helpers.clearScheduledPress(nil, "pressed", { pressedAt = now })
    end

    if telemetry then
        telemetry.triggerTime = now
        telemetry.latencySampled = false

        local history = telemetry.pressHistory
        if typeof(history) ~= "table" then
            history = {}
            telemetry.pressHistory = history
        end
        history[#history + 1] = now

        local window = TARGETING_PRESSURE_WINDOW
        if not Helpers.isFiniteNumber(window) or window <= 0 then
            window = 1
        end
        local cutoff = now - window
        while #history > 0 and history[1] < cutoff do
            table.remove(history, 1)
        end

        if #history >= 2 then
            local gap = history[#history] - history[#history - 1]
            if Helpers.isFiniteNumber(gap) and gap >= 0 then
                telemetry.lastPressGap = gap
            end
        else
            telemetry.lastPressGap = nil
        end

        telemetry.lastPressAt = now
        if window > 0 then
            telemetry.pressRate = #history / window
        else
            telemetry.pressRate = 0
        end
    end

    TelemetryAnalytics.recordPress(pressEvent, scheduledSnapshot)
    local clonedPressEvent = Helpers.cloneTelemetryEvent(pressEvent)
    if typeof(clonedPressEvent) == "table" then
        local pawsSettings = Helpers.ensurePawsSettings()
        pawsSettings.LastPressEvent = clonedPressEvent
        GlobalEnv.LastPressEvent = clonedPressEvent
        ensurePressEventProxy()
    end

    emitTelemetryEvent("press", pressEvent)
    parryEvent:fire(ball, now)
    return true
end

function Helpers.releaseParry()
    if not Context.runtime.parryHeld then
        return
    end

    local ballId = Context.runtime.parryHeldBallId
    Context.runtime.parryHeld = false
    Context.runtime.parryHeldBallId = nil
    if Context.runtime.transientRetryCooldownBallId == ballId then
        Context.runtime.transientRetryCooldown = 0
        Context.runtime.transientRetryCooldownBallId = nil
    end
    if Context.runtime.virtualInputUnavailable and Context.runtime.virtualInputRetryAt > os.clock() then
        Context.runtime.pendingParryRelease = true
    else
        if not Context.hooks.sendParryKeyEvent(false) then
            Context.runtime.pendingParryRelease = true
        else
            Context.runtime.pendingParryRelease = false
        end
    end

    Helpers.clearScheduledPress(ballId, "released")

    if ballId then
        local telemetry = telemetryStates[ballId]
        if telemetry then
            telemetry.triggerTime = nil
            telemetry.latencySampled = true
        end
    end
end

function Helpers.handleHumanoidDied()
    Helpers.clearScheduledPress(nil, "humanoid-died")
    Helpers.safeCall(Helpers.releaseParry)
    Helpers.safeCall(Helpers.safeClearBallVisuals)
    Helpers.safeCall(Helpers.enterRespawnWaitState)
    Helpers.safeCall(Helpers.updateCharacter, nil)
    Helpers.callImmortalController("handleHumanoidDied")
end

function Helpers.updateCharacter(character)
    Context.player.Character = character
    Context.player.RootPart = nil
    Context.player.Humanoid = nil
    Context.runtime.targetingGraceUntil = 0

    if Context.connections.humanoidDied then
        Context.connections.humanoidDied:Disconnect()
        Context.connections.humanoidDied = nil
    end

    if not character then
        return
    end

    Context.player.RootPart = character:FindFirstChild("HumanoidRootPart")
    if not Context.player.RootPart then
        local ok, root = pcall(function()
            return character:WaitForChild("HumanoidRootPart", 5)
        end)
        if ok then
            Context.player.RootPart = root
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

    Context.player.Humanoid = humanoid

    if humanoid then
        Context.connections.humanoidDied = humanoid.Died:Connect(Helpers.handleHumanoidDied)
    end

    if initialization.completed and character then
        Helpers.ensureBallsFolder(false)
        Context.hooks.publishReadyStatus()
    end

    Context.runtime.syncImmortalContext()
end

function Helpers.handleCharacterAdded(character)
    Helpers.updateCharacter(character)
end

function Helpers.handleCharacterRemoving()
    Helpers.clearScheduledPress(nil, "character-removing")
    Helpers.safeCall(Helpers.releaseParry)
    Helpers.safeCall(Helpers.safeClearBallVisuals)
    Helpers.safeCall(Helpers.enterRespawnWaitState)
    Helpers.safeCall(Helpers.updateCharacter, nil)
end

function Helpers.beginInitialization()
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

            Helpers.applyInitStatus(status)
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

            Helpers.applyInitStatus(payload)
            initialization.started = false
            return
        end

        local verificationResult = result

        Context.player.LocalPlayer = verificationResult.player
        Context.player.RemotesFolder = verificationResult.remotesFolder
        Context.player.ParryInputInfo = verificationResult.parryInputInfo

        Context.runtime.syncImmortalContext()

        Helpers.disconnectVerificationWatchers()

        if Context.player.RemotesFolder then
            Helpers.watchResource(Context.player.RemotesFolder, "remotes-folder-removed")
        end

        Helpers.configureSuccessListeners(verificationResult.successRemotes)
        Helpers.setRemoteQueueGuardFolder(Context.player.RemotesFolder)

        if verificationResult.successRemotes then
            local localEntry = verificationResult.successRemotes.ParrySuccess
            if localEntry and localEntry.remote then
                Helpers.watchResource(localEntry.remote, "removeevents-local-missing")
            end

            local broadcastEntry = verificationResult.successRemotes.ParrySuccessAll
            if broadcastEntry and broadcastEntry.remote then
                Helpers.watchResource(broadcastEntry.remote, "removeevents-all-missing")
            end
        end

        if verificationResult.ballsFolder then
            Context.player.BallsFolder = verificationResult.ballsFolder
        else
            Context.player.BallsFolder = nil
        end
        Helpers.setBallsFolderWatcher(Context.player.BallsFolder)
        Context.player.WatchedBallsFolder = Context.player.BallsFolder

        Context.runtime.syncImmortalContext()

        if Context.player.LocalPlayer then
            Helpers.safeDisconnect(Context.connections.characterAdded)
            Helpers.safeDisconnect(Context.connections.characterRemoving)

            local characterAddedSignal = Context.player.LocalPlayer.CharacterAdded
            local characterRemovingSignal = Context.player.LocalPlayer.CharacterRemoving

            if characterAddedSignal and typeof(characterAddedSignal.Connect) == "function" then
                Context.connections.characterAdded = characterAddedSignal:Connect(Helpers.handleCharacterAdded)
            else
                Context.connections.characterAdded = nil
            end

            if characterRemovingSignal and typeof(characterRemovingSignal.Connect) == "function" then
                Context.connections.characterRemoving = characterRemovingSignal:Connect(Helpers.handleCharacterRemoving)
            else
                Context.connections.characterRemoving = nil
            end

            local currentCharacter = Context.player.LocalPlayer.Character
            if currentCharacter then
                Helpers.updateCharacter(currentCharacter)
            elseif characterAddedSignal and typeof(characterAddedSignal.Wait) == "function" then
                local okChar, char = pcall(function()
                    return characterAddedSignal:Wait()
                end)
                if okChar and char then
                    Helpers.updateCharacter(char)
                end
            end
        end

        Helpers.ensureUi()

        Context.hooks.setStage("waiting-character", { player = Context.player.LocalPlayer and Context.player.LocalPlayer.Name or "Unknown" })

        Context.hooks.setStage("waiting-balls")
        Helpers.ensureBallsFolder(true)

        if Context.player.BallsFolder then
            Helpers.setBallsFolderWatcher(Context.player.BallsFolder)
            Context.player.WatchedBallsFolder = Context.player.BallsFolder
        else
            Helpers.setBallsFolderWatcher(nil)
        end

        if verificationResult.ballsStatus then
            Context.watchers.ballsSnapshot = Helpers.cloneTable(verificationResult.ballsStatus)
        else
            Context.watchers.ballsSnapshot = nil
        end

        Context.hooks.publishReadyStatus()
        initialization.completed = true
    end)
end

function Helpers.ensureInitialization()
    if initialization.destroyed then
        initialization.destroyed = false
    end
    if initialization.completed or initialization.started then
        return
    end
    Helpers.beginInitialization()
end

local BallKinematics = {}

local PressDecision = {
    scratch = {},
    output = {},
    ballisticScratch = {},
}

function BallKinematics.computeBallDebug(
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

function BallKinematics.computeUpdateTiming(telemetry, now)
    local previousUpdate = telemetry.lastUpdate or now
    local dt = now - previousUpdate
    if not Helpers.isFiniteNumber(dt) or dt <= 0 then
        dt = 1 / 240
    end
    dt = math.clamp(dt, 1 / 240, 0.5)
    telemetry.lastUpdate = now
    return dt
end

function BallKinematics.computeSpatialContext(context, ballPosition, playerPosition, safeRadius)
    local relative = ballPosition - playerPosition
    local distance = relative.Magnitude
    local unit = Vector3.zero
    if distance > Constants.EPSILON then
        unit = relative / distance
    end

    context.relative = relative
    context.distance = distance
    context.unit = unit
    context.d0 = distance - safeRadius
end

function BallKinematics.computeRawMotion(context, telemetry, dt)
    local position = context.ballPosition

    local rawVelocity = Vector3.zero
    local lastPosition = telemetry.lastPosition
    if lastPosition then
        rawVelocity = (position - lastPosition) / dt
    end
    telemetry.lastPosition = position
    context.rawVelocity = rawVelocity

    local rawAcceleration = Vector3.zero
    local lastVelocity = telemetry.lastVelocity
    if lastVelocity then
        rawAcceleration = (rawVelocity - lastVelocity) / dt
    end
    telemetry.lastVelocity = rawVelocity
    context.rawAcceleration = rawAcceleration

    local rawJerk = Vector3.zero
    local lastAcceleration = telemetry.lastAcceleration
    if lastAcceleration then
        rawJerk = (rawAcceleration - lastAcceleration) / dt
    end
    telemetry.lastAcceleration = rawAcceleration
    context.rawJerk = rawJerk
end

function BallKinematics.computeFilteredMotion(context, telemetry)
    local rawVelocity = context.rawVelocity
    local rawAcceleration = context.rawAcceleration
    local rawJerk = context.rawJerk

    local velocity = Helpers.emaVector(telemetry.velocity, rawVelocity, Constants.SMOOTH_ALPHA)
    telemetry.velocity = velocity
    context.velocity = velocity
    context.velocityMagnitude = velocity.Magnitude

    local acceleration = Helpers.emaVector(telemetry.acceleration, rawAcceleration, Constants.SMOOTH_ALPHA)
    telemetry.acceleration = acceleration
    context.acceleration = acceleration

    local jerk = Helpers.emaVector(telemetry.jerk, rawJerk, Constants.SMOOTH_ALPHA)
    telemetry.jerk = jerk
    context.jerk = jerk

    local vNorm2 = velocity:Dot(velocity)
    if vNorm2 < Constants.EPSILON then
        vNorm2 = Constants.EPSILON
    end
    context.vNorm2 = vNorm2

    local rawSpeedSq = rawVelocity:Dot(rawVelocity)
    context.rawSpeedSq = rawSpeedSq

    context.rawSpeed = rawVelocity.Magnitude
end

function BallKinematics.computeCurvature(context, telemetry, dt)
    local rawVelocity = context.rawVelocity
    local rawAcceleration = context.rawAcceleration
    local rawSpeed = context.rawSpeed
    local rawSpeedSq = context.rawSpeedSq
    local vNorm2 = context.vNorm2

    local rawKappa = 0
    if rawSpeed > Constants.EPSILON then
        rawKappa = rawVelocity:Cross(rawAcceleration).Magnitude / math.max(rawSpeedSq * rawSpeed, Constants.EPSILON)
    end
    context.rawKappa = rawKappa

    local filteredKappaRaw = Helpers.emaScalar(telemetry.kappa, rawKappa, Constants.KAPPA_ALPHA)
    local filteredKappa, kappaOverflow = Helpers.clampWithOverflow(filteredKappaRaw, Constants.PHYSICS_LIMITS.curvature)
    telemetry.kappa = filteredKappa
    context.filteredKappa = filteredKappa
    context.kappaOverflow = kappaOverflow

    local dkappaRaw = 0
    if telemetry.lastRawKappa ~= nil then
        dkappaRaw = (rawKappa - telemetry.lastRawKappa) / math.max(dt, Constants.EPSILON)
    end
    telemetry.lastRawKappa = rawKappa
    context.dkappaRaw = dkappaRaw

    local filteredDkappaRaw = Helpers.emaScalar(telemetry.dkappa, dkappaRaw, Constants.DKAPPA_ALPHA)
    local filteredDkappa, dkappaOverflow = Helpers.clampWithOverflow(filteredDkappaRaw, Constants.PHYSICS_LIMITS.curvatureRate)
    telemetry.dkappa = filteredDkappa
    context.filteredDkappa = filteredDkappa
    context.dkappaOverflow = dkappaOverflow
end

function BallKinematics.computeRadial(
    context,
    telemetry
)
    local unit = context.unit
    local rawVelocity = context.rawVelocity
    local rawAcceleration = context.rawAcceleration
    local rawJerk = context.rawJerk
    local velocity = context.velocity
    local acceleration = context.acceleration
    local jerk = context.jerk
    local vNorm2 = context.vNorm2
    local rawKappa = context.rawKappa
    local filteredKappa = context.filteredKappa
    local dkappaRaw = context.dkappaRaw
    local filteredDkappa = context.filteredDkappa
    local rawSpeedSq = context.rawSpeedSq

    local rawVr = -unit:Dot(rawVelocity)
    context.rawVr = rawVr

    local filteredVr = Helpers.emaScalar(telemetry.filteredVr, -unit:Dot(velocity), Constants.SMOOTH_ALPHA)
    telemetry.filteredVr = filteredVr
    context.filteredVr = filteredVr

    local vrSign = 0
    if filteredVr > Constants.VR_SIGN_EPSILON then
        vrSign = 1
    elseif filteredVr < -Constants.VR_SIGN_EPSILON then
        vrSign = -1
    end
    context.vrSign = vrSign

    local filteredArEstimate = -unit:Dot(acceleration) + filteredKappa * vNorm2
    context.filteredArEstimate = filteredArEstimate
    local filteredArRaw = Helpers.emaScalar(telemetry.filteredAr, filteredArEstimate, Constants.SMOOTH_ALPHA)
    local filteredAr, arOverflow = Helpers.clampWithOverflow(filteredArRaw, Constants.PHYSICS_LIMITS.radialAcceleration)
    telemetry.filteredAr = filteredAr
    context.filteredAr = filteredAr
    context.arOverflow = arOverflow

    local dotVA = velocity:Dot(acceleration)
    context.dotVA = dotVA

    local filteredJrEstimate = -unit:Dot(jerk) + filteredDkappa * vNorm2 + 2 * filteredKappa * dotVA
    context.filteredJrEstimate = filteredJrEstimate
    local filteredJrRaw = Helpers.emaScalar(telemetry.filteredJr, filteredJrEstimate, Constants.SMOOTH_ALPHA)
    local filteredJr, jrOverflow = Helpers.clampWithOverflow(filteredJrRaw, Constants.PHYSICS_LIMITS.radialJerk)
    telemetry.filteredJr = filteredJr
    context.filteredJr = filteredJr
    context.jrOverflow = jrOverflow

    local rawAr = -unit:Dot(rawAcceleration) + rawKappa * rawSpeedSq
    context.rawAr = rawAr

    local rawJr = -unit:Dot(rawJerk) + dkappaRaw * rawSpeedSq + 2 * rawKappa * rawVelocity:Dot(rawAcceleration)
    context.rawJr = rawJr
end

function BallKinematics.trackVrSignHistory(telemetry, now, vrSign)
    if vrSign ~= 0 then
        local previousSign = telemetry.lastVrSign
        if previousSign and previousSign ~= 0 and previousSign ~= vrSign then
            local flips = telemetry.vrSignFlips
            flips[#flips + 1] = { time = now, sign = vrSign }
        end
        telemetry.lastVrSign = vrSign
    end
    Helpers.trimHistory(telemetry.vrSignFlips, now - Constants.OSCILLATION_HISTORY_SECONDS)
end

function BallKinematics.updateDistanceHistory(context, telemetry, now)
    local d0 = context.d0
    local filteredD = Helpers.emaScalar(telemetry.filteredD, d0, Constants.SMOOTH_ALPHA)
    telemetry.filteredD = filteredD
    context.filteredD = filteredD

    local d0Delta = 0
    local lastD0 = telemetry.lastD0
    if lastD0 ~= nil then
        d0Delta = d0 - lastD0
    end
    telemetry.lastD0 = d0
    telemetry.lastD0Delta = d0Delta

    local d0History = telemetry.d0DeltaHistory
    d0History[#d0History + 1] = { time = now, delta = math.abs(d0Delta) }
    Helpers.trimHistory(d0History, now - Constants.OSCILLATION_HISTORY_SECONDS)
    context.d0Delta = d0Delta

end

function BallKinematics.updateVariance(context, telemetry)
    local d0 = context.d0
    local filteredD = context.filteredD
    local rawVr = context.rawVr
    local filteredVr = context.filteredVr
    local rawAr = context.rawAr
    local filteredAr = context.filteredAr
    local rawJr = context.rawJr
    local filteredJr = context.filteredJr
    local vNorm2 = context.vNorm2
    local dotVA = context.dotVA
    local kappaOverflow = context.kappaOverflow
    local dkappaOverflow = context.dkappaOverflow
    local arOverflow = context.arOverflow
    local jrOverflow = context.jrOverflow

    Helpers.updateRollingStat(telemetry.statsD, d0 - filteredD)
    Helpers.updateRollingStat(telemetry.statsVr, rawVr - filteredVr)
    Helpers.updateRollingStat(telemetry.statsAr, rawAr - filteredAr)
    Helpers.updateRollingStat(telemetry.statsJr, rawJr - filteredJr)

    local sigmaD = Helpers.getRollingStd(telemetry.statsD, Constants.SIGMA_FLOORS.d)
    local sigmaVr = Helpers.getRollingStd(telemetry.statsVr, Constants.SIGMA_FLOORS.vr)
    local sigmaAr = Helpers.getRollingStd(telemetry.statsAr, Constants.SIGMA_FLOORS.ar)
    local sigmaJr = Helpers.getRollingStd(telemetry.statsJr, Constants.SIGMA_FLOORS.jr)

    local sigmaArExtraSq = 0
    if arOverflow > 0 then
        sigmaArExtraSq += arOverflow * arOverflow
    end
    if kappaOverflow and kappaOverflow > 0 then
        local extra = kappaOverflow * vNorm2
        sigmaArExtraSq += extra * extra
    end

    local sigmaArOverflow = 0
    if sigmaArExtraSq > 0 then
        sigmaArOverflow = math.sqrt(sigmaArExtraSq)
        sigmaAr = math.sqrt(sigmaAr * sigmaAr + sigmaArExtraSq)
    end

    local sigmaJrExtraSq = 0
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

    local sigmaJrOverflow = 0
    if sigmaJrExtraSq > 0 then
        sigmaJrOverflow = math.sqrt(sigmaJrExtraSq)
        sigmaJr = math.sqrt(sigmaJr * sigmaJr + sigmaJrExtraSq)
    end

    context.sigmaD = sigmaD
    context.sigmaVr = sigmaVr
    context.sigmaAr = sigmaAr
    context.sigmaJr = sigmaJr
    context.sigmaArOverflow = sigmaArOverflow
    context.sigmaJrOverflow = sigmaJrOverflow
end

function BallKinematics.build(ball, playerPosition, telemetry, safeRadius, now)
    local context = {
        safeRadius = safeRadius,
    }

    context.dt = BallKinematics.computeUpdateTiming(telemetry, now)

    context.ballPosition = ball.Position

    BallKinematics.computeSpatialContext(context, context.ballPosition, playerPosition, safeRadius)

    BallKinematics.computeRawMotion(context, telemetry, context.dt)

    BallKinematics.computeFilteredMotion(context, telemetry)

    BallKinematics.computeCurvature(context, telemetry, context.dt)

    BallKinematics.computeRadial(context, telemetry)

    BallKinematics.trackVrSignHistory(telemetry, now, context.vrSign)

    BallKinematics.updateDistanceHistory(context, telemetry, now)

    BallKinematics.updateVariance(context, telemetry)

    return context
end

function PressDecision.clearTable(target)
    if not target then
        return
    end

    for key in pairs(target) do
        target[key] = nil
    end
end

function PressDecision.computeConfidence(state, config, kinematics)
    local ping = Helpers.getPingTime()
    local delta = 0.5 * ping + activationLatencyEstimate
    local delta2 = delta * delta

    local playerVr = state.playerVr
    if playerVr == nil then
        playerVr = Helpers.getPlayerRadialVelocity(kinematics.unit)
        state.playerVr = playerVr
    end

    state.playerRadialVelocity = playerVr

    local filteredVr = (kinematics.filteredVr or 0) - playerVr
    state.relativeFilteredVr = filteredVr

    local mu =
        kinematics.filteredD
        - filteredVr * delta
        - 0.5 * kinematics.filteredAr * delta2
        - (1 / 6) * kinematics.filteredJr * delta2 * delta

    local sigmaSquared = kinematics.sigmaD * kinematics.sigmaD
    sigmaSquared += delta2 * (kinematics.sigmaVr * kinematics.sigmaVr)
    sigmaSquared += (0.25 * delta2 * delta2) * (kinematics.sigmaAr * kinematics.sigmaAr)
    sigmaSquared += ((1 / 36) * delta2 * delta2 * delta2) * (kinematics.sigmaJr * kinematics.sigmaJr)
    local sigma = math.sqrt(math.max(sigmaSquared, 0))

    local z = config.confidenceZ
    if z == nil then
        z = Defaults.CONFIG.confidenceZ
    end
    if not Helpers.isFiniteNumber(z) or z < 0 then
        z = Defaults.CONFIG.confidenceZ or 2.2
    end

    local muValid = Helpers.isFiniteNumber(mu)
    local sigmaValid = Helpers.isFiniteNumber(sigma)
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

    state.ping = ping
    state.delta = delta
    state.delta2 = delta2
    state.mu = mu
    state.sigma = sigma
    state.z = z
    state.muPlus = muPlus
    state.muMinus = muMinus
    state.muValid = muValid
    state.sigmaValid = sigmaValid
end

function PressDecision.updateTelemetryState(state, telemetry, now, targetingMe, ballId)
    if not telemetry then
        return
    end

    local pulses = telemetry.targetingPulses
    if typeof(pulses) ~= "table" then
        pulses = {}
        telemetry.targetingPulses = pulses
    end

    local runtime = Context.runtime
    local queuedPulses = runtime.targetingHighlightPulseQueue
    if typeof(queuedPulses) == "table" and #queuedPulses > 0 then
        for index = 1, #queuedPulses do
            local pulseTime = queuedPulses[index]
            if Helpers.isFiniteNumber(pulseTime) then
                pulses[#pulses + 1] = pulseTime
            end
        end
        table.clear(queuedPulses)
    end

    if targetingMe then
        if telemetry.targetingActive ~= true then
            local previous = pulses[#pulses]
            pulses[#pulses + 1] = now
            telemetry.targetingActive = true
            if Helpers.isFiniteNumber(previous) then
                local interval = now - previous
                if Helpers.isFiniteNumber(interval) and interval >= 0 then
                    telemetry.targetingLastInterval = interval
                end
            end
            telemetry.lastTargetingPulse = now
        end
        if telemetry.targetDetectedAt == nil then
            telemetry.targetDetectedAt = now
        end
    else
        local holdingSame = Context.runtime.parryHeld and Context.runtime.parryHeldBallId == ballId
        if telemetry.targetingActive then
            telemetry.targetingActive = false
            telemetry.lastTargetingDrop = now
        end
        if not holdingSame then
            telemetry.targetDetectedAt = nil
            telemetry.decisionAt = nil
        end
    end

    local queuedDrops = runtime.targetingHighlightDropQueue
    if typeof(queuedDrops) == "table" and #queuedDrops > 0 then
        local latestDrop = queuedDrops[#queuedDrops]
        if Helpers.isFiniteNumber(latestDrop) then
            telemetry.lastTargetingDrop = latestDrop
        end
        table.clear(queuedDrops)
    end

    local window = TARGETING_PRESSURE_WINDOW
    if not Helpers.isFiniteNumber(window) or window <= 0 then
        window = 1
    end
    local cutoff = now - window
    while #pulses > 0 and pulses[1] < cutoff do
        table.remove(pulses, 1)
    end

    local count = #pulses
    telemetry.targetingBurstCount = count
    if window > 0 then
        telemetry.targetingBurstRate = count / window
    else
        telemetry.targetingBurstRate = 0
    end

    if count >= 2 then
        local minInterval = math.huge
        for index = 2, count do
            local interval = pulses[index] - pulses[index - 1]
            if Helpers.isFiniteNumber(interval) and interval >= 0 and interval < minInterval then
                minInterval = interval
            end
        end
        if minInterval < math.huge then
            telemetry.targetingMinInterval = minInterval
        else
            telemetry.targetingMinInterval = nil
        end

        local lastInterval = pulses[count] - pulses[count - 1]
        if Helpers.isFiniteNumber(lastInterval) and lastInterval >= 0 then
            telemetry.targetingLastInterval = lastInterval
        end
    else
        telemetry.targetingMinInterval = nil
        if count <= 1 then
            telemetry.targetingLastInterval = nil
        end
    end

    if count > 0 then
        telemetry.lastTargetingPulse = pulses[count]
    end
end

function PressDecision.computeApproach(state, kinematics, safeRadius)
    local playerVr = state.playerVr
    if playerVr == nil then
        playerVr = Helpers.getPlayerRadialVelocity(kinematics.unit)
        state.playerVr = playerVr
    end

    local relativeFilteredVr = (kinematics.filteredVr or 0) - playerVr
    local relativeRawVr = (kinematics.rawVr or 0) - playerVr
    local approachSpeed = math.max(relativeFilteredVr, relativeRawVr, 0)
    local approaching = approachSpeed > Constants.EPSILON
    local timeToImpactFallback = math.huge
    local timeToImpactPolynomial
    local timeToImpact = math.huge

    if approaching then
        local speed = math.max(approachSpeed, Constants.EPSILON)
        timeToImpactFallback = kinematics.distance / speed

        local impactRadial = kinematics.filteredD
        local polynomial =
            Helpers.solveRadialImpactTime(
                impactRadial,
                relativeFilteredVr,
                kinematics.filteredAr,
                kinematics.filteredJr
            )
        if polynomial and polynomial > Constants.EPSILON then
            timeToImpactPolynomial = polynomial
            timeToImpact = polynomial
        elseif Helpers.isFiniteNumber(timeToImpactFallback) and timeToImpactFallback >= 0 then
            timeToImpact = timeToImpactFallback
        end
    end

    local responseWindowBase = math.max(state.delta + PROXIMITY_PRESS_GRACE, PROXIMITY_PRESS_GRACE)
    if approaching and timeToImpactPolynomial then
        responseWindowBase = math.max(math.min(responseWindowBase, timeToImpactPolynomial), PROXIMITY_PRESS_GRACE)
    end

    state.approachSpeed = approachSpeed
    state.approaching = approaching
    state.playerRadialVelocity = playerVr
    state.playerVr = playerVr
    state.relativeFilteredVr = relativeFilteredVr
    state.relativeRawVr = relativeRawVr
    state.timeToImpactFallback = timeToImpactFallback
    state.timeToImpactPolynomial = timeToImpactPolynomial
    state.timeToImpact = timeToImpact
    state.responseWindowBase = responseWindowBase
    state.responseWindow = responseWindowBase
    state.curveLeadTime = 0
    state.curveLeadDistance = 0
    state.curveHoldDistance = 0
    state.curveSeverity = 0
    state.curveJerkSeverity = 0
    state.curveLeadApplied = 0
    state.curveHoldApplied = 0
    state.pressRadius = safeRadius
    state.holdRadius = safeRadius
end

function PressDecision.computeCurveAdjustments(state, config, kinematics)
    if not state.approaching then
        return
    end

    local curvatureLeadScale = config.curvatureLeadScale
    if curvatureLeadScale == nil then
        curvatureLeadScale = Defaults.CONFIG.curvatureLeadScale
    end

    local curvatureHoldBoost = config.curvatureHoldBoost
    if curvatureHoldBoost == nil then
        curvatureHoldBoost = Defaults.CONFIG.curvatureHoldBoost
    end

    if not (curvatureLeadScale and curvatureLeadScale > 0) then
        return
    end

    local kappaLimit = Constants.PHYSICS_LIMITS.curvature or 0
    local dkappaLimit = Constants.PHYSICS_LIMITS.curvatureRate or 0
    local arLimit = Constants.PHYSICS_LIMITS.radialAcceleration or 0
    local jrLimit = Constants.PHYSICS_LIMITS.radialJerk or 0

    local normalizedKappa = 0
    if kappaLimit > 0 then
        normalizedKappa = math.clamp(math.abs(kinematics.filteredKappa) / kappaLimit, 0, 1)
    end

    local normalizedDkappa = 0
    if dkappaLimit > 0 then
        normalizedDkappa = math.clamp(math.abs(kinematics.filteredDkappa) / dkappaLimit, 0, 1)
    end

    local normalizedAr = 0
    if arLimit > 0 then
        normalizedAr = math.clamp(math.abs(kinematics.filteredAr) / arLimit, 0, 1)
    end

    local normalizedJr = 0
    if jrLimit > 0 then
        normalizedJr = math.clamp(math.abs(kinematics.filteredJr) / jrLimit, 0, 1)
    end

    local curveSeverity = math.max(normalizedKappa, normalizedDkappa)
    local curveJerkSeverity = math.max(normalizedAr, normalizedJr)
    local severityBoost = math.max(curveSeverity * curvatureLeadScale, curveJerkSeverity * curvatureHoldBoost)

    if severityBoost > 0 then
        local curveLeadTime = severityBoost * state.responseWindowBase
        local approachSpeed = math.max(state.approachSpeed or 0, 0)
        state.curveLeadTime = curveLeadTime
        state.curveLeadDistance = math.max(severityBoost * approachSpeed * state.responseWindowBase, 0)
        state.curveHoldDistance = math.max(curveJerkSeverity * approachSpeed * PROXIMITY_HOLD_GRACE, 0)
        state.responseWindow = state.responseWindow + curveLeadTime
    end

    state.curveSeverity = curveSeverity
    state.curveJerkSeverity = curveJerkSeverity
end

function PressDecision.computeRadii(state, kinematics, safeRadius, telemetry, now)
    local approaching = state.approaching == true
    local approachSpeed = math.max(state.approachSpeed or 0, 0)
    local responseWindow = math.max(state.responseWindow or 0, 0)
    local baseWindow = math.max(state.responseWindowBase or responseWindow, PROXIMITY_PRESS_GRACE)
    local safe = math.max(safeRadius or 0, Constants.EPSILON)
    state.safeRadius = safe

    local dynamicLeadBase
    if approaching then
        dynamicLeadBase = math.max(approachSpeed * PROXIMITY_PRESS_GRACE, safe * 0.12)
    else
        dynamicLeadBase = safe * 0.12
    end
    dynamicLeadBase = math.min(dynamicLeadBase, safe * 0.5)

    local distance = math.max(kinematics.distance or safe, safe)
    local excessDistance = math.max(distance - safe, 0)
    local normalizedDistance = 0
    if safe > 0 then
        normalizedDistance = math.clamp(excessDistance / safe, 0, 16)
    end

    local minSpeed = Defaults.CONFIG.minSpeed or 10
    local normalizedSpeed = 0
    if minSpeed > 0 then
        normalizedSpeed = math.tanh(approachSpeed / minSpeed)
    end

    local lookaheadRatio = 0
    if baseWindow > 0 then
        lookaheadRatio = responseWindow / baseWindow
    end
    local lookaheadGain = math.sqrt(1 + lookaheadRatio * lookaheadRatio) - 1

    local predictedImpact = state.predictedImpact
    local impactRatio = 0
    if approaching and Helpers.isFiniteNumber(predictedImpact) and predictedImpact > 0 then
        impactRatio = math.clamp(responseWindow / math.max(predictedImpact, PROXIMITY_PRESS_GRACE), -4, 4)
    end

    local curvatureEnergy = math.sqrt(
        (state.curveSeverity or 0) * (state.curveSeverity or 0)
            + (state.curveJerkSeverity or 0) * (state.curveJerkSeverity or 0)
    )
    local curvaturePulse = math.sin(math.min(curvatureEnergy * math.pi * 0.5, math.pi / 2))
    curvaturePulse *= curvaturePulse

    local radialAccelerationLimit = (Constants.PHYSICS_LIMITS.radialAcceleration or 0) + 1
    local radialJerkLimit = (Constants.PHYSICS_LIMITS.radialJerk or 0) + 1

    local normalizedAr = 0
    if radialAccelerationLimit > 0 then
        normalizedAr = math.abs(kinematics.filteredAr or 0) / radialAccelerationLimit
    end
    local normalizedJr = 0
    if radialJerkLimit > 0 then
        normalizedJr = math.abs(kinematics.filteredJr or 0) / radialJerkLimit
    end

    local accelerationGain = math.sqrt(1 + normalizedAr * normalizedAr) - 1
    local jerkGain = math.sqrt(1 + normalizedJr * normalizedJr) - 1

    local simulation
    local horizon = responseWindow + PROXIMITY_HOLD_GRACE
    local maxHorizon = math.max(state.timeToImpact or responseWindow, PROXIMITY_PRESS_GRACE) * 1.5

    local ballisticInputs = PressDecision.ballisticScratch
    Helpers.clearTable(ballisticInputs)

    ballisticInputs.safe = safe
    ballisticInputs.distance = kinematics.distance or safe
    ballisticInputs.vr = state.relativeFilteredVr or (kinematics.filteredVr or 0)
    ballisticInputs.ar = kinematics.filteredAr or 0
    ballisticInputs.jr = kinematics.filteredJr or 0
    ballisticInputs.curvature = kinematics.filteredKappa or 0
    ballisticInputs.curvatureRate = kinematics.filteredDkappa or 0
    ballisticInputs.speed = approachSpeed
    ballisticInputs.horizon = horizon
    ballisticInputs.maxHorizon = maxHorizon

    local cache
    if telemetry then
        cache = Helpers.ensureBallisticCache(telemetry)
    end

    local reusedSimulation = false
    local cacheKey
    if cache then
        local refresh, quantizedKey = Helpers.shouldRefreshBallisticCache(cache, ballisticInputs, now)
        cacheKey = quantizedKey
        if refresh then
            simulation = Helpers.simulateBallisticProximity({
                safe = ballisticInputs.safe,
                distance = ballisticInputs.distance,
                vr = ballisticInputs.vr,
                ar = ballisticInputs.ar,
                jr = ballisticInputs.jr,
                curvature = ballisticInputs.curvature,
                curvatureRate = ballisticInputs.curvatureRate,
                curvatureJerk = 0,
                speed = ballisticInputs.speed,
                horizon = ballisticInputs.horizon,
                maxHorizon = ballisticInputs.maxHorizon,
                reuse = cache.result,
            })

            local cacheInputs = cache.inputs
            Helpers.clearTable(cacheInputs)
            for key, value in pairs(ballisticInputs) do
                cacheInputs[key] = value
            end
            cache.timestamp = now
            cache.result = simulation
            cache.reuseCount = cache.reuseCount or 0
            cache.hitStreak = 0
            cache.quantizedKey = quantizedKey or cache.quantizedKey
        else
            simulation = cache.result
            cache.reuseCount = (cache.reuseCount or 0) + 1
            reusedSimulation = true
            if quantizedKey then
                cache.quantizedKey = quantizedKey
            end
        end
    end

    if not simulation then
        simulation = Helpers.simulateBallisticProximity({
            safe = ballisticInputs.safe,
            distance = ballisticInputs.distance,
            vr = ballisticInputs.vr,
            ar = ballisticInputs.ar,
            jr = ballisticInputs.jr,
            curvature = ballisticInputs.curvature,
            curvatureRate = ballisticInputs.curvatureRate,
            curvatureJerk = 0,
            speed = ballisticInputs.speed,
            horizon = ballisticInputs.horizon,
            maxHorizon = ballisticInputs.maxHorizon,
        })
    end

    state.proximitySimulationCached = reusedSimulation
    if cache then
        state.proximitySimulationCacheKey = cache.quantizedKey or cacheKey
        state.proximitySimulationCacheHits = cache.reuseCount or 0
        state.proximitySimulationCacheStreak = cache.hitStreak or 0
    else
        state.proximitySimulationCacheKey = nil
        state.proximitySimulationCacheHits = 0
        state.proximitySimulationCacheStreak = 0
    end
    state.ballisticInputs = ballisticInputs

    local normalizedIntrusion = math.max(simulation.normalizedPeakIntrusion or 0, 0)
    local weightedIntrusion = math.max(simulation.normalizedWeightedIntrusion or 0, 0)
    local areaIntrusion = math.max(simulation.normalizedIntrusionArea or 0, 0)
    local ballisticGain = math.max(simulation.normalizedBallisticEnergy or 0, 0)
    local velocitySignature = math.max(simulation.velocitySignature or 0, 0)
    local simulationUrgency = math.max(simulation.urgency or 0, 0)
    local simulationQuality = math.max(simulation.quality or 0, 0)
    local curvatureSignature = math.max(simulation.curvatureSignature or 0, 0)
    local averageDistance = math.max(simulation.averageDistance or excessDistance, 0)

    local baseManifold = math.sqrt(1 + normalizedSpeed * normalizedSpeed + curvatureEnergy * curvatureEnergy) - 1
    local simulationEnergy = math.sqrt(1 + (weightedIntrusion + areaIntrusion + ballisticGain) ^ 2) - 1
    local manifold = baseManifold + simulationEnergy

    local distanceSuppression = math.exp(-normalizedDistance * (0.45 + 0.4 * normalizedSpeed))
    distanceSuppression *= math.exp(-averageDistance / math.max(safe, Constants.EPSILON))
    distanceSuppression = math.clamp(distanceSuppression, 0, 1)

    local ballisticProjection = approachSpeed * responseWindow
    local proximityEnvelope = math.max(
        ballisticProjection * (0.25 + 0.75 * manifold)
            + safe
                * (
                    0.35 * normalizedIntrusion
                        + 0.28 * weightedIntrusion
                        + 0.22 * ballisticGain
                        + 0.18 * simulationUrgency
                        + 0.12 * curvaturePulse
                ),
        0
    )

    local logisticDriver = manifold
        + lookaheadGain * (1 + simulationQuality * 0.4)
        + accelerationGain * 0.5
        + jerkGain * 0.35
        + curvatureSignature * 0.25
        + simulationUrgency * 0.4
        + velocitySignature * 0.3
        - distanceSuppression
        - math.exp(-math.max(1 - math.abs(impactRatio), 0) * 0.6)

    logisticDriver = math.clamp(logisticDriver, -14, 14)
    local proximityLogistic = 1 / (1 + math.exp(-5.5 * logisticDriver))

    local adaptiveLead = dynamicLeadBase + proximityLogistic * (proximityEnvelope - dynamicLeadBase)
    adaptiveLead += safe * (1 - distanceSuppression) * (0.08 + 0.12 * simulationUrgency)
    adaptiveLead += safe * (accelerationGain * 0.08 + jerkGain * 0.06)
    adaptiveLead += safe * velocitySignature * 0.05
    adaptiveLead = math.max(adaptiveLead, dynamicLeadBase)
    adaptiveLead = math.min(adaptiveLead, safe * 0.8)

    state.curveLeadApplied = math.max(adaptiveLead - dynamicLeadBase, 0)
    state.pressRadius = safe + adaptiveLead

    local holdLeadBase
    if approaching then
        holdLeadBase = math.max(approachSpeed * PROXIMITY_HOLD_GRACE, safe * 0.12)
    else
        holdLeadBase = safe * 0.12
    end
    holdLeadBase = math.min(holdLeadBase, safe * 0.6)

    local holdLead = holdLeadBase
        + proximityLogistic
            * (state.curveHoldDistance + safe * (0.4 * weightedIntrusion + 0.35 * areaIntrusion + 0.25 * normalizedIntrusion))
    holdLead += safe * simulationUrgency * 0.18
    holdLead += safe * (velocitySignature * 0.08 + curvatureEnergy * 0.06)
    holdLead = math.min(holdLead, safe * 0.9)

    state.curveHoldApplied = math.max(holdLead - holdLeadBase, 0)
    state.holdRadius = state.pressRadius + holdLead

    state.proximityBaseLead = dynamicLeadBase
    state.proximityAdaptiveLead = adaptiveLead
    state.proximityEnvelope = proximityEnvelope
    state.proximitySynthesis = manifold
    state.proximityManifold = baseManifold
    state.proximitySimulationEnergy = simulationEnergy
    state.proximitySimulationUrgency = simulationUrgency
    state.proximitySimulationQuality = simulationQuality
    state.proximityVelocityImprint = velocitySignature
    state.proximityLogistic = proximityLogistic
    state.proximityDistanceSuppression = distanceSuppression
    state.proximityBallistic = ballisticProjection
    state.proximityLookaheadGain = lookaheadGain
    state.proximityImpactRatio = impactRatio
    state.proximityHoldLead = holdLead
    state.proximitySimulation = simulation
    state.proximityWeightedIntrusion = weightedIntrusion
    state.proximityBallisticGain = ballisticGain
end

function PressDecision.computeRadiusTimes(state, kinematics, safeRadius)
    local timeToPressRadiusFallback = math.huge
    local timeToHoldRadiusFallback = math.huge
    local timeToPressRadiusPolynomial
    local timeToHoldRadiusPolynomial
    local timeToPressRadius = math.huge
    local timeToHoldRadius = math.huge

    if state.approaching then
        local speed = math.max(state.approachSpeed, Constants.EPSILON)
        timeToPressRadiusFallback = math.max(kinematics.distance - state.pressRadius, 0) / speed
        timeToHoldRadiusFallback = math.max(kinematics.distance - state.holdRadius, 0) / speed

        local radialToPress = kinematics.filteredD + safeRadius - state.pressRadius
        local radialToHold = kinematics.filteredD + safeRadius - state.holdRadius

        local pressPolynomial =
            Helpers.solveRadialImpactTime(
                radialToPress,
                state.relativeFilteredVr or (kinematics.filteredVr or 0),
                kinematics.filteredAr,
                kinematics.filteredJr
            )
        if pressPolynomial and pressPolynomial > Constants.EPSILON then
            timeToPressRadiusPolynomial = pressPolynomial
            timeToPressRadius = pressPolynomial
        else
            timeToPressRadius = timeToPressRadiusFallback
        end

        local holdPolynomial =
            Helpers.solveRadialImpactTime(
                radialToHold,
                state.relativeFilteredVr or (kinematics.filteredVr or 0),
                kinematics.filteredAr,
                kinematics.filteredJr
            )
        if holdPolynomial and holdPolynomial > Constants.EPSILON then
            timeToHoldRadiusPolynomial = holdPolynomial
            timeToHoldRadius = holdPolynomial
        else
            timeToHoldRadius = timeToHoldRadiusFallback
        end
    end

    local holdWindow = state.responseWindow + PROXIMITY_HOLD_GRACE
    if state.approaching and timeToHoldRadiusPolynomial then
        local refinedHoldWindow = math.max(timeToHoldRadiusPolynomial, PROXIMITY_HOLD_GRACE)
        holdWindow = math.min(holdWindow, refinedHoldWindow)
        if holdWindow < state.responseWindow then
            holdWindow = state.responseWindow
        end
    end

    holdWindow = math.max(holdWindow, PROXIMITY_HOLD_GRACE)

    local predictedImpact = math.huge
    if state.approaching then
        predictedImpact = math.min(state.timeToImpact, timeToPressRadius, state.timeToImpactFallback)
        if state.timeToImpactPolynomial then
            predictedImpact = math.min(predictedImpact, state.timeToImpactPolynomial)
        end
        if timeToPressRadiusPolynomial then
            predictedImpact = math.min(predictedImpact, timeToPressRadiusPolynomial)
        end
    end

    if not Helpers.isFiniteNumber(predictedImpact) or predictedImpact < 0 then
        predictedImpact = math.huge
    end

    state.timeToPressRadiusFallback = timeToPressRadiusFallback
    state.timeToHoldRadiusFallback = timeToHoldRadiusFallback
    state.timeToPressRadiusPolynomial = timeToPressRadiusPolynomial
    state.timeToHoldRadiusPolynomial = timeToHoldRadiusPolynomial
    state.timeToPressRadius = timeToPressRadius
    state.timeToHoldRadius = timeToHoldRadius
    state.holdWindow = holdWindow
    state.predictedImpact = predictedImpact
end

function PressDecision.computeSchedulingParameters(state, config)
    local reactionBias = config.pressReactionBias
    if reactionBias == nil then
        reactionBias = Defaults.CONFIG.pressReactionBias
    end
    if not Helpers.isFiniteNumber(reactionBias) or reactionBias < 0 then
        reactionBias = 0
    end

    local scheduleSlack = config.pressScheduleSlack
    if scheduleSlack == nil then
        scheduleSlack = Defaults.CONFIG.pressScheduleSlack
    end
    if not Helpers.isFiniteNumber(scheduleSlack) or scheduleSlack < 0 then
        scheduleSlack = 0
    end

    local maxLookahead = config.pressMaxLookahead
    if maxLookahead == nil then
        maxLookahead = Defaults.CONFIG.pressMaxLookahead
    end
    if not Helpers.isFiniteNumber(maxLookahead) or maxLookahead <= 0 then
        maxLookahead = Defaults.CONFIG.pressMaxLookahead
    end
    if maxLookahead < PROXIMITY_PRESS_GRACE then
        maxLookahead = PROXIMITY_PRESS_GRACE
    end

    local lookaheadGoal = config.pressLookaheadGoal
    if lookaheadGoal == nil then
        lookaheadGoal = Defaults.CONFIG.pressLookaheadGoal
    end
    if not Helpers.isFiniteNumber(lookaheadGoal) or lookaheadGoal <= 0 then
        lookaheadGoal = 0
    elseif maxLookahead < lookaheadGoal then
        maxLookahead = lookaheadGoal
    end

    local confidencePadding = config.pressConfidencePadding
    if confidencePadding == nil then
        confidencePadding = Defaults.CONFIG.pressConfidencePadding
    end
    if not Helpers.isFiniteNumber(confidencePadding) or confidencePadding < 0 then
        confidencePadding = 0
    end

    local minDetectionTime = config.pressMinDetectionTime
    if minDetectionTime == nil then
        minDetectionTime = Defaults.CONFIG.pressMinDetectionTime
    end
    if not Helpers.isFiniteNumber(minDetectionTime) or minDetectionTime < 0 then
        minDetectionTime = 0
    end

    state.reactionBias = reactionBias
    state.scheduleSlack = scheduleSlack
    state.maxLookahead = maxLookahead
    state.lookaheadGoal = lookaheadGoal
    state.confidencePadding = confidencePadding
    state.minDetectionTime = minDetectionTime
end

function PressDecision.applySmartTuning(state, now, ballId)
    local smartTelemetry
    local smartTuningApplied = Helpers.applySmartTuning({
        ballId = ballId,
        now = now,
        baseReactionBias = state.reactionBias,
        baseScheduleSlack = state.scheduleSlack,
        baseConfidencePadding = state.confidencePadding,
        sigma = state.sigma,
        mu = state.mu,
        muPlus = state.muPlus,
        muMinus = state.muMinus,
        delta = state.delta,
        ping = state.ping,
        lookaheadGoal = state.lookaheadGoal,
    })

    if smartTuningApplied then
        local appliedReaction = smartTuningApplied.reactionBias
        if Helpers.isFiniteNumber(appliedReaction) and appliedReaction >= 0 then
            state.reactionBias = appliedReaction
        end

        local appliedSlack = smartTuningApplied.scheduleSlack
        if Helpers.isFiniteNumber(appliedSlack) and appliedSlack >= 0 then
            state.scheduleSlack = appliedSlack
        end

        local appliedConfidence = smartTuningApplied.confidencePadding
        if Helpers.isFiniteNumber(appliedConfidence) and appliedConfidence >= 0 then
            state.confidencePadding = appliedConfidence
        end

        smartTelemetry = Helpers.normalizeSmartTuningPayload(smartTuningApplied.telemetry)
    end

    state.smartTelemetry = smartTelemetry
end

function PressDecision.computeSchedule(state)
    local scheduleLead = math.max(state.delta + state.reactionBias, PROXIMITY_PRESS_GRACE)
    state.scheduleLead = scheduleLead

    local smartTelemetry = state.smartTelemetry
    if smartTelemetry then
        smartTuningState.scheduleLead = scheduleLead
        smartTelemetry.scheduleLead = scheduleLead
        smartTelemetry.latency = smartTuningState.delta

        local applied = smartTelemetry.applied
        if typeof(applied) == "table" then
            applied.scheduleLead = scheduleLead
        end

        local target = smartTelemetry.target
        if typeof(target) == "table" then
            target.scheduleLead = scheduleLead
        end
    end
end

function PressDecision.computeDecisionFlags(state, kinematics, telemetry, now, ballId)
    local inequalityPress =
        state.targetingMe and state.approaching and state.muValid and state.sigmaValid and state.muPlus <= 0
    local confidencePress =
        state.targetingMe and state.muValid and state.sigmaValid and state.muPlus <= -state.confidencePadding

    local detectionAge
    local detectionReady = true
    if state.targetingMe and state.minDetectionTime and state.minDetectionTime > 0 then
        if telemetry and telemetry.targetDetectedAt then
            detectionAge = math.max(now - telemetry.targetDetectedAt, 0)
            detectionReady = detectionAge >= state.minDetectionTime
        else
            detectionReady = false
        end
    end

    local detectionConfidence = 0
    local detectionMin = state.minDetectionTime or 0
    if Helpers.isFiniteNumber(detectionAge) then
        local denominator = detectionMin
        if not Helpers.isFiniteNumber(denominator) or denominator <= 0 then
            denominator = Constants.DETECTION_CONFIDENCE_GRACE or PROXIMITY_PRESS_GRACE
        end

        if denominator and denominator > 0 then
            local progress = math.clamp(detectionAge / denominator, 0, 2)
            local eased = math.tanh(progress)
            if detectionReady then
                detectionConfidence = 0.5 + 0.5 * eased
            else
                detectionConfidence = 0.25 * eased
            end
        end
    elseif detectionReady then
        detectionConfidence = 1
    end

    detectionConfidence = Helpers.clampNumber(detectionConfidence, 0, 1) or 0

    local timeUntilPress = state.predictedImpact - state.scheduleLead
    if not Helpers.isFiniteNumber(timeUntilPress) then
        timeUntilPress = math.huge
    end

    local canPredict = state.approaching and state.targetingMe and state.predictedImpact < math.huge
    local shouldDelay = canPredict and not confidencePress and state.predictedImpact > state.scheduleLead
    local withinLookahead = state.maxLookahead <= 0 or timeUntilPress <= state.maxLookahead
    local shouldSchedule = shouldDelay and withinLookahead

    local proximityPress =
        state.targetingMe
        and state.approaching
        and (
            kinematics.distance <= state.pressRadius
            or state.timeToPressRadius <= state.responseWindow
            or state.timeToImpact <= state.responseWindow
        )

    local proximityHold =
        state.targetingMe
        and state.approaching
        and (
            kinematics.distance <= state.holdRadius
            or state.timeToHoldRadius <= state.holdWindow
            or state.timeToImpact <= state.holdWindow
        )

    local distancePenalty = 1 - math.clamp(state.proximityDistanceSuppression or 0, 0, 1)
    local logistic = math.clamp(state.proximityLogistic or 0, 0, 1)
    local urgency = math.max(state.proximitySimulationUrgency or 0, 0)
    local ballisticGain = math.max(state.proximityBallisticGain or 0, 0)
    local weightedIntrusion = math.max(state.proximityWeightedIntrusion or 0, 0)
    local ballisticProjection = math.max(state.proximityBallistic or 0, 0)
    local safeRadius = state.safeRadius or kinematics.distance or 0

    local severity = math.clamp(
        logistic * (1 + 0.6 * urgency)
            + distancePenalty * 0.35
            + ballisticGain * 0.4
            + weightedIntrusion * 0.3,
        0,
        4
    ) / 4

    local ballisticFlux = 0
    if safeRadius > 0 then
        ballisticFlux = math.clamp(ballisticProjection / safeRadius, 0, 4) / 4
    end
    ballisticFlux += math.clamp(ballisticGain * 0.5, 0, 1)
    ballisticFlux = math.clamp(ballisticFlux, 0, 1)

    local intensity = math.clamp(0.6 * severity + 0.25 * urgency + 0.15 * ballisticFlux, 0, 1)

    local speedComponent = 0
    local minSpeed = Defaults.CONFIG.minSpeed or 10
    if minSpeed > 0 then
        speedComponent = math.tanh(math.abs(state.approachSpeed or 0) / minSpeed)
    end

    local tempo = 0
    if Helpers.isFiniteNumber(state.timeToImpact) and state.timeToImpact < math.huge then
        local baseWindow = math.max(state.responseWindow or PROXIMITY_PRESS_GRACE, PROXIMITY_PRESS_GRACE)
        if baseWindow > 0 then
            tempo = math.clamp(1 - math.exp(-math.max(baseWindow - state.timeToImpact, 0) / baseWindow), 0, 1)
        end
    end

    detectionConfidence = math.clamp(state.detectionConfidence or detectionConfidence, 0, 1)
    local tempoComponent = math.max(tempo, speedComponent)

    local envelopeAnalytics = Helpers.updateThreatEnvelope(state, telemetry, {
        now = now,
        dt = kinematics and kinematics.dt,
        logistic = logistic,
        intensity = intensity,
        severity = severity,
        detectionConfidence = detectionConfidence,
        tempo = tempo,
        speedComponent = speedComponent,
        urgency = urgency,
        sample = math.max(severity, logistic, intensity),
    })

    if envelopeAnalytics then
        detectionConfidence = envelopeAnalytics.detectionConfidence or detectionConfidence
        tempoComponent = math.max(tempoComponent, envelopeAnalytics.tempo or 0)
        state.threatSpectralFast = envelopeAnalytics.fast
        state.threatSpectralMedium = envelopeAnalytics.medium
        state.threatSpectralSlow = envelopeAnalytics.slow
        state.threatLoad = envelopeAnalytics.load
        state.threatAcceleration = envelopeAnalytics.acceleration
        state.threatJerk = envelopeAnalytics.jerk
        state.threatBoost = envelopeAnalytics.detectionBoost
        state.threatInstantReady = envelopeAnalytics.instantReady and true or false
        if envelopeAnalytics.instantReady and not detectionReady then
            detectionReady = true
        end
    else
        state.threatSpectralFast = state.threatSpectralFast or math.max(severity, logistic)
        state.threatSpectralMedium = state.threatSpectralMedium or state.threatSpectralFast
        state.threatSpectralSlow = state.threatSpectralSlow or state.threatSpectralMedium
        state.threatLoad = state.threatLoad or math.max(severity, logistic)
        state.threatAcceleration = state.threatAcceleration or 0
        state.threatJerk = state.threatJerk or 0
        state.threatBoost = state.threatBoost or 0
        state.threatInstantReady = state.threatInstantReady and true or false
    end

    local previousThreat = telemetry and telemetry.threat
    local threatMomentum = Helpers.clampNumber(
        state.threatMomentum or (previousThreat and previousThreat.momentum) or 0,
        -4,
        4
    ) or 0
    local threatVolatility = math.clamp(state.threatVolatility or (previousThreat and previousThreat.volatility) or 0, 0, 1)
    local threatStability = math.clamp(state.threatStability or (previousThreat and previousThreat.stability) or 0, 0, 1)
    local threatLoad = math.clamp(
        state.threatLoad
            or (previousThreat and previousThreat.load)
            or math.max(severity, logistic, intensity),
        0,
        1
    )

    local momentumScale = Constants.THREAT_MOMENTUM_READY_SCALE or 0.9
    local normalizedMomentum = 0.5 + 0.5 * math.tanh(threatMomentum * momentumScale)
    local positiveMomentum = math.max(normalizedMomentum - 0.5, 0) * 2
    local negativeMomentum = math.max(0.5 - normalizedMomentum, 0) * 2

    local momentumConfidenceWeight = Constants.THREAT_MOMENTUM_CONFIDENCE_WEIGHT or 0.6
    local stabilityConfidenceWeight = Constants.THREAT_STABILITY_CONFIDENCE_WEIGHT or 0.3
    local loadConfidenceWeight = Constants.THREAT_LOAD_CONFIDENCE_WEIGHT or 0.2
    local volatilityConfidenceWeight = Constants.THREAT_VOLATILITY_CONFIDENCE_WEIGHT or 0.35

    local stabilityBoost = threatStability * stabilityConfidenceWeight
    local loadBoost = threatLoad * loadConfidenceWeight
    local momentumBoost = positiveMomentum * momentumConfidenceWeight
    local volatilityPenalty = math.max(threatVolatility - threatStability, 0) * volatilityConfidenceWeight
    local detectionMomentumBoost = math.clamp(momentumBoost + stabilityBoost + loadBoost - volatilityPenalty, -0.5, 0.55)

    detectionConfidence = math.clamp(detectionConfidence + detectionMomentumBoost, 0, 1)

    local readinessMomentum = math.clamp(momentumBoost + stabilityBoost + loadBoost, 0, 1)
    local readinessVolatilityWeight = Constants.THREAT_VOLATILITY_READY_WEIGHT or 0.2
    local readinessAdjusted = math.clamp(
        readinessMomentum - readinessVolatilityWeight * math.max(threatVolatility - threatStability, 0),
        0,
        1
    )

    local momentumReadyThreshold = Constants.THREAT_MOMENTUM_READY_THRESHOLD or 0.38
    local momentumReady = readinessAdjusted >= momentumReadyThreshold
    if not detectionReady and momentumReady then
        detectionReady = true
    end

    local slackTightenWeight = Constants.THREAT_MOMENTUM_SLACK_TIGHTEN or 0.6
    local stabilitySlackWeight = Constants.THREAT_STABILITY_SLACK_TIGHTEN or 0.25
    local volatilitySlackWeight = Constants.THREAT_VOLATILITY_SLACK_EXPAND or 0.35
    local slackScale = 1 - positiveMomentum * slackTightenWeight - threatStability * stabilitySlackWeight
    slackScale += math.max(negativeMomentum, math.max(threatVolatility - threatStability, 0)) * volatilitySlackWeight
    local minSlackScale = Constants.THREAT_SCHEDULE_SLACK_MIN_SCALE or 0.35
    local maxSlackScale = Constants.THREAT_SCHEDULE_SLACK_MAX_SCALE or 1.35
    slackScale = math.clamp(slackScale, minSlackScale, maxSlackScale)

    if Helpers.isFiniteNumber(state.scheduleSlack) and state.scheduleSlack > 0 then
        local baseSlack = state.scheduleSlack
        local tightenedSlack = math.clamp(
            baseSlack * slackScale,
            PROXIMITY_PRESS_GRACE * 0.35,
            math.max(baseSlack, PROXIMITY_PRESS_GRACE)
        )
        state.scheduleSlack = tightenedSlack
        state.scheduleSlackScale = slackScale
    else
        state.scheduleSlackScale = 1
    end

    state.detectionMomentumBoost = detectionMomentumBoost
    state.threatReadinessMomentum = readinessAdjusted
    state.threatMomentumReady = momentumReady
    state.threatVolatility = threatVolatility
    state.threatStability = threatStability
    state.threatLoad = threatLoad
    state.threatStabilityBoost = stabilityBoost
    state.threatLoadBoost = loadBoost
    state.threatMomentum = threatMomentum
    state.threatMomentumBoost = momentumBoost
    state.threatVolatilityPenalty = volatilityPenalty

    local function resolveFiniteTime(value)
        if Helpers.isFiniteNumber(value) and value >= 0 then
            return value
        end
        return math.huge
    end

    local scheduleLead = math.max(state.scheduleLead or 0, 0)
    local budgetHorizon = math.min(
        resolveFiniteTime(state.predictedImpact),
        resolveFiniteTime(state.timeToImpact),
        resolveFiniteTime(state.timeToPressRadius),
        resolveFiniteTime(state.timeToHoldRadius)
    )
    if Helpers.isFiniteNumber(state.holdWindow) and state.holdWindow > 0 then
        budgetHorizon = math.min(budgetHorizon, state.holdWindow)
    end

    local threatBudget = timeUntilPress
    if not Helpers.isFiniteNumber(threatBudget) then
        threatBudget = math.huge
    end

    local horizonForRatio = budgetHorizon
    if not Helpers.isFiniteNumber(horizonForRatio) or horizonForRatio <= 0 then
        horizonForRatio = math.max(scheduleLead, PROXIMITY_PRESS_GRACE)
    end

    local budgetRatio = 0
    if Helpers.isFiniteNumber(threatBudget) and Helpers.isFiniteNumber(horizonForRatio) and horizonForRatio > 0 then
        budgetRatio = math.clamp(threatBudget / horizonForRatio, -1, 1)
    end

    local pressureDenominator = math.max(
        scheduleLead,
        Constants.THREAT_BUDGET_PRESSURE_DENOM or 0.12,
        PROXIMITY_PRESS_GRACE
    )

    local budgetPressure = 0
    if Helpers.isFiniteNumber(threatBudget) and threatBudget < 0 then
        budgetPressure = math.clamp(-threatBudget / pressureDenominator, 0, 1)
    end

    local latencyGap = 0
    if Helpers.isFiniteNumber(detectionMin) and detectionMin > 0 then
        latencyGap = detectionMin - math.max(detectionAge or 0, 0)
    end

    local budgetConfidenceGain = math.clamp(
        budgetPressure * (Constants.THREAT_BUDGET_CONFIDENCE_GAIN or 0.22),
        0,
        0.35
    )
    detectionConfidence = math.clamp(detectionConfidence + budgetConfidenceGain, 0, 1)

    local readinessScore = math.clamp(
        (Constants.THREAT_BUDGET_CONFIDENCE_WEIGHT or 0.55) * detectionConfidence
            + (Constants.THREAT_BUDGET_PRESSURE_WEIGHT or 0.3) * budgetPressure
            + (Constants.THREAT_BUDGET_BOOST_WEIGHT or 0.2) * math.clamp(state.threatBoost or 0, 0, 1)
            + (Constants.THREAT_BUDGET_TEMPO_WEIGHT or 0.15) * tempoComponent
            + (Constants.THREAT_BUDGET_MOMENTUM_WEIGHT or 0.18) * (state.threatReadinessMomentum or 0)
            - (Constants.THREAT_BUDGET_LATENCY_WEIGHT or 0.08) * math.max(latencyGap, 0),
        0,
        1
    )

    local budgetReady = false
    if not detectionReady then
        local budgetReadyScore = Constants.THREAT_BUDGET_READY_SCORE or 0.78
        local budgetPressureThreshold = Constants.THREAT_BUDGET_READY_PRESSURE or 0.55
        local budgetConfidenceThreshold = Constants.THREAT_BUDGET_READY_CONFIDENCE or 0.68

        if readinessScore >= budgetReadyScore
            or (budgetPressure >= budgetPressureThreshold and detectionConfidence >= budgetConfidenceThreshold)
        then
            detectionReady = true
            budgetReady = true
        end
    end

    if budgetReady and not state.threatInstantReady then
        state.threatInstantReady = true
    end

    if detectionReady and not shouldPress and state.targetingMe and state.approaching then
        local pressurePressThreshold = Constants.THREAT_BUDGET_PRESS_THRESHOLD or 0.6
        if budgetPressure >= pressurePressThreshold then
            if threatBudget <= 0 or readinessScore >= (Constants.THREAT_BUDGET_PRESS_SCORE or 0.82) then
                shouldPress = true
            end
        end
    end

    if shouldDelay then
        local delayCutoff = Constants.THREAT_BUDGET_DELAY_CUTOFF or 0.35
        if budgetPressure >= delayCutoff or threatBudget <= 0 then
            shouldDelay = false
        end
    end

    shouldSchedule = shouldDelay and withinLookahead

    state.threatBudget = threatBudget
    state.threatBudgetHorizon = budgetHorizon
    state.threatBudgetRatio = budgetRatio
    state.threatBudgetPressure = budgetPressure
    state.threatLatencyGap = latencyGap
    state.threatBudgetReady = budgetReady
    state.threatBudgetInstantReady = budgetReady
    state.threatReadinessScore = readinessScore
    state.threatBudgetConfidenceGain = budgetConfidenceGain
    state.detectionConfidence = detectionConfidence

    local threatScore
    local threatConfidence
    if envelopeAnalytics and Helpers.isFiniteNumber(envelopeAnalytics.score) then
        threatScore = envelopeAnalytics.score
    else
        local loadSample = math.clamp(state.threatLoad or math.max(severity, logistic), 0, 1)
        threatScore = math.clamp(
            0.45 * logistic + 0.22 * intensity + 0.18 * detectionConfidence + 0.1 * tempoComponent + 0.05 * loadSample,
            0,
            1
        )
    end

    if envelopeAnalytics and Helpers.isFiniteNumber(envelopeAnalytics.confidence) then
        threatConfidence = envelopeAnalytics.confidence
    else
        local loadSample = math.clamp(state.threatLoad or math.max(severity, logistic), 0, 1)
        threatConfidence = math.clamp(0.5 * logistic + 0.2 * intensity + 0.2 * detectionConfidence + 0.1 * loadSample, 0, 1)
    end

    state.threatSeverity = severity
    state.threatIntensity = intensity
    state.threatTempo = tempoComponent
    state.threatScore = threatScore
    state.threatConfidence = threatConfidence

    local threatStatus = Helpers.resolveThreatStatus(threatScore)
    state.threatStatus = threatStatus

    state.detectionReady = detectionReady
    state.detectionAge = detectionAge

    if telemetry then
        local resolved, threatTelemetry = Helpers.updateThreatTelemetry(telemetry, state, kinematics, now, ballId)
        if resolved then
            state.threatStatus = resolved
        end
        if typeof(threatTelemetry) == "table" then
            if Helpers.isFiniteNumber(threatTelemetry.momentum) then
                state.threatMomentum = threatTelemetry.momentum
            end
            if Helpers.isFiniteNumber(threatTelemetry.volatility) then
                state.threatVolatility = threatTelemetry.volatility
            end
            if Helpers.isFiniteNumber(threatTelemetry.stability) then
                state.threatStability = threatTelemetry.stability
            end
            if Helpers.isFiniteNumber(threatTelemetry.confidence) then
                state.threatConfidence = threatTelemetry.confidence
            end
            if Helpers.isFiniteNumber(threatTelemetry.load) then
                state.threatLoad = threatTelemetry.load
            end
            if Helpers.isFiniteNumber(threatTelemetry.spectralFast) then
                state.threatSpectralFast = threatTelemetry.spectralFast
            end
            if Helpers.isFiniteNumber(threatTelemetry.spectralMedium) then
                state.threatSpectralMedium = threatTelemetry.spectralMedium
            end
            if Helpers.isFiniteNumber(threatTelemetry.spectralSlow) then
                state.threatSpectralSlow = threatTelemetry.spectralSlow
            end
            if Helpers.isFiniteNumber(threatTelemetry.acceleration) then
                state.threatAcceleration = threatTelemetry.acceleration
            end
            if Helpers.isFiniteNumber(threatTelemetry.jerk) then
                state.threatJerk = threatTelemetry.jerk
            end
            if Helpers.isFiniteNumber(threatTelemetry.detectionBoost) then
                state.threatBoost = threatTelemetry.detectionBoost
            end
            if type(threatTelemetry.instantReady) == "boolean" and threatTelemetry.instantReady and not detectionReady then
                detectionReady = true
            end
            if type(threatTelemetry.instantReady) == "boolean" then
                state.threatInstantReady = threatTelemetry.instantReady
            end
        end
    end

    local shouldPress = detectionReady and (proximityPress or inequalityPress or confidencePress)

    if not detectionReady then
        if state.threatInstantReady then
            shouldPress = proximityPress or inequalityPress or confidencePress
            detectionReady = shouldPress or detectionReady
        elseif state.threatBoost and state.threatBoost >= (Constants.THREAT_SPECTRUM_READY_THRESHOLD or 0.32) then
            shouldPress = proximityPress or inequalityPress or confidencePress
            detectionReady = shouldPress or detectionReady
        end
    end

    if detectionReady and state.threatBoost and state.threatBoost > 0 then
        shouldPress = proximityPress or inequalityPress or confidencePress or shouldPress
    end

    if telemetry then
        if shouldPress then
            telemetry.decisionAt = telemetry.decisionAt or now
        elseif not state.targetingMe then
            telemetry.decisionAt = nil
        end
    end

    local shouldHold = false
    if detectionReady then
        shouldHold = proximityHold or shouldPress
        if state.targetingMe and state.muValid and state.sigmaValid and state.muMinus < 0 then
            shouldHold = true
        end
    end

    state.inequalityPress = inequalityPress
    state.confidencePress = confidencePress
    state.timeUntilPress = timeUntilPress
    state.shouldDelay = shouldDelay
    state.withinLookahead = withinLookahead
    state.shouldSchedule = shouldSchedule
    state.proximityPress = proximityPress
    state.proximityHold = proximityHold
    state.shouldPress = shouldPress
    state.shouldHold = shouldHold
    state.detectionReady = detectionReady
    state.detectionAge = detectionAge
end

function PressDecision.evaluate(params)
    local config = params.config or Defaults.CONFIG
    local kinematics = params.kinematics
    local telemetry = params.telemetry
    local safeRadius = params.safeRadius or 0
    local now = params.now
    local ballId = params.ballId

    local decision = params.decision
    if decision == nil then
        decision = PressDecision.output
    end
    PressDecision.clearTable(decision)

    local state = PressDecision.scratch
    PressDecision.clearTable(state)

    PressDecision.computeConfidence(state, config, kinematics)
    state.targetingMe = Helpers.isTargetingMe(now)

    PressDecision.updateTelemetryState(state, telemetry, now, state.targetingMe, ballId)
    PressDecision.computeApproach(state, kinematics, safeRadius)
    PressDecision.computeCurveAdjustments(state, config, kinematics)
    PressDecision.computeRadii(state, kinematics, safeRadius, telemetry, now)
    PressDecision.computeRadiusTimes(state, kinematics, safeRadius)
    PressDecision.computeSchedulingParameters(state, config)
    PressDecision.applySmartTuning(state, now, ballId)
    PressDecision.computeSchedule(state)
    PressDecision.computeDecisionFlags(state, kinematics, telemetry, now, ballId)

    decision.ping = state.ping
    decision.delta = state.delta
    decision.mu = state.mu
    decision.sigma = state.sigma
    decision.z = state.z
    decision.muPlus = state.muPlus
    decision.muMinus = state.muMinus
    decision.muValid = state.muValid
    decision.sigmaValid = state.sigmaValid
    decision.targetingMe = state.targetingMe
    decision.approachSpeed = state.approachSpeed
    decision.approaching = state.approaching
    decision.playerRadialVelocity = state.playerRadialVelocity
    decision.relativeFilteredVr = state.relativeFilteredVr
    decision.relativeRawVr = state.relativeRawVr
    decision.timeToImpact = state.timeToImpact
    decision.timeToImpactFallback = state.timeToImpactFallback
    decision.timeToImpactPolynomial = state.timeToImpactPolynomial
    decision.responseWindow = state.responseWindow
    decision.curveLeadTime = state.curveLeadTime
    decision.curveLeadDistance = state.curveLeadDistance
    decision.curveHoldDistance = state.curveHoldDistance
    decision.curveSeverity = state.curveSeverity
    decision.curveJerkSeverity = state.curveJerkSeverity
    decision.curveLeadApplied = state.curveLeadApplied
    decision.curveHoldApplied = state.curveHoldApplied
    decision.pressRadius = state.pressRadius
    decision.holdRadius = state.holdRadius
    decision.proximityBaseLead = state.proximityBaseLead
    decision.proximityAdaptiveLead = state.proximityAdaptiveLead
    decision.proximityEnvelope = state.proximityEnvelope
    decision.proximitySynthesis = state.proximitySynthesis
    decision.proximityLogistic = state.proximityLogistic
    decision.proximityDistanceSuppression = state.proximityDistanceSuppression
    decision.proximityBallistic = state.proximityBallistic
    decision.proximityLookaheadGain = state.proximityLookaheadGain
    decision.proximityImpactRatio = state.proximityImpactRatio
    decision.proximityHoldLead = state.proximityHoldLead
    decision.proximityManifold = state.proximityManifold
    decision.proximitySimulationEnergy = state.proximitySimulationEnergy
    decision.proximitySimulationUrgency = state.proximitySimulationUrgency
    decision.proximitySimulationQuality = state.proximitySimulationQuality
    decision.proximityVelocityImprint = state.proximityVelocityImprint
    decision.proximitySimulation = Helpers.cloneTelemetryEvent(state.proximitySimulation)
    decision.proximityWeightedIntrusion = state.proximityWeightedIntrusion
    decision.proximityBallisticGain = state.proximityBallisticGain
    decision.proximitySimulationCached = state.proximitySimulationCached
    decision.proximitySimulationCacheKey = state.proximitySimulationCacheKey
    decision.proximitySimulationCacheHits = state.proximitySimulationCacheHits
    decision.proximitySimulationCacheStreak = state.proximitySimulationCacheStreak
    decision.threatScore = state.threatScore
    decision.threatSeverity = state.threatSeverity
    decision.threatIntensity = state.threatIntensity
    decision.threatTempo = state.threatTempo
    decision.threatStatus = state.threatStatus
    decision.threatConfidence = state.threatConfidence
    decision.threatLoad = state.threatLoad
    decision.threatSpectralFast = state.threatSpectralFast
    decision.threatSpectralMedium = state.threatSpectralMedium
    decision.threatSpectralSlow = state.threatSpectralSlow
    decision.threatMomentum = state.threatMomentum
    decision.threatMomentumBoost = state.threatMomentumBoost
    decision.threatVolatility = state.threatVolatility
    decision.threatStability = state.threatStability
    decision.threatStabilityBoost = state.threatStabilityBoost
    decision.threatAcceleration = state.threatAcceleration
    decision.threatJerk = state.threatJerk
    decision.threatBoost = state.threatBoost
    decision.threatInstantReady = state.threatInstantReady
    decision.threatMomentumReady = state.threatMomentumReady
    decision.threatReadinessMomentum = state.threatReadinessMomentum
    decision.threatVolatilityPenalty = state.threatVolatilityPenalty
    decision.threatLoadBoost = state.threatLoadBoost
    decision.threatBudget = state.threatBudget
    decision.threatBudgetHorizon = state.threatBudgetHorizon
    decision.threatBudgetRatio = state.threatBudgetRatio
    decision.threatBudgetPressure = state.threatBudgetPressure
    decision.threatLatencyGap = state.threatLatencyGap
    decision.threatBudgetReady = state.threatBudgetReady
    decision.threatReadiness = state.threatReadinessScore
    decision.threatBudgetConfidenceGain = state.threatBudgetConfidenceGain
    decision.detectionConfidence = state.detectionConfidence
    decision.detectionMomentumBoost = state.detectionMomentumBoost
    decision.timeToPressRadius = state.timeToPressRadius
    decision.timeToPressRadiusPolynomial = state.timeToPressRadiusPolynomial
    decision.timeToPressRadiusFallback = state.timeToPressRadiusFallback
    decision.timeToHoldRadius = state.timeToHoldRadius
    decision.timeToHoldRadiusPolynomial = state.timeToHoldRadiusPolynomial
    decision.timeToHoldRadiusFallback = state.timeToHoldRadiusFallback
    decision.holdWindow = state.holdWindow
    decision.predictedImpact = state.predictedImpact
    decision.reactionBias = state.reactionBias
    decision.scheduleSlack = state.scheduleSlack
    decision.scheduleSlackScale = state.scheduleSlackScale
    decision.maxLookahead = state.maxLookahead
    decision.lookaheadGoal = state.lookaheadGoal
    decision.confidencePadding = state.confidencePadding
    decision.smartTelemetry = state.smartTelemetry
    decision.scheduleLead = state.scheduleLead
    decision.inequalityPress = state.inequalityPress
    decision.confidencePress = state.confidencePress
    decision.timeUntilPress = state.timeUntilPress
    decision.shouldDelay = state.shouldDelay
    decision.withinLookahead = state.withinLookahead
    decision.shouldSchedule = state.shouldSchedule
    decision.proximityPress = state.proximityPress
    decision.proximityHold = state.proximityHold
    decision.shouldPress = state.shouldPress
    decision.shouldHold = state.shouldHold
    decision.detectionReady = state.detectionReady
    decision.detectionAge = state.detectionAge
    decision.minDetectionTime = state.minDetectionTime

    return decision
end

function Helpers.renderLoop()
    if initialization.destroyed then
        Helpers.clearScheduledPress(nil, "destroyed")
        Helpers.resetSpamBurst("destroyed")
        return
    end

    if not Context.player.LocalPlayer then
        Helpers.clearScheduledPress(nil, "missing-player")
        Helpers.resetSpamBurst("missing-player")
        return
    end

    if not Context.player.Character or not Context.player.RootPart then
        Context.hooks.updateStatusLabel({ "Auto-Parry F", "Status: waiting for character" })
        Helpers.safeClearBallVisuals()
        Helpers.clearScheduledPress(nil, "missing-character")
        Helpers.releaseParry()
        Helpers.resetSpamBurst("missing-character")
        return
    end

    Helpers.ensureBallsFolder(false)
    local folder = Context.player.BallsFolder
    if not folder then
        Context.hooks.updateStatusLabel({ "Auto-Parry F", "Ball: none", "Info: waiting for balls folder" })
        Helpers.safeClearBallVisuals()
        Helpers.clearScheduledPress(nil, "missing-balls-folder")
        Helpers.releaseParry()
        Helpers.resetSpamBurst("missing-balls-folder")
        return
    end

    if not state.enabled then
        Helpers.clearScheduledPress(nil, "disabled")
        Helpers.releaseParry()
        Context.hooks.updateStatusLabel({ "Auto-Parry F", "Status: OFF" })
        Helpers.safeClearBallVisuals()
        Helpers.updateToggleButton()
        Helpers.resetSpamBurst("disabled")
        return
    end

    local now = os.clock()
    Helpers.cleanupTelemetry(now)
    Helpers.prunePendingLatencyPresses(now)
    Helpers.maybeRunAutoTuning(now)

    local ball = Helpers.findRealBall(folder)
    if not ball or not ball:IsDescendantOf(Services.Workspace) then
        Context.hooks.updateStatusLabel({ "Auto-Parry F", "Ball: none", "Info: waiting for realBall..." })
        Helpers.safeClearBallVisuals()
        Helpers.clearScheduledPress(nil, "no-ball")
        Helpers.releaseParry()
        Helpers.resetSpamBurst("no-ball")
        return
    end

    local ballId = Helpers.getBallIdentifier(ball)
    if not ballId then
        Context.hooks.updateStatusLabel({ "Auto-Parry F", "Ball: unknown", "Info: missing identifier" })
        Helpers.safeClearBallVisuals()
        Helpers.clearScheduledPress(nil, "missing-identifier")
        Helpers.releaseParry()
        Helpers.resetSpamBurst("missing-identifier")
        return
    end

    if Context.scheduledPressState.ballId and Context.scheduledPressState.ballId ~= ballId then
        Helpers.clearScheduledPress(nil, "ball-changed")
    elseif Context.scheduledPressState.ballId == ballId and now - Context.scheduledPressState.lastUpdate > Context.smartPress.staleSeconds then
        Helpers.clearScheduledPress(ballId, "schedule-stale")
    end

    local telemetry = Helpers.ensureTelemetry(ballId, now)
    local safeRadius = config.safeRadius or 0
    local kinematics = BallKinematics.build(ball, Context.player.RootPart.Position, telemetry, safeRadius, now)

    local decision = PressDecision.evaluate({
        config = config,
        kinematics = kinematics,
        telemetry = telemetry,
        safeRadius = safeRadius,
        now = now,
        ballId = ballId,
        decision = PressDecision.output,
    })

    local fired = false
    local released = false

    local oscillationTriggered = false
    local spamFallback = false
    if telemetry then
        Helpers.updateTargetingAggressionMemory(telemetry, decision, kinematics, config, now)
        oscillationTriggered = Helpers.evaluateOscillation(telemetry, now)
        if oscillationTriggered and Context.runtime.parryHeld and Context.runtime.parryHeldBallId == ballId then
            if Helpers.shouldForceOscillationPress(decision, telemetry, now, config) then
                spamFallback = Helpers.pressParry(ball, ballId, true, decision)
                if spamFallback then
                    telemetry.lastOscillationApplied = now
                    Helpers.startSpamBurst(ballId, now, decision, telemetry, kinematics)
                end
            end
        end
    end

    local targetingBurst
    if telemetry then
        targetingBurst = Helpers.evaluateTargetingSpam(decision, telemetry, now, config, kinematics, ballId)
        if targetingBurst and targetingBurst.startBurst then
            local forced = false
            if targetingBurst.forcePress and (not Context.runtime.virtualInputUnavailable or Context.runtime.virtualInputRetryAt <= now) then
                forced = Helpers.pressParry(ball, ballId, true, decision)
                if forced then
                    telemetry.lastTargetingApplied = now
                    spamFallback = true
                    fired = true
                end
            end

            Helpers.startSpamBurst(ballId, now, decision, telemetry, kinematics, targetingBurst.reason, targetingBurst)
        end
    end

    local spamBurstPress = Helpers.processSpamBurst(ball, ballId, now, decision, telemetry, kinematics)
    if spamFallback or spamBurstPress then
        fired = true
        spamFallback = spamFallback or spamBurstPress
    end

    local existingSchedule = nil
    if Context.scheduledPressState.ballId == ballId then
        existingSchedule = Context.scheduledPressState
        Context.scheduledPressState.lead = decision.scheduleLead
        Context.scheduledPressState.slack = decision.scheduleSlack
        if decision.smartTelemetry then
            Context.scheduledPressState.smartTuning = decision.smartTelemetry
        end
    end

    local smartReason = nil

    if decision.shouldPress then
        if decision.shouldSchedule then
            smartReason = string.format(
                "impact %.3f > lead %.3f (press in %.3f)",
                decision.predictedImpact,
                decision.scheduleLead,
                math.max(decision.timeUntilPress, 0)
            )
            local scheduleContext = {
                distance = kinematics.distance,
                timeToImpact = decision.timeToImpact,
                timeUntilPress = decision.timeUntilPress,
                speed = kinematics.velocityMagnitude,
                pressRadius = decision.pressRadius,
                holdRadius = decision.holdRadius,
                confidencePress = decision.confidencePress,
                targeting = decision.targetingMe,
                detectionReady = decision.detectionReady,
                detectionAge = decision.detectionAge,
                adaptiveBias = TelemetryAnalytics.adaptiveState and TelemetryAnalytics.adaptiveState.reactionBias or nil,
                lookaheadGoal = decision.lookaheadGoal,
                proximityManifold = decision.proximityManifold,
                proximityLogistic = decision.proximityLogistic,
                proximityEnvelope = decision.proximityEnvelope,
                proximityUrgency = decision.proximitySimulationUrgency,
                proximityEnergy = decision.proximitySimulationEnergy,
                proximityDistanceSuppression = decision.proximityDistanceSuppression,
                proximityVelocity = decision.proximityVelocityImprint,
                proximitySimulation = Helpers.cloneTelemetryEvent(decision.proximitySimulation),
                threatScore = decision.threatScore,
                threatStatus = decision.threatStatus,
                threatIntensity = decision.threatIntensity,
                threatTempo = decision.threatTempo,
            }
            if decision.smartTelemetry then
                scheduleContext.smartTuning = decision.smartTelemetry
            end
            Helpers.updateScheduledPress(
                ballId,
                decision.predictedImpact,
                decision.scheduleLead,
                decision.scheduleSlack,
                smartReason,
                now,
                scheduleContext
            )
            existingSchedule = Context.scheduledPressState
        elseif existingSchedule and not decision.shouldDelay then
            Helpers.clearScheduledPress(ballId, "ready-to-press")
            existingSchedule = nil
        elseif existingSchedule and decision.shouldDelay and not decision.withinLookahead then
            Helpers.clearScheduledPress(ballId, "outside-lookahead")
            existingSchedule = nil
        end

        local activeSlack = (existingSchedule and existingSchedule.slack) or decision.scheduleSlack
        local allowImmediate = decision.confidencePress
        if not allowImmediate and not decision.shouldDelay then
            local predictivePress = Helpers.isFiniteNumber(decision.predictedImpact) and decision.predictedImpact < math.huge
            if predictivePress or decision.proximityPress then
                allowImmediate = true
            end
        end

        local readyToPress = allowImmediate
        if not readyToPress and Helpers.isFiniteNumber(decision.predictedImpact) then
            if decision.predictedImpact <= decision.scheduleLead + activeSlack then
                readyToPress = true
            end
        end

        if not readyToPress and existingSchedule then
            local pressAt = existingSchedule.pressAt or 0
            if decision.detectionReady and now >= pressAt - activeSlack then
                readyToPress = true
            end
        end

        if readyToPress then
            local pressed = Helpers.pressParry(ball, ballId, nil, decision)
            fired = pressed or fired
            if pressed then
                existingSchedule = nil
            end
        end
    else
        if existingSchedule then
            Helpers.clearScheduledPress(ballId, "conditions-changed")
            existingSchedule = nil
        end
    end

    if Context.runtime.parryHeld and Context.runtime.parryHeldBallId == ballId then
        local triggerTime = telemetry and telemetry.triggerTime
        if triggerTime and telemetry and not telemetry.latencySampled then
            local sample = now - triggerTime
            if sample > 0 and sample <= MAX_LATENCY_SAMPLE_SECONDS then
                Helpers.recordLatencySample(sample, "local", ballId, telemetry, now)
            elseif sample > PENDING_LATENCY_MAX_AGE then
                telemetry.latencySampled = true
            end
        end
    end

    if Context.runtime.parryHeld then
        if (not decision.shouldHold) or (Context.runtime.parryHeldBallId and Context.runtime.parryHeldBallId ~= ballId) then
            Helpers.releaseParry()
            released = true
        end
    end

    local latencyEntry = latencySamples.lastSample
    local latencyText = "none"
    if latencyEntry and Helpers.isFiniteNumber(latencyEntry.value) then
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
    if decision.timeToImpactPolynomial then
        timeToImpactPolyText = string.format("%.3f", decision.timeToImpactPolynomial)
    end
    local timeToImpactFallbackText = "n/a"
    if
        Helpers.isFiniteNumber(decision.timeToImpactFallback)
        and decision.timeToImpactFallback < math.huge
    then
        timeToImpactFallbackText = string.format("%.3f", decision.timeToImpactFallback)
    end

    local detectionAgeText = "n/a"
    if Helpers.isFiniteNumber(decision.detectionAge) then
        detectionAgeText = string.format("%.3f", math.max(decision.detectionAge, 0))
    end
    local minDetection = decision.minDetectionTime or 0
    local debugLines = {
        "Auto-Parry F",
        string.format("Ball: %s", ball.Name),
        string.format("d0: %.3f | vr: %.3f", kinematics.filteredD, kinematics.filteredVr),
        string.format("ar: %.3f | jr: %.3f", kinematics.filteredAr, kinematics.filteredJr),
        string.format("μ: %.3f | σ: %.3f | z: %.2f", decision.mu, decision.sigma, decision.z),
        string.format("μ+zσ: %.3f | μ−zσ: %.3f", decision.muPlus, decision.muMinus),
        string.format("Δ: %.3f | ping: %.3f | act: %.3f", decision.delta, decision.ping, activationLatencyEstimate),
        string.format("Latency sample: %s | remoteActive: %s", latencyText, tostring(state.remoteEstimatorActive)),
        string.format("TTI(poly|fb): %s | %s", timeToImpactPolyText, timeToImpactFallbackText),
        string.format(
            "TTI: %.3f | TTpress: %.3f | TThold: %.3f",
            decision.timeToImpact,
            decision.timeToPressRadius,
            decision.timeToHoldRadius
        ),
        string.format(
            "Curve lead: sev %.2f | jerk %.2f | Δt %.3f | target %.3f | pressΔ %.3f | holdΔ %.3f",
            decision.curveSeverity,
            decision.curveJerkSeverity,
            decision.curveLeadTime,
            decision.curveLeadDistance,
            decision.curveLeadApplied,
            decision.curveHoldApplied
        ),
        string.format(
            "Rad: safe %.2f | press %.2f | hold %.2f",
            safeRadius,
            decision.pressRadius,
            decision.holdRadius
        ),
        string.format(
            "Prox lead: base %.3f | dyn %.3f | env %.3f | blend %.2f | damp %.2f",
            decision.proximityBaseLead or 0,
            decision.proximityAdaptiveLead or 0,
            decision.proximityEnvelope or 0,
            decision.proximityLogistic or 0,
            decision.proximityDistanceSuppression or 0
        ),
        string.format(
            "Prox mix: bal %.3f | look %.3f | impact %.3f | holdΔ %.3f",
            decision.proximityBallistic or 0,
            decision.proximityLookaheadGain or 0,
            decision.proximityImpactRatio or 0,
            decision.proximityHoldLead or 0
        ),
        string.format(
            "Prox sim: urg %.2f | energy %.2f | vel %.2f | qual %.2f | weight %.2f | balGain %.2f",
            decision.proximitySimulationUrgency or 0,
            decision.proximitySimulationEnergy or 0,
            decision.proximityVelocityImprint or 0,
            decision.proximitySimulationQuality or 0,
            decision.proximityWeightedIntrusion or 0,
            decision.proximityBallisticGain or 0
        ),
        string.format(
            "Prox: press %s | hold %s",
            tostring(decision.proximityPress),
            tostring(decision.proximityHold)
        ),
        string.format("Targeting: %s", tostring(decision.targetingMe)),
        string.format(
            "Detect: ready %s | age %s | min %.3f",
            tostring(decision.detectionReady),
            detectionAgeText,
            minDetection
        ),
        string.format(
            "Osc: trig %s | flips %d | freq %.2f | dΔ %.3f | spam %s",
            tostring(telemetry.oscillationActive),
            telemetry.lastOscillationCount or 0,
            telemetry.lastOscillationFrequency or 0,
            telemetry.lastOscillationDelta or 0,
            tostring(spamFallback)
        ),
        (function()
            local burst = Context.runtime.spamBurst
            if burst and burst.active and burst.ballId == ballId then
                local eta = math.max(burst.nextPressAt - now, 0)
                local expiresIn = math.max(burst.expireAt - now, 0)
                return string.format(
                    "SpamBurst: rem %d | eta %.3f | gap %.3f | exp %.3f | tight %.2f | mode %s%s",
                    burst.remaining or 0,
                    eta,
                    burst.dynamicGap or burst.gap or 0,
                    expiresIn,
                    burst.tightness or 0,
                    burst.mode or "idle",
                    burst.panicReason and ("(" .. burst.panicReason .. ")") or ""
                )
            end
            return "SpamBurst: idle"
        end)(),
        string.format("ParryHeld: %s", tostring(Context.runtime.parryHeld)),
        string.format("Immortal: %s", tostring(state.immortalEnabled)),
    }

    local reactionLatencyText, decisionLatencyText, commitLatencyText =
        TelemetryAnalytics.computeLatencyReadouts(telemetry, now)
    table.insert(debugLines, string.format("React: %s | Decide: %s | Commit: %s", reactionLatencyText, decisionLatencyText, commitLatencyText))

    if Context.scheduledPressState.ballId == ballId then
        local eta = math.max((Context.scheduledPressState.pressAt or now) - now, 0)
        table.insert(
            debugLines,
            string.format(
                "Smart press: eta %.3f | lead %.3f | slack %.3f | reason %s",
                eta,
                Context.scheduledPressState.lead or 0,
                Context.scheduledPressState.slack or 0,
                Context.scheduledPressState.reason or "?"
            )
        )
    elseif decision.shouldPress and decision.shouldDelay then
        table.insert(
            debugLines,
            string.format(
                "Smart press: delaying %.3f | lookahead %.3f",
                math.max(decision.timeUntilPress, 0),
                decision.maxLookahead
            )
        )
    else
        table.insert(debugLines, "Smart press: idle")
    end

    if kinematics.sigmaArOverflow > 0 or kinematics.sigmaJrOverflow > 0 then
        table.insert(
            debugLines,
            string.format("σ infl.: ar %.2f | jr %.2f", kinematics.sigmaArOverflow, kinematics.sigmaJrOverflow)
        )
    end

    if fired then
        table.insert(debugLines, "🔥 Press F: proximity/inequality met")
    elseif Context.runtime.parryHeld and not released then
        table.insert(debugLines, "Hold: maintaining expanded proximity window")
    else
        table.insert(debugLines, "Hold: conditions not met")
    end

    Context.hooks.updateStatusLabel(debugLines)
    Helpers.setBallVisuals(
        ball,
        BallKinematics.computeBallDebug(
            kinematics.velocityMagnitude,
            kinematics.distance,
            safeRadius,
            decision.mu,
            decision.sigma,
            decision.muPlus,
            decision.delta,
            decision.timeToImpact,
            decision.timeToPressRadius,
            decision.timeToHoldRadius,
            decision.pressRadius,
            decision.holdRadius
        )
    )
end


function Helpers.ensureLoop()
    if Context.connections.loop then
        return
    end

    Context.connections.loop = Services.RunService.PreRender:Connect(Helpers.renderLoop)
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
    pressReactionBias = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    pressScheduleSlack = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    pressMaxLookahead = function(value)
        return typeof(value) == "number" and value > 0
    end,
    pressLookaheadGoal = function(value)
        return value == nil or (typeof(value) == "number" and value >= 0)
    end,
    pressConfidencePadding = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    pressMinDetectionTime = function(value)
        return value == nil or (typeof(value) == "number" and value >= 0)
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
    oscillationSpamCooldown = function(value)
        return value == nil or (typeof(value) == "number" and value >= 0)
    end,
    oscillationMaxLookahead = function(value)
        return value == nil or (typeof(value) == "number" and value > 0)
    end,
    oscillationSpamBurstPresses = function(value)
        return value == nil or (typeof(value) == "number" and value >= 0)
    end,
    oscillationSpamBurstGap = function(value)
        return value == nil or (typeof(value) == "number" and value > 0)
    end,
    oscillationSpamBurstWindow = function(value)
        return value == nil or (typeof(value) == "number" and value > 0)
    end,
    oscillationSpamBurstLookahead = function(value)
        return value == nil or (typeof(value) == "number" and value > 0)
    end,
    oscillationSpamMinGap = function(value)
        return value == nil or (typeof(value) == "number" and value > 0)
    end,
    oscillationSpamPanicTightness = function(value)
        return value == nil or (typeof(value) == "number" and value >= 0 and value <= 1)
    end,
    oscillationSpamPanicGapScale = function(value)
        return value == nil or (typeof(value) == "number" and value > 0)
    end,
    oscillationSpamPanicWindowScale = function(value)
        return value == nil or (typeof(value) == "number" and value >= 1)
    end,
    oscillationSpamPanicLookaheadBoost = function(value)
        return value == nil or (typeof(value) == "number" and value >= 0)
    end,
    oscillationSpamPanicSpeedDelta = function(value)
        return value == nil or (typeof(value) == "number" and value >= 0)
    end,
    oscillationSpamPanicSlack = function(value)
        return value == nil or (typeof(value) == "number" and value >= 0)
    end,
    oscillationSpamRecoverySeconds = function(value)
        return value == nil or (typeof(value) == "number" and value >= 0)
    end,
    oscillationSpamCooldownTightnessGain = function(value)
        return value == nil or (typeof(value) == "number" and value >= 0)
    end,
    oscillationSpamCooldownPanicScale = function(value)
        return value == nil or (typeof(value) == "number" and value > 0)
    end,
    smartTuning = function(value)
        local valueType = typeof(value)
        return value == nil or value == false or value == true or valueType == "table"
    end,
    autoTuning = function(value)
        local valueType = typeof(value)
        return value == nil or value == false or value == true or valueType == "table"
    end,
}

AutoParry = {}

function AutoParry.enable()
    Helpers.ensureInitialization()
    if state.enabled then
        return
    end

    Helpers.resetTelemetryHistory("enabled")
    state.enabled = true
    Helpers.syncGlobalSettings()
    Helpers.updateToggleButton()
    Helpers.ensureLoop()
    stateChanged:fire(true)
end

function AutoParry.disable()
    if not state.enabled then
        return
    end

    state.enabled = false
    Context.runtime.targetingGraceUntil = 0
    Helpers.clearScheduledPress(nil, "disabled")
    Helpers.resetSpamBurst("disabled")
    Helpers.releaseParry()
    telemetryStates = {}
    Context.runtime.trackedBall = nil
    Helpers.syncGlobalSettings()
    Helpers.updateToggleButton()
    stateChanged:fire(false)
    Helpers.resetTelemetryHistory("disabled")
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
    Context.runtime.syncImmortalContext()

    local after = state.immortalEnabled
    Helpers.updateImmortalButton()
    Helpers.syncGlobalSettings()

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

function Helpers.applyConfigOverride(key, value)
    local validator = validators[key]
    if not validator then
        error(("AutoParry.configure: unknown option '%s'"):format(tostring(key)), 0)
    end

    if not validator(value) then
        error(("AutoParry.configure: invalid value for '%s'"):format(tostring(key)), 0)
    end

    if key == "smartTuning" then
        config.smartTuning = Helpers.normalizeSmartTuningConfig(value)
        Helpers.resetSmartTuningState()
        if config.smartTuning == false then
            return
        end
    elseif key == "autoTuning" then
        config.autoTuning = Helpers.normalizeAutoTuningConfig(value)
        Helpers.syncAutoTuningState()
        return
    else
        config[key] = value
    end

    if key == "activationLatency" then
        activationLatencyEstimate = config.activationLatency or Defaults.CONFIG.activationLatency or 0
        if activationLatencyEstimate < 0 then
            activationLatencyEstimate = 0
        end
    elseif key == "confidenceZ" then
        perfectParrySnapshot.z = config.confidenceZ or Defaults.CONFIG.confidenceZ or perfectParrySnapshot.z
    elseif key == "remoteQueueGuards" then
        Helpers.rebuildRemoteQueueGuardTargets()
        Helpers.setRemoteQueueGuardFolder(Context.player.RemotesFolder)
    elseif key == "smartTuning" then
        -- nothing extra; normalization already handled above
    end
end

function AutoParry.configure(opts)
    assert(typeof(opts) == "table", "AutoParry.configure expects a table")

    for key, value in pairs(opts) do
        Helpers.applyConfigOverride(key, value)
    end

    Helpers.syncGlobalSettings()
    return AutoParry.getConfig()
end

function AutoParry.getConfig()
    return Helpers.cloneTable(config)
end

function AutoParry._testEvaluateOscillationBurstTuning(payload)
    payload = payload or {}
    local settings = resolveOscillationSpamSettings()
    local decision = payload.decision
    local kinematics = payload.kinematics
    local fallback = payload.fallbackDecision or payload.initialDecision
    local previousTrend = Context.runtime.telemetrySummaryTrend

    if payload.trend ~= nil then
        if payload.trend == false then
            Context.runtime.telemetrySummaryTrend = nil
        elseif typeof(payload.trend) == "table" then
            Context.runtime.telemetrySummaryTrend = Helpers.cloneTable(payload.trend)
        elseif Helpers.isFiniteNumber(payload.trend) then
            Context.runtime.telemetrySummaryTrend = {
                momentum = payload.trend,
                samples = 8,
                last = nil,
                updatedAt = os.clock(),
            }
        end
    end

    local tuning = Helpers.computeSpamBurstTuning(settings, decision, kinematics, fallback, payload.summary)

    if payload.trend ~= nil then
        Context.runtime.telemetrySummaryTrend = previousTrend
    end

    return Helpers.cloneTable(tuning)
end

function AutoParry.resetConfig()
    config = Util.deepCopy(Defaults.CONFIG)
    config.smartTuning = Helpers.normalizeSmartTuningConfig(config.smartTuning)
    config.autoTuning = Helpers.normalizeAutoTuningConfig(config.autoTuning)
    Helpers.resetActivationLatency()
    Helpers.resetSmartTuningState()
    Helpers.syncAutoTuningState()
    Helpers.resetTelemetryHistory("config-reset")
    Helpers.rebuildRemoteQueueGuardTargets()
    Helpers.setRemoteQueueGuardFolder(Context.player.RemotesFolder)
    Helpers.syncGlobalSettings()
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

function AutoParry.getSmartPressState()
    Helpers.ensureInitialization()

    local now = os.clock()
    local snapshot = {
        ballId = Context.scheduledPressState.ballId,
        pressAt = Context.scheduledPressState.pressAt,
        predictedImpact = Context.scheduledPressState.predictedImpact,
        lead = Context.scheduledPressState.lead,
        slack = Context.scheduledPressState.slack,
        reason = Context.scheduledPressState.reason,
        lastUpdate = Context.scheduledPressState.lastUpdate,
        sampleTime = now,
        latency = activationLatencyEstimate,
        remoteLatencyActive = state.remoteEstimatorActive,
        latencySamples = Helpers.cloneTable(latencySamples),
        pendingLatencyPresses = Helpers.cloneTable(pendingLatencyPresses),
        smartTuning = Helpers.snapshotSmartTuningState(),
    }

    if Context.scheduledPressState.lastUpdate and Context.scheduledPressState.lastUpdate > 0 then
        snapshot.timeSinceUpdate = now - Context.scheduledPressState.lastUpdate
    end

    local ballId = Context.scheduledPressState.ballId
    if ballId then
        local telemetry = telemetryStates[ballId]
        if telemetry then
            snapshot.telemetry = {
                lastUpdate = telemetry.lastUpdate,
                triggerTime = telemetry.triggerTime,
                latencySampled = telemetry.latencySampled,
                targetDetectedAt = telemetry.targetDetectedAt,
                decisionAt = telemetry.decisionAt,
                lastReactionLatency = telemetry.lastReactionLatency,
                lastDecisionLatency = telemetry.lastDecisionLatency,
                lastDecisionToPressLatency = telemetry.lastDecisionToPressLatency,
            }
        end
    end

    if Context.scheduledPressState.smartTuning then
        snapshot.scheduledSmartTuning = Helpers.cloneTable(Context.scheduledPressState.smartTuning)
    end

    if snapshot.pressAt and snapshot.pressAt > 0 then
        snapshot.pressEta = math.max(snapshot.pressAt - now, 0)
    else
        snapshot.pressEta = nil
    end

    if snapshot.ballId then
        Context.scheduledPressState.lastSnapshot = Helpers.cloneTable(snapshot)
    elseif Context.scheduledPressState.lastSnapshot then
        snapshot.lastScheduled = Helpers.cloneTable(Context.scheduledPressState.lastSnapshot)
    end

    return snapshot
end

function AutoParry.getSmartTuningSnapshot()
    Helpers.ensureInitialization()
    return Helpers.snapshotSmartTuningState()
end

function AutoParry.onInitStatus(callback)
    assert(typeof(callback) == "function", "AutoParry.onInitStatus expects a function")
    Helpers.ensureInitialization()
    local connection = initStatus:connect(callback)
    callback(Helpers.cloneTable(initProgress))
    return connection
end

function AutoParry.getInitProgress()
    Helpers.ensureInitialization()
    return Helpers.cloneTable(initProgress)
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

function AutoParry.onTelemetry(callback)
    assert(typeof(callback) == "function", "AutoParry.onTelemetry expects a function")
    return telemetrySignal:connect(function(event)
        callback(Helpers.cloneTelemetryEvent(event))
    end)
end

function Helpers.cloneTelemetryHistory()
    local history = {}
    for index = 1, #Context.telemetry.history do
        history[index] = Helpers.cloneTelemetryEvent(Context.telemetry.history[index])
    end
    return history
end

function AutoParry.getTelemetryHistory()
    return Helpers.cloneTelemetryHistory()
end

function AutoParry.getTelemetrySnapshot()
    local _, telemetryStore = publishTelemetryHistory()
    local stats = TelemetryAnalytics.clone()
    return {
        sequence = Context.telemetry.sequence,
        history = Helpers.cloneTelemetryHistory(),
        activationLatency = activationLatencyEstimate,
        remoteLatencyActive = state.remoteEstimatorActive,
        lastEvent = telemetryStore.lastEvent and Helpers.cloneTelemetryEvent(telemetryStore.lastEvent) or nil,
        smartTuning = Helpers.snapshotSmartTuningState(),
        stats = stats,
        adaptiveState = stats and stats.adaptiveState or telemetryStore.adaptiveState,
    }
end

function AutoParry.getTelemetryStats()
    Helpers.ensureInitialization()
    return TelemetryAnalytics.clone()
end

function Helpers.applyTelemetryUpdates(adjustments, options)
    options = options or {}
    local updates = adjustments.updates or {}
    if typeof(adjustments.reasons) ~= "table" then
        adjustments.reasons = {}
    end
    if next(updates) and not options.dryRun then
        AutoParry.configure(updates)
        local appliedAt = os.clock()
        emitTelemetryEvent("config-adjustment", {
            updates = Helpers.cloneTable(updates),
            reasons = Helpers.cloneTable(adjustments.reasons),
            status = adjustments.status,
            source = options.source or "telemetry-adjustments",
            appliedAt = appliedAt,
        })
        adjustments.appliedAt = appliedAt
        adjustments.newConfig = AutoParry.getConfig()
    else
        adjustments.newConfig = AutoParry.getConfig()
    end

    return adjustments
end

function AutoParry.buildTelemetryAdjustments(options)
    Helpers.ensureInitialization()

    options = options or {}
    local stats = options.stats
    if typeof(stats) ~= "table" then
        stats = TelemetryAnalytics.clone()
    end

    local summary = options.summary
    if typeof(summary) ~= "table" then
        summary = TelemetryAnalytics.computeSummary(stats)
    end

    local configSnapshot = Helpers.cloneTable(config)

    local defaultCommitTarget, defaultLookaheadGoal = Helpers.resolvePerformanceTargets()

    local computeOptions = {
        minSamples = options.minSamples,
        allowWhenSmartTuning = options.allowWhenSmartTuning,
        leadGain = options.leadGain,
        slackGain = options.slackGain,
        latencyGain = options.latencyGain,
        leadTolerance = options.leadTolerance,
        waitTolerance = options.waitTolerance,
        maxReactionBias = options.maxReactionBias,
        maxScheduleSlack = options.maxScheduleSlack,
        maxActivationLatency = options.maxActivationLatency,
        minScheduleSlack = options.minScheduleSlack,
        commitTarget = options.commitTarget or defaultCommitTarget,
        commitReactionGain = options.commitReactionGain,
        commitSlackGain = options.commitSlackGain,
        commitMinSamples = options.commitMinSamples,
        lookaheadGoal = options.lookaheadGoal or defaultLookaheadGoal,
        lookaheadGain = options.lookaheadGain,
        lookaheadMinSamples = options.lookaheadMinSamples,
        maxPressLookahead = options.maxPressLookahead,
        maxPressLookaheadDelta = options.maxPressLookaheadDelta,
    }

    local adjustments = TelemetryAnalytics.computeAdjustments(stats, summary, configSnapshot, computeOptions)
    adjustments.previousConfig = configSnapshot
    adjustments.stats = stats
    adjustments.summary = summary
    adjustments.options = computeOptions
    return adjustments
end

function AutoParry.applyTelemetryAdjustments(options)
    Helpers.ensureInitialization()

    options = options or {}
    local adjustments = AutoParry.buildTelemetryAdjustments(options)
    return Helpers.applyTelemetryUpdates(adjustments, {
        dryRun = options.dryRun,
        source = "telemetry-adjustments",
    })
end

function Helpers.performAutoTuning(options)
    options = options or {}
    local now = options.now or os.clock()
    local force = options.force == true

    if not force and not autoTuningState.enabled then
        return nil
    end

    if not force and not state.enabled then
        return nil
    end

    local interval = autoTuningState.intervalSeconds or Defaults.AUTO_TUNING.intervalSeconds
    if not Helpers.isFiniteNumber(interval) or interval < 0 then
        interval = Defaults.AUTO_TUNING.intervalSeconds
    end

    local lastRun = autoTuningState.lastRun or 0
    if not force and interval > 0 and now - lastRun < interval then
        return nil
    end

    local stats = options.stats
    if typeof(stats) ~= "table" then
        stats = TelemetryAnalytics.clone()
    end

    local summary = options.summary
    if typeof(summary) ~= "table" then
        summary = TelemetryAnalytics.computeSummary(stats)
    end

    local computeOptions = {
        minSamples = options.minSamples or autoTuningState.minSamples,
        allowWhenSmartTuning = options.allowWhenSmartTuning,
        leadGain = options.leadGain or autoTuningState.leadGain,
        slackGain = options.slackGain or autoTuningState.slackGain,
        latencyGain = options.latencyGain or autoTuningState.latencyGain,
        leadTolerance = options.leadTolerance or autoTuningState.leadTolerance,
        waitTolerance = options.waitTolerance or autoTuningState.waitTolerance,
        maxReactionBias = options.maxReactionBias or autoTuningState.maxReactionBias,
        maxScheduleSlack = options.maxScheduleSlack or autoTuningState.maxScheduleSlack,
        maxActivationLatency = options.maxActivationLatency or autoTuningState.maxActivationLatency,
    }

    if computeOptions.allowWhenSmartTuning == nil then
        computeOptions.allowWhenSmartTuning = autoTuningState.allowWhenSmartTuning
    end

    local adjustments = AutoParry.buildTelemetryAdjustments({
        stats = stats,
        summary = summary,
        minSamples = computeOptions.minSamples,
        allowWhenSmartTuning = computeOptions.allowWhenSmartTuning,
        leadGain = computeOptions.leadGain,
        slackGain = computeOptions.slackGain,
        latencyGain = computeOptions.latencyGain,
        leadTolerance = computeOptions.leadTolerance,
        waitTolerance = computeOptions.waitTolerance,
        maxReactionBias = computeOptions.maxReactionBias,
        maxScheduleSlack = computeOptions.maxScheduleSlack,
        maxActivationLatency = computeOptions.maxActivationLatency,
    })

    local minDelta = options.minDelta
    if not Helpers.isFiniteNumber(minDelta) or minDelta < 0 then
        minDelta = autoTuningState.minDelta or 0
    end

    local maxAdjustments = options.maxAdjustmentsPerRun
    if not Helpers.isFiniteNumber(maxAdjustments) or maxAdjustments < 0 then
        maxAdjustments = autoTuningState.maxAdjustmentsPerRun
    end

    local updates = adjustments.updates or {}
    local deltas = adjustments.deltas or {}
    local ranked = {}
    for key, delta in pairs(deltas) do
        local magnitude = math.abs(delta or 0)
        if magnitude < minDelta then
            updates[key] = nil
            deltas[key] = nil
        else
            ranked[#ranked + 1] = { key = key, magnitude = magnitude }
        end
    end

    if Helpers.isFiniteNumber(maxAdjustments) and maxAdjustments and maxAdjustments > 0 and #ranked > maxAdjustments then
        table.sort(ranked, function(a, b)
            if a.magnitude == b.magnitude then
                return a.key < b.key
            end
            return a.magnitude > b.magnitude
        end)

        for index = maxAdjustments + 1, #ranked do
            local entry = ranked[index]
            updates[entry.key] = nil
            deltas[entry.key] = nil
        end
    end

    if not next(updates) and adjustments.status == "updates" then
        if typeof(adjustments.reasons) ~= "table" then
            adjustments.reasons = {}
        end
        table.insert(adjustments.reasons, "Auto-tuning filtered out negligible adjustments before application.")
        adjustments.status = "filtered"
    end

    autoTuningState.lastRun = now
    autoTuningState.lastStatus = adjustments.status
    autoTuningState.lastSummary = Helpers.cloneTable(summary)
    autoTuningState.lastAdjustments = {
        updates = Helpers.cloneTable(adjustments.updates),
        deltas = Helpers.cloneTable(adjustments.deltas),
        reasons = Helpers.cloneTable(adjustments.reasons),
        status = adjustments.status,
    }
    autoTuningState.lastError = nil

    local dryRun = options.dryRun
    if dryRun == nil then
        dryRun = autoTuningState.dryRun
    end

    local applied = Helpers.applyTelemetryUpdates(adjustments, {
        dryRun = dryRun,
        source = options.source or "auto-tuning",
    })

    autoTuningState.lastResult = {
        status = applied.status,
        updates = Helpers.cloneTable(applied.updates),
        deltas = Helpers.cloneTable(applied.deltas),
        appliedAt = applied.appliedAt,
        dryRun = dryRun,
        newConfig = Helpers.cloneTable(applied.newConfig),
    }

    applied.autoTuning = Helpers.cloneAutoTuningSnapshot()
    Helpers.syncGlobalSettings()
    return applied
end

function Helpers.maybeRunAutoTuning(now)
    if not autoTuningState.enabled then
        return
    end

    now = now or os.clock()
    local ok, result = pcall(Helpers.performAutoTuning, { now = now })
    if not ok then
        autoTuningState.lastError = tostring(result)
        warn(("AutoParry: auto-tuning failed (%s)"):format(tostring(result)))
    elseif result then
        autoTuningState.lastError = nil
    end
end

function AutoParry.getDiagnosticsReport()
    Helpers.ensureInitialization()
    local stats = TelemetryAnalytics.clone()
    local summary = TelemetryAnalytics.computeSummary(stats)
    local adjustments = AutoParry.buildTelemetryAdjustments({
        stats = stats,
        summary = summary,
        allowWhenSmartTuning = false,
    })
    local configSnapshot = adjustments.previousConfig or Helpers.cloneTable(config)
    local recommendations = TelemetryAnalytics.buildRecommendations(stats, summary)
    local commitTarget, lookaheadGoal = Helpers.resolvePerformanceTargets()
    local lastPressEvent = GlobalEnv.LastPressEvent
    if not lastPressEvent then
        local pawsSettings = Helpers.ensurePawsSettings()
        lastPressEvent = pawsSettings.LastPressEvent
    end
    if typeof(lastPressEvent) == "table" then
        GlobalEnv.LastPressEvent = Helpers.cloneTelemetryEvent(lastPressEvent)
    else
        GlobalEnv.LastPressEvent = {
            reactionTime = summary.averageReactionTime or 0,
            decisionTime = summary.averageDecisionTime or 0,
            decisionToPressTime = summary.averageDecisionToPressTime or 0,
        }
    end
    ensurePressEventProxy()
    return {
        generatedAt = os.clock(),
        counters = stats.counters,
        stats = stats,
        summary = summary,
        smartTuningEnabled = smartTuningState.enabled,
        adaptiveState = stats.adaptiveState,
        recommendations = recommendations,
        adjustments = adjustments,
        config = configSnapshot,
        insights = TelemetryAnalytics.computeInsights(stats, summary, adjustments, {
            minSamples = adjustments.minSamples,
            commitTarget = commitTarget,
            lookaheadGoal = lookaheadGoal,
        }),
    }
end

function AutoParry.getAutoTuningState()
    Helpers.ensureInitialization()
    return Helpers.cloneAutoTuningSnapshot()
end

function AutoParry.runAutoTuning(options)
    Helpers.ensureInitialization()
    local callOptions = options or {}
    if callOptions.force == nil then
        callOptions.force = true
    end
    if callOptions.now == nil then
        callOptions.now = os.clock()
    end

    local ok, result = pcall(Helpers.performAutoTuning, callOptions)
    if not ok then
        autoTuningState.lastError = tostring(result)
        warn(("AutoParry: auto-tuning failed (%s)"):format(tostring(result)))
        return nil, result
    end

    return result
end

function AutoParry.getTelemetryInsights(options)
    Helpers.ensureInitialization()
    options = options or {}

    local stats = options.stats
    if typeof(stats) ~= "table" then
        stats = TelemetryAnalytics.clone()
    end

    local summary = options.summary
    if typeof(summary) ~= "table" then
        summary = TelemetryAnalytics.computeSummary(stats)
    end

    local defaultCommitTarget, defaultLookaheadGoal = Helpers.resolvePerformanceTargets()

    local adjustments = AutoParry.buildTelemetryAdjustments({
        stats = stats,
        summary = summary,
        minSamples = options.minSamples,
        allowWhenSmartTuning = options.allowWhenSmartTuning,
        leadGain = options.leadGain,
        slackGain = options.slackGain,
        latencyGain = options.latencyGain,
        leadTolerance = options.leadTolerance,
        waitTolerance = options.waitTolerance,
        maxReactionBias = options.maxReactionBias,
        maxScheduleSlack = options.maxScheduleSlack,
        maxActivationLatency = options.maxActivationLatency,
        minScheduleSlack = options.minScheduleSlack,
        commitTarget = options.commitTarget or defaultCommitTarget,
        commitReactionGain = options.commitReactionGain,
        commitSlackGain = options.commitSlackGain,
        commitMinSamples = options.commitMinSamples,
        lookaheadGoal = options.lookaheadGoal or defaultLookaheadGoal,
        lookaheadGain = options.lookaheadGain,
        lookaheadMinSamples = options.lookaheadMinSamples,
        maxPressLookahead = options.maxPressLookahead,
        maxPressLookaheadDelta = options.maxPressLookaheadDelta,
    })

    local insights = TelemetryAnalytics.computeInsights(stats, summary, adjustments, {
        minSamples = adjustments.minSamples,
        leadTolerance = options.leadTolerance,
        waitTolerance = options.waitTolerance,
        commitTarget = options.commitTarget or defaultCommitTarget,
        lookaheadGoal = options.lookaheadGoal or defaultLookaheadGoal,
    })

    insights.adjustments = {
        status = adjustments.status,
        updates = Helpers.cloneTable(adjustments.updates),
        deltas = Helpers.cloneTable(adjustments.deltas),
        reasons = Helpers.cloneTable(adjustments.reasons),
        minSamples = adjustments.minSamples,
    }
    insights.config = Helpers.cloneTable(config)
    insights.smartTuningEnabled = smartTuningState.enabled
    insights.autoTuning = Helpers.cloneAutoTuningSnapshot()
    return insights
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
    Helpers.callImmortalController("destroy")

    if Context.connections.loop then
        Context.connections.loop:Disconnect()
        Context.connections.loop = nil
    end

    if Context.connections.humanoidDied then
        Context.connections.humanoidDied:Disconnect()
        Context.connections.humanoidDied = nil
    end

    if Context.connections.characterAdded then
        Context.connections.characterAdded:Disconnect()
        Context.connections.characterAdded = nil
    end

    if Context.connections.characterRemoving then
        Context.connections.characterRemoving:Disconnect()
        Context.connections.characterRemoving = nil
    end

    Helpers.clearRemoteState()
    Context.runtime.restartPending = false
    initialization.token += 1

    Helpers.destroyUi()
    Helpers.safeClearBallVisuals()

    initialization.started = false
    initialization.completed = false
    initialization.destroyed = true
    initialization.error = nil

    state.lastParry = 0
    state.lastSuccess = 0
    state.lastBroadcast = 0
    Helpers.clearScheduledPress(nil, "destroyed")
    Helpers.resetSpamBurst("destroyed")
    Helpers.releaseParry()
    telemetryStates = {}
    Context.runtime.trackedBall = nil
    Context.player.BallsFolder = nil
    Context.player.WatchedBallsFolder = nil
    pendingBallsFolderSearch = false
    Context.watchers.ballsSnapshot = nil
    if Context.watchers.ballsConnections then
        Helpers.disconnectConnections(Context.watchers.ballsConnections)
        Context.watchers.ballsConnections = nil
    end
    Context.player.LocalPlayer = nil
    Context.player.Character = nil
    Context.player.RootPart = nil
    Context.player.Humanoid = nil
    Helpers.resetActivationLatency()
    Helpers.resetSmartTuningState()

    Helpers.resetTelemetryHistory("destroyed")

    initProgress = { stage = "waiting-player" }
    Helpers.applyInitStatus(Helpers.cloneTable(initProgress))

    GlobalEnv.Paws = nil

    initialization.destroyed = false
    Context.runtime.targetingGraceUntil = 0
end

Helpers.ensureInitialization()
Helpers.ensureLoop()
Helpers.syncAutoTuningState()
Helpers.syncGlobalSettings()
Context.runtime.syncImmortalContext()

return AutoParry

]===],
    ['src/core/immortal.lua'] = [===[
-- src/core/immortal.lua (sha1: 33d8113542e8d65a94596a1983dce26485a046bb)
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
-- src/core/verification.lua (sha1: 8d31acf50e4ba8a9b6eb014fcea63d4c93361807)
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
-- src/main.lua (sha1: c0be85af0331493c1a548e35f5eaea79d6edce04)
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
-- src/shared/util.lua (sha1: 4feb5bb8ffd5e102e9ab622cd0b84166c8e5377f)
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

function Util.setConstraintSize(constraint, minSize, maxSize)
    if typeof(constraint) ~= "Instance" then
        return
    end

    if constraint.ClassName ~= "UISizeConstraint" and not constraint:IsA("UISizeConstraint") then
        return
    end

    minSize = minSize or Vector2.new(0, 0)
    maxSize = maxSize or Vector2.new(0, 0)

    local minX = math.max(0, minSize.X or 0)
    local minY = math.max(0, minSize.Y or 0)
    local maxX = math.max(minX, maxSize.X or 0)
    local maxY = math.max(minY, maxSize.Y or 0)

    local currentMax = constraint.MaxSize or Vector2.new(math.huge, math.huge)
    local newMin = Vector2.new(minX, minY)
    local newMax = Vector2.new(maxX, maxY)

    if currentMax.X < minX or currentMax.Y < minY then
        constraint.MaxSize = newMax
        constraint.MinSize = newMin
    else
        constraint.MinSize = newMin
        constraint.MaxSize = newMax
    end
end

return Util

]===],
    ['src/ui/diagnostics_panel.lua'] = [===[
-- src/ui/diagnostics_panel.lua (sha1: 3d0ae73d30e2bd878f47b6341c35f76cbbf63719)
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
    eventListHeight = 240,
    eventListPadding = Vector2.new(10, 8),
    eventScrollBarThickness = 6,
    eventScrollBarColor = Color3.fromRGB(82, 156, 255),
    eventScrollBarTransparency = 0.25,
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
    overview = {
        backgroundColor = Color3.fromRGB(26, 30, 40),
        backgroundTransparency = 0.08,
        strokeColor = Color3.fromRGB(82, 156, 255),
        strokeTransparency = 0.6,
        accentColor = Color3.fromRGB(112, 198, 255),
        successColor = Color3.fromRGB(118, 228, 182),
        warningColor = Color3.fromRGB(255, 198, 110),
        dangerColor = Color3.fromRGB(248, 110, 128),
        headerFont = Enum.Font.GothamSemibold,
        headerTextSize = 13,
        headerColor = Color3.fromRGB(176, 192, 224),
        valueFont = Enum.Font.GothamBlack,
        valueTextSize = 24,
        valueColor = Color3.fromRGB(232, 242, 255),
        detailFont = Enum.Font.Gotham,
        detailTextSize = 13,
        detailColor = Color3.fromRGB(160, 176, 210),
        chipCorner = UDim.new(0, 12),
        padding = Vector2.new(18, 16),
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

local STAGE_STATUS_PRIORITY = {
    failed = 5,
    warning = 4,
    active = 3,
    pending = 2,
    ok = 1,
}

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
    frame.AutomaticSize = Enum.AutomaticSize.None
    frame.Size = UDim2.new(1, 0, 0, 90)
    frame.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = theme.stageCorner
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color = theme.stageStrokeColor
    stroke.Transparency = theme.stageStrokeTransparency
    stroke.Parent = frame

    local accent = Instance.new("Frame")
    accent.Name = "Accent"
    accent.AnchorPoint = Vector2.new(0, 0.5)
    accent.Position = UDim2.new(0, -2, 0.5, 0)
    accent.Size = UDim2.new(0, 6, 1, -24)
    accent.BorderSizePixel = 0
    accent.BackgroundColor3 = theme.statusColors.pending
    accent.BackgroundTransparency = 0.35
    accent.Parent = frame

    local accentCorner = Instance.new("UICorner")
    accentCorner.CornerRadius = UDim.new(1, 0)
    accentCorner.Parent = accent

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
        accent = accent,
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

local function createOverviewCard(theme, parent, id, title)
    local config = theme.overview or DEFAULT_THEME.overview

    local frame = Instance.new("Frame")
    frame.Name = string.format("Overview_%s", id or "Card")
    frame.BackgroundColor3 = config.backgroundColor or DEFAULT_THEME.overview.backgroundColor
    frame.BackgroundTransparency = config.backgroundTransparency or DEFAULT_THEME.overview.backgroundTransparency or 0.08
    frame.BorderSizePixel = 0
    frame.AutomaticSize = Enum.AutomaticSize.Y
    frame.Size = UDim2.new(1, 0, 0, 0)
    frame.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = config.chipCorner or DEFAULT_THEME.overview.chipCorner or UDim.new(0, 12)
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color = config.strokeColor or DEFAULT_THEME.overview.strokeColor
    stroke.Transparency = config.strokeTransparency or DEFAULT_THEME.overview.strokeTransparency or 0.6
    stroke.Thickness = 1.2
    stroke.Parent = frame

    local padding = config.padding or DEFAULT_THEME.overview.padding or Vector2.new(18, 16)
    local contentPadding = Instance.new("UIPadding")
    contentPadding.PaddingTop = UDim.new(0, padding.Y)
    contentPadding.PaddingBottom = UDim.new(0, padding.Y)
    contentPadding.PaddingLeft = UDim.new(0, padding.X)
    contentPadding.PaddingRight = UDim.new(0, padding.X)
    contentPadding.Parent = frame

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 6)
    layout.Parent = frame

    local header = Instance.new("TextLabel")
    header.Name = "Label"
    header.BackgroundTransparency = 1
    header.Font = config.headerFont or DEFAULT_THEME.overview.headerFont
    header.TextSize = config.headerTextSize or DEFAULT_THEME.overview.headerTextSize
    header.TextColor3 = config.headerColor or DEFAULT_THEME.overview.headerColor
    header.TextXAlignment = Enum.TextXAlignment.Left
    header.Text = string.upper(title or id or "Overview")
    header.Size = UDim2.new(1, 0, 0, math.max(20, (config.headerTextSize or DEFAULT_THEME.overview.headerTextSize) + 6))
    header.LayoutOrder = 1
    header.Parent = frame

    local value = Instance.new("TextLabel")
    value.Name = "Value"
    value.BackgroundTransparency = 1
    value.Font = config.valueFont or DEFAULT_THEME.overview.valueFont
    value.TextSize = config.valueTextSize or DEFAULT_THEME.overview.valueTextSize
    value.TextColor3 = config.valueColor or DEFAULT_THEME.overview.valueColor
    value.TextXAlignment = Enum.TextXAlignment.Left
    value.Text = "--"
    value.Size = UDim2.new(1, 0, 0, value.TextSize + 6)
    value.LayoutOrder = 2
    value.Parent = frame

    local detail = Instance.new("TextLabel")
    detail.Name = "Detail"
    detail.BackgroundTransparency = 1
    detail.Font = config.detailFont or DEFAULT_THEME.overview.detailFont
    detail.TextSize = config.detailTextSize or DEFAULT_THEME.overview.detailTextSize
    detail.TextColor3 = config.detailColor or DEFAULT_THEME.overview.detailColor
    detail.TextXAlignment = Enum.TextXAlignment.Left
    detail.TextWrapped = true
    detail.Text = "Awaiting data"
    detail.Size = UDim2.new(1, 0, 0, math.max(18, detail.TextSize + 4))
    detail.LayoutOrder = 3
    detail.Parent = frame

    return {
        frame = frame,
        stroke = stroke,
        title = header,
        value = value,
        detail = detail,
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
    layout.Padding = UDim.new(0, (theme.sectionSpacing or 12) + 4)
    layout.Parent = frame

    local overviewRow = Instance.new("Frame")
    overviewRow.Name = "OverviewRow"
    overviewRow.BackgroundTransparency = 1
    overviewRow.Size = UDim2.new(1, 0, 0, 0)
    overviewRow.AutomaticSize = Enum.AutomaticSize.Y
    overviewRow.LayoutOrder = 1
    overviewRow.Parent = frame

    local overviewLayout = Instance.new("UIListLayout")
    overviewLayout.FillDirection = Enum.FillDirection.Horizontal
    overviewLayout.SortOrder = Enum.SortOrder.LayoutOrder
    overviewLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    overviewLayout.Padding = UDim.new(0, theme.sectionSpacing or 12)
    overviewLayout.Parent = overviewRow

    local overviewCards = {
        status = createOverviewCard(theme, overviewRow, "status", "Verification"),
        events = createOverviewCard(theme, overviewRow, "events", "Events"),
        alerts = createOverviewCard(theme, overviewRow, "alerts", "Alerts"),
    }
    overviewCards.status.frame.LayoutOrder = 1
    overviewCards.events.frame.LayoutOrder = 2
    overviewCards.alerts.frame.LayoutOrder = 3

    local contentRow = Instance.new("Frame")
    contentRow.Name = "ContentRow"
    contentRow.BackgroundTransparency = 1
    contentRow.Size = UDim2.new(1, 0, 0, 0)
    contentRow.AutomaticSize = Enum.AutomaticSize.Y
    contentRow.LayoutOrder = 2
    contentRow.Parent = frame

    local contentLayout = Instance.new("UIListLayout")
    contentLayout.FillDirection = Enum.FillDirection.Vertical
    contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
    contentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    contentLayout.Padding = UDim.new(0, theme.sectionSpacing or 12)
    contentLayout.Parent = contentRow

    local primaryColumn = Instance.new("Frame")
    primaryColumn.Name = "PrimaryColumn"
    primaryColumn.BackgroundTransparency = 1
    primaryColumn.AutomaticSize = Enum.AutomaticSize.Y
    primaryColumn.Size = UDim2.new(1, 0, 0, 0)
    primaryColumn.LayoutOrder = 1
    primaryColumn.Parent = contentRow

    local primaryLayout = Instance.new("UIListLayout")
    primaryLayout.FillDirection = Enum.FillDirection.Vertical
    primaryLayout.SortOrder = Enum.SortOrder.LayoutOrder
    primaryLayout.Padding = UDim.new(0, theme.sectionSpacing)
    primaryLayout.Parent = primaryColumn

    local secondaryColumn = Instance.new("Frame")
    secondaryColumn.Name = "SecondaryColumn"
    secondaryColumn.BackgroundTransparency = 1
    secondaryColumn.AutomaticSize = Enum.AutomaticSize.Y
    secondaryColumn.Size = UDim2.new(1, 0, 0, 0)
    secondaryColumn.LayoutOrder = 2
    secondaryColumn.Parent = contentRow

    local secondaryLayout = Instance.new("UIListLayout")
    secondaryLayout.FillDirection = Enum.FillDirection.Vertical
    secondaryLayout.SortOrder = Enum.SortOrder.LayoutOrder
    secondaryLayout.Padding = UDim.new(0, theme.sectionSpacing)
    secondaryLayout.Parent = secondaryColumn

    local stagesSection = createSection(theme, primaryColumn, "Verification stages", 1)
    local eventsSection = createSection(theme, secondaryColumn, "Event history", 1)
    local errorsSection = createSection(theme, primaryColumn, "Alerts", 2)

    local stageGrid = Instance.new("Frame")
    stageGrid.Name = "StageGrid"
    stageGrid.BackgroundTransparency = 1
    stageGrid.Size = UDim2.new(1, 0, 0, 0)
    stageGrid.AutomaticSize = Enum.AutomaticSize.Y
    stageGrid.Parent = stagesSection.body

    local stageLayout = Instance.new("UIGridLayout")
    stageLayout.FillDirection = Enum.FillDirection.Horizontal
    stageLayout.SortOrder = Enum.SortOrder.LayoutOrder
    stageLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    stageLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    stageLayout.CellPadding = UDim2.new(0, theme.sectionSpacing, 0, theme.sectionSpacing)
    stageLayout.CellSize = UDim2.new(1, 0, 0, 90)
    stageLayout.Parent = stageGrid

    local stageRows = {}
    local stageOrder = {}
    for index, definition in ipairs(DEFAULT_STAGES) do
        local row = createStageRow(theme, stageGrid, definition)
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

    local eventBase = theme.eventBackground or DEFAULT_THEME.eventBackground
    local accentColor = (theme.filterButton and theme.filterButton.activeColor)
        or (theme.statusColors and theme.statusColors.active)
        or (DEFAULT_THEME.statusColors and DEFAULT_THEME.statusColors.active)
        or Color3.fromRGB(112, 198, 255)

    local eventViewport = Instance.new("Frame")
    eventViewport.Name = "EventViewport"
    eventViewport.BackgroundColor3 = eventBase
    eventViewport.BackgroundTransparency = theme.eventTransparency or DEFAULT_THEME.eventTransparency or 0.04
    eventViewport.BorderSizePixel = 0
    eventViewport.AutomaticSize = Enum.AutomaticSize.None
    eventViewport.Size = UDim2.new(1, 0, 0, theme.eventListHeight or DEFAULT_THEME.eventListHeight)
    eventViewport.ClipsDescendants = true
    eventViewport.Parent = eventsSection.body

    local eventViewportCorner = Instance.new("UICorner")
    eventViewportCorner.CornerRadius = theme.eventCorner or DEFAULT_THEME.eventCorner or UDim.new(0, 10)
    eventViewportCorner.Parent = eventViewport

    local eventViewportStroke = Instance.new("UIStroke")
    eventViewportStroke.Color = theme.eventStrokeColor or DEFAULT_THEME.eventStrokeColor
    eventViewportStroke.Transparency = theme.eventStrokeTransparency or DEFAULT_THEME.eventStrokeTransparency or 0.4
    eventViewportStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    eventViewportStroke.Parent = eventViewport

    local viewportGradient = Instance.new("UIGradient")
    viewportGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, eventBase:Lerp(accentColor, 0.08)),
        ColorSequenceKeypoint.new(1, eventBase),
    })
    viewportGradient.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, math.clamp((theme.eventTransparency or 0.04) + 0.05, 0, 1)),
        NumberSequenceKeypoint.new(1, 0.35),
    })
    viewportGradient.Rotation = 90
    viewportGradient.Parent = eventViewport

    local viewportPadding = Instance.new("UIPadding")
    viewportPadding.PaddingTop = UDim.new(0, 6)
    viewportPadding.PaddingBottom = UDim.new(0, 6)
    viewportPadding.PaddingLeft = UDim.new(0, 6)
    viewportPadding.PaddingRight = UDim.new(0, 6)
    viewportPadding.Parent = eventViewport

    local eventList = Instance.new("ScrollingFrame")
    eventList.Name = "Events"
    eventList.Active = true
    eventList.BackgroundTransparency = 1
    eventList.BorderSizePixel = 0
    eventList.AutomaticSize = Enum.AutomaticSize.None
    eventList.Size = UDim2.new(1, 0, 1, 0)
    eventList.CanvasSize = UDim2.new(0, 0, 0, 0)
    eventList.AutomaticCanvasSize = Enum.AutomaticSize.Y
    eventList.ScrollBarThickness = theme.eventScrollBarThickness or DEFAULT_THEME.eventScrollBarThickness or 6
    eventList.ScrollBarImageColor3 = theme.eventScrollBarColor or DEFAULT_THEME.eventScrollBarColor
    eventList.ScrollBarImageTransparency = theme.eventScrollBarTransparency or DEFAULT_THEME.eventScrollBarTransparency or 0.2
    eventList.ScrollingDirection = Enum.ScrollingDirection.Y
    eventList.ElasticBehavior = Enum.ElasticBehavior.Never
    eventList.Parent = eventViewport
    eventsSection.list = eventList

    local eventPadding = theme.eventListPadding or DEFAULT_THEME.eventListPadding or Vector2.new(10, 8)
    local eventListPadding = Instance.new("UIPadding")
    eventListPadding.PaddingTop = UDim.new(0, eventPadding.Y)
    eventListPadding.PaddingBottom = UDim.new(0, eventPadding.Y)
    eventListPadding.PaddingLeft = UDim.new(0, eventPadding.X)
    eventListPadding.PaddingRight = UDim.new(0, eventPadding.X)
    eventListPadding.Parent = eventList

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
        _overviewRow = overviewRow,
        _overviewLayout = overviewLayout,
        _overviewCards = overviewCards,
        _contentRow = contentRow,
        _contentLayout = contentLayout,
        _primaryColumn = primaryColumn,
        _secondaryColumn = secondaryColumn,
        _primaryLayout = primaryLayout,
        _secondaryLayout = secondaryLayout,
        _stageGrid = stageGrid,
        _stageLayout = stageLayout,
        _stageRows = stageRows,
        _stageOrder = stageOrder,
        _events = {},
        _eventRows = {},
        _eventsList = eventList,
        _filters = {},
        _filterButtons = filterButtons,
        _filterRow = filterRow,
        _filterLayout = filterLayout,
        _activeFilter = nil,
        _badges = {},
        _badgesFrame = badges,
        _badgesLayout = badgesLayout,
        _startClock = os.clock(),
        _metrics = {
            totalStages = #stageOrder,
            readyStages = 0,
            warningStages = 0,
            failedStages = 0,
            activeStage = nil,
            events = 0,
            loaderEvents = 0,
            parryEvents = 0,
            warnings = 0,
            errors = 0,
            activeAlerts = 0,
            lastEvent = nil,
        },
        _connections = {},
        _destroyed = false,
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
    self:_refreshOverview()
    self:_installResponsiveHandlers()

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

    if row.accent then
        row.accent.BackgroundColor3 = color
        row.accent.BackgroundTransparency = (status == "pending" or status == "active") and 0.35 or 0.1
    end

    if row.frame then
        local base = theme.stageBackground
        local emphasis = status == "ok" and 0.08 or (status == "failed" and 0.2 or 0.14)
        row.frame.BackgroundColor3 = base:Lerp(color, emphasis)
    end
end

function DiagnosticsPanel:_updateStageMetrics(stageMap)
    local metrics = self._metrics
    if not metrics then
        return
    end

    local ready = 0
    local warning = 0
    local failed = 0
    local focusScore = -math.huge
    local focusInfo = nil

    for _, id in ipairs(self._stageOrder or {}) do
        local stage = stageMap[id]
        if stage then
            local status = stage.status or "pending"
            if status == "ok" then
                ready += 1
            elseif status == "warning" then
                warning += 1
            elseif status == "failed" then
                failed += 1
            end

            local score = STAGE_STATUS_PRIORITY[status] or 0
            if status ~= "ok" and score >= focusScore then
                focusScore = score
                local label = stage.title or stage.message or stage.description or stage.id or id
                focusInfo = {
                    id = id,
                    title = label,
                    status = status,
                }
            end
        end
    end

    metrics.totalStages = #(self._stageOrder or {})
    metrics.readyStages = ready
    metrics.warningStages = warning
    metrics.failedStages = failed
    metrics.activeStage = focusInfo
end

function DiagnosticsPanel:_registerEventMetrics(event)
    local metrics = self._metrics
    if not metrics then
        return
    end

    metrics.events = (metrics.events or 0) + 1
    if event.kind == "loader" then
        metrics.loaderEvents = (metrics.loaderEvents or 0) + 1
    elseif event.kind == "parry" then
        metrics.parryEvents = (metrics.parryEvents or 0) + 1
    end

    if event.severity == "warning" then
        metrics.warnings = (metrics.warnings or 0) + 1
    elseif event.severity == "error" then
        metrics.errors = (metrics.errors or 0) + 1
    end

    metrics.lastEvent = {
        kind = event.kind,
        message = event.message,
        detail = event.detail,
        timestamp = event.timestamp,
    }
end

function DiagnosticsPanel:_recountActiveAlerts()
    local metrics = self._metrics
    if not metrics then
        return
    end

    local active = 0
    for _, badge in pairs(self._badges) do
        if badge.active then
            active += 1
        end
    end

    metrics.activeAlerts = active
end

function DiagnosticsPanel:_refreshOverview()
    if self._destroyed then
        return
    end

    local cards = self._overviewCards
    if not cards then
        return
    end

    local theme = self._theme or DEFAULT_THEME
    local overviewTheme = theme.overview or DEFAULT_THEME.overview
    local metrics = self._metrics or {}

    local totalStages = metrics.totalStages or #(self._stageOrder or {})
    local readyStages = metrics.readyStages or 0
    local statusCard = cards.status
    if statusCard then
        statusCard.value.Text = string.format("%d/%d", readyStages, totalStages)
        local focus = metrics.activeStage
        if readyStages >= totalStages and totalStages > 0 then
            statusCard.value.TextColor3 = overviewTheme.successColor or overviewTheme.valueColor
            statusCard.detail.Text = "All verification stages passed"
        else
            statusCard.value.TextColor3 = overviewTheme.accentColor or overviewTheme.valueColor
            if focus then
                statusCard.detail.Text = string.format("Focus: %s", tostring(focus.title or focus.id or "stage"))
            else
                statusCard.detail.Text = "Awaiting verification data"
            end
        end
    end

    local eventsCard = cards.events
    if eventsCard then
        local eventsTotal = metrics.events or 0
        eventsCard.value.Text = tostring(eventsTotal)
        eventsCard.value.TextColor3 = overviewTheme.valueColor or Color3.new(1, 1, 1)
        local loader = metrics.loaderEvents or 0
        local parry = metrics.parryEvents or 0
        local lastEvent = metrics.lastEvent
        local summary = string.format("Loader %d • Parry %d", loader, parry)
        if lastEvent then
            local elapsed = formatElapsed(self._startClock, lastEvent.timestamp) or "now"
            local label = lastEvent.message or lastEvent.detail or lastEvent.kind or "event"
            summary = string.format("%s\nLast: %s (%s)", summary, label, elapsed)
        elseif eventsTotal == 0 then
            summary = string.format("%s\nNo events yet", summary)
        end
        eventsCard.detail.Text = summary
    end

    local alertsCard = cards.alerts
    if alertsCard then
        local active = metrics.activeAlerts or 0
        local warnings = metrics.warnings or 0
        local errors = metrics.errors or 0
        if active > 0 or errors > 0 then
            alertsCard.value.Text = tostring(active > 0 and active or errors)
            alertsCard.value.TextColor3 = overviewTheme.dangerColor or overviewTheme.warningColor
            if active > 0 then
                alertsCard.detail.Text = string.format("%d alert%s requiring action", active, active == 1 and "" or "s")
            else
                alertsCard.detail.Text = string.format("%d error event%s logged", errors, errors == 1 and "" or "s")
            end
        elseif warnings > 0 then
            alertsCard.value.Text = tostring(warnings)
            alertsCard.value.TextColor3 = overviewTheme.warningColor or overviewTheme.accentColor
            alertsCard.detail.Text = string.format("%d warning event%s logged", warnings, warnings == 1 and "" or "s")
        else
            alertsCard.value.Text = "0"
            alertsCard.value.TextColor3 = overviewTheme.successColor or overviewTheme.valueColor
            alertsCard.detail.Text = "No active alerts"
        end
    end
end

function DiagnosticsPanel:_installResponsiveHandlers()
    if self._destroyed or not self.frame then
        return
    end

    local connection = self.frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
        if self._destroyed then
            return
        end
        self:_applyResponsiveLayout(self.frame.AbsoluteSize.X)
    end)
    table.insert(self._connections, connection)

    task.defer(function()
        if self._destroyed then
            return
        end
        self:_applyResponsiveLayout(self.frame.AbsoluteSize.X)
    end)
end

function DiagnosticsPanel:_applyResponsiveLayout(width)
    if self._destroyed then
        return
    end

    width = tonumber(width) or 0
    if width <= 0 and self.frame then
        width = self.frame.AbsoluteSize.X
    end
    if width <= 0 then
        return
    end

    local breakpoint
    if width < 640 then
        breakpoint = "small"
    elseif width < 880 then
        breakpoint = "medium"
    else
        breakpoint = "large"
    end
    self._currentBreakpoint = breakpoint

    if self._overviewLayout then
        if breakpoint == "small" then
            self._overviewLayout.FillDirection = Enum.FillDirection.Vertical
            self._overviewLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
            self._overviewLayout.Padding = UDim.new(0, 10)
        else
            self._overviewLayout.FillDirection = Enum.FillDirection.Horizontal
            self._overviewLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
            self._overviewLayout.Padding = UDim.new(0, self._theme.sectionSpacing or DEFAULT_THEME.sectionSpacing or 12)
        end
    end

    local cards = self._overviewCards
    if cards then
        if breakpoint == "small" then
            for _, card in pairs(cards) do
                if card.frame then
                    card.frame.Size = UDim2.new(1, 0, 0, 0)
                end
            end
        elseif breakpoint == "medium" then
            if cards.status and cards.status.frame then
                cards.status.frame.Size = UDim2.new(0.5, -6, 0, 0)
            end
            if cards.events and cards.events.frame then
                cards.events.frame.Size = UDim2.new(0.5, -6, 0, 0)
            end
            if cards.alerts and cards.alerts.frame then
                cards.alerts.frame.Size = UDim2.new(1, 0, 0, 0)
            end
        else
            local segments = 0
            for _, card in pairs(cards) do
                if card.frame then
                    segments += 1
                end
            end
            segments = math.max(segments, 1)
            local widthScale = 1 / segments
            for _, card in pairs(cards) do
                if card.frame then
                    card.frame.Size = UDim2.new(widthScale, -8, 0, 0)
                end
            end
        end
    end

    if self._contentLayout then
        if breakpoint == "large" then
            self._contentLayout.FillDirection = Enum.FillDirection.Horizontal
            self._contentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
            self._contentLayout.Padding = UDim.new(0, self._theme.sectionSpacing or DEFAULT_THEME.sectionSpacing or 12)
        else
            self._contentLayout.FillDirection = Enum.FillDirection.Vertical
            self._contentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
            self._contentLayout.Padding = UDim.new(0, self._theme.sectionSpacing or DEFAULT_THEME.sectionSpacing or 12)
        end
    end

    if self._primaryColumn and self._secondaryColumn then
        if breakpoint == "large" then
            self._primaryColumn.Size = UDim2.new(0.56, -8, 0, 0)
            self._secondaryColumn.Size = UDim2.new(0.44, -8, 0, 0)
        else
            self._primaryColumn.Size = UDim2.new(1, 0, 0, 0)
            self._secondaryColumn.Size = UDim2.new(1, 0, 0, 0)
        end
    end

    if self._stageLayout then
        if breakpoint == "large" then
            self._stageLayout.CellSize = UDim2.new(0.5, -8, 0, 98)
            self._stageLayout.CellPadding = UDim2.new(0, 12, 0, 12)
        else
            self._stageLayout.CellSize = UDim2.new(1, 0, 0, 98)
            self._stageLayout.CellPadding = UDim2.new(0, 10, 0, 10)
        end
    end

    if self._filterLayout then
        local filterTheme = (self._theme and self._theme.filterButton) or DEFAULT_THEME.filterButton
        if breakpoint == "small" then
            self._filterLayout.FillDirection = Enum.FillDirection.Vertical
            self._filterLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
            self._filterLayout.Padding = UDim.new(0, 6)
            for _, button in pairs(self._filterButtons) do
                button.Size = UDim2.new(1, 0, 0, 28)
                button.TextXAlignment = Enum.TextXAlignment.Left
            end
        else
            self._filterLayout.FillDirection = Enum.FillDirection.Horizontal
            self._filterLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
            self._filterLayout.Padding = UDim.new(0, 8)
            for _, button in pairs(self._filterButtons) do
                local widthEstimate = math.max(60, button.TextBounds.X + filterTheme.padding.X * 2)
                button.Size = UDim2.new(0, widthEstimate, 0, 26)
                button.TextXAlignment = Enum.TextXAlignment.Center
            end
        end
    end

    if self._badgesLayout then
        if breakpoint == "small" then
            self._badgesLayout.FillDirection = Enum.FillDirection.Vertical
            self._badgesLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
        else
            self._badgesLayout.FillDirection = Enum.FillDirection.Horizontal
            self._badgesLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
        end
    end
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

    self:_updateStageMetrics(map)
    self:_refreshOverview()
end

function DiagnosticsPanel:pushEvent(event)
    if typeof(event) ~= "table" then
        return
    end

    local copied = deepCopy(event)
    copied.sequence = copied.sequence or (#self._events + 1)
    copied.timestamp = copied.timestamp or os.clock()

    table.insert(self._events, copied)

    local eventsList = self._eventsList
    if not eventsList and self._sections and self._sections.events then
        eventsList = self._sections.events.list
        self._eventsList = eventsList
    end

    if not eventsList then
        return
    end

    local entry = createEventRow(self._theme, eventsList, copied, self._startClock)
    entry.event = copied
    table.insert(self._eventRows, entry)

    self:_updateEventRow(entry, copied)
    self:_applyFilter()
    self:_registerEventMetrics(copied)
    self:_refreshOverview()
end

function DiagnosticsPanel:showError(errorInfo)
    if errorInfo == nil then
        for _, badge in pairs(self._badges) do
            badge.frame:Destroy()
        end
        self._badges = {}
        self:_recountActiveAlerts()
        self:_refreshOverview()
        return
    end

    local id = tostring(errorInfo.id or errorInfo.kind or (#self._badges + 1))
    local badge = self._badges[id]
    if not badge then
        local badgeParent = (self._badgesFrame and self._badgesFrame.Parent) and self._badgesFrame or (self._sections.errors and self._sections.errors.body and self._sections.errors.body.Badges)
        badge = createBadge(self._theme, badgeParent, id)
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
    self:_recountActiveAlerts()
    self:_refreshOverview()
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

    if self._metrics then
        self._metrics.events = 0
        self._metrics.loaderEvents = 0
        self._metrics.parryEvents = 0
        self._metrics.warnings = 0
        self._metrics.errors = 0
        self._metrics.activeAlerts = 0
        self._metrics.lastEvent = nil
        self._metrics.readyStages = 0
        self._metrics.warningStages = 0
        self._metrics.failedStages = 0
        self._metrics.activeStage = nil
    end

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

    self:_refreshOverview()
end

function DiagnosticsPanel:destroy()
    if self._destroyed then
        return
    end

    self._destroyed = true

    for _, connection in ipairs(self._connections or {}) do
        connection:Disconnect()
    end
    self._connections = nil

    if self.frame then
        self.frame:Destroy()
        self.frame = nil
    end

    self._sections = nil
    self._stageRows = nil
    self._eventRows = nil
    self._eventsList = nil
    self._badges = nil
end

return DiagnosticsPanel

]===],
    ['src/ui/init.lua'] = [===[
-- src/ui/init.lua (sha1: 4e0730c226ce2e2f7003a1800dc5b5716e9280e3)
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
-- src/ui/loading_overlay.lua (sha1: 5083ababdb30a04805bb33f5e6c05af90807122f)
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
    dashboardMinWidth = 360,
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
    local dashboardMinWidth = math.max(theme.dashboardMinWidth or DEFAULT_THEME.dashboardMinWidth or 360, 0)
    local configuredDashboardMaxWidth = theme.dashboardMaxWidth or DEFAULT_THEME.dashboardMaxWidth or 760
    -- Roblox errors when MaxSize < MinSize; clamp to keep constraints sane even
    -- if a custom theme requests an unusually small dashboard width.
    local dashboardMaxWidth = math.max(configuredDashboardMaxWidth, dashboardMinWidth)
    Util.setConstraintSize(
        dashboardMountConstraint,
        Vector2.new(dashboardMinWidth, 0),
        Vector2.new(dashboardMaxWidth, math.huge)
    )
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
        _dashboardMountConstraint = dashboardMountConstraint,
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
        viewportHeight = math.floor(viewportHeight + 0.5),
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
        viewportHeight = viewportSize and math.floor(viewportHeight + 0.5) or scaledHeight,
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
    if self._dashboardMountConstraint then
        local minWidth = math.max(theme.dashboardMinWidth or DEFAULT_THEME.dashboardMinWidth or 360, 0)
        local configuredMax = theme.dashboardMaxWidth or DEFAULT_THEME.dashboardMaxWidth or minWidth
        local maxWidth = math.max(configuredMax, minWidth)
        local minVector = Vector2.new(minWidth, 0)
        local maxVector = Vector2.new(maxWidth, math.huge)
        Util.setConstraintSize(self._dashboardMountConstraint, minVector, maxVector)
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
-- src/ui/verification_dashboard.lua (sha1: 88012866db3efe27938fc5dee5af622c07d20b27)
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
        widthScale = 1,
        maxWidth = 1100,
        minWidth = 560,
        horizontalPadding = 24,
        contentSpacing = 20,
        contentColumnPadding = 24,
        primaryColumnRatio = 0.64,
        primaryColumnMinWidth = 420,
        secondaryColumnMinWidth = 320,
    },
    timeline = {
        headerFont = Enum.Font.GothamSemibold,
        headerTextSize = 18,
        headerColor = Color3.fromRGB(226, 236, 252),
        subtitleFont = Enum.Font.Gotham,
        subtitleTextSize = 15,
        subtitleColor = Color3.fromRGB(176, 192, 224),
        subtitleTintMix = 0.22,
        badgeFont = Enum.Font.GothamSemibold,
        badgeTextSize = 13,
        badgeTextColor = Color3.fromRGB(226, 236, 252),
        badgeBackground = Color3.fromRGB(30, 36, 48),
        badgeBackgroundTransparency = 0.18,
        badgeBackgroundHighlight = 0.16,
        badgeStrokeColor = Color3.fromRGB(88, 142, 218),
        badgeStrokeTransparency = 0.28,
        badgeStrokeMix = 0.18,
        badgeAccentColor = Color3.fromRGB(112, 198, 255),
        badgeAccentTransparency = 0,
        badgeDefaultColor = Color3.fromRGB(112, 198, 255),
        badgeActiveColor = Color3.fromRGB(112, 198, 255),
        badgeSuccessColor = Color3.fromRGB(118, 228, 182),
        badgeWarningColor = Color3.fromRGB(255, 198, 110),
        badgeDangerColor = Color3.fromRGB(248, 110, 128),
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
    local initialMinWidth = math.max(0, layoutTheme.minWidth or 420)
    local configuredMaxWidth = layoutTheme.maxWidth or 720
    -- Guard against custom themes setting a max width smaller than the min
    -- width, which would otherwise trigger Roblox constraint warnings.
    local initialMaxWidth = math.max(configuredMaxWidth, initialMinWidth)
    Util.setConstraintSize(canvasConstraint, Vector2.new(initialMinWidth, 0), Vector2.new(initialMaxWidth, math.huge))
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

    local contentRow = Instance.new("Frame")
    contentRow.Name = "ContentRow"
    contentRow.BackgroundTransparency = 1
    contentRow.AutomaticSize = Enum.AutomaticSize.Y
    contentRow.Size = UDim2.new(1, 0, 0, 0)
    contentRow.LayoutOrder = 2
    contentRow.Parent = canvas

    local contentLayout = Instance.new("UIListLayout")
    contentLayout.FillDirection = Enum.FillDirection.Vertical
    contentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    contentLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
    contentLayout.Padding = UDim.new(0, layoutTheme.contentSpacing or 18)
    contentLayout.Parent = contentRow

    local primaryColumn = Instance.new("Frame")
    primaryColumn.Name = "PrimaryColumn"
    primaryColumn.BackgroundTransparency = 1
    primaryColumn.AutomaticSize = Enum.AutomaticSize.Y
    primaryColumn.Size = UDim2.new(1, 0, 0, 0)
    primaryColumn.LayoutOrder = 1
    primaryColumn.Parent = contentRow

    local primaryLayout = Instance.new("UIListLayout")
    primaryLayout.FillDirection = Enum.FillDirection.Vertical
    primaryLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    primaryLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    primaryLayout.SortOrder = Enum.SortOrder.LayoutOrder
    primaryLayout.Padding = UDim.new(0, layoutTheme.contentSpacing or 18)
    primaryLayout.Parent = primaryColumn

    local secondaryColumn = Instance.new("Frame")
    secondaryColumn.Name = "SecondaryColumn"
    secondaryColumn.BackgroundTransparency = 1
    secondaryColumn.AutomaticSize = Enum.AutomaticSize.Y
    secondaryColumn.Size = UDim2.new(1, 0, 0, 0)
    secondaryColumn.LayoutOrder = 2
    secondaryColumn.Parent = contentRow

    local secondaryLayout = Instance.new("UIListLayout")
    secondaryLayout.FillDirection = Enum.FillDirection.Vertical
    secondaryLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    secondaryLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    secondaryLayout.SortOrder = Enum.SortOrder.LayoutOrder
    secondaryLayout.Padding = UDim.new(0, layoutTheme.contentSpacing or 18)
    secondaryLayout.Parent = secondaryColumn

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
    insightsCard.LayoutOrder = 1
    insightsCard.AutomaticSize = Enum.AutomaticSize.Y
    insightsCard.Size = UDim2.new(1, 0, 0, 0)
    insightsCard.Parent = primaryColumn

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

    local timelineTheme = mergeTable(DEFAULT_THEME.timeline or {}, theme.timeline or {})

    local timelineCard = Instance.new("Frame")
    timelineCard.Name = "TimelineCard"
    timelineCard.BackgroundColor3 = theme.cardColor
    timelineCard.BackgroundTransparency = theme.cardTransparency
    timelineCard.BorderSizePixel = 0
    timelineCard.AutomaticSize = Enum.AutomaticSize.Y
    timelineCard.Size = UDim2.new(1, 0, 0, 200)
    timelineCard.LayoutOrder = 2
    timelineCard.Parent = secondaryColumn

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

    local timelineHeader = Instance.new("Frame")
    timelineHeader.Name = "TimelineHeader"
    timelineHeader.BackgroundTransparency = 1
    timelineHeader.AutomaticSize = Enum.AutomaticSize.Y
    timelineHeader.Size = UDim2.new(1, 0, 0, 0)
    timelineHeader.LayoutOrder = 1
    timelineHeader.Parent = timelineCard

    local timelineHeaderLayout = Instance.new("UIListLayout")
    timelineHeaderLayout.FillDirection = Enum.FillDirection.Vertical
    timelineHeaderLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    timelineHeaderLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    timelineHeaderLayout.SortOrder = Enum.SortOrder.LayoutOrder
    timelineHeaderLayout.Padding = UDim.new(0, 6)
    timelineHeaderLayout.Parent = timelineHeader

    local headerRow = Instance.new("Frame")
    headerRow.Name = "HeaderRow"
    headerRow.BackgroundTransparency = 1
    headerRow.Size = UDim2.new(1, 0, 0, 32)
    headerRow.LayoutOrder = 1
    headerRow.Parent = timelineHeader

    local timelineTitle = Instance.new("TextLabel")
    timelineTitle.Name = "Title"
    timelineTitle.BackgroundTransparency = 1
    timelineTitle.AnchorPoint = Vector2.new(0, 0.5)
    timelineTitle.Position = UDim2.new(0, 0, 0.5, 0)
    timelineTitle.Size = UDim2.new(1, -150, 0, 26)
    timelineTitle.Text = "Verification timeline"
    timelineTitle.TextXAlignment = Enum.TextXAlignment.Left
    timelineTitle.Font = timelineTheme.headerFont or DEFAULT_THEME.timeline.headerFont
    timelineTitle.TextSize = timelineTheme.headerTextSize or DEFAULT_THEME.timeline.headerTextSize
    timelineTitle.TextColor3 = timelineTheme.headerColor or DEFAULT_THEME.timeline.headerColor
    timelineTitle.Parent = headerRow

    local badgeContainer = Instance.new("Frame")
    badgeContainer.Name = "StatusBadge"
    badgeContainer.AnchorPoint = Vector2.new(1, 0.5)
    badgeContainer.Position = UDim2.new(1, 0, 0.5, 0)
    badgeContainer.AutomaticSize = Enum.AutomaticSize.XY
    badgeContainer.Size = UDim2.new(0, 144, 0, 28)
    badgeContainer.BackgroundColor3 = timelineTheme.badgeBackground or DEFAULT_THEME.timeline.badgeBackground
    badgeContainer.BackgroundTransparency = timelineTheme.badgeBackgroundTransparency or DEFAULT_THEME.timeline.badgeBackgroundTransparency
    badgeContainer.BorderSizePixel = 0
    badgeContainer.Parent = headerRow

    local badgeCorner = Instance.new("UICorner")
    badgeCorner.CornerRadius = UDim.new(0, 12)
    badgeCorner.Parent = badgeContainer

    local badgeStroke = Instance.new("UIStroke")
    badgeStroke.Thickness = 1
    badgeStroke.Color = timelineTheme.badgeStrokeColor or DEFAULT_THEME.timeline.badgeStrokeColor
    badgeStroke.Transparency = timelineTheme.badgeStrokeTransparency or DEFAULT_THEME.timeline.badgeStrokeTransparency
    badgeStroke.Parent = badgeContainer

    local badgeAccent = Instance.new("Frame")
    badgeAccent.Name = "Accent"
    badgeAccent.AnchorPoint = Vector2.new(0, 0.5)
    badgeAccent.Position = UDim2.new(0, 0, 0.5, 0)
    badgeAccent.Size = UDim2.new(0, 4, 1, 0)
    badgeAccent.BorderSizePixel = 0
    badgeAccent.BackgroundColor3 = timelineTheme.badgeAccentColor or DEFAULT_THEME.timeline.badgeAccentColor
    badgeAccent.BackgroundTransparency = timelineTheme.badgeAccentTransparency or DEFAULT_THEME.timeline.badgeAccentTransparency
    badgeAccent.Parent = badgeContainer

    local badgeLabel = Instance.new("TextLabel")
    badgeLabel.Name = "Label"
    badgeLabel.BackgroundTransparency = 1
    badgeLabel.AnchorPoint = Vector2.new(0, 0.5)
    badgeLabel.Position = UDim2.new(0, 8, 0.5, 0)
    badgeLabel.Size = UDim2.new(1, -16, 0, 0)
    badgeLabel.AutomaticSize = Enum.AutomaticSize.Y
    badgeLabel.Font = timelineTheme.badgeFont or DEFAULT_THEME.timeline.badgeFont
    badgeLabel.TextSize = timelineTheme.badgeTextSize or DEFAULT_THEME.timeline.badgeTextSize
    badgeLabel.TextXAlignment = Enum.TextXAlignment.Left
    badgeLabel.TextColor3 = timelineTheme.badgeTextColor or DEFAULT_THEME.timeline.badgeTextColor
    badgeLabel.Text = "Preparing checks"
    badgeLabel.Parent = badgeContainer

    local timelineStatus = Instance.new("TextLabel")
    timelineStatus.Name = "Status"
    timelineStatus.BackgroundTransparency = 1
    timelineStatus.AutomaticSize = Enum.AutomaticSize.Y
    timelineStatus.Size = UDim2.new(1, 0, 0, 0)
    timelineStatus.TextXAlignment = Enum.TextXAlignment.Left
    timelineStatus.TextWrapped = true
    timelineStatus.Font = timelineTheme.subtitleFont or DEFAULT_THEME.timeline.subtitleFont
    timelineStatus.TextSize = timelineTheme.subtitleTextSize or DEFAULT_THEME.timeline.subtitleTextSize
    timelineStatus.TextColor3 = timelineTheme.subtitleColor or DEFAULT_THEME.timeline.subtitleColor
    timelineStatus.Text = "Awaiting verification updates."
    timelineStatus.LayoutOrder = 2
    timelineStatus.Parent = timelineHeader

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
    progressTrack.LayoutOrder = 2
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
    listFrame.LayoutOrder = 3
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
    actionsFrame.LayoutOrder = 3
    actionsFrame.Size = UDim2.new(1, 0, 0, theme.actionHeight + 12)
    actionsFrame.Visible = false
    actionsFrame.Parent = canvas

    local actionsLayout = Instance.new("UIListLayout")
    actionsLayout.FillDirection = Enum.FillDirection.Horizontal
    actionsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    actionsLayout.SortOrder = Enum.SortOrder.LayoutOrder
    actionsLayout.Padding = UDim.new(0, 12)
    actionsLayout.Parent = actionsFrame

    local contentDefaults = {
        fillDirection = contentLayout.FillDirection,
        horizontalAlignment = contentLayout.HorizontalAlignment,
        verticalAlignment = contentLayout.VerticalAlignment,
        padding = contentLayout.Padding,
    }

    local columnDefaults = {
        primarySize = primaryColumn.Size,
        primaryOrder = primaryColumn.LayoutOrder,
        secondarySize = secondaryColumn.Size,
        secondaryOrder = secondaryColumn.LayoutOrder,
    }

    local primaryLayoutDefaults = {
        padding = primaryLayout.Padding,
        horizontalAlignment = primaryLayout.HorizontalAlignment,
    }

    local secondaryLayoutDefaults = {
        padding = secondaryLayout.Padding,
        horizontalAlignment = secondaryLayout.HorizontalAlignment,
    }

    local timelineHeaderDefaults = {
        horizontalAlignment = timelineHeaderLayout.HorizontalAlignment,
        titleAlignment = timelineTitle.TextXAlignment,
        statusAlignment = timelineStatus.TextXAlignment,
    }

    local timelineBadgeDefaults = {
        anchorPoint = badgeContainer.AnchorPoint,
        position = badgeContainer.Position,
    }

    local insightsCardSizeDefault = insightsCard.Size
    local timelineCardSizeDefault = timelineCard.Size

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
        _contentRow = contentRow,
        _contentLayout = contentLayout,
        _contentDefaults = contentDefaults,
        _primaryColumn = primaryColumn,
        _secondaryColumn = secondaryColumn,
        _primaryLayout = primaryLayout,
        _secondaryLayout = secondaryLayout,
        _columnDefaults = columnDefaults,
        _primaryLayoutDefaults = primaryLayoutDefaults,
        _secondaryLayoutDefaults = secondaryLayoutDefaults,
        _insightsCard = insightsCard,
        _insightsStroke = insightsStroke,
        _insightsGradient = insightsGradient,
        _insightsLayout = insightsLayout,
        _insightsPadding = insightsPadding,
        _insightsSizeDefaults = insightsCardSizeDefault,
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
        _timelineHeader = timelineHeader,
        _timelineHeaderLayout = timelineHeaderLayout,
        _timelineHeaderDefaults = timelineHeaderDefaults,
        _timelineTitle = timelineTitle,
        _timelineStatusLabel = timelineStatus,
        _timelineBadgeFrame = badgeContainer,
        _timelineBadge = badgeLabel,
        _timelineBadgeAccent = badgeAccent,
        _timelineBadgeStroke = badgeStroke,
        _timelineBadgeDefaults = timelineBadgeDefaults,
        _progressTrack = progressTrack,
        _progressFill = progressFill,
        _progressTrackStroke = trackStroke,
        _progressTween = nil,
        _stepsFrame = listFrame,
        _steps = steps,
        _stepStates = {},
        _timelineSizeDefaults = timelineCardSizeDefault,
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

    self:_updateTimelineBadge()

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
        local minVector = Vector2.new(math.max(0, minWidth), 0)
        local maxVector = Vector2.new(math.max(0, maxWidth), math.huge)
        Util.setConstraintSize(canvasConstraint, minVector, maxVector)
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

    if self._contentLayout and self._contentDefaults then
        self._contentLayout.FillDirection = self._contentDefaults.fillDirection
        self._contentLayout.HorizontalAlignment = self._contentDefaults.horizontalAlignment
        self._contentLayout.VerticalAlignment = self._contentDefaults.verticalAlignment
        self._contentLayout.Padding = self._contentDefaults.padding or self._contentLayout.Padding
    end

    if self._primaryLayout and self._primaryLayoutDefaults then
        self._primaryLayout.Padding = self._primaryLayoutDefaults.padding or self._primaryLayout.Padding
        self._primaryLayout.HorizontalAlignment = self._primaryLayoutDefaults.horizontalAlignment or self._primaryLayout.HorizontalAlignment
    end

    if self._secondaryLayout and self._secondaryLayoutDefaults then
        self._secondaryLayout.Padding = self._secondaryLayoutDefaults.padding or self._secondaryLayout.Padding
        self._secondaryLayout.HorizontalAlignment = self._secondaryLayoutDefaults.horizontalAlignment or self._secondaryLayout.HorizontalAlignment
    end

    if self._primaryColumn and self._columnDefaults then
        self._primaryColumn.Size = self._columnDefaults.primarySize
        self._primaryColumn.LayoutOrder = self._columnDefaults.primaryOrder or self._primaryColumn.LayoutOrder
    end

    if self._secondaryColumn and self._columnDefaults then
        self._secondaryColumn.Size = self._columnDefaults.secondarySize
        self._secondaryColumn.LayoutOrder = self._columnDefaults.secondaryOrder or self._secondaryColumn.LayoutOrder
    end

    if self._timelineHeaderLayout and self._timelineHeaderDefaults then
        self._timelineHeaderLayout.HorizontalAlignment = self._timelineHeaderDefaults.horizontalAlignment or self._timelineHeaderLayout.HorizontalAlignment
    end

    if self._timelineTitle and self._timelineHeaderDefaults then
        self._timelineTitle.TextXAlignment = self._timelineHeaderDefaults.titleAlignment or self._timelineTitle.TextXAlignment
    end

    if self._timelineStatusLabel and self._timelineHeaderDefaults then
        self._timelineStatusLabel.TextXAlignment = self._timelineHeaderDefaults.statusAlignment or self._timelineStatusLabel.TextXAlignment
    end

    if self._timelineBadgeFrame and self._timelineBadgeDefaults then
        self._timelineBadgeFrame.AnchorPoint = self._timelineBadgeDefaults.anchorPoint or self._timelineBadgeFrame.AnchorPoint
        self._timelineBadgeFrame.Position = self._timelineBadgeDefaults.position or self._timelineBadgeFrame.Position
    end

    if self._insightsCard and self._insightsSizeDefaults then
        self._insightsCard.Size = self._insightsSizeDefaults
    end

    if self._timelineCard and self._timelineSizeDefaults then
        self._timelineCard.Size = self._timelineSizeDefaults
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
        if self._contentLayout then
            self._contentLayout.FillDirection = Enum.FillDirection.Vertical
            self._contentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
            self._contentLayout.Padding = UDim.new(0, layoutTheme.contentSpacing or 18)
        end
        if self._primaryColumn then
            self._primaryColumn.Size = UDim2.new(1, 0, 0, 0)
            self._primaryColumn.LayoutOrder = 1
        end
        if self._secondaryColumn then
            self._secondaryColumn.Size = UDim2.new(1, 0, 0, 0)
            self._secondaryColumn.LayoutOrder = 2
        end
        if self._insightsCard then
            self._insightsCard.Size = UDim2.new(1, 0, 0, 0)
        end
        if self._timelineCard then
            self._timelineCard.Size = UDim2.new(1, 0, 0, 0)
        end
        if self._timelineHeaderLayout then
            self._timelineHeaderLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        end
        if self._timelineTitle then
            self._timelineTitle.TextXAlignment = Enum.TextXAlignment.Center
        end
        if self._timelineStatusLabel then
            self._timelineStatusLabel.TextXAlignment = Enum.TextXAlignment.Center
        end
        if self._timelineBadgeFrame then
            self._timelineBadgeFrame.AnchorPoint = Vector2.new(0.5, 0.5)
            self._timelineBadgeFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
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
        if self._contentLayout then
            self._contentLayout.FillDirection = Enum.FillDirection.Vertical
            self._contentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
            self._contentLayout.Padding = UDim.new(0, layoutTheme.contentSpacing or 18)
        end
        if self._primaryColumn then
            self._primaryColumn.Size = UDim2.new(1, 0, 0, 0)
            self._primaryColumn.LayoutOrder = 1
        end
        if self._secondaryColumn then
            self._secondaryColumn.Size = UDim2.new(1, 0, 0, 0)
            self._secondaryColumn.LayoutOrder = 2
        end
        if self._insightsCard then
            self._insightsCard.Size = UDim2.new(1, 0, 0, 0)
        end
        if self._timelineCard then
            self._timelineCard.Size = UDim2.new(1, 0, 0, 0)
        end
        if self._timelineHeaderLayout then
            self._timelineHeaderLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
        end
        if self._timelineTitle then
            self._timelineTitle.TextXAlignment = Enum.TextXAlignment.Left
        end
        if self._timelineStatusLabel then
            self._timelineStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
        end
        if self._timelineBadgeFrame then
            self._timelineBadgeFrame.AnchorPoint = Vector2.new(1, 0.5)
            self._timelineBadgeFrame.Position = UDim2.new(1, 0, 0.5, 0)
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

        local columnPadding = (layoutTheme and layoutTheme.contentColumnPadding) or 24
        if self._contentLayout then
            self._contentLayout.FillDirection = Enum.FillDirection.Horizontal
            self._contentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
            self._contentLayout.VerticalAlignment = Enum.VerticalAlignment.Top
            self._contentLayout.Padding = UDim.new(0, columnPadding)
        end

        local horizontalPadding = (layoutTheme and layoutTheme.horizontalPadding) or 0
        local estimatedWidth = dashboardWidth - (horizontalPadding * 2)
        if bounds and bounds.contentWidth then
            estimatedWidth = bounds.contentWidth
        elseif self._contentRow and self._contentRow.AbsoluteSize.X > 0 then
            estimatedWidth = self._contentRow.AbsoluteSize.X
        end

        local minPrimary = (layoutTheme and layoutTheme.primaryColumnMinWidth) or 420
        local minSecondary = (layoutTheme and layoutTheme.secondaryColumnMinWidth) or 320
        estimatedWidth = math.max(estimatedWidth, minPrimary + minSecondary + columnPadding)
        local availableWidth = math.max(estimatedWidth - columnPadding, minPrimary + minSecondary)
        local ratio = (layoutTheme and layoutTheme.primaryColumnRatio) or 0.64
        ratio = math.clamp(ratio, 0.48, 0.75)
        local desiredPrimary = math.floor(availableWidth * ratio + 0.5)
        local maxPrimary = math.max(minPrimary, availableWidth - minSecondary)
        local primaryWidth = math.clamp(desiredPrimary, minPrimary, maxPrimary)
        local secondaryWidth = availableWidth - primaryWidth
        if secondaryWidth < minSecondary then
            secondaryWidth = minSecondary
            primaryWidth = math.max(minPrimary, availableWidth - secondaryWidth)
        end
        primaryWidth = math.floor(primaryWidth + 0.5)
        secondaryWidth = math.floor(secondaryWidth + 0.5)
        if primaryWidth + secondaryWidth > availableWidth then
            primaryWidth = math.max(minPrimary, availableWidth - minSecondary)
            secondaryWidth = math.max(minSecondary, availableWidth - primaryWidth)
        end

        if self._primaryColumn then
            self._primaryColumn.Size = UDim2.new(0, primaryWidth, 0, 0)
            self._primaryColumn.LayoutOrder = 1
        end
        if self._secondaryColumn then
            self._secondaryColumn.Size = UDim2.new(0, secondaryWidth, 0, 0)
            self._secondaryColumn.LayoutOrder = 2
        end
        if self._insightsCard then
            self._insightsCard.Size = UDim2.new(1, 0, 0, 0)
        end
        if self._timelineCard then
            self._timelineCard.Size = UDim2.new(1, 0, 0, 0)
        end
        if self._timelineHeaderLayout then
            self._timelineHeaderLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
        end
        if self._timelineTitle then
            self._timelineTitle.TextXAlignment = Enum.TextXAlignment.Left
        end
        if self._timelineStatusLabel then
            self._timelineStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
        end
        if self._timelineBadgeFrame then
            self._timelineBadgeFrame.AnchorPoint = Vector2.new(1, 0.5)
            self._timelineBadgeFrame.Position = UDim2.new(1, 0, 0.5, 0)
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

    if self._contentLayout then
        local contentPadding = self._layoutTheme.contentSpacing or 18
        self._contentLayout.Padding = UDim.new(0, contentPadding)
        if self._contentDefaults then
            self._contentDefaults.padding = UDim.new(0, contentPadding)
        end
    end

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

    local timelineTheme = mergeTable(DEFAULT_THEME.timeline or {}, currentTheme.timeline or {})
    if self._timelineTitle then
        self._timelineTitle.Font = timelineTheme.headerFont or DEFAULT_THEME.timeline.headerFont
        self._timelineTitle.TextSize = timelineTheme.headerTextSize or DEFAULT_THEME.timeline.headerTextSize
        self._timelineTitle.TextColor3 = timelineTheme.headerColor or DEFAULT_THEME.timeline.headerColor
    end
    if self._timelineStatusLabel then
        self._timelineStatusLabel.Font = timelineTheme.subtitleFont or DEFAULT_THEME.timeline.subtitleFont
        self._timelineStatusLabel.TextSize = timelineTheme.subtitleTextSize or DEFAULT_THEME.timeline.subtitleTextSize
        self._timelineStatusLabel.TextColor3 = timelineTheme.subtitleColor or DEFAULT_THEME.timeline.subtitleColor
    end
    if self._timelineBadge then
        self._timelineBadge.Font = timelineTheme.badgeFont or DEFAULT_THEME.timeline.badgeFont
        self._timelineBadge.TextSize = timelineTheme.badgeTextSize or DEFAULT_THEME.timeline.badgeTextSize
        self._timelineBadge.TextColor3 = timelineTheme.badgeTextColor or DEFAULT_THEME.timeline.badgeTextColor
    end
    if self._timelineBadgeFrame then
        self._timelineBadgeFrame.BackgroundColor3 = timelineTheme.badgeBackground or DEFAULT_THEME.timeline.badgeBackground
        self._timelineBadgeFrame.BackgroundTransparency = timelineTheme.badgeBackgroundTransparency or DEFAULT_THEME.timeline.badgeBackgroundTransparency
    end
    if self._timelineBadgeStroke then
        self._timelineBadgeStroke.Color = timelineTheme.badgeStrokeColor or DEFAULT_THEME.timeline.badgeStrokeColor
        self._timelineBadgeStroke.Transparency = timelineTheme.badgeStrokeTransparency or DEFAULT_THEME.timeline.badgeStrokeTransparency
    end
    if self._timelineBadgeAccent then
        self._timelineBadgeAccent.BackgroundColor3 = timelineTheme.badgeAccentColor or DEFAULT_THEME.timeline.badgeAccentColor
        self._timelineBadgeAccent.BackgroundTransparency = timelineTheme.badgeAccentTransparency or DEFAULT_THEME.timeline.badgeAccentTransparency
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

    self:_updateTimelineBadge()

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

    self:_updateTimelineBadge()
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

function VerificationDashboard:_updateTimelineBadge()
    if self._destroyed then
        return
    end

    if not (self._timelineBadge and self._timelineStatusLabel) then
        return
    end

    local theme = self._theme or DEFAULT_THEME
    local timelineTheme = mergeTable(DEFAULT_THEME.timeline or {}, theme.timeline or {})

    local states = self._stepStates or {}
    local worstStatus = "pending"
    local worstPriority = -math.huge
    local worstDefinition
    local activeDefinition
    local nextPending
    local allOk = true

    for _, definition in ipairs(STEP_DEFINITIONS) do
        local state = states[definition.id]
        local status = state and state.status or "pending"
        local priority = STATUS_PRIORITY[status] or 0

        if status ~= "ok" then
            allOk = false
        end

        if status == "active" and not activeDefinition then
            activeDefinition = definition
        end

        if status == "pending" and not nextPending then
            nextPending = definition
        end

        if priority > worstPriority then
            worstPriority = priority
            worstStatus = status
            worstDefinition = definition
        end
    end

    local badgeColor
    local badgeText
    local statusText

    if worstStatus == "failed" then
        badgeText = "Failure detected"
        badgeColor = timelineTheme.badgeDangerColor or theme.failedColor
        statusText = string.format("%s needs attention immediately.", (worstDefinition and worstDefinition.title) or "A verification stage")
    elseif worstStatus == "warning" then
        badgeText = "Warnings active"
        badgeColor = timelineTheme.badgeWarningColor or theme.warningColor
        statusText = string.format("%s reported unusual data.", (worstDefinition and worstDefinition.title) or "A verification stage")
    elseif allOk and worstPriority >= (STATUS_PRIORITY.ok or 2) then
        badgeText = "All systems ready"
        badgeColor = timelineTheme.badgeSuccessColor or theme.okColor
        statusText = "Every verification check has passed."
    elseif worstStatus == "active" then
        local focus = activeDefinition or worstDefinition or nextPending or STEP_DEFINITIONS[1]
        badgeText = "Verification running"
        badgeColor = timelineTheme.badgeActiveColor or theme.accentColor
        statusText = focus and string.format("Currently checking %s.", focus.title) or "Verification checks are in progress."
    else
        local upcoming = nextPending or worstDefinition or STEP_DEFINITIONS[1]
        badgeText = "Preparing checks"
        badgeColor = timelineTheme.badgeDefaultColor or theme.accentColor
        statusText = upcoming and string.format("Next up: %s.", upcoming.title) or "Awaiting verification updates."
    end

    if self._timelineBadge then
        self._timelineBadge.Text = badgeText
        self._timelineBadge.TextColor3 = timelineTheme.badgeTextColor or self._timelineBadge.TextColor3
        self._timelineBadge.Font = timelineTheme.badgeFont or DEFAULT_THEME.timeline.badgeFont
        self._timelineBadge.TextSize = timelineTheme.badgeTextSize or DEFAULT_THEME.timeline.badgeTextSize
    end

    if self._timelineBadgeFrame then
        local baseBackground = timelineTheme.badgeBackground or theme.cardColor
        local highlight = timelineTheme.badgeBackgroundHighlight or 0.16
        self._timelineBadgeFrame.BackgroundColor3 = baseBackground:Lerp(badgeColor, highlight)
        self._timelineBadgeFrame.BackgroundTransparency = timelineTheme.badgeBackgroundTransparency or DEFAULT_THEME.timeline.badgeBackgroundTransparency
    end

    if self._timelineBadgeAccent then
        self._timelineBadgeAccent.BackgroundColor3 = badgeColor
        self._timelineBadgeAccent.BackgroundTransparency = timelineTheme.badgeAccentTransparency or DEFAULT_THEME.timeline.badgeAccentTransparency
    end

    if self._timelineBadgeStroke then
        local mix = timelineTheme.badgeStrokeMix or 0.18
        local strokeBase = timelineTheme.badgeStrokeColor or theme.cardStrokeColor or badgeColor
        self._timelineBadgeStroke.Color = badgeColor:Lerp(strokeBase, mix)
        self._timelineBadgeStroke.Transparency = timelineTheme.badgeStrokeTransparency or DEFAULT_THEME.timeline.badgeStrokeTransparency
    end

    if self._timelineStatusLabel then
        local baseStatusColor = timelineTheme.subtitleColor or self._timelineStatusLabel.TextColor3
        local tintMix = timelineTheme.subtitleTintMix or 0.22
        self._timelineStatusLabel.Text = statusText
        if typeof(baseStatusColor) == "Color3" then
            self._timelineStatusLabel.TextColor3 = baseStatusColor:Lerp(badgeColor, tintMix)
        else
            self._timelineStatusLabel.TextColor3 = badgeColor
        end
        self._timelineStatusLabel.Font = timelineTheme.subtitleFont or DEFAULT_THEME.timeline.subtitleFont
        self._timelineStatusLabel.TextSize = timelineTheme.subtitleTextSize or DEFAULT_THEME.timeline.subtitleTextSize
    end
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

    self:_updateTimelineBadge()
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
-- loader.lua (sha1: c36665c135075f84774e87d86018299db5172ba1)
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
-- tests/perf/config.lua (sha1: f597fabeb13cfe072d0748b9fa004a3a31be6067)
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
-- tests/fixtures/ui_snapshot.json (sha1: 5e0eec5321e9dc15c667ae7f755a4c59040ecc01)
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
