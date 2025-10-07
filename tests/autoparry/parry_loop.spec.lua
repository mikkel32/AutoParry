-- selene: allow(global_usage)
-- selene: allow(incorrect_standard_library_use)
local TestHarness = script.Parent.Parent
local Harness = require(TestHarness:WaitForChild("Harness"))

local Scheduler = Harness.Scheduler

local function createBall(options)
    options = options or {}

    local position = options.position or Vector3.new()
    local velocity = options.velocity or Vector3.new(0, 0, -140)

    local function computeCFrame(pos, vel)
        if vel and vel.Magnitude > 1e-3 then
            return CFrame.new(pos, pos + vel.Unit)
        end

        return CFrame.new(pos)
    end

    local ball = {
        Name = options.name or "TestBall",
        Position = position,
        AssemblyLinearVelocity = velocity,
        CFrame = options.cframe or computeCFrame(position, velocity),
        Parent = nil,
        _isReal = options.realBall ~= false,
        _attributes = {},
    }

    if options.attributes then
        for key, value in pairs(options.attributes) do
            ball._attributes[key] = value
        end
    end

    function ball:IsA(className)
        if className == "BasePart" then
            return true
        end
        return className == options.className
    end

    function ball:GetAttribute(name)
        if name == "realBall" then
            return self._isReal
        end
        return self._attributes[name]
    end

    function ball:SetPosition(newPosition)
        self.Position = newPosition
        self.CFrame = computeCFrame(newPosition, self.AssemblyLinearVelocity)
    end

    function ball:SetVelocity(newVelocity)
        self.AssemblyLinearVelocity = newVelocity
        self.CFrame = computeCFrame(self.Position, newVelocity)
    end

    function ball:SetRealBall(value)
        self._isReal = value
    end

    return ball
end

local BallsFolder = {}
BallsFolder.__index = BallsFolder

function BallsFolder.new(name)
    return setmetatable({
        Name = name or "Balls",
        _children = {},
    }, BallsFolder)
end

function BallsFolder:Add(ball)
    table.insert(self._children, ball)
    ball.Parent = self
    return ball
end

function BallsFolder:Remove(ball)
    for index, child in ipairs(self._children) do
        if child == ball then
            table.remove(self._children, index)
            child.Parent = nil
            break
        end
    end
end

function BallsFolder:GetChildren()
    return table.clone(self._children)
end

function BallsFolder:Clear()
    for index = #self._children, 1, -1 do
        local child = table.remove(self._children, index)
        child.Parent = nil
    end
end

local function createRunServiceStub()
    local connections = {}

    local heartbeat = {}

    function heartbeat:Connect(callback)
        table.insert(connections, callback)
        local index = #connections

        local connection = {}

        function connection.Disconnect()
            connections[index] = nil
        end

        connection.disconnect = connection.Disconnect
        return connection
    end

    local stub = { Heartbeat = heartbeat }

    function stub:step(deltaTime)
        for _, callback in ipairs(connections) do
            if callback then
                callback(deltaTime)
            end
        end
    end

    return stub
end

local luauTypeof = rawget(_G, "typeof")

local function isCallable(value)
    if luauTypeof then
        local ok, kind = pcall(luauTypeof, value)
        if ok and kind == "function" then
            return true
        end
    end

    return type(value) == "function"
end

