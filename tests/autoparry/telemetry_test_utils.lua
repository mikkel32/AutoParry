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
        schedule = {
            lead = { mean = 0.052, count = 8 },
            slack = { mean = 0.014, count = 8 },
            pingCompensation = { mean = 0.018, count = 8 },
            pingCompensationMinLead = { mean = 0.012, count = 8 },
            pingCompensationSlack = { mean = 0.009, count = 8 },
            pingCompensationJitter = { mean = 0.003, count = 8 },
            pingCompensationStress = { mean = 0.42, count = 8 },
            pingEffective = { mean = 0.052, count = 8 },
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
        performance = {
            ping = { mean = 0.042, count = 12 },
            pingJitter = { mean = 0.004, count = 12 },
            frameRate = { mean = 120, count = 12 },
            frameTime = { mean = 1 / 120, count = 12 },
            heartbeatTime = { mean = 1 / 120, count = 12 },
            physicsStep = { mean = 1 / 240, count = 12 },
            networkIn = { mean = 150, count = 12 },
            networkOut = { mean = 140, count = 12 },
            stressTotal = { mean = 0.6, count = 12 },
            stressLatency = { mean = 0.5, count = 12 },
            stressFrame = { mean = 0.3, count = 12 },
            stressNetwork = { mean = 0.2, count = 12 },
            stressPhysics = { mean = 0.1, count = 12 },
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
        averageScheduleLead = stats.schedule and stats.schedule.lead and stats.schedule.lead.mean or 0,
        averageScheduleSlack = stats.schedule and stats.schedule.slack and stats.schedule.slack.mean or 0,
        averageSchedulePingCompensation = stats.schedule and stats.schedule.pingCompensation and stats.schedule.pingCompensation.mean or 0,
        averageSchedulePingMinLead = stats.schedule and stats.schedule.pingCompensationMinLead and stats.schedule.pingCompensationMinLead.mean or 0,
        averageSchedulePingSlack = stats.schedule and stats.schedule.pingCompensationSlack and stats.schedule.pingCompensationSlack.mean or 0,
        averageSchedulePingJitter = stats.schedule and stats.schedule.pingCompensationJitter and stats.schedule.pingCompensationJitter.mean or 0,
        averageSchedulePingStress = stats.schedule and stats.schedule.pingCompensationStress and stats.schedule.pingCompensationStress.mean or 0,
        averageSchedulePingEffective = stats.schedule and stats.schedule.pingEffective and stats.schedule.pingEffective.mean or 0,
        adaptiveBias = stats.adaptiveState and stats.adaptiveState.reactionBias or 0,
        cancellationCount = stats.cancellations and stats.cancellations.total or 0,
        topCancellationReason = nil,
        topCancellationCount = 0,
        averagePing = stats.performance and stats.performance.ping and stats.performance.ping.mean or 0,
        averagePingJitter = stats.performance and stats.performance.pingJitter and stats.performance.pingJitter.mean or 0,
        averageFrameRate = stats.performance and stats.performance.frameRate and stats.performance.frameRate.mean or 0,
        averageFrameTime = stats.performance and stats.performance.frameTime and stats.performance.frameTime.mean or 0,
        averageHeartbeatTime = stats.performance and stats.performance.heartbeatTime and stats.performance.heartbeatTime.mean or 0,
        averagePhysicsStep = stats.performance and stats.performance.physicsStep and stats.performance.physicsStep.mean or 0,
        averageNetworkIn = stats.performance and stats.performance.networkIn and stats.performance.networkIn.mean or 0,
        averageNetworkOut = stats.performance and stats.performance.networkOut and stats.performance.networkOut.mean or 0,
        averagePerformanceStress = stats.performance and stats.performance.stressTotal and stats.performance.stressTotal.mean or 0,
        averageLatencyStress = stats.performance and stats.performance.stressLatency and stats.performance.stressLatency.mean or 0,
        averageFrameStress = stats.performance and stats.performance.stressFrame and stats.performance.stressFrame.mean or 0,
        averageNetworkStress = stats.performance and stats.performance.stressNetwork and stats.performance.stressNetwork.mean or 0,
        averagePhysicsStress = stats.performance and stats.performance.stressPhysics and stats.performance.stressPhysics.mean or 0,
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
