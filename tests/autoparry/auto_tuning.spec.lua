local TestHarness = script.Parent.Parent
local Context = require(TestHarness:WaitForChild("Context"))
local TelemetryUtils = require(TestHarness:WaitForChild("TelemetryTestUtils"))

return function(t)
    t.test("auto tuning applies telemetry adjustments", function(expect)
        local context = Context.createContext()
        local autoparry = context.autoparry

        autoparry.resetConfig()
        autoparry.configure({
            pressReactionBias = 0.02,
            pressScheduleSlack = 0.005,
            activationLatency = 0.05,
            smartTuning = false,
            autoTuning = {
                enabled = true,
                intervalSeconds = 0,
                minSamples = 4,
                minDelta = 0,
                maxAdjustmentsPerRun = 2,
                dryRun = false,
            },
        })

        local stats = TelemetryUtils.buildStats()
        local summary = TelemetryUtils.buildSummary(stats)

        local before = autoparry.getConfig()
        local result, err = autoparry.runAutoTuning({
            stats = stats,
            summary = summary,
            force = true,
        })
        expect(err):toEqual(nil)
        expect(type(result) == "table"):toBeTruthy()
        local after = autoparry.getConfig()
        expect(result.status == "updates"):toBeTruthy()
        expect(result.updates.pressScheduleSlack > before.pressScheduleSlack):toBeTruthy()
        expect(result.updates.activationLatency > before.activationLatency):toBeTruthy()
        expect(after.pressScheduleSlack > before.pressScheduleSlack):toBeTruthy()
        expect(after.activationLatency > before.activationLatency):toBeTruthy()

        local autoState = autoparry.getAutoTuningState()
        expect(autoState.enabled):toBeTruthy()
        expect(autoState.lastStatus == result.status):toBeTruthy()
        expect(type(autoState.lastResult) == "table"):toBeTruthy()
        expect(autoState.lastResult.dryRun == false):toBeTruthy()

        context:destroy()
    end)

    t.test("auto tuning supports dry run and filtering", function(expect)
        local context = Context.createContext()
        local autoparry = context.autoparry

        autoparry.resetConfig()
        autoparry.configure({
            pressReactionBias = 0.02,
            pressScheduleSlack = 0.005,
            activationLatency = 0.05,
            smartTuning = false,
            autoTuning = {
                enabled = true,
                intervalSeconds = 0,
                minSamples = 1,
                minDelta = 0.05,
                maxAdjustmentsPerRun = 1,
                dryRun = true,
            },
        })

        local stats = TelemetryUtils.buildStats({
            press = {
                waitDelta = { mean = 0.001, count = 4 },
                activationLatency = { mean = 0.11, count = 4 },
            },
            timeline = {
                leadDelta = { mean = 0.0005, count = 4 },
            },
        })
        local summary = TelemetryUtils.buildSummary(stats)

        local before = autoparry.getConfig()
        local result, err = autoparry.runAutoTuning({
            stats = stats,
            summary = summary,
            force = true,
        })

        expect(err):toEqual(nil)
        expect(type(result) == "table"):toBeTruthy()
        expect(result.appliedAt).toEqual(nil)
        expect(autoparry.getConfig().pressReactionBias == before.pressReactionBias):toBeTruthy()
        expect(autoparry.getConfig().pressScheduleSlack == before.pressScheduleSlack):toBeTruthy()

        local autoState = autoparry.getAutoTuningState()
        expect(type(autoState.lastResult) == "table"):toBeTruthy()
        expect(autoState.lastResult.dryRun == true):toBeTruthy()

        context:destroy()
    end)
end