local function createContext(options)
    options = options or {}
    local scheduler = Scheduler.new(1 / 120)
    local runService = createRunServiceStub()

    local highlightEnabled = true
    local highlight = { Name = "Highlight" }

    local rootPart = {
        Position = Vector3.new(),
        AssemblyLinearVelocity = Vector3.new(),
        CFrame = CFrame.new(),
    }
    local character

    character = {
        PrimaryPart = rootPart,
        FindFirstChild = function(_, name)
            if name == "Highlight" and highlightEnabled then
                return highlight
            end
            return nil
        end,
    }

    local player = {
        Name = "LocalPlayer",
        Character = character,
    }

    local stats = Harness.createStats({
        pingResponses = {
            { value = 0 },
        },
    })

    local services, remotes = Harness.createBaseServices(scheduler, {
        initialLocalPlayer = player,
        runService = runService,
        stats = stats,
    })

    local remote = Harness.createRemote(options.remote)
    remotes:Add(remote)

    local ballsFolder = BallsFolder.new("Balls")

    local workspaceStub = {
        Name = "Workspace",
        FindFirstChild = function(_, name)
            if name == ballsFolder.Name then
                return ballsFolder
            end
            return nil
        end,
    }

    local originalWorkspace = rawget(_G, "workspace")
    rawset(_G, "workspace", workspaceStub)

    local autoparry = Harness.loadAutoparry({
        scheduler = scheduler,
        services = services,
    })

    local originalClock = os.clock
    -- selene: allow(incorrect_standard_library_use)
    os.clock = function()
        return scheduler:clock()
    end

    local remoteLog = {}
    local instrumentedRemotes = {}

    local function hookRemote(remoteInstance)
        local methodName = remoteInstance._parryMethod or "FireServer"
        local original = remoteInstance[methodName]

        assert(isCallable(original), "Harness remote missing parry method")

        remoteInstance[methodName] = function(self, ...)
            table.insert(remoteLog, {
                timestamp = scheduler:clock(),
                payload = { ... },
            })
            return original(self, ...)
        end

        table.insert(instrumentedRemotes, {
            remote = remoteInstance,
            method = methodName,
            original = original,
        })

        return methodName
    end

    local context

    local function setActiveRemote(remoteInstance)
        local methodName = hookRemote(remoteInstance)
        if context then
            context.remote = remoteInstance
            context.remoteMethod = methodName
        end
        return methodName
    end

    local parryMethodName = setActiveRemote(remote)

    local parryLog = {}
    local parryConnection = autoparry.onParry(function(ball, timestamp)
        table.insert(parryLog, {
            ball = ball,
            timestamp = timestamp,
        })
    end)

    context = {
        scheduler = scheduler,
        runService = runService,
        autoparry = autoparry,
        remote = remote,
        remoteMethod = parryMethodName,
        remotes = remotes,
        remoteLog = remoteLog,
        parryLog = parryLog,
        ballsFolder = ballsFolder,
        rootPart = rootPart,
        character = character,
        setHighlightEnabled = function(flag)
            highlightEnabled = flag
        end,
    }

    function context:addBall(options)
        local ball = createBall(options)
        self.ballsFolder:Add(ball)
        return ball
    end

    function context:clearBalls()
        self.ballsFolder:Clear()
    end

    function context:step(deltaTime)
        local dt = deltaTime or 1 / 120
        self.scheduler:wait(dt)
        self.runService:step(dt)
    end

    function context:clearParryLog()
        for index = #parryLog, 1, -1 do
            parryLog[index] = nil
        end
        for index = #remoteLog, 1, -1 do
            remoteLog[index] = nil
        end
    end

    function context:removeParryRemote()
        if not self.remotes then
            return nil
        end

        local targetName = self.remote and self.remote.Name
        if not targetName then
            return nil
        end

        local removed = self.remotes:Remove(targetName)
        if removed == self.remote then
            self.remote = nil
            self.remoteMethod = nil
        end

        return removed
    end

    function context:attachParryRemote(remoteOptions)
        if not self.remotes then
            return nil
        end

        local newRemote = Harness.createRemote(remoteOptions)
        self.remotes:Add(newRemote)
        local methodName = setActiveRemote(newRemote)
        self.remote = newRemote
        self.remoteMethod = methodName
        return newRemote
    end

    function context:destroy()
        if parryConnection then
            parryConnection:Disconnect()
        end
        autoparry.destroy()
        -- selene: allow(incorrect_standard_library_use)
        os.clock = originalClock
        for index = #instrumentedRemotes, 1, -1 do
            local entry = instrumentedRemotes[index]
            entry.remote[entry.method] = entry.original
            instrumentedRemotes[index] = nil
        end
        if originalWorkspace == nil then
            rawset(_G, "workspace", nil)
        else
            rawset(_G, "workspace", originalWorkspace)
        end
    end

    return context
end

