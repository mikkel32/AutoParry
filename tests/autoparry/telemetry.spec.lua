local TestHarness = script.Parent.Parent
local Context = require(TestHarness:WaitForChild("Context"))

return function(t)
    local function findEvent(events, eventType)
        for _, event in ipairs(events) do
            if event.type == eventType then
                return event
            end
        end
        return nil
    end

    local function sanitizeValue(value)
        local valueType = typeof(value)

        if valueType == "Vector3" then
            return { x = value.X, y = value.Y, z = value.Z }
        elseif valueType == "CFrame" then
            local components = { value:GetComponents() }
            return { cframe = components }
        elseif valueType == "Color3" then
            return { r = value.R, g = value.G, b = value.B }
        elseif valueType == "EnumItem" then
            return tostring(value)
        elseif valueType == "Instance" then
            return { className = value.ClassName, name = value.Name }
        elseif valueType == "table" then
            local isArray = #value > 0
            local result = {}
            if isArray then
                for index, item in ipairs(value) do
                    result[index] = sanitizeValue(item)
                end
            else
                for key, item in pairs(value) do
                    if type(key) == "string" or type(key) == "number" then
                        if type(item) ~= "function" and type(item) ~= "thread" then
                            result[key] = sanitizeValue(item)
                        end
                    end
                end
            end
            return result
        end

        if type(value) == "function" or type(value) == "userdata" or type(value) == "thread" then
            return tostring(value)
        end

        return value
    end

    local function sanitizeEvents(eventList)
        local result = {}
        for index, event in ipairs(eventList) do
            result[index] = sanitizeValue(event)
        end
        return result
    end

    local function sanitizeParryLog(parryLog)
        local result = {}
        for index, entry in ipairs(parryLog) do
            local ball = entry.ball
            local ballPayload
            if typeof(ball) == "table" then
                ballPayload = {
                    name = ball.Name,
                    position = sanitizeValue(ball.Position),
                    velocity = sanitizeValue(ball.AssemblyLinearVelocity),
                }
            else
                ballPayload = sanitizeValue(ball)
            end

            result[index] = {
                timestamp = entry.timestamp,
                ball = ballPayload,
            }
        end
        return result
    end

    t.test("telemetry captures schedule, press, and latency details", function(expect)
        local context = Context.createContext()
        local autoparry = context.autoparry

        autoparry.resetConfig()
        autoparry.configure({
            minTTI = 0,
            pingOffset = 0,
            cooldown = 0.12,
            activationLatency = 0.08,
            pressMaxLookahead = 2.5,
            pressReactionBias = 0,
            pressConfidencePadding = 0.2,
            pressScheduleSlack = 0.01,
        })

        local events = {}
        local connection = autoparry.onTelemetry(function(event)
            events[#events + 1] = event
        end)

        autoparry.setEnabled(true)

        local ball = context:addBall({
            name = "TelemetryThreat",
            position = Vector3.new(0, 0, 180),
            velocity = Vector3.new(0, 0, -160),
        })

        local parried = context:stepUntil(function()
            return #context.parryLog > 0
        end, { step = 1 / 240, maxSteps = 1500 })

        expect(parried):toEqual(true)
        expect(#context.parryLog):toEqual(1)
        expect(context.parryLog[1].ball):toEqual(ball)

        context:advance(0.3, { step = 1 / 240 })

        local snapshot = autoparry.getTelemetrySnapshot()
        expect(type(snapshot.sequence) == "number"):toBeTruthy()
        expect(snapshot.history ~= nil):toBeTruthy()

        local smartSnapshot = autoparry.getSmartTuningSnapshot()
        expect(type(smartSnapshot) == "table"):toBeTruthy()

        expect(type(snapshot.smartTuning) == "table"):toBeTruthy()
        expect(type(smartSnapshot.enabled) == "boolean"):toBeTruthy()

        local stats = autoparry.getTelemetryStats()
        expect(type(stats) == "table"):toBeTruthy()
        expect((stats.counters and stats.counters.press) or 0):toBeGreaterThanOrEqual(1)
        expect((stats.press and stats.press.scheduledCount) or 0):toBeGreaterThanOrEqual(1)
        expect(((stats.press or {}).reactionTime or {}).count or 0):toBeGreaterThanOrEqual(1)
        expect(((stats.press or {}).decisionTime or {}).count or 0):toBeGreaterThanOrEqual(1)
        expect(((stats.press or {}).decisionToPressTime or {}).count or 0):toBeGreaterThanOrEqual(1)
        expect(type(stats.performance) == "table"):toBeTruthy()
        expect(((stats.performance or {}).ping or {}).count or 0):toBeGreaterThanOrEqual(1)

        local scheduleEvent = findEvent(events, "schedule")
        expect(scheduleEvent ~= nil):toBeTruthy()

        local pressEvent = findEvent(events, "press")
        expect(pressEvent ~= nil):toBeTruthy()

        expect(type(pressEvent.decision) == "table"):toBeTruthy()
        expect(type(pressEvent.decision.manifold) == "number"):toBeTruthy()
        expect(type(pressEvent.decision.simulationEnergy) == "number"):toBeTruthy()
        expect(type(pressEvent.decision.simulationUrgency) == "number"):toBeTruthy()
        expect(type(pressEvent.decision.weightedIntrusion) == "number"):toBeTruthy()
        expect(type(pressEvent.decision.ballisticGain) == "number"):toBeTruthy()

        local decisionSimulation = pressEvent.decision.simulation
        expect(type(decisionSimulation) == "table"):toBeTruthy()
        expect(type(decisionSimulation.peakIntrusion) == "number"):toBeTruthy()
        expect(type(decisionSimulation.urgency) == "number"):toBeTruthy()
        expect(type(decisionSimulation.quality) == "number"):toBeTruthy()
        expect(type(pressEvent.decision.threatScore) == "number"):toBeTruthy()
        expect(type(pressEvent.decision.threatStatus) == "string"):toBeTruthy()
        expect(type(pressEvent.decision.threatIntensity) == "number"):toBeTruthy()
        expect(type(pressEvent.decision.threatTempo) == "number"):toBeTruthy()
        expect(type(pressEvent.decision.threatConfidence) == "number"):toBeTruthy()
        expect(type(pressEvent.decision.threatLoad) == "number"):toBeTruthy()
        expect(type(pressEvent.decision.threatSpectralFast) == "number"):toBeTruthy()
        expect(type(pressEvent.decision.threatSpectralMedium) == "number"):toBeTruthy()
        expect(type(pressEvent.decision.threatSpectralSlow) == "number"):toBeTruthy()
        expect(type(pressEvent.decision.threatMomentum) == "number"):toBeTruthy()
        expect(type(pressEvent.decision.threatMomentumBoost) == "number" or pressEvent.decision.threatMomentumBoost == nil):toBeTruthy()
        expect(type(pressEvent.decision.threatVolatility) == "number"):toBeTruthy()
        expect(type(pressEvent.decision.threatStability) == "number"):toBeTruthy()
        expect(type(pressEvent.decision.threatStabilityBoost) == "number" or pressEvent.decision.threatStabilityBoost == nil):toBeTruthy()
        expect(type(pressEvent.decision.threatAcceleration) == "number"):toBeTruthy()
        expect(type(pressEvent.decision.threatJerk) == "number"):toBeTruthy()
        expect(type(pressEvent.decision.threatBoost) == "number"):toBeTruthy()
        expect(type(pressEvent.decision.threatInstantReady) == "boolean" or pressEvent.decision.threatInstantReady == nil):toBeTruthy()
        expect(type(pressEvent.decision.threatMomentumReady) == "boolean" or pressEvent.decision.threatMomentumReady == nil):toBeTruthy()
        expect(type(pressEvent.decision.threatReadinessMomentum) == "number" or pressEvent.decision.threatReadinessMomentum == nil):toBeTruthy()
        expect(type(pressEvent.decision.threatVolatilityPenalty) == "number" or pressEvent.decision.threatVolatilityPenalty == nil):toBeTruthy()
        expect(type(pressEvent.decision.threatLoadBoost) == "number" or pressEvent.decision.threatLoadBoost == nil):toBeTruthy()
        expect(type(pressEvent.decision.threatBudget) == "number" or pressEvent.decision.threatBudget == nil):toBeTruthy()
        expect(type(pressEvent.decision.threatBudgetHorizon) == "number" or pressEvent.decision.threatBudgetHorizon == nil):toBeTruthy()
        expect(type(pressEvent.decision.threatBudgetRatio) == "number" or pressEvent.decision.threatBudgetRatio == nil):toBeTruthy()
        expect(type(pressEvent.decision.threatBudgetPressure) == "number" or pressEvent.decision.threatBudgetPressure == nil):toBeTruthy()
        expect(type(pressEvent.decision.threatLatencyGap) == "number" or pressEvent.decision.threatLatencyGap == nil):toBeTruthy()
        expect(type(pressEvent.decision.threatBudgetReady) == "boolean" or pressEvent.decision.threatBudgetReady == nil):toBeTruthy()
        expect(type(pressEvent.decision.threatReadiness) == "number" or pressEvent.decision.threatReadiness == nil):toBeTruthy()
        expect(type(pressEvent.decision.threatBudgetConfidenceGain) == "number" or pressEvent.decision.threatBudgetConfidenceGain == nil):toBeTruthy()
        expect(type(pressEvent.decision.detectionConfidence) == "number"):toBeTruthy()
        expect(type(pressEvent.decision.detectionMomentumBoost) == "number" or pressEvent.decision.detectionMomentumBoost == nil):toBeTruthy()
        expect(type(pressEvent.decision.scheduleSlackScale) == "number" or pressEvent.decision.scheduleSlackScale == nil):toBeTruthy()
        expect(type(pressEvent.decision.proximitySimulationCached) == "boolean" or pressEvent.decision.proximitySimulationCached == nil):toBeTruthy()
        expect(type(pressEvent.decision.proximitySimulationCacheHits) == "number" or pressEvent.decision.proximitySimulationCacheHits == nil):toBeTruthy()
        expect(type(pressEvent.decision.proximitySimulationCacheStreak) == "number" or pressEvent.decision.proximitySimulationCacheStreak == nil):toBeTruthy()
        if pressEvent.decision.proximitySimulationCacheKey ~= nil then
            expect(type(pressEvent.decision.proximitySimulationCacheKey) == "string"):toBeTruthy()
        end

        local diagnostics = autoparry.getDiagnosticsReport()
        expect(type(diagnostics) == "table"):toBeTruthy()
        expect((diagnostics.counters and diagnostics.counters.press) or 0):toBeGreaterThanOrEqual(1)
        expect(type(diagnostics.summary) == "table"):toBeTruthy()
        expect(type(diagnostics.summary.averageReactionTime) == "number"):toBeTruthy()
        expect(type(diagnostics.summary.averageDecisionTime) == "number"):toBeTruthy()
        expect(type(diagnostics.summary.averageDecisionToPressTime) == "number"):toBeTruthy()
        expect(math.abs((diagnostics.summary.averageReactionTime or 0) - pressEvent.reactionTime) < 0.05):toBeTruthy()
        expect(type(diagnostics.summary.averageThreatScore) == "number"):toBeTruthy()
        expect(type(diagnostics.summary.averageThreatLoad) == "number"):toBeTruthy()
        expect(type(diagnostics.summary.averageThreatBoost) == "number"):toBeTruthy()
        expect(type(diagnostics.summary.averageThreatBudget) == "number"):toBeTruthy()
        expect(type(diagnostics.summary.averageThreatBudgetPressure) == "number"):toBeTruthy()
        expect(type(diagnostics.summary.averageThreatBudgetRatio) == "number"):toBeTruthy()
        expect(type(diagnostics.summary.averageThreatReadiness) == "number"):toBeTruthy()
        expect(type(diagnostics.summary.averageThreatLatencyGap) == "number"):toBeTruthy()
        expect(type(diagnostics.summary.averageThreatHorizon) == "number"):toBeTruthy()
        expect(type(diagnostics.summary.averageThreatBudgetConfidenceGain) == "number"):toBeTruthy()
        expect(type(diagnostics.summary.averageThreatBudgetReadyRate) == "number"):toBeTruthy()
        expect((diagnostics.stats and diagnostics.stats.threat and diagnostics.stats.threat.score and diagnostics.stats.threat.score.count) or 0):toBeGreaterThanOrEqual(1)
        expect((diagnostics.stats and diagnostics.stats.threat and diagnostics.stats.threat.load and diagnostics.stats.threat.load.count) or 0):toBeGreaterThanOrEqual(1)

        local latencyEvent = findEvent(events, "latency-sample")
        expect(latencyEvent ~= nil):toBeTruthy()

        expect(type(scheduleEvent.smartTuning) == "table"):toBeTruthy()
        expect(type(pressEvent.smartTuning) == "table"):toBeTruthy()
        expect(type(scheduleEvent.smartTuning.applied) == "table"):toBeTruthy()

        expect(type(scheduleEvent.ballId) == "string"):toBeTruthy()
        expect(scheduleEvent.ballId):toEqual(pressEvent.ballId)
        expect(pressEvent.time >= scheduleEvent.time):toBeTruthy()

        expect(type(pressEvent.reactionTime) == "number"):toBeTruthy()
        expect(pressEvent.reactionTime >= 0):toBeTruthy()
        expect(type(pressEvent.decisionTime) == "number"):toBeTruthy()
        expect(pressEvent.decisionTime >= 0):toBeTruthy()
        expect(pressEvent.decisionTime <= pressEvent.reactionTime + 1e-3):toBeTruthy()
        expect(type(pressEvent.decisionToPressTime) == "number"):toBeTruthy()
        expect(pressEvent.decisionToPressTime >= 0):toBeTruthy()

        if scheduleEvent.pressAt then
            local delta = math.abs(pressEvent.time - scheduleEvent.pressAt)
            expect(delta <= 0.05):toBeTruthy()
        end

        expect(latencyEvent.source):toEqual("local")
        expect(latencyEvent.accepted):toEqual(true)
        expect(type(latencyEvent.value) == "number"):toBeTruthy()
        expect(latencyEvent.value > 0):toBeTruthy()

        local threatEvent = findEvent(events, "threat")
        expect(threatEvent ~= nil):toBeTruthy()
        expect(type(threatEvent.score) == "number"):toBeTruthy()
        expect(type(threatEvent.status) == "string"):toBeTruthy()
        expect(type(threatEvent.intensity) == "number"):toBeTruthy()
        expect(type(threatEvent.confidence) == "number"):toBeTruthy()
        expect(type(threatEvent.detectionConfidence) == "number"):toBeTruthy()
        expect(type(threatEvent.momentum) == "number"):toBeTruthy()
        expect(type(threatEvent.volatility) == "number"):toBeTruthy()
        expect(type(threatEvent.stability) == "number"):toBeTruthy()
        expect(type(threatEvent.momentumBoost) == "number" or threatEvent.momentumBoost == nil):toBeTruthy()
        expect(type(threatEvent.readinessMomentum) == "number" or threatEvent.readinessMomentum == nil):toBeTruthy()
        expect(type(threatEvent.detectionMomentumBoost) == "number" or threatEvent.detectionMomentumBoost == nil):toBeTruthy()
        expect(type(threatEvent.momentumReady) == "boolean" or threatEvent.momentumReady == nil):toBeTruthy()
        expect(type(threatEvent.scheduleSlackScale) == "number" or threatEvent.scheduleSlackScale == nil):toBeTruthy()

        local historyTypes = {}
        for _, event in ipairs(snapshot.history) do
            historyTypes[#historyTypes + 1] = event.type
        end

        expect(table.find(historyTypes, "schedule") ~= nil):toBeTruthy()
        expect(table.find(historyTypes, "press") ~= nil):toBeTruthy()
        expect(table.find(historyTypes, "latency-sample") ~= nil):toBeTruthy()
        expect(table.find(historyTypes, "threat") ~= nil):toBeTruthy()

        if t.artifact then
            t.artifact("telemetry_timeline", {
                events = sanitizeEvents(events),
                snapshot = sanitizeValue(snapshot),
                parryLog = sanitizeParryLog(context.parryLog),
                smartTuningSnapshot = sanitizeValue(smartSnapshot),
                stats = sanitizeValue(stats),
                diagnostics = sanitizeValue(diagnostics),
            })
        end

        if connection then
            connection:Disconnect()
        end
        context:destroy()
    end)
end
