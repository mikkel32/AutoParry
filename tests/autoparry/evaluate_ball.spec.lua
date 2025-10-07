local TestHarness = script.Parent.Parent
local Harness = require(TestHarness:WaitForChild("Harness"))

local Scheduler = Harness.Scheduler

local function cloneTable(source)
    if not source then
        return {}
    end
    return table.clone(source)
end

local function createBallsFolder(config)
    local folder = {
        Name = config.ballsFolderName,
        _children = {},
    }

    function folder:Add(child)
        table.insert(self._children, child)
        child.Parent = self
        return child
    end

    function folder:GetChildren()
        return table.clone(self._children)
    end

    function folder:Clear()
        for index = #self._children, 1, -1 do
            local child = table.remove(self._children, index)
            child.Parent = nil
        end
    end

    return folder
end

local function instantiateBall(options)
    local ball = {
        Name = options.name or "Ball",
        Position = options.position or Vector3.new(),
        AssemblyLinearVelocity = options.velocity or Vector3.new(),
        Parent = nil,
    }

    ball._classBehavior = options.classBehavior or function(_, className)
        return className == "BasePart"
    end
    ball._realBall = options.realBall
    ball._attributes = cloneTable(options.attributes)

    function ball:IsA(className)
        return self._classBehavior(self, className)
    end

    function ball:GetAttribute(name)
        if name == "realBall" then
            if self._realBall ~= nil then
                return self._realBall
            end
        end
        return self._attributes[name]
    end

    function ball:SetPosition(position)
        self.Position = position
    end

    function ball:SetVelocity(velocity)
        self.AssemblyLinearVelocity = velocity
    end

    function ball:SetRealBall(value)
        self._realBall = value
    end

    function ball:SetClassBehavior(fn)
        self._classBehavior = fn
    end

    function ball:SetAttribute(name, value)
        self._attributes[name] = value
    end

    function ball:Clone()
        return instantiateBall({
            name = self.Name,
            position = self.Position,
            velocity = self.AssemblyLinearVelocity,
            realBall = self._realBall,
            attributes = cloneTable(self._attributes),
            classBehavior = self._classBehavior,
        })
    end

    return ball
end

local BallBuilder = {}
BallBuilder.__index = BallBuilder

function BallBuilder.new(config)
    return setmetatable({
        name = "BallTemplate",
        position = Vector3.new(0, 0, config.safeRadius + 30),
        velocity = Vector3.new(0, 0, -(config.minSpeed + 20)),
        realBall = true,
        classBehavior = function(_, className)
            return className == "BasePart"
        end,
        attributes = {},
    }, BallBuilder)
end

function BallBuilder:copy()
    local copy = {
        name = self.name,
        position = self.position,
        velocity = self.velocity,
        realBall = self.realBall,
        classBehavior = self.classBehavior,
        attributes = cloneTable(self.attributes),
    }
    return setmetatable(copy, BallBuilder)
end

function BallBuilder:withPosition(position)
    local copy = self:copy()
    copy.position = position
    return copy
end

function BallBuilder:withVelocity(velocity)
    local copy = self:copy()
    copy.velocity = velocity
    return copy
end

function BallBuilder:withRealBall(value)
    local copy = self:copy()
    copy.realBall = value
    return copy
end

function BallBuilder:withClassBehavior(fn)
    local copy = self:copy()
    copy.classBehavior = fn
    return copy
end

function BallBuilder:withName(name)
    local copy = self:copy()
    copy.name = name
    return copy
end

function BallBuilder:build(folder)
    local ball = instantiateBall({
        name = self.name,
        position = self.position,
        velocity = self.velocity,
        realBall = self.realBall,
        attributes = cloneTable(self.attributes),
        classBehavior = self.classBehavior,
    })

    if folder then
        folder:Add(ball)
    end

    return ball
end

local function createContext()
    local scheduler = Scheduler.new(0.25)
    local services, remotes = Harness.createBaseServices(scheduler, {
        initialLocalPlayer = { Name = "LocalPlayer" },
    })

    remotes:Add(Harness.createParryButtonPress({ scheduler = scheduler }))

    local autoparry = Harness.loadAutoparry({
        scheduler = scheduler,
        services = services,
    })

    local internals = Harness.extractInternals(autoparry)
    local evaluateBall = internals.evaluateBall
    local config = autoparry.getConfig()
    local folder = createBallsFolder(config)

    return {
        scheduler = scheduler,
        autoparry = autoparry,
        evaluateBall = evaluateBall,
        config = config,
        ballsFolder = folder,
        rootPosition = Vector3.new(),
    }
