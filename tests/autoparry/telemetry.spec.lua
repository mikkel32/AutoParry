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

        local diagnostics = autoparry.getDiagnosticsReport()
        expect(type(diagnostics) == "table"):toBeTruthy()
        expect((diagnostics.counters and diagnostics.counters.press) or 0):toBeGreaterThanOrEqual(1)
        expect(type(diagnostics.summary) == "table"):toBeTruthy()

        local scheduleEvent = findEvent(events, "schedule")
        expect(scheduleEvent ~= nil):toBeTruthy()

        local pressEvent = findEvent(events, "press")
        expect(pressEvent ~= nil):toBeTruthy()

        local latencyEvent = findEvent(events, "latency-sample")
        expect(latencyEvent ~= nil):toBeTruthy()

        expect(type(scheduleEvent.smartTuning) == "table"):toBeTruthy()
        expect(type(pressEvent.smartTuning) == "table"):toBeTruthy()
        expect(type(scheduleEvent.smartTuning.applied) == "table"):toBeTruthy()

        expect(type(scheduleEvent.ballId) == "string"):toBeTruthy()
        expect(scheduleEvent.ballId):toEqual(pressEvent.ballId)
        expect(pressEvent.time >= scheduleEvent.time):toBeTruthy()

        if scheduleEvent.pressAt then
            local delta = math.abs(pressEvent.time - scheduleEvent.pressAt)
            expect(delta <= 0.05):toBeTruthy()
        end

        expect(latencyEvent.source):toEqual("local")
        expect(latencyEvent.accepted):toEqual(true)
        expect(type(latencyEvent.value) == "number"):toBeTruthy()
        expect(latencyEvent.value > 0):toBeTruthy()

        local historyTypes = {}
        for _, event in ipairs(snapshot.history) do
            historyTypes[#historyTypes + 1] = event.type
        end

        expect(table.find(historyTypes, "schedule") ~= nil):toBeTruthy()
        expect(table.find(historyTypes, "press") ~= nil):toBeTruthy()
        expect(table.find(historyTypes, "latency-sample") ~= nil):toBeTruthy()

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
