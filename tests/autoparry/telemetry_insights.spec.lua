local TestHarness = script.Parent.Parent
local Context = require(TestHarness:WaitForChild("Context"))

local function buildStats()
    return {
        counters = {
            press = 10,
            schedule = 10,
            latency = 6,
            success = 6,
        },
        press = {
            waitDelta = { mean = 0.012, count = 10 },
            actualWait = { mean = 0.028, count = 10 },
            activationLatency = { mean = 0.11, count = 10 },
            adaptiveBias = { mean = 0.009, count = 10 },
            immediateCount = 2,
            scheduledCount = 10,
            unscheduledCount = 0,
            forcedCount = 1,
            smart = {},
        },
        timeline = {
            leadDelta = { mean = -0.009, count = 10 },
            achievedLead = { mean = 0.031, count = 10 },
            scheduleLifetime = { mean = 0.039, count = 10 },
        },
        latency = {
            accepted = { mean = 0.13, count = 6 },
            activation = { mean = 0.12, count = 6 },
            localAccepted = { mean = 0.12, count = 3 },
            remoteAccepted = { mean = 0.14, count = 3 },
            counters = {
                accepted = 4,
                rejected = 2,
                localSamples = 3,
                remoteSamples = 3,
            },
        },
        success = {
            latency = { mean = 0.1, count = 4 },
            acceptedCount = 4,
        },
        cancellations = {
            total = 2,
            stale = 1,
            reasonCounts = {
                ["ball-vanished"] = 1,
                ["prediction-timeout"] = 1,
            },
        },
        adaptiveState = {
            reactionBias = 0.012,
            lastUpdate = 0,
        },
    }
end

local function buildSummary(stats)
    return {
        pressCount = stats.counters.press,
        scheduleCount = stats.counters.schedule,
        latencyCount = stats.counters.latency,
        successCount = stats.counters.success,
        acceptedSuccessCount = stats.success.acceptedCount,
        successRate = stats.counters.success / stats.counters.press,
        acceptedSuccessRate = stats.success.acceptedCount / stats.counters.press,
        latencyAcceptedCount = stats.latency.counters.accepted,
        latencyAcceptanceRate = stats.latency.counters.accepted / stats.counters.latency,
        averageWaitDelta = stats.press.waitDelta.mean,
        averageActivationLatency = stats.latency.activation.mean,
        averageLatency = stats.latency.accepted.mean,
        leadDeltaMean = stats.timeline.leadDelta.mean,
        achievedLeadMean = stats.timeline.achievedLead.mean,
        scheduleLifetimeMean = stats.timeline.scheduleLifetime.mean,
        adaptiveBias = stats.adaptiveState.reactionBias,
        cancellationCount = stats.cancellations.total,
        topCancellationReason = "prediction-timeout",
        topCancellationCount = 1,
        immediateCount = stats.press.immediateCount,
        immediateRate = stats.press.immediateCount / stats.counters.press,
        cancellationRate = stats.cancellations.total / stats.counters.schedule,
    }
end

local function sanitize(value)
    local valueType = typeof(value)
    if valueType == "table" then
        local result = {}
        if #value > 0 then
            for index, item in ipairs(value) do
                result[index] = sanitize(item)
            end
        else
            for key, item in pairs(value) do
                if type(item) ~= "function" and type(item) ~= "thread" then
                    result[key] = sanitize(item)
                end
            end
        end
        return result
    end

    if valueType == "Vector3" then
        return { x = value.X, y = value.Y, z = value.Z }
    end
    if valueType == "CFrame" then
        local components = { value:GetComponents() }
        return { cframe = components }
    end
    if valueType == "EnumItem" then
        return tostring(value)
    end

    return value
end

return function(t)
    t.test("telemetry insights summarise reliability", function(expect)
        local context = Context.createContext()
        local autoparry = context.autoparry

        autoparry.resetConfig()
        autoparry.configure({ smartTuning = false })

        local stats = buildStats()
        local summary = buildSummary(stats)

        local insights = autoparry.getTelemetryInsights({
            stats = stats,
            summary = summary,
            allowWhenSmartTuning = true,
        })

        expect(type(insights) == "table"):toBeTruthy()
        expect(type(insights.summary) == "table"):toBeTruthy()
        expect(type(insights.stats) == "table"):toBeTruthy()
        expect(type(insights.flags) == "table"):toBeTruthy()
        expect(type(insights.focusAreas) == "table"):toBeTruthy()
        expect(type(insights.recommendations) == "table"):toBeTruthy()
        expect(type(insights.adjustments) == "table"):toBeTruthy()
        expect(type(insights.healthScore) == "number"):toBeTruthy()
        expect(insights.successRate):toEqual(summary.successRate)
        expect(insights.adjustments.status == "updates"):toBeTruthy()

        t.artifact("telemetry-insights", sanitize({
            status = insights.status,
            successRate = insights.successRate,
            acceptedSuccessRate = insights.acceptedSuccessRate,
            latencyAcceptanceRate = insights.latencyAcceptanceRate,
            healthScore = insights.healthScore,
            flags = insights.flags,
            focusAreas = insights.focusAreas,
            recommendations = insights.recommendations,
            adjustments = {
                status = insights.adjustments.status,
                updates = insights.adjustments.updates,
                reasons = insights.adjustments.reasons,
            },
        }))

        context:destroy()
    end)
end