end

local function computeExpectedTti(ball, rootPosition, pingSeconds, config)
    local toPlayer = rootPosition - ball.Position
    local distance = toPlayer.Magnitude
    local toward = ball.AssemblyLinearVelocity:Dot(toPlayer.Unit)
    local rawTti = distance / toward
    return rawTti - (pingSeconds + config.pingOffset)
end

local function assertAnalysis(expect, analysis, ball, rootPosition)
    expect(analysis ~= nil):toBeTruthy()
    expect(analysis.ball).toEqual(ball)
    expect(analysis.rootPosition).toEqual(rootPosition)
    return analysis.tti
end

return function(t)
    t.test("evaluateBall rejects clones that are not BaseParts", function(expect)
        local context = createContext()
        local builder = BallBuilder.new(context.config)
        local ball = builder
            :withClassBehavior(function()
                return false
            end)
            :withName("NotBasePart")
            :build(context.ballsFolder)

        local analysis = context.evaluateBall(ball, context.rootPosition, 0)
        expect(analysis == nil):toBeTruthy()
        context.autoparry.destroy()
    end)

    t.test("evaluateBall rejects clones without the realBall attribute", function(expect)
        local context = createContext()
        local builder = BallBuilder.new(context.config)
        local ball = builder:withRealBall(false):build(context.ballsFolder)

        local analysis = context.evaluateBall(ball, context.rootPosition, 0)
        expect(analysis == nil):toBeTruthy()
        context.autoparry.destroy()
    end)

    t.test("evaluateBall rejects clones moving slower than the minimum speed", function(expect)
        local context = createContext()
        local builder = BallBuilder.new(context.config)
        local slowSpeed = context.config.minSpeed * 0.5
        local ball = builder
            :withVelocity(Vector3.new(0, 0, -slowSpeed))
            :build(context.ballsFolder)

        local analysis = context.evaluateBall(ball, context.rootPosition, 0)
        expect(analysis == nil):toBeTruthy()
        context.autoparry.destroy()
    end)

    t.test("evaluateBall returns zero when the clone overlaps the root position", function(expect)
        local context = createContext()
        local builder = BallBuilder.new(context.config)
        local ball = builder
            :withPosition(context.rootPosition)
            :build(context.ballsFolder)

        local analysis = context.evaluateBall(ball, context.rootPosition, 0)
        local tti = assertAnalysis(expect, analysis, ball, context.rootPosition)
        expect(tti):toEqual(0)
        expect(analysis.immediate):toEqual(true)
        context.autoparry.destroy()
    end)

    t.test("evaluateBall rejects clones that are not travelling toward the player", function(expect)
        local context = createContext()
        local builder = BallBuilder.new(context.config)
        local awayVelocity = Vector3.new(0, 0, context.config.minSpeed + 10)
        local ball = builder
            :withVelocity(awayVelocity)
            :build(context.ballsFolder)

        local analysis = context.evaluateBall(ball, context.rootPosition, 0)
        expect(analysis == nil):toBeTruthy()
        context.autoparry.destroy()
    end)

    t.test("evaluateBall rejects clones travelling perpendicular to the player", function(expect)
        local context = createContext()
        local builder = BallBuilder.new(context.config)
        local sidewaysVelocity = Vector3.new(context.config.minSpeed + 15, 0, 0)
        local ball = builder
            :withVelocity(sidewaysVelocity)
            :build(context.ballsFolder)

        local analysis = context.evaluateBall(ball, context.rootPosition, 0)
        expect(analysis == nil):toBeTruthy()
        context.autoparry.destroy()
    end)

    t.test("evaluateBall returns zero when the clone is inside the safe radius", function(expect)
        local context = createContext()
        local builder = BallBuilder.new(context.config)
        local insideDistance = context.config.safeRadius - 1
        local position = Vector3.new(0, 0, insideDistance)
        local velocity = Vector3.new(0, 0, -(context.config.minSpeed + 20))
        local ball = builder
            :withPosition(position)
            :withVelocity(velocity)
            :build(context.ballsFolder)

        local analysis = context.evaluateBall(ball, context.rootPosition, 0)
        local tti = assertAnalysis(expect, analysis, ball, context.rootPosition)
        expect(tti):toEqual(0)
        expect(analysis.immediate):toEqual(true)
        context.autoparry.destroy()
    end)

    t.test("evaluateBall rejects clones with time-to-impact below the configured minimum", function(expect)
        local context = createContext()
        local builder = BallBuilder.new(context.config)
        local position = Vector3.new(0, 0, context.config.safeRadius + 1)
        local velocity = Vector3.new(0, 0, -(context.config.minSpeed + 100))
        local ball = builder
            :withPosition(position)
            :withVelocity(velocity)
            :build(context.ballsFolder)

        local analysis = context.evaluateBall(ball, context.rootPosition, 0)
        expect(analysis == nil):toBeTruthy()
        context.autoparry.destroy()
    end)

    t.test("evaluateBall rejects clones with time-to-impact above the configured maximum", function(expect)
        local context = createContext()
        local builder = BallBuilder.new(context.config)
        local distance = context.config.safeRadius + 120
        local position = Vector3.new(0, 0, distance)
        local velocity = Vector3.new(0, 0, -(context.config.minSpeed + 1))
        local ball = builder
            :withPosition(position)
            :withVelocity(velocity)
            :build(context.ballsFolder)

        local analysis = context.evaluateBall(ball, context.rootPosition, 0)
        expect(analysis == nil):toBeTruthy()
        context.autoparry.destroy()
    end)

    t.test("evaluateBall returns a positive time-to-impact within configured bounds", function(expect)
        local context = createContext()
        local builder = BallBuilder.new(context.config)
        local distance = context.config.safeRadius + 20
        local position = Vector3.new(0, 0, distance)
        local speed = context.config.minSpeed + 60
        local velocity = Vector3.new(5, -3, -speed)
        local ball = builder
            :withPosition(position)
            :withVelocity(velocity)
            :build(context.ballsFolder)

        local pingSeconds = 0.01
        local analysis = context.evaluateBall(ball, context.rootPosition, pingSeconds)
        local tti = assertAnalysis(expect, analysis, ball, context.rootPosition)

        local expected = computeExpectedTti(ball, context.rootPosition, pingSeconds, context.config)
        expect(tti):toBeCloseTo(expected, 1e-3)
        expect(tti):toBeGreaterThanOrEqual(context.config.minTTI)
        expect(tti <= context.config.maxTTI):toBeTruthy()
        context.autoparry.destroy()
    end)

    t.test("evaluateBall property: rejects random velocities moving away from the player", function(expect)
        local context = createContext()
        local builder = BallBuilder.new(context.config)
            :withPosition(Vector3.new(0, 0, context.config.safeRadius + 25))
        local random = Random.new(8675309)
        local iterations = 64

        for _ = 1, iterations do
            local speed = context.config.minSpeed + random:NextNumber(10, 120)
            local velocity = Vector3.new(
                random:NextNumber(-speed, speed),
                random:NextNumber(-speed, speed),
                random:NextNumber(5, speed)
            )

            local ball = builder:withVelocity(velocity):build(context.ballsFolder)
            local analysis = context.evaluateBall(ball, context.rootPosition, 0)
            expect(analysis == nil):toBeTruthy()
        end

        context.autoparry.destroy()
    end)

    t.test("evaluateBall property: stable TTI for random toward velocities", function(expect)
        local context = createContext()
        local builder = BallBuilder.new(context.config)
            :withPosition(Vector3.new(0, 0, context.config.safeRadius + 30))
        local random = Random.new(13579)
        local iterations = 64

        for _ = 1, iterations do
            local speed = random:NextNumber(context.config.minSpeed + 40, context.config.minSpeed + 120)
            local velocity = Vector3.new(
                random:NextNumber(-15, 15),
                random:NextNumber(-15, 15),
                -speed
            )

            local ball = builder:withVelocity(velocity):build(context.ballsFolder)
            local analysis = context.evaluateBall(ball, context.rootPosition, 0)
            local tti = assertAnalysis(expect, analysis, ball, context.rootPosition)

            local expected = computeExpectedTti(ball, context.rootPosition, 0, context.config)
            expect(tti):toBeCloseTo(expected, 1e-3)
            expect(tti):toBeGreaterThanOrEqual(context.config.minTTI)
            expect(tti <= context.config.maxTTI):toBeTruthy()
        end

        context.autoparry.destroy()
    end)
end