return function(t)
    t.test("parry loop fires when a valid threat enters the window", function(expect)
        local context = createContext()
        local autoparry = context.autoparry

        autoparry.resetConfig()
        autoparry.configure({
            minTTI = 0,
            pingOffset = 0,
            cooldown = 0.12,
        })

        local ball = context:addBall({
            name = "DirectThreat",
            position = Vector3.new(0, 0, 36),
            velocity = Vector3.new(0, 0, -180),
        })

        autoparry.setEnabled(true)
        context:step(1 / 60)

        expect(#context.parryLog).toEqual(1)
        expect(context.parryLog[1].ball).toEqual(ball)

        context:destroy()
    end)

    t.test("parry loop respects the cooldown before firing again", function(expect)
        local context = createContext()
        local autoparry = context.autoparry

        autoparry.resetConfig()
        autoparry.configure({
            minTTI = 0,
            pingOffset = 0,
            cooldown = 0.18,
        })

        context:addBall({
            name = "CooldownThreatA",
            position = Vector3.new(0, 0, 40),
            velocity = Vector3.new(0, 0, -200),
        })
        local secondBall = context:addBall({
            name = "CooldownThreatB",
            position = Vector3.new(0, 0, 50),
            velocity = Vector3.new(0, 0, -220),
        })

        autoparry.setEnabled(true)
        context:step(1 / 60)

        expect(#context.parryLog).toEqual(1)

        -- remove the first ball to mirror game behaviour where successful parries
        -- despawn the projectile immediately.
        local firstBall = context.parryLog[1].ball
        context.ballsFolder:Remove(firstBall)

        context:step(0.05)
        expect(#context.parryLog).toEqual(1)

        context:step(0.15)
        expect(#context.parryLog).toEqual(2)
        expect(context.parryLog[2].ball).toEqual(secondBall)

        context:destroy()
    end)

    t.test("parry loop waits for the highlight gate before firing", function(expect)
        local context = createContext()
        local autoparry = context.autoparry

        context:setHighlightEnabled(false)

        autoparry.resetConfig()
        autoparry.configure({
            minTTI = 0,
            pingOffset = 0,
            cooldown = 0.12,
        })

        local ball = context:addBall({
            name = "HighlightGatedThreat",
            position = Vector3.new(0, 0, 48),
            velocity = Vector3.new(0, 0, -200),
        })

        autoparry.setEnabled(true)
        context:step(1 / 60)

        expect(#context.parryLog).toEqual(0)

        context:setHighlightEnabled(true)
        context:step(1 / 60)

        expect(#context.parryLog).toEqual(1)
        expect(context.parryLog[1].ball).toEqual(ball)

        context:destroy()
    end)

    t.test("parry loop fires bindable parry remotes", function(expect)
        local context = createContext({
            remote = {
                kind = "BindableEvent",
            },
        })

        local autoparry = context.autoparry

        autoparry.resetConfig()
        autoparry.configure({
            minTTI = 0,
            pingOffset = 0,
            cooldown = 0.12,
        })

        local ball = context:addBall({
            name = "BindableThreat",
            position = Vector3.new(0, 0, 36),
            velocity = Vector3.new(0, 0, -180),
        })

        autoparry.setEnabled(true)
        context:step(1 / 60)

        expect(#context.parryLog).toEqual(1)
        expect(context.parryLog[1].ball).toEqual(ball)
        expect(context.remoteMethod).toEqual("Fire")
        expect(#context.remoteLog).toEqual(1)
        expect(context.remote.lastPayload).toEqual({})

        context:destroy()
    end)

    t.test("parry loop builds a legacy parry attempt payload", function(expect)
        local context = createContext({
            remote = {
                name = "ParryAttempt",
                kind = "RemoteEvent",
            },
        })

        local autoparry = context.autoparry

        autoparry.resetConfig()
        autoparry.configure({
            minTTI = 0,
            pingOffset = 0,
            cooldown = 0.12,
        })

        local ball = context:addBall({
            name = "LegacyThreat",
            position = Vector3.new(0, 0, 36),
            velocity = Vector3.new(0, 0, -180),
        })

        autoparry.setEnabled(true)
        context:step(1 / 60)

        expect(#context.parryLog).toEqual(1)
        expect(context.parryLog[1].ball).toEqual(ball)
        expect(context.remoteMethod).toEqual("FireServer")

        local payload = context.remote.lastPayload
        expect(#payload).toEqual(5)
        expect(type(payload[1])).toEqual("number")
        expect(payload[2]).toEqual(ball.CFrame)
        expect(type(payload[4])).toEqual("number")
        expect(type(payload[5])).toEqual("number")

        local snapshot = payload[3]
        expect(type(snapshot)).toEqual("table")
        local localEntry = snapshot["LocalPlayer"]
        expect(type(localEntry)).toEqual("table")
        expect(localEntry.position).toEqual(context.rootPart.Position)
        expect(localEntry.velocity).toEqual(context.rootPart.AssemblyLinearVelocity)

        context:destroy()
    end)

    t.test("parry loop pauses while the parry remote is missing and recovers once replaced", function(expect)
        local context = createContext()
        local autoparry = context.autoparry

        autoparry.resetConfig()
        autoparry.configure({
            minTTI = 0,
            pingOffset = 0,
            cooldown = 0.12,
        })

        local firstBall = context:addBall({
            name = "InitialThreat",
            position = Vector3.new(0, 0, 36),
            velocity = Vector3.new(0, 0, -180),
        })

        autoparry.setEnabled(true)
        context:step(1 / 60)

        expect(#context.parryLog).toEqual(1)
        expect(context.parryLog[1].ball).toEqual(firstBall)
        expect(#context.remoteLog).toEqual(1)

        context:clearBalls()
        context:clearParryLog()

        local stalledBall = context:addBall({
            name = "StalledThreat",
            position = Vector3.new(0, 0, 36),
            velocity = Vector3.new(0, 0, -180),
        })

        context:removeParryRemote()

        for _ = 1, 5 do
            context:step(1 / 60)
        end

        expect(#context.parryLog).toEqual(0)
        expect(#context.remoteLog).toEqual(0)

        context:attachParryRemote()

        local readyObserved = false
        for _ = 1, 60 do
            context:step(1 / 60)
            if autoparry.getInitProgress().stage == "ready" then
                readyObserved = true
                break
            end
        end

        expect(readyObserved).toEqual(true)

        for _ = 1, 5 do
            context:step(1 / 60)
        end

        expect(#context.parryLog).toEqual(1)
        expect(context.parryLog[1].ball).toEqual(stalledBall)
        expect(#context.remoteLog).toEqual(1)

        context:destroy()
    end)
end
