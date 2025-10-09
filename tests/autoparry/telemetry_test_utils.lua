local TelemetryTestUtils = {}

local function deepMerge(target, overrides)
    for key, value in pairs(overrides) do
        if type(value) == "table" and type(target[key]) == "table" then
            deepMerge(target[key], value)
        else
            target[key] = value
        end
    end
end

function TelemetryTestUtils.buildStats(overrides)
    local stats = {
        counters = {
            press = 8,
            schedule = 8,
            latency = 4,
        },
        press = {
            waitDelta = { mean = 0.016, count = 8 },
            actualWait = { mean = 0.032, count = 8 },
            activationLatency = { mean = 0.12, count = 8 },
            adaptiveBias = { mean = 0.01, count = 8 },
            immediateCount = 1,
            scheduledCount = 8,
            unscheduledCount = 0,
            forcedCount = 0,
            smart = {},
        },
        timeline = {
            leadDelta = { mean = -0.012, count = 8 },
            achievedLead = { mean = 0.035, count = 8 },
            scheduleLifetime = { mean = 0.042, count = 8 },
        },
        latency = {
            accepted = { mean = 0.14, count = 4 },
            activation = { mean = 0.14, count = 4 },
            localAccepted = { mean = 0.13, count = 2 },
            remoteAccepted = { mean = 0.15, count = 2 },
            counters = {
                accepted = 4,
                rejected = 0,
                localSamples = 2,
                remoteSamples = 2,
            },
        },
        cancellations = {
            total = 0,
            stale = 0,
            reasonCounts = {},
        },
        adaptiveState = {
            reactionBias = 0.01,
            lastUpdate = 0,
        },
    }

    if type(overrides) == "table" then
        deepMerge(stats, overrides)
    end

    return stats
end

function TelemetryTestUtils.buildSummary(stats, overrides)
    stats = stats or TelemetryTestUtils.buildStats()

    local counters = stats.counters or {}
    local summary = {
        pressCount = counters.press or 0,
        scheduleCount = counters.schedule or 0,
        latencyCount = counters.latency or 0,
        immediateCount = stats.press and stats.press.immediateCount or 0,
        averageWaitDelta = stats.press and stats.press.waitDelta and stats.press.waitDelta.mean or 0,
        averageActivationLatency = stats.latency and stats.latency.activation and stats.latency.activation.mean or 0,
        averageLatency = stats.latency and stats.latency.accepted and stats.latency.accepted.mean or 0,
        leadDeltaMean = stats.timeline and stats.timeline.leadDelta and stats.timeline.leadDelta.mean or 0,
        achievedLeadMean = stats.timeline and stats.timeline.achievedLead and stats.timeline.achievedLead.mean or 0,
        scheduleLifetimeMean = stats.timeline and stats.timeline.scheduleLifetime and stats.timeline.scheduleLifetime.mean or 0,
        adaptiveBias = stats.adaptiveState and stats.adaptiveState.reactionBias or 0,
        cancellationCount = stats.cancellations and stats.cancellations.total or 0,
        topCancellationReason = nil,
        topCancellationCount = 0,
    }

    if summary.pressCount > 0 then
        summary.immediateRate = summary.immediateCount / summary.pressCount
    else
        summary.immediateRate = 0
    end

    if type(overrides) == "table" then
        deepMerge(summary, overrides)
    end

    return summary
end

return TelemetryTestUtils
