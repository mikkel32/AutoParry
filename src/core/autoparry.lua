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

local TelemetryAnalytics = {}

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
        leadTolerance = options.leadTolerance or TELEMETRY_ADJUSTMENT_LEAD_TOLERANCE,
        waitTolerance = options.waitTolerance or TELEMETRY_ADJUSTMENT_WAIT_TOLERANCE,
        commit = {
            target = commitTarget,
            samples = summary.commitLatencySampleCount or 0,
            p99 = summary.commitLatencyP99,
            minSamples = options.commitMinSamples or 6,
        },
        lookahead = {
            goal = lookaheadGoal,
            samples = summary.scheduleLookaheadSampleCount or 0,
            p10 = summary.scheduleLookaheadP10,
            minSamples = options.lookaheadMinSamples or 4,
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

    local change = Helpers.clampNumber(
        -leadDelta * (context.options.leadGain or TELEMETRY_ADJUSTMENT_LEAD_GAIN),
        -0.05,
        0.05
    )
    if not change or math.abs(change) < 1e-4 then
        return
    end

    local currentReaction = context.current.reaction
    local maxReaction = context.options.maxReactionBias
        or math.max(TELEMETRY_ADJUSTMENT_MAX_REACTION, Defaults.CONFIG.pressReactionBias or 0)
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

    local change = Helpers.clampNumber(
        waitDelta * (context.options.slackGain or TELEMETRY_ADJUSTMENT_SLACK_GAIN),
        -0.03,
        0.03
    )
    if not change or math.abs(change) < 1e-4 then
        return
    end

    local currentSlack = context.current.slack
    local maxSlack = context.options.maxScheduleSlack
        or math.max(TELEMETRY_ADJUSTMENT_MAX_SLACK, Defaults.CONFIG.pressScheduleSlack or 0)
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
        local reactionGain = context.options.commitReactionGain or Defaults.SMART_TUNING.commitReactionGain or 0
        if reactionGain > 0 then
            local currentReaction = context.current.reaction
            local maxReaction = context.options.maxReactionBias
                or math.max(TELEMETRY_ADJUSTMENT_MAX_REACTION, Defaults.CONFIG.pressReactionBias or 0)
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

        local slackGain = context.options.commitSlackGain or Defaults.SMART_TUNING.commitSlackGain or 0
        if slackGain > 0 then
            local currentSlack = context.current.slack
            local maxSlack = context.options.maxScheduleSlack
                or math.max(TELEMETRY_ADJUSTMENT_MAX_SLACK, Defaults.CONFIG.pressScheduleSlack or 0)
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

    local delta = Helpers.clampNumber(
        (goal - p10) * (context.options.lookaheadGain or 0.5),
        0,
        context.options.maxPressLookaheadDelta or 0.75
    )
    if not delta or delta < 1e-4 then
        return
    end

    local maxLookahead = context.options.maxPressLookahead or math.max(currentLookahead, goal) + 0.6
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
    local maxLatency = context.options.maxActivationLatency or TELEMETRY_ADJUSTMENT_MAX_LATENCY
    maxLatency = math.max(maxLatency, currentLatency)

    local target = Helpers.clampNumber(observed, 0, maxLatency)
    local blended = Helpers.clampNumber(
        currentLatency + (target - currentLatency) * (context.options.latencyGain or TELEMETRY_ADJUSTMENT_LATENCY_GAIN),
        0,
        maxLatency
    )

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

    if state.enabled then
        Context.hooks.setStage("waiting-input", { reason = "virtual-input" })
        Context.hooks.updateStatusLabel({ "Auto-Parry F", "Status: waiting for input permissions" })
    end
end

function Helpers.noteVirtualInputSuccess()
    if Context.runtime.virtualInputUnavailable then
        Context.runtime.virtualInputUnavailable = false
        Context.runtime.virtualInputRetryAt = 0
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
local pushTelemetryEvent

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
        pushTelemetryEvent("latency-sample", eventPayload)
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
    pushTelemetryEvent("latency-sample", eventPayload)
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
            pushTelemetryEvent("success", successEvent)
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

    return commitTarget, lookaheadGoal
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

function Helpers.resetTelemetryHistory(reason: string?)
    local previousResets = 0
    if TelemetryAnalytics.metrics and TelemetryAnalytics.metrics.counters and typeof(TelemetryAnalytics.metrics.counters.resets) == "number" then
        previousResets = TelemetryAnalytics.metrics.counters.resets
    end
    TelemetryAnalytics.resetMetrics(previousResets + 1)
    TelemetryAnalytics.resetAdaptive()
    Context.telemetry.history = {}
    publishTelemetryHistory()
    if reason then
        pushTelemetryEvent("telemetry-reset", { reason = reason })
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

function Helpers.isTargetingMe(now)
    if not Context.player.Character then
        Context.runtime.targetingGraceUntil = 0
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

    if ok and result ~= nil then
        Context.runtime.targetingGraceUntil = now + Constants.TARGETING_GRACE_SECONDS
        return true
    end

    if Context.runtime.targetingGraceUntil > now then
        return true
    end

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
        pushTelemetryEvent("schedule-cleared", event)
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
    pushTelemetryEvent("schedule", event)
end


function Helpers.pressParry(ball: BasePart?, ballId: string?, force: boolean?)
    local forcing = force == true
    if Context.runtime.virtualInputUnavailable and Context.runtime.virtualInputRetryAt > os.clock() and not forcing then
        return false
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
    end

    TelemetryAnalytics.recordPress(pressEvent, scheduledSnapshot)
    pushTelemetryEvent("press", pressEvent)
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

    local mu =
        kinematics.filteredD
        - kinematics.filteredVr * delta
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

    if targetingMe then
        if telemetry.targetDetectedAt == nil then
            telemetry.targetDetectedAt = now
        end
    elseif not Context.runtime.parryHeld or Context.runtime.parryHeldBallId ~= ballId then
        telemetry.targetDetectedAt = nil
        telemetry.decisionAt = nil
    end
end

function PressDecision.computeApproach(state, kinematics, safeRadius)
    local approachSpeed = math.max(kinematics.filteredVr, kinematics.rawVr, 0)
    local approaching = approachSpeed > Constants.EPSILON
    local timeToImpactFallback = math.huge
    local timeToImpactPolynomial
    local timeToImpact = math.huge

    if approaching then
        local speed = math.max(approachSpeed, Constants.EPSILON)
        timeToImpactFallback = kinematics.distance / speed

        local impactRadial = kinematics.filteredD
        local polynomial =
            Helpers.solveRadialImpactTime(impactRadial, kinematics.filteredVr, kinematics.filteredAr, kinematics.filteredJr)
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
        state.curveLeadTime = curveLeadTime
        state.curveLeadDistance = math.max(severityBoost * kinematics.filteredVr * state.responseWindowBase, 0)
        state.curveHoldDistance =
            math.max(curveJerkSeverity * kinematics.filteredVr * PROXIMITY_HOLD_GRACE, 0)
        state.responseWindow = state.responseWindow + curveLeadTime
    end

    state.curveSeverity = curveSeverity
    state.curveJerkSeverity = curveJerkSeverity
end

function PressDecision.computeRadii(state, kinematics, safeRadius)
    local dynamicLeadBase
    if state.approaching then
        dynamicLeadBase = math.max(state.approachSpeed * PROXIMITY_PRESS_GRACE, safeRadius * 0.1)
    else
        dynamicLeadBase = safeRadius * 0.1
    end
    dynamicLeadBase = math.min(dynamicLeadBase, safeRadius * 0.5)

    local dynamicLead = 0
    if state.approaching then
        dynamicLead = math.max(state.approachSpeed * state.responseWindow, 0)
    end
    dynamicLead = math.min(dynamicLead, safeRadius * 0.5)

    state.curveLeadApplied = math.max(dynamicLead - dynamicLeadBase, 0)
    state.pressRadius = safeRadius + dynamicLead

    local holdLeadBase
    if state.approaching then
        holdLeadBase = math.max(state.approachSpeed * PROXIMITY_HOLD_GRACE, safeRadius * 0.1)
    else
        holdLeadBase = safeRadius * 0.1
    end
    holdLeadBase = math.min(holdLeadBase, safeRadius * 0.5)

    local holdLead = math.min(holdLeadBase + state.curveHoldDistance, safeRadius * 0.5)
    state.curveHoldApplied = math.max(holdLead - holdLeadBase, 0)
    state.holdRadius = state.pressRadius + holdLead
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
            Helpers.solveRadialImpactTime(radialToPress, kinematics.filteredVr, kinematics.filteredAr, kinematics.filteredJr)
        if pressPolynomial and pressPolynomial > Constants.EPSILON then
            timeToPressRadiusPolynomial = pressPolynomial
            timeToPressRadius = pressPolynomial
        else
            timeToPressRadius = timeToPressRadiusFallback
        end

        local holdPolynomial =
            Helpers.solveRadialImpactTime(radialToHold, kinematics.filteredVr, kinematics.filteredAr, kinematics.filteredJr)
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

    state.reactionBias = reactionBias
    state.scheduleSlack = scheduleSlack
    state.maxLookahead = maxLookahead
    state.lookaheadGoal = lookaheadGoal
    state.confidencePadding = confidencePadding
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
    local inequalityPress = state.targetingMe and state.muValid and state.sigmaValid and state.muPlus <= 0
    local confidencePress =
        state.targetingMe and state.muValid and state.sigmaValid and state.muPlus <= -state.confidencePadding

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

    local shouldPress = proximityPress or inequalityPress

    if telemetry then
        if shouldPress then
            telemetry.decisionAt = telemetry.decisionAt or now
        elseif not state.targetingMe then
            telemetry.decisionAt = nil
        end
    end

    local shouldHold = proximityHold
    if state.targetingMe and state.muValid and state.sigmaValid and state.muMinus < 0 then
        shouldHold = true
    end
    if shouldPress then
        shouldHold = true
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
    PressDecision.computeRadii(state, kinematics, safeRadius)
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

    return decision
end

function Helpers.renderLoop()
    if initialization.destroyed then
        Helpers.clearScheduledPress(nil, "destroyed")
        return
    end

    if not Context.player.LocalPlayer then
        Helpers.clearScheduledPress(nil, "missing-player")
        return
    end

    if not Context.player.Character or not Context.player.RootPart then
        Context.hooks.updateStatusLabel({ "Auto-Parry F", "Status: waiting for character" })
        Helpers.safeClearBallVisuals()
        Helpers.clearScheduledPress(nil, "missing-character")
        Helpers.releaseParry()
        return
    end

    Helpers.ensureBallsFolder(false)
    local folder = Context.player.BallsFolder
    if not folder then
        Context.hooks.updateStatusLabel({ "Auto-Parry F", "Ball: none", "Info: waiting for balls folder" })
        Helpers.safeClearBallVisuals()
        Helpers.clearScheduledPress(nil, "missing-balls-folder")
        Helpers.releaseParry()
        return
    end

    if not state.enabled then
        Helpers.clearScheduledPress(nil, "disabled")
        Helpers.releaseParry()
        Context.hooks.updateStatusLabel({ "Auto-Parry F", "Status: OFF" })
        Helpers.safeClearBallVisuals()
        Helpers.updateToggleButton()
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
        return
    end

    local ballId = Helpers.getBallIdentifier(ball)
    if not ballId then
        Context.hooks.updateStatusLabel({ "Auto-Parry F", "Ball: unknown", "Info: missing identifier" })
        Helpers.safeClearBallVisuals()
        Helpers.clearScheduledPress(nil, "missing-identifier")
        Helpers.releaseParry()
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
        oscillationTriggered = Helpers.evaluateOscillation(telemetry, now)
        if oscillationTriggered and Context.runtime.parryHeld and Context.runtime.parryHeldBallId == ballId then
            local lastApplied = telemetry.lastOscillationApplied or 0
            if now - lastApplied > (1 / 120) then
                spamFallback = Helpers.pressParry(ball, ballId, true)
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
                adaptiveBias = TelemetryAnalytics.adaptiveState and TelemetryAnalytics.adaptiveState.reactionBias or nil,
                lookaheadGoal = decision.lookaheadGoal,
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
        local readyToPress = decision.confidencePress or not decision.shouldDelay
        if not readyToPress and decision.predictedImpact <= decision.scheduleLead + activeSlack then
            readyToPress = true
        end

        if not readyToPress and existingSchedule then
            if now >= existingSchedule.pressAt - activeSlack then
                readyToPress = true
            end
        end

        if readyToPress then
            local pressed = Helpers.pressParry(ball, ballId)
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
            "Prox: press %s | hold %s",
            tostring(decision.proximityPress),
            tostring(decision.proximityHold)
        ),
        string.format("Targeting: %s", tostring(decision.targetingMe)),
        string.format(
            "Osc: trig %s | flips %d | freq %.2f | dΔ %.3f | spam %s",
            tostring(telemetry.oscillationActive),
            telemetry.lastOscillationCount or 0,
            telemetry.lastOscillationFrequency or 0,
            telemetry.lastOscillationDelta or 0,
            tostring(spamFallback)
        ),
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
        pushTelemetryEvent("config-adjustment", {
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
