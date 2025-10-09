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

local DEFAULT_SMART_TUNING = {
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

local DEFAULT_AUTO_TUNING = {
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

local DEFAULT_CONFIG = {
    cooldown = 0.1,
    minSpeed = 10,
    pingOffset = 0.05,
    minTTI = 0.12,
    maxTTI = 0.55,
    -- public API configuration that remains relevant for the PERFECT-PARRY rule
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
    targetHighlightName = "Highlight",
    ballsFolderName = "Balls",
    playerTimeout = 10,
    remotesTimeout = 10,
    ballsFolderTimeout = 5,
    verificationRetryInterval = 0,
    remoteQueueGuards = { "SyncDragonSpirit", "SecondaryEndCD" },
    oscillationFrequency = 3,
    oscillationDistanceDelta = 0.35,
    smartTuning = DEFAULT_SMART_TUNING,
    autoTuning = DEFAULT_AUTO_TUNING,
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
local TARGETING_GRACE_SECONDS = 0.2
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
local targetingGraceUntil = 0

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
local publishReadyStatus
local scheduledPressState = {
    ballId = nil :: string?,
    pressAt = 0,
    predictedImpact = math.huge,
    lead = 0,
    slack = 0,
    reason = nil :: string?,
    lastUpdate = 0,
    immediate = false,
    lastSnapshot = nil,
}
local SMART_PRESS_TRIGGER_GRACE = 0.01
local SMART_PRESS_STALE_SECONDS = 0.75
local setStage
local updateStatusLabel
local virtualInputWarningIssued = false
local virtualInputUnavailable = false
local virtualInputRetryAt = 0

local TELEMETRY_HISTORY_LIMIT = 200
local telemetryHistory: { { [string]: any } } = {}
local telemetrySequence = 0

local function isFiniteNumber(value: number?)
    return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function newAggregate()
    return { count = 0, sum = 0, sumSquares = 0, min = nil, max = nil }
end

local function updateAggregate(target, value)
    if not target or not isFiniteNumber(value) then
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

local function summariseAggregate(source)
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

local function newQuantileEstimator(targetQuantile, maxSamples)
    local quantile = targetQuantile
    if not isFiniteNumber(quantile) then
        quantile = 0.5
    end
    quantile = math.clamp(quantile, 0, 1)

    local capacity = maxSamples
    if not isFiniteNumber(capacity) or capacity < 3 then
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

local function quantileBinaryInsert(samples, value)
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

local function quantileRemoveValue(samples, value)
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

local function updateQuantileEstimator(estimator, value)
    if typeof(estimator) ~= "table" or not isFiniteNumber(value) then
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

    quantileBinaryInsert(samples, value)
    queue[#queue + 1] = value

    local capacity = estimator.maxSamples
    if not isFiniteNumber(capacity) or capacity < 3 then
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
            quantileRemoveValue(samples, oldest)
        end
    end
end

local function summariseQuantileEstimator(estimator)
    if typeof(estimator) ~= "table" then
        return { count = 0 }
    end

    local samples = estimator.samples
    if typeof(samples) ~= "table" or #samples == 0 then
        return { count = 0 }
    end

    local count = #samples
    local quantile = estimator.quantile
    if not isFiniteNumber(quantile) then
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

local function getQuantileValue(estimator)
    local summary = summariseQuantileEstimator(estimator)
    if typeof(summary) ~= "table" then
        return nil
    end

    return summary.value
end

local function cloneCounts(source)
    local result = {}
    if typeof(source) ~= "table" then
        return result
    end

    for key, value in pairs(source) do
        result[key] = value
    end

    return result
end

local function incrementCount(container, key, delta)
    if typeof(container) ~= "table" then
        return
    end

    local current = container[key]
    if typeof(current) ~= "number" then
        current = 0
    end

    container[key] = current + (delta or 1)
end

local function emaScalar(previous: number?, sample: number, alpha: number)
    if previous == nil then
        return sample
    end
    return previous + (sample - previous) * alpha
end

local function emaVector(previous: Vector3?, sample: Vector3, alpha: number)
    if previous == nil then
        return sample
    end
    return previous + (sample - previous) * alpha
end

local TelemetryAnalytics = {}

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

local function clampAdaptive(value)
    if not isFiniteNumber(value) then
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

local function clampNumber(value, minValue, maxValue)
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

local function incrementCounter(name, delta)
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
            resets = resetCount or 0,
        },
        schedule = {
            lead = newAggregate(),
            slack = newAggregate(),
            eta = newAggregate(),
            predictedImpact = newAggregate(),
            adaptiveBias = newAggregate(),
            reasons = {},
            smartLead = newAggregate(),
            smartReaction = newAggregate(),
            smartSlack = newAggregate(),
            smartConfidence = newAggregate(),
        },
        press = {
            waitDelta = newAggregate(),
            actualWait = newAggregate(),
            activationLatency = newAggregate(),
            adaptiveBias = newAggregate(),
            reactionTime = newAggregate(),
            decisionTime = newAggregate(),
            decisionToPressTime = newAggregate(),
            immediateCount = 0,
            forcedCount = 0,
            scheduledCount = 0,
            unscheduledCount = 0,
            scheduledReasons = {},
            smartLatency = newAggregate(),
            smartReaction = newAggregate(),
            smartSlack = newAggregate(),
            smartConfidence = newAggregate(),
        },
        latency = {
            accepted = newAggregate(),
            localAccepted = newAggregate(),
            remoteAccepted = newAggregate(),
            activation = newAggregate(),
        },
        success = {
            latency = newAggregate(),
            acceptedCount = 0,
        },
        cancellations = {
            total = 0,
            stale = 0,
            reasonCounts = {},
        },
        timeline = {
            scheduleLifetime = newAggregate(),
            achievedLead = newAggregate(),
            leadDelta = newAggregate(),
        },
        quantiles = {
            commitLatency = newQuantileEstimator(0.99, 512),
            scheduleLookahead = newQuantileEstimator(DEFAULT_SMART_TUNING.lookaheadQuantile or 0.1, 512),
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
            adaptiveState = {
                reactionBias = TelemetryAnalytics.adaptiveState and TelemetryAnalytics.adaptiveState.reactionBias or 0,
                lastUpdate = TelemetryAnalytics.adaptiveState and TelemetryAnalytics.adaptiveState.lastUpdate or 0,
            },
        }
    end

    local counters = cloneCounts(metrics.counters)

    local result = {
        counters = counters,
        schedule = {
            lead = summariseAggregate(metrics.schedule.lead),
            slack = summariseAggregate(metrics.schedule.slack),
            eta = summariseAggregate(metrics.schedule.eta),
            predictedImpact = summariseAggregate(metrics.schedule.predictedImpact),
            adaptiveBias = summariseAggregate(metrics.schedule.adaptiveBias),
            reasons = cloneCounts(metrics.schedule.reasons),
            smart = {
                lead = summariseAggregate(metrics.schedule.smartLead),
                reactionBias = summariseAggregate(metrics.schedule.smartReaction),
                scheduleSlack = summariseAggregate(metrics.schedule.smartSlack),
                confidencePadding = summariseAggregate(metrics.schedule.smartConfidence),
            },
        },
        press = {
            waitDelta = summariseAggregate(metrics.press.waitDelta),
            actualWait = summariseAggregate(metrics.press.actualWait),
            activationLatency = summariseAggregate(metrics.press.activationLatency),
            adaptiveBias = summariseAggregate(metrics.press.adaptiveBias),
            reactionTime = summariseAggregate(metrics.press.reactionTime),
            decisionTime = summariseAggregate(metrics.press.decisionTime),
            decisionToPressTime = summariseAggregate(metrics.press.decisionToPressTime),
            immediateCount = metrics.press.immediateCount,
            forcedCount = metrics.press.forcedCount,
            scheduledCount = metrics.press.scheduledCount,
            unscheduledCount = metrics.press.unscheduledCount,
            scheduledReasons = cloneCounts(metrics.press.scheduledReasons),
            smart = {
                latency = summariseAggregate(metrics.press.smartLatency),
                reactionBias = summariseAggregate(metrics.press.smartReaction),
                scheduleSlack = summariseAggregate(metrics.press.smartSlack),
                confidencePadding = summariseAggregate(metrics.press.smartConfidence),
            },
        },
        latency = {
            accepted = summariseAggregate(metrics.latency.accepted),
            localAccepted = summariseAggregate(metrics.latency.localAccepted),
            remoteAccepted = summariseAggregate(metrics.latency.remoteAccepted),
            activation = summariseAggregate(metrics.latency.activation),
            counters = {
                accepted = counters.latencyAccepted or 0,
                rejected = counters.latencyRejected or 0,
                localSamples = counters.latencyLocal or 0,
                remoteSamples = counters.latencyRemote or 0,
            },
        },
        success = {
            latency = summariseAggregate(metrics.success.latency),
            acceptedCount = metrics.success.acceptedCount,
        },
        cancellations = {
            total = metrics.cancellations.total,
            stale = metrics.cancellations.stale,
            reasonCounts = cloneCounts(metrics.cancellations.reasonCounts),
        },
        timeline = {
            scheduleLifetime = summariseAggregate(metrics.timeline.scheduleLifetime),
            achievedLead = summariseAggregate(metrics.timeline.achievedLead),
            leadDelta = summariseAggregate(metrics.timeline.leadDelta),
        },
        quantiles = {
            commitLatency = summariseQuantileEstimator(metrics.quantiles and metrics.quantiles.commitLatency),
            scheduleLookahead = summariseQuantileEstimator(metrics.quantiles and metrics.quantiles.scheduleLookahead),
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
    elseif isFiniteNumber(leadDelta) then
        desired = clampAdaptive(-leadDelta)
    end

    adaptive.reactionBias = emaScalar(adaptive.reactionBias, desired, TELEMETRY_ADAPTIVE_ALPHA)
    adaptive.lastUpdate = os.clock()
end

function TelemetryAnalytics.recordSchedule(event)
    local metrics = TelemetryAnalytics.metrics
    if typeof(event) ~= "table" or typeof(metrics) ~= "table" then
        return
    end

    incrementCounter("schedule", 1)

    updateAggregate(metrics.schedule.lead, event.lead)
    updateAggregate(metrics.schedule.slack, event.slack)
    updateAggregate(metrics.schedule.eta, event.eta)
    updateAggregate(metrics.schedule.predictedImpact, event.predictedImpact)
    updateAggregate(metrics.schedule.adaptiveBias, event.adaptiveBias)

    if metrics.quantiles then
        updateQuantileEstimator(metrics.quantiles.scheduleLookahead, event.eta)
    end

    if event.reason then
        incrementCount(metrics.schedule.reasons, event.reason, 1)
    end

    if isFiniteNumber(event.activationLatency) then
        updateAggregate(metrics.latency.activation, event.activationLatency)
    end

    if typeof(event.smartTuning) == "table" then
        if isFiniteNumber(event.smartTuning.scheduleLead) then
            updateAggregate(metrics.schedule.smartLead, event.smartTuning.scheduleLead)
        end

        local applied = event.smartTuning.applied
        if typeof(applied) == "table" then
            updateAggregate(metrics.schedule.smartReaction, applied.reactionBias)
            updateAggregate(metrics.schedule.smartSlack, applied.scheduleSlack)
            updateAggregate(metrics.schedule.smartConfidence, applied.confidencePadding)
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
    incrementCounter("scheduleCleared", 1)
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
            if isFiniteNumber(eventTime) and isFiniteNumber(entry.time) then
                updateAggregate(metrics.timeline.scheduleLifetime, eventTime - entry.time)
            elseif isFiniteNumber(event.timeSinceUpdate) then
                updateAggregate(metrics.timeline.scheduleLifetime, event.timeSinceUpdate)
            end
            inFlight[ballId] = nil
        elseif isFiniteNumber(event.timeSinceUpdate) then
            updateAggregate(metrics.timeline.scheduleLifetime, event.timeSinceUpdate)
        end
    elseif isFiniteNumber(event.timeSinceUpdate) then
        updateAggregate(metrics.timeline.scheduleLifetime, event.timeSinceUpdate)
    end

    if event.reason ~= "pressed" then
        metrics.cancellations.total += 1
        incrementCount(metrics.cancellations.reasonCounts, event.reason or "unknown", 1)

        if isFiniteNumber(event.timeSinceUpdate) and event.timeSinceUpdate >= SMART_PRESS_STALE_SECONDS then
            metrics.cancellations.stale += 1
        end
    end
end

function TelemetryAnalytics.formatLatencyText(seconds: number?, pending: boolean?)
    if not isFiniteNumber(seconds) then
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
    elseif isFiniteNumber(telemetry.lastReactionLatency) then
        reactionLatency = telemetry.lastReactionLatency
    end

    local decisionLatency
    local decisionPending = false
    if telemetry.targetDetectedAt and telemetry.decisionAt then
        decisionLatency = math.max(telemetry.decisionAt - telemetry.targetDetectedAt, 0)
        decisionPending = telemetry.lastDecisionLatency == nil
    elseif isFiniteNumber(telemetry.lastDecisionLatency) then
        decisionLatency = telemetry.lastDecisionLatency
    end

    local commitLatency
    local commitPending = false
    if telemetry.decisionAt then
        commitLatency = math.max(now - telemetry.decisionAt, 0)
        commitPending = telemetry.lastDecisionToPressLatency == nil
    elseif isFiniteNumber(telemetry.lastDecisionToPressLatency) then
        commitLatency = telemetry.lastDecisionToPressLatency
    end

    return TelemetryAnalytics.formatLatencyText(reactionLatency, reactionPending),
        TelemetryAnalytics.formatLatencyText(decisionLatency, decisionPending),
        TelemetryAnalytics.formatLatencyText(commitLatency, commitPending)
end

function TelemetryAnalytics.applyPressLatencyTelemetry(telemetry: TelemetryState?, pressEvent, now: number)
    if not telemetry then
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
    incrementCounter("latency", 1)
    local metrics = TelemetryAnalytics.metrics
    if typeof(event) ~= "table" or typeof(metrics) ~= "table" then
        return
    end

    if event.source == "remote" then
        incrementCounter("latencyRemote", 1)
    elseif event.source == "local" then
        incrementCounter("latencyLocal", 1)
    end

    if event.accepted then
        incrementCounter("latencyAccepted", 1)
        updateAggregate(metrics.latency.accepted, event.value)

        if event.source == "remote" then
            updateAggregate(metrics.latency.remoteAccepted, event.value)
        elseif event.source == "local" then
            updateAggregate(metrics.latency.localAccepted, event.value)
        end
    else
        incrementCounter("latencyRejected", 1)
    end

    if isFiniteNumber(event.activationLatency) then
        updateAggregate(metrics.latency.activation, event.activationLatency)
    end
end

function TelemetryAnalytics.recordSuccess(event)
    incrementCounter("success", 1)
    local metrics = TelemetryAnalytics.metrics
    if typeof(event) ~= "table" or typeof(metrics) ~= "table" then
        return
    end

    if event.accepted and isFiniteNumber(event.latency) then
        metrics.success.acceptedCount += 1
        updateAggregate(metrics.success.latency, event.latency)
    end
end

function TelemetryAnalytics.recordPress(event, scheduledSnapshot)
    incrementCounter("press", 1)
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
            incrementCount(metrics.press.scheduledReasons, scheduledSnapshot.reason, 1)
            if scheduledSnapshot.reason == "immediate-press" then
                isImmediate = true
            end
        end

        local eventTime = event.time or os.clock()
        local scheduleTime = scheduledSnapshot.scheduleTime
        if not isFiniteNumber(scheduleTime) then
            scheduleTime = eventTime
        end

        local pressAt = scheduledSnapshot.pressAt
        if not isFiniteNumber(pressAt) then
            pressAt = scheduleTime
        end

        local actualWait = nil
        if isFiniteNumber(eventTime) and isFiniteNumber(scheduleTime) then
            actualWait = eventTime - scheduleTime
            updateAggregate(metrics.press.actualWait, actualWait)
            updateAggregate(metrics.timeline.scheduleLifetime, actualWait)
        end

        local expectedWait = 0
        if isFiniteNumber(pressAt) and isFiniteNumber(scheduleTime) then
            expectedWait = math.max(pressAt - scheduleTime, 0)
        end

        if actualWait ~= nil then
            local waitDelta = actualWait - expectedWait
            updateAggregate(metrics.press.waitDelta, waitDelta)
        end

        local predictedImpact = scheduledSnapshot.predictedImpact
        if isFiniteNumber(predictedImpact) and actualWait ~= nil then
            local achievedLead = predictedImpact - actualWait
            updateAggregate(metrics.timeline.achievedLead, achievedLead)
            leadDelta = achievedLead - (scheduledSnapshot.lead or 0)
            updateAggregate(metrics.timeline.leadDelta, leadDelta)
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

    if isFiniteNumber(event.activationLatency) then
        updateAggregate(metrics.press.activationLatency, event.activationLatency)
        updateAggregate(metrics.latency.activation, event.activationLatency)
    end

    if isFiniteNumber(event.adaptiveBias) then
        updateAggregate(metrics.press.adaptiveBias, event.adaptiveBias)
    end

    if isFiniteNumber(event.reactionTime) then
        updateAggregate(metrics.press.reactionTime, event.reactionTime)
    end

    if isFiniteNumber(event.decisionTime) then
        updateAggregate(metrics.press.decisionTime, event.decisionTime)
    end

    if isFiniteNumber(event.decisionToPressTime) then
        updateAggregate(metrics.press.decisionToPressTime, event.decisionToPressTime)
    end

    if metrics.quantiles and isFiniteNumber(event.decisionToPressTime) then
        updateQuantileEstimator(metrics.quantiles.commitLatency, event.decisionToPressTime)
    end

    if typeof(event.smartTuning) == "table" then
        if isFiniteNumber(event.smartTuning.latency) then
            updateAggregate(metrics.press.smartLatency, event.smartTuning.latency)
        end

        local applied = event.smartTuning.applied
        if typeof(applied) == "table" then
            updateAggregate(metrics.press.smartReaction, applied.reactionBias)
            updateAggregate(metrics.press.smartSlack, applied.scheduleSlack)
            updateAggregate(metrics.press.smartConfidence, applied.confidencePadding)
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
    summary.immediateCount = stats.press and stats.press.immediateCount or 0
    if summary.pressCount > 0 then
        summary.immediateRate = summary.immediateCount / summary.pressCount
    else
        summary.immediateRate = 0
    end
    summary.averageWaitDelta = TelemetryAnalytics.aggregateMean(stats.press and stats.press.waitDelta)
    summary.averageActivationLatency = TelemetryAnalytics.aggregateMean(stats.latency and stats.latency.activation)
    summary.averageLatency = TelemetryAnalytics.aggregateMean(stats.latency and stats.latency.accepted)
    summary.averageReactionTime = TelemetryAnalytics.aggregateMean(stats.press and stats.press.reactionTime)
    summary.averageDecisionTime = TelemetryAnalytics.aggregateMean(stats.press and stats.press.decisionTime)
    summary.averageDecisionToPressTime =
        TelemetryAnalytics.aggregateMean(stats.press and stats.press.decisionToPressTime)
    summary.leadDeltaMean = TelemetryAnalytics.aggregateMean(stats.timeline and stats.timeline.leadDelta)
    summary.achievedLeadMean = TelemetryAnalytics.aggregateMean(stats.timeline and stats.timeline.achievedLead)
    summary.scheduleLifetimeMean = TelemetryAnalytics.aggregateMean(stats.timeline and stats.timeline.scheduleLifetime)
    summary.adaptiveBias = stats.adaptiveState and stats.adaptiveState.reactionBias or 0
    summary.cancellationCount = stats.cancellations and stats.cancellations.total or 0
    summary.topCancellationReason, summary.topCancellationCount = TelemetryAnalytics.selectTopReason(stats.cancellations and stats.cancellations.reasonCounts)

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
    local commitTarget = DEFAULT_SMART_TUNING.commitP99Target or 0.01
    if isFiniteNumber(commitP99) and commitP99 > commitTarget then
        table.insert(
            recommendations,
            string.format(
                "Commit latency P99 is %.1f ms (target %.0f ms); tighten pressScheduleSlack or increase reaction bias.",
                commitP99 * 1000,
                commitTarget * 1000
            )
        )
    end

    local lookaheadGoal = DEFAULT_SMART_TUNING.lookaheadGoal or DEFAULT_CONFIG.pressLookaheadGoal or 0
    local lookaheadP10 = summary.scheduleLookaheadP10
    if isFiniteNumber(lookaheadGoal) and lookaheadGoal > 0 and isFiniteNumber(lookaheadP10) and lookaheadP10 < lookaheadGoal then
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

    local minSamples = options.minSamples or TELEMETRY_ADJUSTMENT_MIN_SAMPLES
    local leadTolerance = options.leadTolerance or TELEMETRY_ADJUSTMENT_LEAD_TOLERANCE
    local waitTolerance = options.waitTolerance or TELEMETRY_ADJUSTMENT_WAIT_TOLERANCE

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
    if pressCount >= minSamples and isFiniteNumber(leadDelta) then
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
    if pressCount >= minSamples and isFiniteNumber(waitDelta) then
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
    if isFiniteNumber(averageLatency) and averageLatency > 0 then
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

    local commitTarget = options.commitTarget or DEFAULT_SMART_TUNING.commitP99Target or 0.01
    local commitSamples = summary.commitLatencySampleCount or 0
    local commitP99 = summary.commitLatencyP99
    if commitSamples > 0 and isFiniteNumber(commitP99) and commitTarget > 0 then
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

    local lookaheadGoal = options.lookaheadGoal or DEFAULT_SMART_TUNING.lookaheadGoal or DEFAULT_CONFIG.pressLookaheadGoal or 0
    local lookaheadSamples = summary.scheduleLookaheadSampleCount or 0
    local lookaheadP10 = summary.scheduleLookaheadP10
    if lookaheadSamples > 0 and isFiniteNumber(lookaheadGoal) and lookaheadGoal > 0 and isFiniteNumber(lookaheadP10) then
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
    intervalSeconds = DEFAULT_AUTO_TUNING.intervalSeconds,
    minSamples = DEFAULT_AUTO_TUNING.minSamples,
    allowWhenSmartTuning = DEFAULT_AUTO_TUNING.allowWhenSmartTuning,
    dryRun = DEFAULT_AUTO_TUNING.dryRun,
    leadGain = DEFAULT_AUTO_TUNING.leadGain,
    slackGain = DEFAULT_AUTO_TUNING.slackGain,
    latencyGain = DEFAULT_AUTO_TUNING.latencyGain,
    leadTolerance = DEFAULT_AUTO_TUNING.leadTolerance,
    waitTolerance = DEFAULT_AUTO_TUNING.waitTolerance,
    maxReactionBias = DEFAULT_AUTO_TUNING.maxReactionBias,
    maxScheduleSlack = DEFAULT_AUTO_TUNING.maxScheduleSlack,
    maxActivationLatency = DEFAULT_AUTO_TUNING.maxActivationLatency,
    minDelta = DEFAULT_AUTO_TUNING.minDelta,
    maxAdjustmentsPerRun = DEFAULT_AUTO_TUNING.maxAdjustmentsPerRun,
    lastRun = 0,
    lastStatus = nil :: string?,
    lastAdjustments = nil :: { [string]: any }?,
    lastResult = nil :: { [string]: any }?,
    lastError = nil :: string?,
    lastSummary = nil :: { [string]: any }?,
}

local function normalizeAutoTuningConfig(value)
    if value == false then
        return false
    end

    local base = Util.deepCopy(DEFAULT_AUTO_TUNING)

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
        if not isFiniteNumber(base.intervalSeconds) or base.intervalSeconds < 0 then
            base.intervalSeconds = DEFAULT_AUTO_TUNING.intervalSeconds
        end
    end
    if base.minSamples ~= nil then
        if not isFiniteNumber(base.minSamples) or base.minSamples < 1 then
            base.minSamples = DEFAULT_AUTO_TUNING.minSamples
        end
    end
    if base.minDelta ~= nil and (not isFiniteNumber(base.minDelta) or base.minDelta < 0) then
        base.minDelta = DEFAULT_AUTO_TUNING.minDelta
    end
    if base.maxAdjustmentsPerRun ~= nil then
        if not isFiniteNumber(base.maxAdjustmentsPerRun) or base.maxAdjustmentsPerRun < 0 then
            base.maxAdjustmentsPerRun = DEFAULT_AUTO_TUNING.maxAdjustmentsPerRun
        end
    end

    base.enabled = base.enabled ~= false
    base.allowWhenSmartTuning = base.allowWhenSmartTuning == true
    base.dryRun = base.dryRun == true

    return base
end

local function syncAutoTuningState()
    local normalized = normalizeAutoTuningConfig(config.autoTuning)
    config.autoTuning = normalized

    if normalized == false then
        autoTuningState.enabled = false
        autoTuningState.intervalSeconds = DEFAULT_AUTO_TUNING.intervalSeconds
        autoTuningState.minSamples = DEFAULT_AUTO_TUNING.minSamples
        autoTuningState.allowWhenSmartTuning = DEFAULT_AUTO_TUNING.allowWhenSmartTuning
        autoTuningState.dryRun = DEFAULT_AUTO_TUNING.dryRun
        autoTuningState.leadGain = DEFAULT_AUTO_TUNING.leadGain
        autoTuningState.slackGain = DEFAULT_AUTO_TUNING.slackGain
        autoTuningState.latencyGain = DEFAULT_AUTO_TUNING.latencyGain
        autoTuningState.leadTolerance = DEFAULT_AUTO_TUNING.leadTolerance
        autoTuningState.waitTolerance = DEFAULT_AUTO_TUNING.waitTolerance
        autoTuningState.maxReactionBias = DEFAULT_AUTO_TUNING.maxReactionBias
        autoTuningState.maxScheduleSlack = DEFAULT_AUTO_TUNING.maxScheduleSlack
        autoTuningState.maxActivationLatency = DEFAULT_AUTO_TUNING.maxActivationLatency
        autoTuningState.minDelta = DEFAULT_AUTO_TUNING.minDelta
        autoTuningState.maxAdjustmentsPerRun = DEFAULT_AUTO_TUNING.maxAdjustmentsPerRun
        return
    end

    local spec = normalized or DEFAULT_AUTO_TUNING
    autoTuningState.enabled = spec.enabled ~= false
    autoTuningState.intervalSeconds = spec.intervalSeconds or DEFAULT_AUTO_TUNING.intervalSeconds
    if not isFiniteNumber(autoTuningState.intervalSeconds) or autoTuningState.intervalSeconds < 0 then
        autoTuningState.intervalSeconds = DEFAULT_AUTO_TUNING.intervalSeconds
    end
    autoTuningState.minSamples = spec.minSamples or DEFAULT_AUTO_TUNING.minSamples
    if not isFiniteNumber(autoTuningState.minSamples) or autoTuningState.minSamples < 1 then
        autoTuningState.minSamples = DEFAULT_AUTO_TUNING.minSamples
    end
    autoTuningState.minSamples = math.floor(autoTuningState.minSamples + 0.5)
    if autoTuningState.minSamples < 1 then
        autoTuningState.minSamples = 1
    end
    autoTuningState.allowWhenSmartTuning = spec.allowWhenSmartTuning == true
    autoTuningState.dryRun = spec.dryRun == true
    autoTuningState.leadGain = spec.leadGain or DEFAULT_AUTO_TUNING.leadGain
    autoTuningState.slackGain = spec.slackGain or DEFAULT_AUTO_TUNING.slackGain
    autoTuningState.latencyGain = spec.latencyGain or DEFAULT_AUTO_TUNING.latencyGain
    autoTuningState.leadTolerance = spec.leadTolerance or DEFAULT_AUTO_TUNING.leadTolerance
    autoTuningState.waitTolerance = spec.waitTolerance or DEFAULT_AUTO_TUNING.waitTolerance
    autoTuningState.maxReactionBias = spec.maxReactionBias or DEFAULT_AUTO_TUNING.maxReactionBias
    autoTuningState.maxScheduleSlack = spec.maxScheduleSlack or DEFAULT_AUTO_TUNING.maxScheduleSlack
    autoTuningState.maxActivationLatency = spec.maxActivationLatency or DEFAULT_AUTO_TUNING.maxActivationLatency
    autoTuningState.minDelta = spec.minDelta or DEFAULT_AUTO_TUNING.minDelta
    if autoTuningState.minDelta < 0 then
        autoTuningState.minDelta = 0
    end
    autoTuningState.maxAdjustmentsPerRun = spec.maxAdjustmentsPerRun or DEFAULT_AUTO_TUNING.maxAdjustmentsPerRun
    if autoTuningState.maxAdjustmentsPerRun < 0 then
        autoTuningState.maxAdjustmentsPerRun = 0
    end
end

function TelemetryAnalytics.computeAdjustments(stats, summary, configSnapshot, options)
    options = options or {}
    stats = stats or TelemetryAnalytics.clone()
    summary = summary or TelemetryAnalytics.computeSummary(stats)
    configSnapshot = configSnapshot or {}

    local adjustments = {
        updates = {},
        deltas = {},
        reasons = {},
        stats = stats,
        summary = summary,
        minSamples = options.minSamples or TELEMETRY_ADJUSTMENT_MIN_SAMPLES,
    }

    local pressCount = summary.pressCount or 0
    if pressCount < adjustments.minSamples then
        adjustments.status = "insufficient"
        table.insert(
            adjustments.reasons,
            string.format(
                "Need at least %d presses (observed %d) before telemetry-based tuning can stabilise.",
                adjustments.minSamples,
                pressCount
            )
        )
        return adjustments
    end

    if smartTuningState and smartTuningState.enabled and not options.allowWhenSmartTuning then
        adjustments.status = "skipped"
        table.insert(adjustments.reasons, "Smart tuning is enabled; skipping direct telemetry adjustments.")
        return adjustments
    end

    local function resolveConfig(key, fallback)
        local value = configSnapshot[key]
        if value == nil then
            value = fallback
        end
        if not isFiniteNumber(value) then
            value = fallback
        end
        return value
    end

    local updates = adjustments.updates
    local deltas = adjustments.deltas

    local currentReaction = resolveConfig("pressReactionBias", DEFAULT_CONFIG.pressReactionBias or 0)
    currentReaction = math.max(currentReaction, 0)
    local leadDelta = summary.leadDeltaMean
    if isFiniteNumber(leadDelta) and math.abs(leadDelta) > (options.leadTolerance or TELEMETRY_ADJUSTMENT_LEAD_TOLERANCE) then
        local gain = options.leadGain or TELEMETRY_ADJUSTMENT_LEAD_GAIN
        local change = clampNumber(-leadDelta * gain, -0.05, 0.05)
        if change and math.abs(change) >= 1e-4 then
            local maxReaction = options.maxReactionBias or math.max(TELEMETRY_ADJUSTMENT_MAX_REACTION, DEFAULT_CONFIG.pressReactionBias or 0)
            maxReaction = math.max(maxReaction, currentReaction)
            local newReaction = clampNumber(currentReaction + change, 0, maxReaction)
            if newReaction and math.abs(newReaction - currentReaction) >= 1e-4 then
                updates.pressReactionBias = newReaction
                deltas.pressReactionBias = newReaction - currentReaction
                table.insert(
                    adjustments.reasons,
                    string.format(
                        "Adjusted reaction bias by %.1f ms to offset the %.1f ms average lead delta.",
                        (deltas.pressReactionBias or 0) * 1000,
                        leadDelta * 1000
                    )
                )
            end
        end
    end

    if updates.pressReactionBias ~= nil then
        currentReaction = updates.pressReactionBias
    end

    local currentSlack = resolveConfig("pressScheduleSlack", DEFAULT_CONFIG.pressScheduleSlack or 0)
    currentSlack = math.max(currentSlack, 0)
    local waitDelta = summary.averageWaitDelta
    if isFiniteNumber(waitDelta) and math.abs(waitDelta) > (options.waitTolerance or TELEMETRY_ADJUSTMENT_WAIT_TOLERANCE) then
        local gain = options.slackGain or TELEMETRY_ADJUSTMENT_SLACK_GAIN
        local change = clampNumber(waitDelta * gain, -0.03, 0.03)
        if change and math.abs(change) >= 1e-4 then
            local maxSlack = options.maxScheduleSlack or math.max(TELEMETRY_ADJUSTMENT_MAX_SLACK, DEFAULT_CONFIG.pressScheduleSlack or 0)
            maxSlack = math.max(maxSlack, currentSlack)
            local newSlack = clampNumber(currentSlack + change, 0, maxSlack)
            if newSlack and math.abs(newSlack - currentSlack) >= 1e-4 then
                updates.pressScheduleSlack = newSlack
                deltas.pressScheduleSlack = newSlack - currentSlack
                table.insert(
                    adjustments.reasons,
                    string.format(
                        "Adjusted schedule slack by %.1f ms based on the %.1f ms average wait delta.",
                        (deltas.pressScheduleSlack or 0) * 1000,
                        waitDelta * 1000
                    )
                )
            end
        end
    end

    if updates.pressScheduleSlack ~= nil then
        currentSlack = updates.pressScheduleSlack
    end

    local commitTarget = options.commitTarget
    if not isFiniteNumber(commitTarget) or commitTarget <= 0 then
        commitTarget = DEFAULT_SMART_TUNING.commitP99Target or 0.01
    end
    local commitMinSamples = options.commitMinSamples or 6
    local commitSamples = summary.commitLatencySampleCount or 0
    local commitP99 = summary.commitLatencyP99
    if commitSamples >= commitMinSamples and isFiniteNumber(commitP99) and commitTarget > 0 then
        local overshoot = commitP99 - commitTarget
        if overshoot > 0 then
            local reactionGain = options.commitReactionGain or DEFAULT_SMART_TUNING.commitReactionGain or 0
            if reactionGain > 0 then
                local maxReaction = options.maxReactionBias or math.max(TELEMETRY_ADJUSTMENT_MAX_REACTION, DEFAULT_CONFIG.pressReactionBias or 0)
                maxReaction = math.max(maxReaction, currentReaction)
                local boost = clampNumber(overshoot * reactionGain, 0, maxReaction - currentReaction)
                if boost and boost >= 1e-4 then
                    local newReaction = clampNumber(currentReaction + boost, 0, maxReaction)
                    if newReaction and math.abs(newReaction - currentReaction) >= 1e-4 then
                        updates.pressReactionBias = newReaction
                        deltas.pressReactionBias = newReaction - currentReaction
                        currentReaction = newReaction
                        table.insert(
                            adjustments.reasons,
                            string.format(
                                "Raised reaction bias by %.1f ms to chase the %.0f ms commit target (P99=%.1f ms).",
                                (deltas.pressReactionBias or 0) * 1000,
                                commitTarget * 1000,
                                commitP99 * 1000
                            )
                        )
                    end
                end
            end

            local slackGain = options.commitSlackGain or DEFAULT_SMART_TUNING.commitSlackGain or 0
            if slackGain > 0 then
                local maxSlack = options.maxScheduleSlack or math.max(TELEMETRY_ADJUSTMENT_MAX_SLACK, DEFAULT_CONFIG.pressScheduleSlack or 0)
                maxSlack = math.max(maxSlack, currentSlack)
                local minSlack = options.minScheduleSlack or 0
                local newSlack = clampNumber(currentSlack - overshoot * slackGain, minSlack, maxSlack)
                if newSlack and math.abs(newSlack - currentSlack) >= 1e-4 then
                    updates.pressScheduleSlack = newSlack
                    deltas.pressScheduleSlack = newSlack - currentSlack
                    table.insert(
                        adjustments.reasons,
                        string.format(
                            "Adjusted schedule slack by %.1f ms to curb commit latency overshoot (P99 %.1f ms).",
                            (deltas.pressScheduleSlack or 0) * 1000,
                            commitP99 * 1000
                        )
                    )
                    currentSlack = newSlack
                end
            end
        end
    end

    local lookaheadGoal = options.lookaheadGoal
    if not isFiniteNumber(lookaheadGoal) or lookaheadGoal <= 0 then
        lookaheadGoal = configSnapshot.pressLookaheadGoal or DEFAULT_CONFIG.pressLookaheadGoal or DEFAULT_SMART_TUNING.lookaheadGoal or 0
    end
    local lookaheadMinSamples = options.lookaheadMinSamples or 4
    local lookaheadSamples = summary.scheduleLookaheadSampleCount or 0
    local lookaheadP10 = summary.scheduleLookaheadP10
    if
        lookaheadGoal > 0
        and lookaheadSamples >= lookaheadMinSamples
        and isFiniteNumber(lookaheadP10)
        and lookaheadP10 < lookaheadGoal
    then
        local currentLookahead = resolveConfig("pressMaxLookahead", DEFAULT_CONFIG.pressMaxLookahead or lookaheadGoal)
        currentLookahead = math.max(currentLookahead, lookaheadGoal)
        local gain = options.lookaheadGain or 0.5
        local delta = clampNumber((lookaheadGoal - lookaheadP10) * gain, 0, options.maxPressLookaheadDelta or 0.75)
        if delta and delta >= 1e-4 then
            local maxLookahead = options.maxPressLookahead or math.max(currentLookahead, lookaheadGoal) + 0.6
            local newLookahead = clampNumber(currentLookahead + delta, lookaheadGoal, maxLookahead)
            if newLookahead and newLookahead - currentLookahead >= 1e-4 then
                updates.pressMaxLookahead = newLookahead
                deltas.pressMaxLookahead = newLookahead - currentLookahead
                table.insert(
                    adjustments.reasons,
                    string.format(
                        "Raised pressMaxLookahead by %.0f ms to meet the %.0f ms lookahead goal (P10=%.0f ms).",
                        (deltas.pressMaxLookahead or 0) * 1000,
                        lookaheadGoal * 1000,
                        lookaheadP10 * 1000
                    )
                )
            end
        end
    end

    local currentLatency = resolveConfig("activationLatency", DEFAULT_CONFIG.activationLatency or 0.12)
    currentLatency = math.max(currentLatency, 0)
    local observedLatency = summary.averageActivationLatency
    if isFiniteNumber(observedLatency) and observedLatency > 0 then
        local gain = options.latencyGain or TELEMETRY_ADJUSTMENT_LATENCY_GAIN
        local maxLatency = options.maxActivationLatency or TELEMETRY_ADJUSTMENT_MAX_LATENCY
        maxLatency = math.max(maxLatency, currentLatency)
        local target = clampNumber(observedLatency, 0, maxLatency)
        local blended = clampNumber(currentLatency + (target - currentLatency) * gain, 0, maxLatency)
        if blended and math.abs(blended - currentLatency) >= 1e-4 then
            updates.activationLatency = blended
            deltas.activationLatency = blended - currentLatency
            table.insert(
                adjustments.reasons,
                string.format(
                    "Blended activation latency by %.1f ms toward the %.1f ms observed latency sample.",
                    (deltas.activationLatency or 0) * 1000,
                    observedLatency * 1000
                )
            )
        end
    end

    if next(updates) then
        adjustments.status = "updates"
    else
        adjustments.status = adjustments.status or "stable"
        if #adjustments.reasons == 0 then
            table.insert(adjustments.reasons, "Telemetry averages are within tolerance; no config changes suggested.")
        end
    end

    return adjustments
end

local function ensurePawsSettings()
    local settings = GlobalEnv.Paws
    if typeof(settings) ~= "table" then
        settings = {}
        GlobalEnv.Paws = settings
    end
    return settings
end

local function noteVirtualInputFailure(delay)
    virtualInputUnavailable = true
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

    virtualInputRetryAt = os.clock() + finalDelay

    if state.enabled then
        setStage("waiting-input", { reason = "virtual-input" })
        updateStatusLabel({ "Auto-Parry F", "Status: waiting for input permissions" })
    end
end

local function noteVirtualInputSuccess()
    if virtualInputUnavailable then
        virtualInputUnavailable = false
        virtualInputRetryAt = 0
        local retry = state.virtualInputRetry
        if typeof(retry) == "table" then
            retry.failureCount = 0
        end

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
    targetDetectedAt: number?,
    decisionAt: number?,
    lastReactionLatency: number?,
    lastReactionTimestamp: number?,
    lastDecisionLatency: number?,
    lastDecisionToPressLatency: number?,
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

local MAX_LATENCY_SAMPLE_SECONDS = 2
local PENDING_LATENCY_MAX_AGE = 5

local latencySamples = {
    lastSample = nil,
    lastLocalSample = nil,
    lastRemoteSample = nil,
}

local pendingLatencyPresses = {}

local publishTelemetryHistory
local pushTelemetryEvent

local function publishLatencyTelemetry()
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

local function recordLatencySample(
    sample: number?,
    source: string?,
    ballId: string?,
    telemetry: TelemetryState?,
    now: number?
)
    local timestamp = now or os.clock()
    if not isFiniteNumber(sample) or not sample or sample <= 0 or sample > MAX_LATENCY_SAMPLE_SECONDS then
        local eventPayload = {
            ballId = ballId,
            source = source or "unknown",
            value = sample,
            accepted = false,
            reason = "invalid",
            time = timestamp,
        }
        TelemetryAnalytics.recordLatency(eventPayload)
        pushTelemetryEvent("latency-sample", eventPayload)
        return false
    end

    activationLatencyEstimate = emaScalar(activationLatencyEstimate, sample, ACTIVATION_LATENCY_ALPHA)
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

    publishLatencyTelemetry()
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
    pushTelemetryEvent("latency-sample", eventPayload)
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
            local accepted = recordLatencySample(elapsed, "remote", entry.ballId, telemetry, now)
            local successEvent = {
                ballId = entry.ballId,
                latency = elapsed,
                accepted = accepted,
                source = "remote",
                time = now,
            }
            TelemetryAnalytics.recordSuccess(successEvent)
            pushTelemetryEvent("success", successEvent)
            if accepted then
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
        targetDetectedAt = nil,
        decisionAt = nil,
        lastReactionLatency = nil,
        lastReactionTimestamp = nil,
        lastDecisionLatency = nil,
        lastDecisionToPressLatency = nil,
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

local AutoParry
local updateCharacter
local beginInitialization
local setBallsFolderWatcher
local maybeRunAutoTuning

local function cloneTable(tbl)
    return Util.deepCopy(tbl)
end

local function cloneAutoTuningSnapshot()
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
        lastSummary = autoTuningState.lastSummary and cloneTable(autoTuningState.lastSummary) or nil,
        lastAdjustments = autoTuningState.lastAdjustments and cloneTable(autoTuningState.lastAdjustments) or nil,
        lastResult = autoTuningState.lastResult and cloneTable(autoTuningState.lastResult) or nil,
    }
end

captureScheduledPressSnapshot = function(ballId)
    if not ballId or scheduledPressState.ballId ~= ballId then
        return nil
    end

    local snapshot = {
        ballId = ballId,
        pressAt = scheduledPressState.pressAt,
        predictedImpact = scheduledPressState.predictedImpact,
        lead = scheduledPressState.lead,
        slack = scheduledPressState.slack,
        reason = scheduledPressState.reason,
        scheduleTime = scheduledPressState.lastUpdate,
        immediate = scheduledPressState.immediate,
    }

    if scheduledPressState.smartTuning then
        snapshot.smartTuning = cloneTable(scheduledPressState.smartTuning)
    end

    return snapshot
end

local function resetSmartTuningState()
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

local function snapshotSmartTuningState()
    return cloneTable(smartTuningState)
end

local function normalizeSmartTuningConfig(value)
    if value == false then
        return false
    end

    local base = Util.deepCopy(DEFAULT_SMART_TUNING)

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

local function normalizeSmartTuningPayload(payload)
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

local function getSmartTuningConfig()
    local tuning = config.smartTuning
    if tuning == false then
        return false
    end
    if typeof(tuning) == "table" then
        return tuning
    end
    return DEFAULT_CONFIG.smartTuning
end

local function resolvePerformanceTargets()
    local smartConfig = getSmartTuningConfig()

    local commitTarget = DEFAULT_SMART_TUNING.commitP99Target or 0.01
    if smartConfig and smartConfig ~= false and isFiniteNumber(smartConfig.commitP99Target) then
        commitTarget = smartConfig.commitP99Target
    end
    if not isFiniteNumber(commitTarget) or commitTarget <= 0 then
        commitTarget = 0.01
    end

    local lookaheadGoal = config.pressLookaheadGoal
    if lookaheadGoal == nil then
        lookaheadGoal = DEFAULT_CONFIG.pressLookaheadGoal
    end
    if smartConfig and smartConfig ~= false and isFiniteNumber(smartConfig.lookaheadGoal) then
        lookaheadGoal = smartConfig.lookaheadGoal
    end
    if not isFiniteNumber(lookaheadGoal) then
        lookaheadGoal = DEFAULT_SMART_TUNING.lookaheadGoal or 0
    end
    if not isFiniteNumber(lookaheadGoal) or lookaheadGoal < 0 then
        lookaheadGoal = 0
    end

    return commitTarget, lookaheadGoal
end

local function applySmartTuning(params)
    local tuning = getSmartTuningConfig()
    local now = params.now or os.clock()

    if not tuning or tuning == false or tuning.enabled == false then
        if smartTuningState.enabled then
            resetSmartTuningState()
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
    if not isFiniteNumber(sigma) or sigma < 0 then
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
    if not isFiniteNumber(delta) or delta < 0 then
        delta = 0
    end
    local deltaAlpha = math.clamp(tuning.deltaAlpha or 0.2, 0, 1)
    smartTuningState.delta = emaScalar(smartTuningState.delta, delta, deltaAlpha)

    local ping = params.ping
    if not isFiniteNumber(ping) or ping < 0 then
        ping = 0
    end
    local pingAlpha = math.clamp(tuning.pingAlpha or 0.3, 0, 1)
    smartTuningState.ping = emaScalar(smartTuningState.ping, ping, pingAlpha)

    local overshoot = params.muPlus
    if not isFiniteNumber(overshoot) or overshoot < 0 then
        overshoot = 0
    end
    local overshootAlpha = math.clamp(tuning.overshootAlpha or 0.25, 0, 1)
    smartTuningState.overshoot = emaScalar(smartTuningState.overshoot, overshoot, overshootAlpha)

    local metrics = TelemetryAnalytics.metrics
    local commitSummary
    local lookaheadSummary
    if typeof(metrics) == "table" and typeof(metrics.quantiles) == "table" then
        commitSummary = summariseQuantileEstimator(metrics.quantiles.commitLatency)
        lookaheadSummary = summariseQuantileEstimator(metrics.quantiles.scheduleLookahead)
    end

    local commitP99 = commitSummary and commitSummary.value or nil
    local commitSamples = commitSummary and commitSummary.count or 0
    local lookaheadP10 = lookaheadSummary and lookaheadSummary.value or nil
    local lookaheadSamples = lookaheadSummary and lookaheadSummary.count or 0
    local commitTarget, lookaheadGoal = resolvePerformanceTargets()
    if params and isFiniteNumber(params.lookaheadGoal) and params.lookaheadGoal > 0 then
        lookaheadGoal = params.lookaheadGoal
    end

    local minSlack = math.max(tuning.minSlack or 0, 0)
    local maxSlack = tuning.maxSlack or math.max(minSlack, 0.08)
    if maxSlack < minSlack then
        maxSlack = minSlack
    end
    local slackTarget = math.clamp(sigma * (tuning.sigmaLead or 1), minSlack, maxSlack)

    if commitTarget > 0 and commitSamples >= 6 and isFiniteNumber(commitP99) and commitP99 > commitTarget then
        local overshoot = commitP99 - commitTarget
        local slackGain = math.max(tuning.commitSlackGain or 0, 0)
        if slackGain > 0 then
            slackTarget = math.max(slackTarget - overshoot * slackGain, minSlack)
        end
    end

    if lookaheadGoal > 0 and lookaheadSamples >= 4 and isFiniteNumber(lookaheadP10) and lookaheadP10 < lookaheadGoal then
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
    smartTuningState.scheduleSlack = emaScalar(smartTuningState.scheduleSlack or baseScheduleSlack, slackTarget, slackAlpha)

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
    smartTuningState.confidencePadding = emaScalar(
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

    if commitTarget > 0 and commitSamples >= 6 and isFiniteNumber(commitP99) then
        local overshoot = commitP99 - commitTarget
        local reactionGain = math.max(tuning.commitReactionGain or 0, 0)
        if overshoot > 0 and reactionGain > 0 then
            reactionTarget = math.min(reactionTarget + overshoot * reactionGain, maxReaction)
        elseif overshoot < -commitTarget * 0.4 and reactionGain > 0 then
            local relief = math.min(-overshoot, commitTarget) * reactionGain * 0.5
            reactionTarget = math.max(reactionTarget - relief, minReaction)
        end
    end

    if lookaheadGoal > 0 and lookaheadSamples >= 4 and isFiniteNumber(lookaheadP10) then
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
    smartTuningState.reactionBias = emaScalar(
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

local function ensureTelemetryStore()
    local settings = ensurePawsSettings()
    local telemetryStore = settings.Telemetry
    if typeof(telemetryStore) ~= "table" then
        telemetryStore = {}
        settings.Telemetry = telemetryStore
    end
    return settings, telemetryStore
end

local function cloneTelemetryEvent(event)
    if typeof(event) ~= "table" then
        return event
    end
    return cloneTable(event)
end

publishTelemetryHistory = function()
    local settings, telemetryStore = ensureTelemetryStore()
    telemetryStore.history = telemetryHistory
    telemetryStore.sequence = telemetrySequence
    telemetryStore.lastEvent = telemetryHistory[#telemetryHistory]
    telemetryStore.smartTuning = snapshotSmartTuningState()
    telemetryStore.metrics = TelemetryAnalytics.clone()
    if telemetryStore.metrics then
        telemetryStore.adaptiveState = telemetryStore.metrics.adaptiveState
    else
        telemetryStore.adaptiveState = {
            reactionBias = TelemetryAnalytics.adaptiveState and TelemetryAnalytics.adaptiveState.reactionBias or 0,
            lastUpdate = TelemetryAnalytics.adaptiveState and TelemetryAnalytics.adaptiveState.lastUpdate or 0,
        }
    end
    return settings, telemetryStore
end

pushTelemetryEvent = function(eventType: string, payload: { [string]: any }?)
    telemetrySequence += 1

    local event: { [string]: any } = {}
    if typeof(payload) == "table" then
        event = cloneTelemetryEvent(payload)
    elseif payload ~= nil then
        event.value = payload
    end

    event.type = eventType
    event.sequence = telemetrySequence
    event.time = event.time or os.clock()

    telemetryHistory[#telemetryHistory + 1] = event
    if #telemetryHistory > TELEMETRY_HISTORY_LIMIT then
        table.remove(telemetryHistory, 1)
    end

    publishTelemetryHistory()
    telemetrySignal:fire(cloneTelemetryEvent(event))
    return event
end

local function resetTelemetryHistory(reason: string?)
    local previousResets = 0
    if TelemetryAnalytics.metrics and TelemetryAnalytics.metrics.counters and typeof(TelemetryAnalytics.metrics.counters.resets) == "number" then
        previousResets = TelemetryAnalytics.metrics.counters.resets
    end
    TelemetryAnalytics.resetMetrics(previousResets + 1)
    TelemetryAnalytics.resetAdaptive()
    telemetryHistory = {}
    publishTelemetryHistory()
    if reason then
        pushTelemetryEvent("telemetry-reset", { reason = reason })
    end
end

publishTelemetryHistory()

resetActivationLatency()
resetSmartTuningState()

local function safeCall(fn, ...)
    if typeof(fn) == "function" then
        return fn(...)
    end
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
    settings.SmartPress = {
        reactionBias = config.pressReactionBias,
        scheduleSlack = config.pressScheduleSlack,
        maxLookahead = config.pressMaxLookahead,
        confidencePadding = config.pressConfidencePadding,
    }
    settings.SmartTuning = snapshotSmartTuningState()
    settings.AutoTuning = cloneAutoTuningSnapshot()
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

    local playerGui
    if LocalPlayer then
        local finder = LocalPlayer.FindFirstChildOfClass or LocalPlayer.FindFirstChildWhichIsA
        if typeof(finder) == "function" then
            local ok, result = pcall(finder, LocalPlayer, "PlayerGui")
            if ok then
                playerGui = result
            end
        end

        if not playerGui and typeof(LocalPlayer.WaitForChild) == "function" then
            local okWait, result = pcall(LocalPlayer.WaitForChild, LocalPlayer, "PlayerGui", 5)
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

local function isTargetingMe(now)
    if not Character then
        targetingGraceUntil = 0
        return false
    end

    local highlightName = config.targetHighlightName
    now = now or os.clock()

    if not highlightName or highlightName == "" then
        targetingGraceUntil = math.max(targetingGraceUntil, now + TARGETING_GRACE_SECONDS)
        return true
    end

    local ok, result = pcall(function()
        return Character:FindFirstChild(highlightName)
    end)

    if ok and result ~= nil then
        targetingGraceUntil = now + TARGETING_GRACE_SECONDS
        return true
    end

    if targetingGraceUntil > now then
        return true
    end

    return false
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


local function clearScheduledPress(targetBallId: string?, reason: string?, metadata: { [string]: any }?)
    if targetBallId and scheduledPressState.ballId ~= targetBallId then
        return
    end

    local previousBallId = scheduledPressState.ballId
    local previousPressAt = scheduledPressState.pressAt
    local previousPredictedImpact = scheduledPressState.predictedImpact
    local previousLead = scheduledPressState.lead
    local previousSlack = scheduledPressState.slack
    local previousReason = scheduledPressState.reason
    local lastUpdate = scheduledPressState.lastUpdate

    scheduledPressState.ballId = nil
    scheduledPressState.pressAt = 0
    scheduledPressState.predictedImpact = math.huge
    scheduledPressState.lead = 0
    scheduledPressState.slack = 0
    scheduledPressState.reason = nil
    scheduledPressState.lastUpdate = 0
    scheduledPressState.smartTuning = nil
    scheduledPressState.immediate = false

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

        local snapshot = scheduledPressState.lastSnapshot
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
        pushTelemetryEvent("schedule-cleared", event)
    end
end

local function updateScheduledPress(
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

    if scheduledPressState.ballId ~= ballId then
        scheduledPressState.ballId = ballId
    elseif math.abs(scheduledPressState.pressAt - pressAt) > SMART_PRESS_TRIGGER_GRACE then
        scheduledPressState.ballId = ballId
    end

    scheduledPressState.pressAt = pressAt
    scheduledPressState.predictedImpact = predictedImpact
    scheduledPressState.lead = lead
    scheduledPressState.slack = slack
    scheduledPressState.reason = reason
    scheduledPressState.lastUpdate = now
    if typeof(context) == "table" and context.immediate ~= nil then
        scheduledPressState.immediate = context.immediate == true
    else
        scheduledPressState.immediate = false
    end
    if typeof(context) == "table" and context.smartTuning ~= nil then
        scheduledPressState.smartTuning = normalizeSmartTuningPayload(context.smartTuning)
    else
        scheduledPressState.smartTuning = nil
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

    scheduledPressState.lastSnapshot = cloneTable(event)

    if event.immediate == nil then
        event.immediate = scheduledPressState.immediate
    end

    TelemetryAnalytics.recordSchedule(event)
    pushTelemetryEvent("schedule", event)
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

    local smartContext = scheduledPressState.smartTuning
    if smartContext == nil and smartTuningState.enabled then
        smartContext = snapshotSmartTuningState()
    end
    local normalizedSmartContext = nil
    if smartContext ~= nil then
        normalizedSmartContext = normalizeSmartTuningPayload(smartContext)
    end

    local scheduledSnapshot = nil
    if ballId then
        local hasSchedule = scheduledPressState.ballId == ballId and scheduledPressState.lastUpdate and scheduledPressState.lastUpdate > 0
        if not hasSchedule then
            local immediateContext = {
                immediate = true,
                adaptiveBias = TelemetryAnalytics.adaptiveState and TelemetryAnalytics.adaptiveState.reactionBias or nil,
            }
            if normalizedSmartContext ~= nil then
                immediateContext.smartTuning = normalizedSmartContext
            end
            updateScheduledPress(ballId, 0, 0, 0, "immediate-press", now, immediateContext)
        end
        scheduledSnapshot = captureScheduledPressSnapshot(ballId)
    end
    prunePendingLatencyPresses(now)
    pendingLatencyPresses[#pendingLatencyPresses + 1] = { time = now, ballId = ballId }

    local telemetry = nil
    if ballId then
        telemetry = telemetryStates[ballId]
    end

    local scheduledReason = nil
    if ballId and scheduledPressState.ballId == ballId then
        scheduledReason = scheduledPressState.reason
    end

    local pressEvent = {
        ballId = ballId,
        forced = forcing,
        time = now,
        activationLatency = activationLatencyEstimate,
        remoteLatencyActive = state.remoteEstimatorActive,
        scheduledReason = scheduledReason,
    }

    if TelemetryAnalytics.adaptiveState then
        pressEvent.adaptiveBias = TelemetryAnalytics.adaptiveState.reactionBias
    end

    local eventSmartContext = normalizedSmartContext or scheduledPressState.smartTuning
    if eventSmartContext == nil and smartTuningState.enabled then
        eventSmartContext = normalizeSmartTuningPayload(snapshotSmartTuningState())
    end
    if eventSmartContext ~= nil then
        if typeof(eventSmartContext) == "table" then
            pressEvent.smartTuning = cloneTable(eventSmartContext)
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
        clearScheduledPress(ballId, "pressed", { pressedAt = now })
    else
        clearScheduledPress(nil, "pressed", { pressedAt = now })
    end

    if telemetry then
        telemetry.triggerTime = now
        telemetry.latencySampled = false
    end

    TelemetryAnalytics.recordPress(pressEvent, scheduledSnapshot)
    pushTelemetryEvent("press", pressEvent)
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

    clearScheduledPress(ballId, "released")

    if ballId then
        local telemetry = telemetryStates[ballId]
        if telemetry then
            telemetry.triggerTime = nil
            telemetry.latencySampled = true
        end
    end
end

local function handleHumanoidDied()
    clearScheduledPress(nil, "humanoid-died")
    safeCall(releaseParry)
    safeCall(safeClearBallVisuals)
    safeCall(enterRespawnWaitState)
    safeCall(updateCharacter, nil)
    callImmortalController("handleHumanoidDied")
end

local function updateCharacter(character)
    Character = character
    RootPart = nil
    Humanoid = nil
    targetingGraceUntil = 0

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
    clearScheduledPress(nil, "character-removing")
    safeCall(releaseParry)
    safeCall(safeClearBallVisuals)
    safeCall(enterRespawnWaitState)
    safeCall(updateCharacter, nil)
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

            local characterAddedSignal = LocalPlayer.CharacterAdded
            local characterRemovingSignal = LocalPlayer.CharacterRemoving

            if characterAddedSignal and typeof(characterAddedSignal.Connect) == "function" then
                characterAddedConnection = characterAddedSignal:Connect(handleCharacterAdded)
            else
                characterAddedConnection = nil
            end

            if characterRemovingSignal and typeof(characterRemovingSignal.Connect) == "function" then
                characterRemovingConnection = characterRemovingSignal:Connect(handleCharacterRemoving)
            else
                characterRemovingConnection = nil
            end

            local currentCharacter = LocalPlayer.Character
            if currentCharacter then
                updateCharacter(currentCharacter)
            elseif characterAddedSignal and typeof(characterAddedSignal.Wait) == "function" then
                local okChar, char = pcall(function()
                    return characterAddedSignal:Wait()
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

local function computeUpdateTiming(telemetry, now)
    local previousUpdate = telemetry.lastUpdate or now
    local dt = now - previousUpdate
    if not isFiniteNumber(dt) or dt <= 0 then
        dt = 1 / 240
    end
    dt = math.clamp(dt, 1 / 240, 0.5)
    telemetry.lastUpdate = now
    return dt
end

local function computeSpatialContext(context, ballPosition, playerPosition, safeRadius)
    local relative = ballPosition - playerPosition
    local distance = relative.Magnitude
    local unit = Vector3.zero
    if distance > EPSILON then
        unit = relative / distance
    end

    context.relative = relative
    context.distance = distance
    context.unit = unit
    context.d0 = distance - safeRadius
end

local function computeRawMotion(context, telemetry, dt)
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

local function computeFilteredMotion(context, telemetry)
    local rawVelocity = context.rawVelocity
    local rawAcceleration = context.rawAcceleration
    local rawJerk = context.rawJerk

    local velocity = emaVector(telemetry.velocity, rawVelocity, SMOOTH_ALPHA)
    telemetry.velocity = velocity
    context.velocity = velocity
    context.velocityMagnitude = velocity.Magnitude

    local acceleration = emaVector(telemetry.acceleration, rawAcceleration, SMOOTH_ALPHA)
    telemetry.acceleration = acceleration
    context.acceleration = acceleration

    local jerk = emaVector(telemetry.jerk, rawJerk, SMOOTH_ALPHA)
    telemetry.jerk = jerk
    context.jerk = jerk

    local vNorm2 = velocity:Dot(velocity)
    if vNorm2 < EPSILON then
        vNorm2 = EPSILON
    end
    context.vNorm2 = vNorm2

    local rawSpeedSq = rawVelocity:Dot(rawVelocity)
    context.rawSpeedSq = rawSpeedSq

    context.rawSpeed = rawVelocity.Magnitude
end

local function computeCurvature(context, telemetry, dt)
    local rawVelocity = context.rawVelocity
    local rawAcceleration = context.rawAcceleration
    local rawSpeed = context.rawSpeed
    local rawSpeedSq = context.rawSpeedSq
    local vNorm2 = context.vNorm2

    local rawKappa = 0
    if rawSpeed > EPSILON then
        rawKappa = rawVelocity:Cross(rawAcceleration).Magnitude / math.max(rawSpeedSq * rawSpeed, EPSILON)
    end
    context.rawKappa = rawKappa

    local filteredKappaRaw = emaScalar(telemetry.kappa, rawKappa, KAPPA_ALPHA)
    local filteredKappa, kappaOverflow = clampWithOverflow(filteredKappaRaw, PHYSICS_LIMITS.curvature)
    telemetry.kappa = filteredKappa
    context.filteredKappa = filteredKappa
    context.kappaOverflow = kappaOverflow

    local dkappaRaw = 0
    if telemetry.lastRawKappa ~= nil then
        dkappaRaw = (rawKappa - telemetry.lastRawKappa) / math.max(dt, EPSILON)
    end
    telemetry.lastRawKappa = rawKappa
    context.dkappaRaw = dkappaRaw

    local filteredDkappaRaw = emaScalar(telemetry.dkappa, dkappaRaw, DKAPPA_ALPHA)
    local filteredDkappa, dkappaOverflow = clampWithOverflow(filteredDkappaRaw, PHYSICS_LIMITS.curvatureRate)
    telemetry.dkappa = filteredDkappa
    context.filteredDkappa = filteredDkappa
    context.dkappaOverflow = dkappaOverflow
end

local function computeRadial(
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

    local filteredVr = emaScalar(telemetry.filteredVr, -unit:Dot(velocity), SMOOTH_ALPHA)
    telemetry.filteredVr = filteredVr
    context.filteredVr = filteredVr

    local vrSign = 0
    if filteredVr > VR_SIGN_EPSILON then
        vrSign = 1
    elseif filteredVr < -VR_SIGN_EPSILON then
        vrSign = -1
    end
    context.vrSign = vrSign

    local filteredArEstimate = -unit:Dot(acceleration) + filteredKappa * vNorm2
    context.filteredArEstimate = filteredArEstimate
    local filteredArRaw = emaScalar(telemetry.filteredAr, filteredArEstimate, SMOOTH_ALPHA)
    local filteredAr, arOverflow = clampWithOverflow(filteredArRaw, PHYSICS_LIMITS.radialAcceleration)
    telemetry.filteredAr = filteredAr
    context.filteredAr = filteredAr
    context.arOverflow = arOverflow

    local dotVA = velocity:Dot(acceleration)
    context.dotVA = dotVA

    local filteredJrEstimate = -unit:Dot(jerk) + filteredDkappa * vNorm2 + 2 * filteredKappa * dotVA
    context.filteredJrEstimate = filteredJrEstimate
    local filteredJrRaw = emaScalar(telemetry.filteredJr, filteredJrEstimate, SMOOTH_ALPHA)
    local filteredJr, jrOverflow = clampWithOverflow(filteredJrRaw, PHYSICS_LIMITS.radialJerk)
    telemetry.filteredJr = filteredJr
    context.filteredJr = filteredJr
    context.jrOverflow = jrOverflow

    local rawAr = -unit:Dot(rawAcceleration) + rawKappa * rawSpeedSq
    context.rawAr = rawAr

    local rawJr = -unit:Dot(rawJerk) + dkappaRaw * rawSpeedSq + 2 * rawKappa * rawVelocity:Dot(rawAcceleration)
    context.rawJr = rawJr
end

local function trackVrSignHistory(telemetry, now, vrSign)
    if vrSign ~= 0 then
        local previousSign = telemetry.lastVrSign
        if previousSign and previousSign ~= 0 and previousSign ~= vrSign then
            local flips = telemetry.vrSignFlips
            flips[#flips + 1] = { time = now, sign = vrSign }
        end
        telemetry.lastVrSign = vrSign
    end
    trimHistory(telemetry.vrSignFlips, now - OSCILLATION_HISTORY_SECONDS)
end

local function updateDistanceHistory(context, telemetry, now)
    local d0 = context.d0
    local filteredD = emaScalar(telemetry.filteredD, d0, SMOOTH_ALPHA)
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
    trimHistory(d0History, now - OSCILLATION_HISTORY_SECONDS)
    context.d0Delta = d0Delta

end

local function updateVariance(context, telemetry)
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

    updateRollingStat(telemetry.statsD, d0 - filteredD)
    updateRollingStat(telemetry.statsVr, rawVr - filteredVr)
    updateRollingStat(telemetry.statsAr, rawAr - filteredAr)
    updateRollingStat(telemetry.statsJr, rawJr - filteredJr)

    local sigmaD = getRollingStd(telemetry.statsD, SIGMA_FLOORS.d)
    local sigmaVr = getRollingStd(telemetry.statsVr, SIGMA_FLOORS.vr)
    local sigmaAr = getRollingStd(telemetry.statsAr, SIGMA_FLOORS.ar)
    local sigmaJr = getRollingStd(telemetry.statsJr, SIGMA_FLOORS.jr)

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

local function buildBallKinematics(ball, playerPosition, telemetry, safeRadius, now)
    local context = {
        safeRadius = safeRadius,
    }

    context.dt = computeUpdateTiming(telemetry, now)

    context.ballPosition = ball.Position

    computeSpatialContext(context, context.ballPosition, playerPosition, safeRadius)

    computeRawMotion(context, telemetry, context.dt)

    computeFilteredMotion(context, telemetry)

    computeCurvature(context, telemetry, context.dt)

    computeRadial(context, telemetry)

    trackVrSignHistory(telemetry, now, context.vrSign)

    updateDistanceHistory(context, telemetry, now)

    updateVariance(context, telemetry)

    return context
end

local function renderLoop()
    if initialization.destroyed then
        clearScheduledPress(nil, "destroyed")
        return
    end

    if not LocalPlayer then
        clearScheduledPress(nil, "missing-player")
        return
    end

    if not Character or not RootPart then
        updateStatusLabel({ "Auto-Parry F", "Status: waiting for character" })
        safeClearBallVisuals()
        clearScheduledPress(nil, "missing-character")
        releaseParry()
        return
    end

    ensureBallsFolder(false)
    local folder = BallsFolder
    if not folder then
        updateStatusLabel({ "Auto-Parry F", "Ball: none", "Info: waiting for balls folder" })
        safeClearBallVisuals()
        clearScheduledPress(nil, "missing-balls-folder")
        releaseParry()
        return
    end

    if not state.enabled then
        clearScheduledPress(nil, "disabled")
        releaseParry()
        updateStatusLabel({ "Auto-Parry F", "Status: OFF" })
        safeClearBallVisuals()
        updateToggleButton()
        return
    end

    local now = os.clock()
    cleanupTelemetry(now)
    prunePendingLatencyPresses(now)
    maybeRunAutoTuning(now)

    local ball = findRealBall(folder)
    if not ball or not ball:IsDescendantOf(Workspace) then
        updateStatusLabel({ "Auto-Parry F", "Ball: none", "Info: waiting for realBall..." })
        safeClearBallVisuals()
        clearScheduledPress(nil, "no-ball")
        releaseParry()
        return
    end

    local ballId = getBallIdentifier(ball)
    if not ballId then
        updateStatusLabel({ "Auto-Parry F", "Ball: unknown", "Info: missing identifier" })
        safeClearBallVisuals()
        clearScheduledPress(nil, "missing-identifier")
        releaseParry()
        return
    end

    if scheduledPressState.ballId and scheduledPressState.ballId ~= ballId then
        clearScheduledPress(nil, "ball-changed")
    elseif scheduledPressState.ballId == ballId and now - scheduledPressState.lastUpdate > SMART_PRESS_STALE_SECONDS then
        clearScheduledPress(ballId, "schedule-stale")
    end

    local telemetry = ensureTelemetry(ballId, now)
    local safeRadius = config.safeRadius or 0
    local kinematics = buildBallKinematics(ball, RootPart.Position, telemetry, safeRadius, now)

    local ping = getPingTime()
    local delta = 0.5 * ping + activationLatencyEstimate

    local delta2 = delta * delta
    local mu =
        kinematics.filteredD
        - kinematics.filteredVr * delta
        - 0.5 * kinematics.filteredAr * delta2
        - (1 / 6) * kinematics.filteredJr * delta2 * delta

    local sigmaSquared = kinematics.sigmaD * kinematics.sigmaD
    sigmaSquared += (delta2) * (kinematics.sigmaVr * kinematics.sigmaVr)
    sigmaSquared += (0.25 * delta2 * delta2) * (kinematics.sigmaAr * kinematics.sigmaAr)
    sigmaSquared += ((1 / 36) * delta2 * delta2 * delta2) * (kinematics.sigmaJr * kinematics.sigmaJr)
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

    local targetingMe = isTargetingMe(now)
    if telemetry then
        if targetingMe then
            if telemetry.targetDetectedAt == nil then
                telemetry.targetDetectedAt = now
            end
        elseif not parryHeld or parryHeldBallId ~= ballId then
            telemetry.targetDetectedAt = nil
            telemetry.decisionAt = nil
        end
    end
    local fired = false
    local released = false

    local approachSpeed = math.max(kinematics.filteredVr, kinematics.rawVr, 0)
    local approaching = approachSpeed > EPSILON
    local timeToImpactFallback = math.huge
    local timeToImpactPolynomial: number?
    local timeToImpact = math.huge
    if approaching then
        local speed = math.max(approachSpeed, EPSILON)
        timeToImpactFallback = kinematics.distance / speed

        local impactRadial = kinematics.filteredD
        local polynomial =
            solveRadialImpactTime(impactRadial, kinematics.filteredVr, kinematics.filteredAr, kinematics.filteredJr)
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
                normalizedKappa = math.clamp(math.abs(kinematics.filteredKappa) / kappaLimit, 0, 1)
            end

            local normalizedDkappa = 0
            if dkappaLimit > 0 then
                normalizedDkappa = math.clamp(math.abs(kinematics.filteredDkappa) / dkappaLimit, 0, 1)
            end

            local normalizedAr = 0
            if arLimit > 0 then
                normalizedAr = math.clamp(math.max(kinematics.filteredAr, 0) / arLimit, 0, 1)
            end

            local normalizedJerkOverflow = 0
            if jrLimit > 0 then
                local overflow = math.max(kinematics.jrOverflow or 0, kinematics.sigmaJrOverflow or 0)
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
        timeToPressRadiusFallback = math.max(kinematics.distance - pressRadius, 0) / speed
        timeToHoldRadiusFallback = math.max(kinematics.distance - holdRadius, 0) / speed

        local radialToPress = kinematics.filteredD + safeRadius - pressRadius
        local radialToHold = kinematics.filteredD + safeRadius - holdRadius

        local pressPolynomial =
            solveRadialImpactTime(radialToPress, kinematics.filteredVr, kinematics.filteredAr, kinematics.filteredJr)
        if pressPolynomial and pressPolynomial > EPSILON then
            timeToPressRadiusPolynomial = pressPolynomial
            timeToPressRadius = pressPolynomial
        else
            timeToPressRadius = timeToPressRadiusFallback
        end

        local holdPolynomial =
            solveRadialImpactTime(radialToHold, kinematics.filteredVr, kinematics.filteredAr, kinematics.filteredJr)
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

    local predictedImpact = math.huge
    if approaching then
        predictedImpact = math.min(timeToImpact, timeToPressRadius, timeToImpactFallback)
        if timeToImpactPolynomial then
            predictedImpact = math.min(predictedImpact, timeToImpactPolynomial)
        end
        if timeToPressRadiusPolynomial then
            predictedImpact = math.min(predictedImpact, timeToPressRadiusPolynomial)
        end
    end
    if not isFiniteNumber(predictedImpact) or predictedImpact < 0 then
        predictedImpact = math.huge
    end

    local reactionBias = config.pressReactionBias
    if reactionBias == nil then
        reactionBias = DEFAULT_CONFIG.pressReactionBias
    end
    if not isFiniteNumber(reactionBias) or reactionBias < 0 then
        reactionBias = 0
    end

    local scheduleSlack = config.pressScheduleSlack
    if scheduleSlack == nil then
        scheduleSlack = DEFAULT_CONFIG.pressScheduleSlack
    end
    if not isFiniteNumber(scheduleSlack) or scheduleSlack < 0 then
        scheduleSlack = 0
    end

    local maxLookahead = config.pressMaxLookahead
    if maxLookahead == nil then
        maxLookahead = DEFAULT_CONFIG.pressMaxLookahead
    end
    if not isFiniteNumber(maxLookahead) or maxLookahead <= 0 then
        maxLookahead = DEFAULT_CONFIG.pressMaxLookahead
    end
    if maxLookahead < PROXIMITY_PRESS_GRACE then
        maxLookahead = PROXIMITY_PRESS_GRACE
    end

    local lookaheadGoal = config.pressLookaheadGoal
    if lookaheadGoal == nil then
        lookaheadGoal = DEFAULT_CONFIG.pressLookaheadGoal
    end
    if not isFiniteNumber(lookaheadGoal) or lookaheadGoal <= 0 then
        lookaheadGoal = 0
    elseif maxLookahead < lookaheadGoal then
        maxLookahead = lookaheadGoal
    end

    local confidencePadding = config.pressConfidencePadding
    if confidencePadding == nil then
        confidencePadding = DEFAULT_CONFIG.pressConfidencePadding
    end
    if not isFiniteNumber(confidencePadding) or confidencePadding < 0 then
        confidencePadding = 0
    end

    local smartTelemetry
    local smartTuningApplied = applySmartTuning({
        ballId = ballId,
        now = now,
        baseReactionBias = reactionBias,
        baseScheduleSlack = scheduleSlack,
        baseConfidencePadding = confidencePadding,
        sigma = sigma,
        mu = mu,
        muPlus = muPlus,
        muMinus = muMinus,
        delta = delta,
        ping = ping,
        lookaheadGoal = lookaheadGoal,
    })

    if smartTuningApplied then
        local appliedReaction = smartTuningApplied.reactionBias
        if isFiniteNumber(appliedReaction) and appliedReaction >= 0 then
            reactionBias = appliedReaction
        end

        local appliedSlack = smartTuningApplied.scheduleSlack
        if isFiniteNumber(appliedSlack) and appliedSlack >= 0 then
            scheduleSlack = appliedSlack
        end

        local appliedConfidence = smartTuningApplied.confidencePadding
        if isFiniteNumber(appliedConfidence) and appliedConfidence >= 0 then
            confidencePadding = appliedConfidence
        end

        smartTelemetry = normalizeSmartTuningPayload(smartTuningApplied.telemetry)
    end

    local scheduleLead = math.max(delta + reactionBias, PROXIMITY_PRESS_GRACE)

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

    local inequalityPress = targetingMe and muValid and sigmaValid and muPlus <= 0
    local confidencePress = targetingMe and muValid and sigmaValid and muPlus <= -confidencePadding

    local timeUntilPress = predictedImpact - scheduleLead
    if not isFiniteNumber(timeUntilPress) then
        timeUntilPress = math.huge
    end
    local canPredict = approaching and targetingMe and predictedImpact < math.huge
    local shouldDelay = canPredict and not confidencePress and predictedImpact > scheduleLead
    local withinLookahead = maxLookahead <= 0 or timeUntilPress <= maxLookahead
    local shouldSchedule = shouldDelay and withinLookahead

    local proximityPress =
        targetingMe
        and approaching
        and (
            kinematics.distance <= pressRadius
            or timeToPressRadius <= responseWindow
            or timeToImpact <= responseWindow
        )

    local proximityHold =
        targetingMe
        and approaching
        and (
            kinematics.distance <= holdRadius
            or timeToHoldRadius <= holdWindow
            or timeToImpact <= holdWindow
        )

    local shouldPress = proximityPress or inequalityPress

    if telemetry then
        if shouldPress then
            telemetry.decisionAt = telemetry.decisionAt or now
        elseif not targetingMe then
            telemetry.decisionAt = nil
        end
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

    local existingSchedule = nil
    if scheduledPressState.ballId == ballId then
        existingSchedule = scheduledPressState
        scheduledPressState.lead = scheduleLead
        scheduledPressState.slack = scheduleSlack
        if smartTelemetry then
            scheduledPressState.smartTuning = smartTelemetry
        end
    end

    local smartReason = nil

    if shouldPress then
        if shouldSchedule then
            smartReason = string.format("impact %.3f > lead %.3f (press in %.3f)", predictedImpact, scheduleLead, math.max(timeUntilPress, 0))
            local scheduleContext = {
                distance = kinematics.distance,
                timeToImpact = timeToImpact,
                timeUntilPress = timeUntilPress,
                speed = kinematics.velocityMagnitude,
                pressRadius = pressRadius,
                holdRadius = holdRadius,
                confidencePress = confidencePress,
                targeting = targetingMe,
                adaptiveBias = TelemetryAnalytics.adaptiveState and TelemetryAnalytics.adaptiveState.reactionBias or nil,
                lookaheadGoal = lookaheadGoal,
            }
            if smartTelemetry then
                scheduleContext.smartTuning = smartTelemetry
            end
            updateScheduledPress(ballId, predictedImpact, scheduleLead, scheduleSlack, smartReason, now, scheduleContext)
            existingSchedule = scheduledPressState
        elseif existingSchedule and not shouldDelay then
            clearScheduledPress(ballId, "ready-to-press")
            existingSchedule = nil
        elseif existingSchedule and shouldDelay and not withinLookahead then
            clearScheduledPress(ballId, "outside-lookahead")
            existingSchedule = nil
        end

        local activeSlack = (existingSchedule and existingSchedule.slack) or scheduleSlack
        local readyToPress = confidencePress or not shouldDelay
        if not readyToPress and predictedImpact <= scheduleLead + activeSlack then
            readyToPress = true
        end

        if not readyToPress and existingSchedule then
            if now >= existingSchedule.pressAt - activeSlack then
                readyToPress = true
            end
        end

        if readyToPress then
            local pressed = pressParry(ball, ballId)
            fired = pressed or fired
            if pressed then
                existingSchedule = nil
            end
        end
    else
        if existingSchedule then
            clearScheduledPress(ballId, "conditions-changed")
            existingSchedule = nil
        end
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
        string.format("d0: %.3f | vr: %.3f", kinematics.filteredD, kinematics.filteredVr),
        string.format("ar: %.3f | jr: %.3f", kinematics.filteredAr, kinematics.filteredJr),
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

    local reactionLatencyText, decisionLatencyText, commitLatencyText =
        TelemetryAnalytics.computeLatencyReadouts(telemetry, now)
    table.insert(debugLines, string.format("React: %s | Decide: %s | Commit: %s", reactionLatencyText, decisionLatencyText, commitLatencyText))

    if scheduledPressState.ballId == ballId then
        local eta = math.max((scheduledPressState.pressAt or now) - now, 0)
        table.insert(
            debugLines,
            string.format(
                "Smart press: eta %.3f | lead %.3f | slack %.3f | reason %s",
                eta,
                scheduledPressState.lead or 0,
                scheduledPressState.slack or 0,
                scheduledPressState.reason or "?"
            )
        )
    elseif shouldPress and shouldDelay then
        table.insert(
            debugLines,
            string.format(
                "Smart press: delaying %.3f | lookahead %.3f",
                math.max(timeUntilPress, 0),
                maxLookahead
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
    elseif parryHeld and not released then
        table.insert(debugLines, "Hold: maintaining expanded proximity window")
    else
        table.insert(debugLines, "Hold: conditions not met")
    end

    updateStatusLabel(debugLines)
    setBallVisuals(
        ball,
        computeBallDebug(
            kinematics.velocityMagnitude,
            kinematics.distance,
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
    ensureInitialization()
    if state.enabled then
        return
    end

    resetTelemetryHistory("enabled")
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
    targetingGraceUntil = 0
    clearScheduledPress(nil, "disabled")
    releaseParry()
    telemetryStates = {}
    trackedBall = nil
    syncGlobalSettings()
    updateToggleButton()
    stateChanged:fire(false)
    resetTelemetryHistory("disabled")
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

    if key == "smartTuning" then
        config.smartTuning = normalizeSmartTuningConfig(value)
        resetSmartTuningState()
        if config.smartTuning == false then
            return
        end
    elseif key == "autoTuning" then
        config.autoTuning = normalizeAutoTuningConfig(value)
        syncAutoTuningState()
        return
    else
        config[key] = value
    end

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
    elseif key == "smartTuning" then
        -- nothing extra; normalization already handled above
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
    config.smartTuning = normalizeSmartTuningConfig(config.smartTuning)
    config.autoTuning = normalizeAutoTuningConfig(config.autoTuning)
    resetActivationLatency()
    resetSmartTuningState()
    syncAutoTuningState()
    resetTelemetryHistory("config-reset")
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

function AutoParry.getSmartPressState()
    ensureInitialization()

    local now = os.clock()
    local snapshot = {
        ballId = scheduledPressState.ballId,
        pressAt = scheduledPressState.pressAt,
        predictedImpact = scheduledPressState.predictedImpact,
        lead = scheduledPressState.lead,
        slack = scheduledPressState.slack,
        reason = scheduledPressState.reason,
        lastUpdate = scheduledPressState.lastUpdate,
        sampleTime = now,
        latency = activationLatencyEstimate,
        remoteLatencyActive = state.remoteEstimatorActive,
        latencySamples = cloneTable(latencySamples),
        pendingLatencyPresses = cloneTable(pendingLatencyPresses),
        smartTuning = snapshotSmartTuningState(),
    }

    if scheduledPressState.lastUpdate and scheduledPressState.lastUpdate > 0 then
        snapshot.timeSinceUpdate = now - scheduledPressState.lastUpdate
    end

    local ballId = scheduledPressState.ballId
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

    if scheduledPressState.smartTuning then
        snapshot.scheduledSmartTuning = cloneTable(scheduledPressState.smartTuning)
    end

    if snapshot.pressAt and snapshot.pressAt > 0 then
        snapshot.pressEta = math.max(snapshot.pressAt - now, 0)
    else
        snapshot.pressEta = nil
    end

    if snapshot.ballId then
        scheduledPressState.lastSnapshot = cloneTable(snapshot)
    elseif scheduledPressState.lastSnapshot then
        snapshot.lastScheduled = cloneTable(scheduledPressState.lastSnapshot)
    end

    return snapshot
end

function AutoParry.getSmartTuningSnapshot()
    ensureInitialization()
    return snapshotSmartTuningState()
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

function AutoParry.onTelemetry(callback)
    assert(typeof(callback) == "function", "AutoParry.onTelemetry expects a function")
    return telemetrySignal:connect(function(event)
        callback(cloneTelemetryEvent(event))
    end)
end

local function cloneTelemetryHistory()
    local history = {}
    for index = 1, #telemetryHistory do
        history[index] = cloneTelemetryEvent(telemetryHistory[index])
    end
    return history
end

function AutoParry.getTelemetryHistory()
    return cloneTelemetryHistory()
end

function AutoParry.getTelemetrySnapshot()
    local _, telemetryStore = publishTelemetryHistory()
    local stats = TelemetryAnalytics.clone()
    return {
        sequence = telemetrySequence,
        history = cloneTelemetryHistory(),
        activationLatency = activationLatencyEstimate,
        remoteLatencyActive = state.remoteEstimatorActive,
        lastEvent = telemetryStore.lastEvent and cloneTelemetryEvent(telemetryStore.lastEvent) or nil,
        smartTuning = snapshotSmartTuningState(),
        stats = stats,
        adaptiveState = stats and stats.adaptiveState or telemetryStore.adaptiveState,
    }
end

function AutoParry.getTelemetryStats()
    ensureInitialization()
    return TelemetryAnalytics.clone()
end

local function applyTelemetryUpdates(adjustments, options)
    options = options or {}
    local updates = adjustments.updates or {}
    if typeof(adjustments.reasons) ~= "table" then
        adjustments.reasons = {}
    end
    if next(updates) and not options.dryRun then
        AutoParry.configure(updates)
        local appliedAt = os.clock()
        pushTelemetryEvent("config-adjustment", {
            updates = cloneTable(updates),
            reasons = cloneTable(adjustments.reasons),
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
    ensureInitialization()

    options = options or {}
    local stats = options.stats
    if typeof(stats) ~= "table" then
        stats = TelemetryAnalytics.clone()
    end

    local summary = options.summary
    if typeof(summary) ~= "table" then
        summary = TelemetryAnalytics.computeSummary(stats)
    end

    local configSnapshot = cloneTable(config)

    local defaultCommitTarget, defaultLookaheadGoal = resolvePerformanceTargets()

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
    ensureInitialization()

    options = options or {}
    local adjustments = AutoParry.buildTelemetryAdjustments(options)
    return applyTelemetryUpdates(adjustments, {
        dryRun = options.dryRun,
        source = "telemetry-adjustments",
    })
end

local function performAutoTuning(options)
    options = options or {}
    local now = options.now or os.clock()
    local force = options.force == true

    if not force and not autoTuningState.enabled then
        return nil
    end

    if not force and not state.enabled then
        return nil
    end

    local interval = autoTuningState.intervalSeconds or DEFAULT_AUTO_TUNING.intervalSeconds
    if not isFiniteNumber(interval) or interval < 0 then
        interval = DEFAULT_AUTO_TUNING.intervalSeconds
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
    if not isFiniteNumber(minDelta) or minDelta < 0 then
        minDelta = autoTuningState.minDelta or 0
    end

    local maxAdjustments = options.maxAdjustmentsPerRun
    if not isFiniteNumber(maxAdjustments) or maxAdjustments < 0 then
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

    if isFiniteNumber(maxAdjustments) and maxAdjustments and maxAdjustments > 0 and #ranked > maxAdjustments then
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
    autoTuningState.lastSummary = cloneTable(summary)
    autoTuningState.lastAdjustments = {
        updates = cloneTable(adjustments.updates),
        deltas = cloneTable(adjustments.deltas),
        reasons = cloneTable(adjustments.reasons),
        status = adjustments.status,
    }
    autoTuningState.lastError = nil

    local dryRun = options.dryRun
    if dryRun == nil then
        dryRun = autoTuningState.dryRun
    end

    local applied = applyTelemetryUpdates(adjustments, {
        dryRun = dryRun,
        source = options.source or "auto-tuning",
    })

    autoTuningState.lastResult = {
        status = applied.status,
        updates = cloneTable(applied.updates),
        deltas = cloneTable(applied.deltas),
        appliedAt = applied.appliedAt,
        dryRun = dryRun,
        newConfig = cloneTable(applied.newConfig),
    }

    applied.autoTuning = cloneAutoTuningSnapshot()
    syncGlobalSettings()
    return applied
end

function maybeRunAutoTuning(now)
    if not autoTuningState.enabled then
        return
    end

    now = now or os.clock()
    local ok, result = pcall(performAutoTuning, { now = now })
    if not ok then
        autoTuningState.lastError = tostring(result)
        warn(("AutoParry: auto-tuning failed (%s)"):format(tostring(result)))
    elseif result then
        autoTuningState.lastError = nil
    end
end

function AutoParry.getDiagnosticsReport()
    ensureInitialization()
    local stats = TelemetryAnalytics.clone()
    local summary = TelemetryAnalytics.computeSummary(stats)
    local adjustments = AutoParry.buildTelemetryAdjustments({
        stats = stats,
        summary = summary,
        allowWhenSmartTuning = false,
    })
    local configSnapshot = adjustments.previousConfig or cloneTable(config)
    local recommendations = TelemetryAnalytics.buildRecommendations(stats, summary)
    local commitTarget, lookaheadGoal = resolvePerformanceTargets()
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
    ensureInitialization()
    return cloneAutoTuningSnapshot()
end

function AutoParry.runAutoTuning(options)
    ensureInitialization()
    local callOptions = options or {}
    if callOptions.force == nil then
        callOptions.force = true
    end
    if callOptions.now == nil then
        callOptions.now = os.clock()
    end

    local ok, result = pcall(performAutoTuning, callOptions)
    if not ok then
        autoTuningState.lastError = tostring(result)
        warn(("AutoParry: auto-tuning failed (%s)"):format(tostring(result)))
        return nil, result
    end

    return result
end

function AutoParry.getTelemetryInsights(options)
    ensureInitialization()
    options = options or {}

    local stats = options.stats
    if typeof(stats) ~= "table" then
        stats = TelemetryAnalytics.clone()
    end

    local summary = options.summary
    if typeof(summary) ~= "table" then
        summary = TelemetryAnalytics.computeSummary(stats)
    end

    local defaultCommitTarget, defaultLookaheadGoal = resolvePerformanceTargets()

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
        updates = cloneTable(adjustments.updates),
        deltas = cloneTable(adjustments.deltas),
        reasons = cloneTable(adjustments.reasons),
        minSamples = adjustments.minSamples,
    }
    insights.config = cloneTable(config)
    insights.smartTuningEnabled = smartTuningState.enabled
    insights.autoTuning = cloneAutoTuningSnapshot()
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
    clearScheduledPress(nil, "destroyed")
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
    resetSmartTuningState()

    resetTelemetryHistory("destroyed")

    initProgress = { stage = "waiting-player" }
    applyInitStatus(cloneTable(initProgress))

    GlobalEnv.Paws = nil

    initialization.destroyed = false
    targetingGraceUntil = 0
end

ensureInitialization()
ensureLoop()
syncAutoTuningState()
syncGlobalSettings()
syncImmortalContext()

return AutoParry
