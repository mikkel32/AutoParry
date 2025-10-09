local TestHarness = script.Parent.Parent
local Context = require(TestHarness:WaitForChild("Context"))

local function buildStats(overrides)
    local stats = {
        counters = {
            press = 8,
            schedule = 8,
            latency = 4,
            success = 4,
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
        success = {
            latency = { mean = 0.11, count = 3 },
            acceptedCount = 3,
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

    for key, value in pairs(overrides or {}) do
        stats[key] = value
    end

    return stats
end

return function(t)
    t.test("telemetry adjustments suggest config updates", function(expect)
        local context = Context.createContext()
        local autoparry = context.autoparry

        autoparry.resetConfig()
        autoparry.configure({
            pressReactionBias = 0.02,
            pressScheduleSlack = 0.005,
            activationLatency = 0.05,
            pressConfidencePadding = 0.08,
            smartTuning = false,
        })

        local stats = buildStats()
        local summary = {
            pressCount = stats.counters.press,
            averageWaitDelta = stats.press.waitDelta.mean,
            averageActivationLatency = stats.latency.activation.mean,
            averageLatency = stats.latency.accepted.mean,
            leadDeltaMean = stats.timeline.leadDelta.mean,
            achievedLeadMean = stats.timeline.achievedLead.mean,
            scheduleLifetimeMean = stats.timeline.scheduleLifetime.mean,
            adaptiveBias = stats.adaptiveState.reactionBias,
            cancellationCount = stats.cancellations.total,
            topCancellationReason = nil,
            immediateCount = stats.press.immediateCount,
            immediateRate = stats.press.immediateCount / stats.counters.press,
            successCount = stats.counters.success,
            acceptedSuccessCount = stats.success.acceptedCount,
            successRate = stats.counters.success / stats.counters.press,
            acceptedSuccessRate = stats.success.acceptedCount / stats.counters.press,
            latencyCount = stats.counters.latency,
            latencyAcceptedCount = stats.latency.counters.accepted,
            latencyAcceptanceRate = stats.latency.counters.accepted / stats.counters.latency,
        }

        local adjustments = autoparry.buildTelemetryAdjustments({
            stats = stats,
            summary = summary,
            allowWhenSmartTuning = true,
        })

        expect(type(adjustments) == "table"):toBeTruthy()
        expect(type(adjustments.updates) == "table"):toBeTruthy()
        expect(type(adjustments.reasons) == "table"):toBeTruthy()
        expect(adjustments.status == "updates"):toBeTruthy()
        expect(adjustments.updates.pressReactionBias ~= nil):toBeTruthy()
        expect(adjustments.deltas.pressReactionBias > 0):toBeTruthy()
        expect(adjustments.updates.pressScheduleSlack ~= nil):toBeTruthy()
        expect(adjustments.deltas.pressScheduleSlack > 0):toBeTruthy()
        expect(adjustments.updates.activationLatency ~= nil):toBeTruthy()
        expect(adjustments.updates.activationLatency > 0.05):toBeTruthy()
        expect(adjustments.updates.pressConfidencePadding ~= nil):toBeTruthy()
        expect(adjustments.deltas.pressConfidencePadding > 0):toBeTruthy()
        expect(#adjustments.reasons > 0):toBeTruthy()

        local before = autoparry.getConfig()
        local result = autoparry.applyTelemetryAdjustments({
            stats = stats,
            summary = summary,
            allowWhenSmartTuning = true,
        })

        expect(result.newConfig.pressReactionBias > before.pressReactionBias):toBeTruthy()
        expect(result.newConfig.pressScheduleSlack > before.pressScheduleSlack):toBeTruthy()
        expect(result.newConfig.activationLatency > before.activationLatency):toBeTruthy()
        expect(result.newConfig.pressConfidencePadding > before.pressConfidencePadding):toBeTruthy()
        expect(type(result.appliedAt) == "number"):toBeTruthy()

        context:destroy()
    end)

    t.test("insufficient telemetry defers adjustments", function(expect)
        local context = Context.createContext()
        local autoparry = context.autoparry

        autoparry.resetConfig()
        autoparry.configure({ smartTuning = false })

        local stats = {
            counters = { press = 2 },
        }
        local summary = {
            pressCount = 2,
        }

        local adjustments = autoparry.buildTelemetryAdjustments({
            stats = stats,
            summary = summary,
        })

        expect(adjustments.status == "insufficient"):toBeTruthy()
        expect(next(adjustments.updates)):toEqual(nil)
        expect(#adjustments.reasons >= 1):toBeTruthy()

        local before = autoparry.getConfig()
        local result = autoparry.applyTelemetryAdjustments({
            stats = stats,
            summary = summary,
            dryRun = true,
        })

        expect(result.newConfig.pressReactionBias):toEqual(before.pressReactionBias)
        expect(result.newConfig.pressScheduleSlack):toEqual(before.pressScheduleSlack)

        context:destroy()
    end)
end
