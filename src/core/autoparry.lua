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
        Context.runtime.transientRetryCooldown = 0
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
