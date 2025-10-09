local TestHarness = script.Parent.Parent
local Context = require(TestHarness:WaitForChild("Context"))

local function sanitizeValue(value, visited)
    visited = visited or {}
    local valueType = typeof(value)

    if valueType == "Vector3" then
        return { x = value.X, y = value.Y, z = value.Z }
    elseif valueType == "CFrame" then
        return { cframe = { value:GetComponents() } }
    elseif valueType == "Color3" then
        return { r = value.R, g = value.G, b = value.B }
    elseif valueType == "EnumItem" then
        return tostring(value)
    elseif valueType == "Instance" then
        return { className = value.ClassName, name = value.Name }
    elseif valueType == "table" then
        if visited[value] then
            return "<cycle>"
        end

        visited[value] = true
        local result = {}
        for key, item in pairs(value) do
            if type(item) ~= "function" and type(item) ~= "thread" then
                result[key] = sanitizeValue(item, visited)
            end
        end
        visited[value] = nil
        return result
    end

    return value
end

return function(t)
    t.test("diagnostics aggregates telemetry metrics", function(expect)
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
            smartTuning = false,
        })

        autoparry.setEnabled(true)

        context:addBall({
            name = "DiagnosticsBallA",
            position = Vector3.new(0, 0, 150),
            velocity = Vector3.new(0, 0, -145),
        })

        local firstParried = context:stepUntil(function()
            return #context.parryLog >= 1
        end, { step = 1 / 240, maxSteps = 4000 })

        expect(firstParried):toEqual(true)

        context:advance(0.1, { step = 1 / 240 })
        context:clearBalls()

        context:addBall({
            name = "DiagnosticsBallB",
            position = Vector3.new(3, 0, 140),
            velocity = Vector3.new(0, 0, -138),
        })

        local secondParried = context:stepUntil(function()
            return #context.parryLog >= 2
        end, { step = 1 / 240, maxSteps = 4000 })

        expect(secondParried):toEqual(true)
        expect(#context.parryLog):toBeGreaterThanOrEqual(2)

        context:advance(0.4, { step = 1 / 240 })

        local stats = context:getTelemetryStats()
        local diagnostics = context:getDiagnosticsReport()

        expect(type(stats) == "table"):toBeTruthy()
        expect((stats.counters and stats.counters.press) or 0):toBeGreaterThanOrEqual(2)
        expect((stats.press and stats.press.scheduledCount) or 0):toBeGreaterThanOrEqual(1)

        expect(type(diagnostics) == "table"):toBeTruthy()
        expect(type(diagnostics.summary) == "table"):toBeTruthy()
        expect((diagnostics.summary.pressCount or 0)):toBeGreaterThanOrEqual(2)
        expect(type(diagnostics.recommendations) == "table"):toBeTruthy()

        if t.artifact then
            t.artifact("telemetry_diagnostics", {
                stats = sanitizeValue(stats),
                diagnostics = sanitizeValue(diagnostics),
                parries = sanitizeValue(context.parryLog),
            })
        end

        context:destroy()
    end)
end
