local TestHarness = script.Parent.Parent
local Context = require(TestHarness:WaitForChild("Context"))

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
        local result = {}
        for key, item in pairs(value) do
            if type(key) == "string" or type(key) == "number" then
                result[key] = sanitizeValue(item)
            end
        end
        return result
    end

    return value
end

return function(t)
    t.test("smart tuning converges to configured targets", function(expect)
        local context = Context.createContext()
        local autoparry = context.autoparry

        autoparry.resetConfig()
        autoparry.configure({
            activationLatency = 0.04,
            pressReactionBias = 0,
            pressScheduleSlack = 0,
            pressConfidencePadding = 0,
            smartTuning = {
                enabled = true,
                minSlack = 0.01,
                maxSlack = 0.01,
                sigmaLead = 1,
                slackAlpha = 1,
                minConfidence = 0.06,
                maxConfidence = 0.06,
                sigmaConfidence = 1,
                confidenceAlpha = 1,
                reactionLatencyShare = 0.5,
                overshootShare = 0,
                reactionAlpha = 1,
                minReactionBias = 0.02,
                maxReactionBias = 0.02,
                deltaAlpha = 1,
                pingAlpha = 1,
                overshootAlpha = 1,
                sigmaFloor = 0.01,
                enforceBaseSlack = true,
                enforceBaseConfidence = true,
                enforceBaseReaction = true,
            },
        })

        autoparry.setEnabled(true)

        local events = {}
        local connection = autoparry.onTelemetry(function(event)
            events[#events + 1] = event
        end)

        local ball = context:addBall({
            name = "SmartTuningBall",
            position = Vector3.new(0, 0, 160),
            velocity = Vector3.new(0, 0, -150),
        })

        local parried = context:stepUntil(function()
            return #context.parryLog > 0
        end, { step = 1 / 240, maxSteps = 2000 })

        expect(parried):toEqual(true)
        expect(#context.parryLog > 0):toBeTruthy()
        expect(context.parryLog[1].ball):toEqual(ball)

        context:advance(0.2, { step = 1 / 240 })

        local smartSnapshot = context:getSmartTuningSnapshot()
        expect(smartSnapshot.enabled):toEqual(true)
        expect(math.abs((smartSnapshot.scheduleSlack or 0) - 0.01) <= 1e-3):toBeTruthy()
        expect(math.abs((smartSnapshot.confidencePadding or 0) - 0.06) <= 1e-3):toBeTruthy()
        expect(math.abs((smartSnapshot.reactionBias or 0) - 0.02) <= 1e-3):toBeTruthy()

        local scheduleEvent
        local pressEvent
        for _, event in ipairs(events) do
            if event.type == "schedule" then
                scheduleEvent = event
            elseif event.type == "press" then
                pressEvent = event
            end
        end

        expect(scheduleEvent ~= nil):toBeTruthy()
        expect(pressEvent ~= nil):toBeTruthy()

        expect(type(scheduleEvent.smartTuning) == "table"):toBeTruthy()
        expect(math.abs((scheduleEvent.smartTuning.applied.scheduleSlack or 0) - 0.01) <= 1e-3):toBeTruthy()
        expect(math.abs((scheduleEvent.smartTuning.applied.confidencePadding or 0) - 0.06) <= 1e-3):toBeTruthy()
        expect(math.abs((scheduleEvent.smartTuning.applied.reactionBias or 0) - 0.02) <= 1e-3):toBeTruthy()

        expect(type(pressEvent.smartTuning) == "table"):toBeTruthy()
        expect(math.abs((pressEvent.smartTuning.applied.scheduleSlack or 0) - 0.01) <= 1e-3):toBeTruthy()

        local pressState = context:getSmartPressState()
        expect(type(pressState.smartTuning) == "table"):toBeTruthy()

        if t.artifact then
            t.artifact("smart_tuning_snapshot", {
                tuning = sanitizeValue(smartSnapshot),
                scheduleEvent = sanitizeValue(scheduleEvent),
                pressEvent = sanitizeValue(pressEvent),
                pressState = sanitizeValue(pressState),
            })
        end

        if connection then
            connection:Disconnect()
        end
        context:destroy()
    end)
end
