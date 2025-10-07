local TestHarness = script.Parent.Parent
local Harness = require(TestHarness:WaitForChild("Harness"))

local Scheduler = Harness.Scheduler

local function makeBall(distance, speed)
    local ball = {
        Position = Vector3.new(0, 0, distance),
        AssemblyLinearVelocity = Vector3.new(0, 0, -speed),
    }

    function ball:IsA(className)
        return className == "BasePart"
    end

    function ball:GetAttribute(name)
        if name == "realBall" then
            return true
        end
        return nil
    end

    return ball
end

local function computeBaseTti(ball, rootPos)
    local toPlayer = rootPos - ball.Position
    local distance = (ball.Position - rootPos).Magnitude
    local toward = ball.AssemblyLinearVelocity:Dot(toPlayer.Unit)
    return distance / toward
end

return function(t)
    t.test("evaluateBall subtracts ping and configured offset", function(expect)
        local scenarios = {
            {
                label = "stat-timeout",
                stub = { statError = "timeout" },
            },
            {
                label = "getvalue-timeout",
                stub = { valueError = "timeout" },
            },
            {
                label = "nil-value",
                stub = { valueIsNil = true },
            },
            {
                label = "high-latency",
                stub = { value = 150 },
            },
        }

        local pingResponses = {}
        for _, scenario in ipairs(scenarios) do
            table.insert(pingResponses, scenario.stub)
        end

        local scheduler = Scheduler.new(0.5)
        local stats = Harness.createStats({ pingResponses = pingResponses })

        local services, remotes = Harness.createBaseServices(scheduler, {
            initialLocalPlayer = { Name = "LocalPlayer" },
            stats = stats,
        })

        remotes:Add(Harness.createRemote())

        local autoparry = Harness.loadAutoparry({
            scheduler = scheduler,
            services = services,
        })

        local internals = Harness.extractInternals(autoparry)
        local evaluateBall = internals.evaluateBall
        local currentPing = internals.currentPing
        expect(type(evaluateBall) == "function"):toBeTruthy()
        expect(type(currentPing) == "function"):toBeTruthy()

        local config = autoparry.getConfig()
        local rootPosition = Vector3.new(0, 0, 0)
        local baselineBall = makeBall(15, 45)
        local baseTti = computeBaseTti(baselineBall, rootPosition)

        local observations = {}

        for index, scenario in ipairs(scenarios) do
            local pingSeconds = currentPing()
            local ball = makeBall(15, 45)
            local tti = evaluateBall(ball, rootPosition, pingSeconds)

            expect(tti ~= nil):toBeTruthy()

            local expectedAdjustment = pingSeconds + config.pingOffset
            local expectedTti = baseTti - expectedAdjustment
            expect(tti):toBeCloseTo(expectedTti, 1e-3)

            table.insert(observations, {
                sequence = index,
                scenario = scenario.label,
                pingSeconds = pingSeconds,
                expectedAdjustment = expectedAdjustment,
                adjustedTti = tti,
            })
        end

        if t.artifact then
            t.artifact("ping-tti", {
                baseTti = baseTti,
                pingOffset = config.pingOffset,
                observations = observations,
            })
        end

        autoparry.destroy()
    end)
end
