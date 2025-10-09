local TestHarness = script.Parent.Parent
local Context = require(TestHarness:WaitForChild("Context"))
local TelemetryUtils = require(TestHarness:WaitForChild("TelemetryTestUtils"))

return function(t)
    t.test("telemetry adjustments suggest config updates", function(expect)
        local context = Context.createContext()
        local autoparry = context.autoparry

        autoparry.resetConfig()
        autoparry.configure({
            pressReactionBias = 0.02,
            pressScheduleSlack = 0.005,
            activationLatency = 0.05,
            smartTuning = false,
        })

        local stats = TelemetryUtils.buildStats()
        local summary = TelemetryUtils.buildSummary(stats)

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
        expect(type(result.appliedAt) == "number"):toBeTruthy()

        context:destroy()
    end)

    t.test("insufficient telemetry defers adjustments", function(expect)
        local context = Context.createContext()
        local autoparry = context.autoparry

        autoparry.resetConfig()
        autoparry.configure({ smartTuning = false })

        local stats = TelemetryUtils.buildStats({
            counters = { press = 2 },
            press = { immediateCount = 1 },
        })
        local summary = TelemetryUtils.buildSummary(stats, {
            pressCount = 2,
            immediateCount = 1,
        })

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
