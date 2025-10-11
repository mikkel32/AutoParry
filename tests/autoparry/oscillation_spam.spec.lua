-- selene: allow(global_usage)
-- selene: allow(incorrect_standard_library_use)
local TestHarness = script.Parent.Parent
local RuntimeFolder = TestHarness:WaitForChild("engine")
local Runtime = require(RuntimeFolder:WaitForChild("runtime"))

local Scheduler = Runtime.Scheduler
local TelemetryTestUtils = require(script.Parent:WaitForChild("telemetry_test_utils"))

local function loadAutoparry()
    local scheduler = Scheduler.new(0.25)
    local services, remotes = Runtime.createBaseServices(scheduler, {
        initialLocalPlayer = { Name = "LocalPlayer" },
    })

    remotes:Add(Runtime.createParryButtonPress({ scheduler = scheduler }))

    local autoparry = Runtime.loadAutoParry({
        scheduler = scheduler,
        services = services,
    })

    return autoparry
end

return function(t)
    t.test("oscillation spam burst tightens gap for imminent hits", function(expect)
        local autoparry = loadAutoparry()
        local defaults = autoparry.getConfig()

        local baseline = autoparry._testEvaluateOscillationBurstTuning({})
        expect(math.abs(baseline.gap - defaults.oscillationSpamBurstGap) < 1e-6):toEqual(true)

        local aggressive = autoparry._testEvaluateOscillationBurstTuning({
            decision = {
                predictedImpact = 0.08,
                timeUntilPress = 0.08,
                scheduleSlack = 0.02,
            },
            kinematics = {
                velocityMagnitude = defaults.minSpeed + 60,
            },
        })

        expect(aggressive.gap < defaults.oscillationSpamBurstGap):toEqual(true)
        expect(aggressive.tightness > 0):toEqual(true)
        expect(aggressive.window >= aggressive.predictedImpact + defaults.activationLatency):toEqual(true)
        expect(aggressive.lookahead >= aggressive.predictedImpact + defaults.activationLatency):toEqual(true)

        autoparry.destroy()
    end)

    t.test("oscillation spam burst stays conservative for distant hits", function(expect)
        local autoparry = loadAutoparry()
        local defaults = autoparry.getConfig()

        local tempered = autoparry._testEvaluateOscillationBurstTuning({
            decision = {
                predictedImpact = 0.4,
                timeUntilPress = 0.4,
            },
            kinematics = {
                velocityMagnitude = defaults.minSpeed,
            },
        })

        expect(tempered.gap <= defaults.oscillationSpamBurstGap):toEqual(true)
        expect(tempered.gap):toBeGreaterThanOrEqual(defaults.oscillationSpamBurstGap * 0.7)
        expect(tempered.tightness <= 0.35):toEqual(true)

        autoparry.destroy()
    end)

    t.test("oscillation spam panic mode slashes gap and extends headroom", function(expect)
        local autoparry = loadAutoparry()
        local defaults = autoparry.getConfig()

        local panic = autoparry._testEvaluateOscillationBurstTuning({
            decision = {
                predictedImpact = 0.045,
                timeUntilPress = 0.045,
                scheduleSlack = defaults.oscillationSpamMinGap,
                confidence = 0.95,
                detectionAge = 0.02,
                minDetectionTime = 0.02,
            },
            kinematics = {
                velocityMagnitude = defaults.minSpeed + defaults.oscillationSpamPanicSpeedDelta + 15,
            },
            fallbackDecision = {
                predictedImpact = 0.05,
            },
        })

        expect(panic.panic):toEqual(true)
        expect(panic.panicGap <= panic.gap):toEqual(true)
        expect(panic.panicWindow):toBeGreaterThanOrEqual(panic.window)
        expect(panic.panicLookahead):toBeGreaterThanOrEqual(panic.lookahead)
        expect(panic.recoverySeconds > 0):toEqual(true)

        autoparry.destroy()
    end)

    t.test("oscillation spam gap honours configured minimum", function(expect)
        local autoparry = loadAutoparry()
        local defaults = autoparry.getConfig()

        local tuned = autoparry._testEvaluateOscillationBurstTuning({
            decision = {
                predictedImpact = 0.18,
                timeUntilPress = 0.18,
            },
        })

        expect(tuned.gap):toBeGreaterThanOrEqual(defaults.oscillationSpamMinGap)
        expect(tuned.panicGap):toBeGreaterThanOrEqual(defaults.oscillationSpamMinGap)

        autoparry.destroy()
    end)

    t.test("oscillation spam reacts to telemetry pressure for late presses", function(expect)
        local autoparry = loadAutoparry()
        local defaults = autoparry.getConfig()

        local baseline = autoparry._testEvaluateOscillationBurstTuning({
            decision = {
                predictedImpact = 0.09,
                timeUntilPress = 0.09,
                scheduleSlack = defaults.pressScheduleSlack,
                confidence = 0.9,
            },
            kinematics = {
                velocityMagnitude = defaults.minSpeed + 55,
            },
        })

        local aggressiveSummary = {
            pressCount = 40,
            scheduleCount = 36,
            averageWaitDelta = 0.012,
            leadDeltaMean = -0.007,
            commitLatencyP99 = 0.013,
            commitLatencySampleCount = 18,
            averageLatency = defaults.activationLatency + 0.04,
            cancellationCount = 1,
            immediateRate = 0.08,
            averageThreatSpeed = defaults.minSpeed + 65,
        }

        local tuned = autoparry._testEvaluateOscillationBurstTuning({
            decision = {
                predictedImpact = 0.09,
                timeUntilPress = 0.09,
                scheduleSlack = defaults.pressScheduleSlack,
                confidence = 0.92,
            },
            kinematics = {
                velocityMagnitude = defaults.minSpeed + 70,
            },
            summary = aggressiveSummary,
        })

        expect(tuned.statsSamples):toBeGreaterThanOrEqual(4)
        expect(tuned.statsAggression > 0.2):toEqual(true)
        expect(tuned.gap <= baseline.gap):toEqual(true)
        expect(tuned.panicGap <= tuned.gap):toEqual(true)
        expect(tuned.panicTightnessThreshold < baseline.panicTightnessThreshold):toEqual(true)
        expect(tuned.panicSlackLimit < baseline.panicSlackLimit):toEqual(true)

        autoparry.destroy()
    end)

    t.test("oscillation spam eases when telemetry shows generous slack", function(expect)
        local autoparry = loadAutoparry()
        local defaults = autoparry.getConfig()

        local baseline = autoparry._testEvaluateOscillationBurstTuning({
            decision = {
                predictedImpact = 0.2,
                timeUntilPress = 0.2,
                scheduleSlack = defaults.pressScheduleSlack,
                confidence = 0.7,
            },
        })

        local relaxedSummary = {
            pressCount = 42,
            scheduleCount = 42,
            averageWaitDelta = -0.011,
            leadDeltaMean = 0.009,
            commitLatencyP99 = 0.008,
            commitLatencySampleCount = 20,
            averageLatency = defaults.activationLatency - 0.02,
            cancellationCount = 12,
            immediateRate = 0.32,
            averageThreatSpeed = defaults.minSpeed + 5,
        }

        local tuned = autoparry._testEvaluateOscillationBurstTuning({
            decision = {
                predictedImpact = 0.2,
                timeUntilPress = 0.2,
                scheduleSlack = defaults.pressScheduleSlack * 1.2,
                confidence = 0.65,
            },
            summary = relaxedSummary,
        })

        expect(tuned.statsAggression < 0):toEqual(true)
        expect(tuned.gap):toBeGreaterThanOrEqual(baseline.gap)
        expect(tuned.panicGap):toBeGreaterThanOrEqual(tuned.gap)
        expect(tuned.panicSlackLimit):toBeGreaterThanOrEqual(baseline.panicSlackLimit)
        expect(tuned.panicTightnessThreshold):toBeGreaterThanOrEqual(baseline.panicTightnessThreshold)

        autoparry.destroy()
    end)

    t.test("oscillation spam widens safety window when lookahead collapses", function(expect)
        local autoparry = loadAutoparry()
        local defaults = autoparry.getConfig()

        local baseline = autoparry._testEvaluateOscillationBurstTuning({
            decision = {
                predictedImpact = 0.14,
                timeUntilPress = 0.14,
                scheduleSlack = defaults.pressScheduleSlack,
                confidence = 0.84,
            },
            summary = {
                pressCount = 30,
                scheduleCount = 28,
                averageWaitDelta = 0,
                averageLatency = defaults.activationLatency,
            },
        })

        local pressuredSummary = {
            pressCount = 42,
            scheduleCount = 40,
            averageWaitDelta = 0.01,
            averageLatency = defaults.activationLatency + 0.03,
            scheduleLookaheadP10 = defaults.pressScheduleSlack * 0.25,
            scheduleLookaheadMin = defaults.oscillationSpamMinGap * 0.6,
            averageThreatTempo = 18,
            averageThreatSpeed = defaults.minSpeed + 55,
        }

        local pressured = autoparry._testEvaluateOscillationBurstTuning({
            decision = {
                predictedImpact = 0.14,
                timeUntilPress = 0.14,
                scheduleSlack = defaults.pressScheduleSlack * 0.85,
                confidence = 0.9,
            },
            summary = pressuredSummary,
        })

        expect(pressured.statsLookaheadPressure ~= nil):toEqual(true)
        expect(pressured.window > baseline.window):toEqual(true)
        expect(pressured.panicWindow):toBeGreaterThanOrEqual(pressured.window)

        autoparry.destroy()
    end)

    t.test("oscillation spam trend momentum tightens cadence", function(expect)
        local autoparry = loadAutoparry()
        local defaults = autoparry.getConfig()

        local baseline = autoparry._testEvaluateOscillationBurstTuning({
            decision = {
                predictedImpact = 0.11,
                timeUntilPress = 0.11,
                scheduleSlack = defaults.pressScheduleSlack,
                confidence = 0.82,
            },
            summary = {
                pressCount = 28,
                scheduleCount = 28,
                averageWaitDelta = 0.004,
                averageLatency = defaults.activationLatency + 0.01,
            },
        })

        local trendy = autoparry._testEvaluateOscillationBurstTuning({
            decision = {
                predictedImpact = 0.11,
                timeUntilPress = 0.11,
                scheduleSlack = defaults.pressScheduleSlack * 0.9,
                confidence = 0.9,
            },
            summary = {
                pressCount = 36,
                scheduleCount = 34,
                averageWaitDelta = 0.012,
                averageLatency = defaults.activationLatency + 0.03,
                averageThreatSpeed = defaults.minSpeed + 60,
            },
            trend = {
                momentum = 1.15,
                samples = 6,
                updatedAt = os.clock(),
            },
        })

        expect(trendy.statsTrend ~= nil):toEqual(true)
        expect(trendy.panicTightnessThreshold <= baseline.panicTightnessThreshold):toEqual(true)

        autoparry.destroy()
    end)

    t.test("oscillation spam boosts cadence when reaction lags and misses rise", function(expect)
        local autoparry = loadAutoparry()
        local defaults = autoparry.getConfig()

        local baseline = autoparry._testEvaluateOscillationBurstTuning({
            decision = {
                predictedImpact = 0.11,
                timeUntilPress = 0.11,
                scheduleSlack = defaults.pressScheduleSlack,
                confidence = 0.82,
            },
            summary = {
                pressCount = 28,
                scheduleCount = 26,
                averageWaitDelta = 0.004,
                averageLatency = defaults.activationLatency + 0.01,
                averageReactionTime = defaults.pressReactionBias + 0.005,
                successRate = 0.92,
            },
        })

        local pressured = autoparry._testEvaluateOscillationBurstTuning({
            decision = {
                predictedImpact = 0.08,
                timeUntilPress = 0.08,
                scheduleSlack = defaults.pressScheduleSlack * 0.75,
                confidence = 0.94,
            },
            kinematics = {
                velocityMagnitude = defaults.minSpeed + 85,
            },
            summary = {
                pressCount = 42,
                scheduleCount = 38,
                averageWaitDelta = 0.015,
                averageLatency = defaults.activationLatency + 0.06,
                averageReactionTime = defaults.pressReactionBias + 0.03,
                averageDecisionToPressTime = 0.018,
                successRate = 0.68,
                pressMissCount = 14,
            },
        })

        expect(pressured.presses):toBeGreaterThanOrEqual(baseline.presses)
        expect(pressured.gap <= baseline.gap):toEqual(true)
        expect(pressured.statsReactionPressure > 0):toEqual(true)
        expect(pressured.statsMissPressure > 0):toEqual(true)
        expect(pressured.statsPressMissCount > 0):toEqual(true)
        expect(pressured.window):toBeGreaterThanOrEqual(baseline.window)
        expect(pressured.panicWindow):toBeGreaterThanOrEqual(pressured.window)

        autoparry.destroy()
    end)

    t.test("oscillation spam unlocks neuro focus when reactions stay razor sharp", function(expect)
        local autoparry = loadAutoparry()
        local defaults = autoparry.getConfig()

        local baseline = autoparry._testEvaluateOscillationBurstTuning({
            decision = {
                predictedImpact = 0.1,
                timeUntilPress = 0.1,
                scheduleSlack = defaults.pressScheduleSlack,
                confidence = 0.85,
            },
            kinematics = {
                velocityMagnitude = defaults.minSpeed + 55,
            },
            summary = {
                pressCount = 32,
                scheduleCount = 30,
                averageReactionTime = defaults.pressReactionBias,
                averageDecisionToPressTime = defaults.pressScheduleSlack,
                successRate = 0.94,
                immediateRate = 0.18,
                reactionFocusScore = 0,
                cognitiveLoadScore = 0,
            },
        })

        local focused = autoparry._testEvaluateOscillationBurstTuning({
            decision = {
                predictedImpact = 0.082,
                timeUntilPress = 0.082,
                scheduleSlack = defaults.pressScheduleSlack * 0.75,
                confidence = 0.94,
            },
            kinematics = {
                velocityMagnitude = defaults.minSpeed + 95,
            },
            summary = {
                pressCount = 60,
                scheduleCount = 58,
                averageReactionTime = math.max(defaults.pressReactionBias * 0.68, 0.004),
                reactionStdDev = defaults.oscillationSpamMinGap * 0.25,
                averageDecisionToPressTime = defaults.pressScheduleSlack * 0.42,
                decisionToPressStdDev = defaults.oscillationSpamMinGap * 0.35,
                decisionStdDev = defaults.oscillationSpamMinGap * 0.32,
                successRate = 0.99,
                immediateRate = 0.05,
                reactionFocusScore = 1.7,
                neuroTempoScore = 1.2,
                cognitiveLoadScore = -1.1,
            },
        })

        expect(focused.statsReactionFocus):toBeGreaterThanOrEqual(1)
        expect(math.abs(focused.statsReactionStdDev - defaults.oscillationSpamMinGap * 0.25) <= defaults.oscillationSpamMinGap * 0.001):toEqual(true)
        expect(focused.gap <= baseline.gap):toEqual(true)
        expect(focused.presses):toBeGreaterThanOrEqual(baseline.presses)
        expect(focused.lookahead):toBeGreaterThanOrEqual(baseline.lookahead)
        expect(focused.statsCognitiveLoad < 0):toEqual(true)

        autoparry.destroy()
    end)

    t.test("oscillation spam recognises cognitive overload and widens safety", function(expect)
        local autoparry = loadAutoparry()
        local defaults = autoparry.getConfig()

        local baseline = autoparry._testEvaluateOscillationBurstTuning({
            decision = {
                predictedImpact = 0.135,
                timeUntilPress = 0.135,
                scheduleSlack = defaults.pressScheduleSlack,
                confidence = 0.82,
            },
            summary = {
                pressCount = 38,
                scheduleCount = 36,
                averageReactionTime = defaults.pressReactionBias + 0.01,
                averageDecisionToPressTime = defaults.pressScheduleSlack * 0.95,
                successRate = 0.9,
                reactionFocusScore = 0.2,
                cognitiveLoadScore = 0.1,
            },
        })

        local overloaded = autoparry._testEvaluateOscillationBurstTuning({
            decision = {
                predictedImpact = 0.14,
                timeUntilPress = 0.14,
                scheduleSlack = defaults.pressScheduleSlack * 1.3,
                confidence = 0.78,
            },
            summary = {
                pressCount = 64,
                scheduleCount = 60,
                averageReactionTime = defaults.pressReactionBias + 0.045,
                reactionStdDev = defaults.oscillationSpamMinGap * 1.05,
                averageDecisionToPressTime = defaults.pressScheduleSlack * 1.55,
                decisionToPressStdDev = defaults.oscillationSpamMinGap * 1.35,
                decisionStdDev = defaults.oscillationSpamMinGap * 1.25,
                successRate = 0.72,
                immediateRate = 0.3,
                pressMissCount = 22,
                reactionFocusScore = -1.3,
                neuroTempoScore = -0.9,
                cognitiveLoadScore = 2.1,
            },
        })

        expect(overloaded.statsCognitiveLoad):toBeGreaterThanOrEqual(1.5)
        expect(overloaded.gap):toBeGreaterThanOrEqual(baseline.gap)
        expect(overloaded.window):toBeGreaterThanOrEqual(baseline.window)
        expect(overloaded.panicSlackLimit):toBeGreaterThanOrEqual(baseline.panicSlackLimit)
        expect(overloaded.panicTightnessThreshold):toBeGreaterThanOrEqual(baseline.panicTightnessThreshold)

        autoparry.destroy()
    end)

    t.test("oscillation spam relaxes when success is high and reactions are sharp", function(expect)
        local autoparry = loadAutoparry()
        local defaults = autoparry.getConfig()

        local pressured = autoparry._testEvaluateOscillationBurstTuning({
            decision = {
                predictedImpact = 0.16,
                timeUntilPress = 0.16,
                scheduleSlack = defaults.pressScheduleSlack * 1.1,
                confidence = 0.78,
            },
            summary = {
                pressCount = 40,
                scheduleCount = 40,
                averageWaitDelta = -0.006,
                averageLatency = defaults.activationLatency - 0.015,
                averageReactionTime = defaults.pressReactionBias * 0.8,
                successRate = 0.98,
                pressMissCount = 1,
            },
        })

        expect(pressured.statsReactionPressure < 0):toEqual(true)
        expect(pressured.statsMissPressure <= 0):toEqual(true)
        expect(pressured.gap):toBeGreaterThanOrEqual(defaults.oscillationSpamMinGap)
        expect(pressured.presses <= defaults.oscillationSpamBurstPresses + 1):toEqual(true)
        expect(pressured.panic):toEqual(false)

        autoparry.destroy()
    end)

    t.test("oscillation spam tightens gap when adaptive slack debt spikes", function(expect)
        local autoparry = loadAutoparry()
        local defaults = autoparry.getConfig()

        local baseline = autoparry._testEvaluateOscillationBurstTuning({
            decision = {
                predictedImpact = 0.13,
                timeUntilPress = 0.13,
                scheduleSlack = defaults.pressScheduleSlack,
                confidence = 0.82,
            },
        })

        local summary = TelemetryTestUtils.buildSummary(nil, {
            pressCount = 54,
            scheduleCount = 50,
            averageScheduleSlack = defaults.pressScheduleSlack * 0.35,
            averageWaitDelta = 0.02,
            immediateRate = 0.28,
            successRate = 0.74,
            pressMissCount = 16,
            scheduleLookaheadP10 = defaults.pressScheduleSlack * 0.3,
            averageLatency = defaults.activationLatency + 0.05,
        })

        local tuned = autoparry._testEvaluateOscillationBurstTuning({
            decision = {
                predictedImpact = 0.11,
                timeUntilPress = 0.11,
                scheduleSlack = defaults.pressScheduleSlack * 0.7,
                confidence = 0.9,
            },
            summary = summary,
        })

        expect(tuned.gap < baseline.gap):toEqual(true)
        expect(tuned.window > baseline.window):toEqual(true)
        expect(tuned.statsSlackDebt):toBeTruthy()
        expect(tuned.statsBurstFatigue):toBeGreaterThanOrEqual(0)
        expect(tuned.statsImmediatePressure):toBeGreaterThanOrEqual(0)

        autoparry.destroy()
    end)

    t.test("oscillation spam eases when adaptive relief builds", function(expect)
        local autoparry = loadAutoparry()
        local defaults = autoparry.getConfig()

        local baseline = autoparry._testEvaluateOscillationBurstTuning({
            decision = {
                predictedImpact = 0.17,
                timeUntilPress = 0.17,
                scheduleSlack = defaults.pressScheduleSlack,
                confidence = 0.76,
            },
        })

        local summary = TelemetryTestUtils.buildSummary(nil, {
            pressCount = 60,
            scheduleCount = 60,
            averageScheduleSlack = defaults.pressScheduleSlack * 1.6,
            averageWaitDelta = -0.02,
            immediateRate = 0.08,
            successRate = 0.99,
            averageReactionTime = math.max(defaults.pressReactionBias * 0.7, 0.003),
            scheduleLookaheadP10 = defaults.pressScheduleSlack * 1.5,
            scheduleLookaheadMin = defaults.oscillationSpamMinGap * 1.4,
        })

        local tuned = autoparry._testEvaluateOscillationBurstTuning({
            decision = {
                predictedImpact = 0.2,
                timeUntilPress = 0.2,
                scheduleSlack = defaults.pressScheduleSlack * 1.45,
                confidence = 0.7,
            },
            summary = summary,
        })

        expect(tuned.gap):toBeGreaterThanOrEqual(baseline.gap)
        expect(tuned.window):toBeGreaterThanOrEqual(baseline.window)
        expect(tuned.statsSlackRelief):toBeTruthy()
        expect(tuned.statsImmediateRelief):toBeGreaterThanOrEqual(0)
        expect(tuned.statsBurstFatigue == nil or tuned.statsBurstFatigue <= (tuned.statsSlackRelief or 0) + 3):toEqual(true)

        autoparry.destroy()
    end)
end
