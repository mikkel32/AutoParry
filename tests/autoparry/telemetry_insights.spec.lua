local TestHarness = script.Parent.Parent
local Context = require(TestHarness:WaitForChild("Context"))
local TelemetryUtils = require(TestHarness:WaitForChild("TelemetryTestUtils"))

return function(t)
    t.test("telemetry insights summarise performance", function(expect)
        local context = Context.createContext()
        local autoparry = context.autoparry

        autoparry.resetConfig()
        autoparry.configure({ smartTuning = false })

        local stats = TelemetryUtils.buildStats()
        local summary = TelemetryUtils.buildSummary(stats)

        local insights = autoparry.getTelemetryInsights({
            stats = stats,
            summary = summary,
            minSamples = 4,
        })

        expect(type(insights) == "table"):toBeTruthy()
        expect(insights.samples.press == summary.pressCount):toBeTruthy()
        expect(type(insights.metrics.successRate) == "number"):toBeTruthy()
        expect(insights.adjustments.status == "updates"):toBeTruthy()
        expect(type(insights.recommendations) == "table"):toBeTruthy()
        expect(type(insights.statuses) == "table"):toBeTruthy()
        expect(type(insights.autoTuning) == "table"):toBeTruthy()
        context:destroy()
    end)

    t.test("telemetry insights warn when dataset is small", function(expect)
        local context = Context.createContext()
        local autoparry = context.autoparry

        autoparry.resetConfig()
        autoparry.configure({ smartTuning = false })

        local stats = TelemetryUtils.buildStats({
            counters = { press = 2, schedule = 2, latency = 1 },
            press = { immediateCount = 0 },
        })
        local summary = TelemetryUtils.buildSummary(stats, {
            pressCount = 2,
            scheduleCount = 2,
            latencyCount = 1,
        })

        local insights = autoparry.getTelemetryInsights({
            stats = stats,
            summary = summary,
            minSamples = 6,
        })

        expect(insights.statuses.dataset.level == "warning"):toBeTruthy()
        expect(insights.severity == "warning" or insights.severity == "critical"):toBeTruthy()
        context:destroy()
    end)
end
