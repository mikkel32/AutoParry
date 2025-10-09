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

    function ball:IsDescendantOf(parent)
        local current = self.Parent
        while current do
            if current == parent then
                return true
            end
            current = current.Parent
        end
        return false
    end

    function ball:SetRealBall(value)
        self._isReal = value
    end

    function ball:_advance(dt)
        local velocity = self.AssemblyLinearVelocity
        if velocity then
            local newPosition = self.Position + velocity * dt
            self:SetPosition(newPosition)
        end
    end

    return ball
end

local BallsFolder = {}

local function createPropertySignals()
    return setmetatable({}, {
        __index = function(container, key)
            local signal = Harness.createSignal()
            rawset(container, key, signal)
            return signal
        end,
    })
end

function BallsFolder.new(name)
    local folder = {
        Name = name or "Balls",
        Parent = nil,
        ClassName = "Folder",
        _children = {},
        _propertySignals = createPropertySignals(),
        ChildAdded = Harness.createSignal(),
        ChildRemoved = Harness.createSignal(),
        Destroying = Harness.createSignal(),
        AncestryChanged = Harness.createSignal(),
    }

    local function rawUpdate(key, value)
        rawset(folder, key, value)
        folder._propertySignals[key]:Fire(value)
    end

    local metatable = {}

    function metatable.__index(_, key)
        return BallsFolder[key]
    end

    function metatable.__newindex(_, key, value)
        if key == "Parent" then
            if rawget(folder, "Parent") ~= value then
                rawset(folder, key, value)
                folder._propertySignals.Parent:Fire(value)
                folder.AncestryChanged:Fire(folder, value)
            end
            return
        elseif key == "Name" then
            if rawget(folder, "Name") ~= value then
                rawUpdate(key, value)
            end
            return
        end

        rawset(folder, key, value)
    end

    return setmetatable(folder, metatable)
end

function BallsFolder:_setChildParent(child, parent)
    if type(child) ~= "table" then
        return
    end

    if type(child._mockSetParent) == "function" then
        child:_mockSetParent(parent)
        return
    end

    child.Parent = parent
end

function BallsFolder:Add(ball)
    table.insert(self._children, ball)
    self:_setChildParent(ball, self)
    self.ChildAdded:Fire(ball)
    return ball
end

function BallsFolder:Remove(ball)
    for index, child in ipairs(self._children) do
        if child == ball then
            table.remove(self._children, index)
            self:_setChildParent(child, nil)
            self.ChildRemoved:Fire(child)
            return child
        end
    end
    return nil
end

function BallsFolder:GetChildren()
    return table.clone(self._children)
end

function BallsFolder:Clear()
    for index = #self._children, 1, -1 do
        local child = table.remove(self._children, index)
        self:_setChildParent(child, nil)
        self.ChildRemoved:Fire(child)
    end
end

function BallsFolder:_mockDestroy()
    self.Destroying:Fire(self)
    self:Clear()
end

function BallsFolder:GetPropertyChangedSignal(propertyName)
    return self._propertySignals[propertyName]
end

local function createRunServiceStub()
    local heartbeatConnections = {}
    local preRenderConnections = {}

    local heartbeat = {}

    function heartbeat:Connect(callback)
        table.insert(heartbeatConnections, callback)
        local index = #heartbeatConnections

        local connection = {}

        function connection.Disconnect()
            heartbeatConnections[index] = nil
        end

        connection.disconnect = connection.Disconnect
        return connection
    end

    local preRender = {}

    function preRender:Connect(callback)
        table.insert(preRenderConnections, callback)
        local index = #preRenderConnections

        local connection = {}

        function connection.Disconnect()
            preRenderConnections[index] = nil
        end

        connection.disconnect = connection.Disconnect
        return connection
    end

    local stub = { Heartbeat = heartbeat, PreRender = preRender }

    function stub:step(deltaTime)
        for _, callback in ipairs(heartbeatConnections) do
            if callback then
                callback(deltaTime)
            end
        end

        for _, callback in ipairs(preRenderConnections) do
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
        Name = "HumanoidRootPart",
        Position = Vector3.new(),
        AssemblyLinearVelocity = Vector3.new(),
        CFrame = CFrame.new(),
    }
    local humanoid = { Name = "Humanoid" }
    humanoid.Died = Harness.createSignal()
    local character

    character = {
        PrimaryPart = rootPart,
        FindFirstChild = function(_, name)
            if name == "HumanoidRootPart" then
                return rootPart
            end
            if name == "Highlight" and highlightEnabled then
                return highlight
            end
            return nil
        end,
        FindFirstChildOfClass = function(_, className)
            if className == "Humanoid" then
                return humanoid
            end
            if className == "Highlight" and highlightEnabled then
                return highlight
            end
            return nil
        end,
        FindFirstChildWhichIsA = function(self, className)
            return self:FindFirstChildOfClass(className)
        end,
        WaitForChild = function(self, childName)
            if childName == "HumanoidRootPart" then
                return rootPart
            end
            if childName == "Humanoid" then
                return humanoid
            end
            if childName == "Highlight" and highlightEnabled then
                return highlight
            end
            return nil
        end,
    }

    local player = {
        Name = "LocalPlayer",
        Character = character,
    }

    do
        local addedSignal = Harness.createSignal()
        local removingSignal = Harness.createSignal()
        player.CharacterAdded = addedSignal
        player.CharacterRemoving = removingSignal

        local playerGui = Instance.new("PlayerGui")
        playerGui.Name = "PlayerGui"
        player.PlayerGui = playerGui

        function player:_mockSetCharacter(newCharacter)
            self.Character = newCharacter
            addedSignal:Fire(newCharacter)
        end

        function player:_mockRemoveCharacter(currentCharacter)
            removingSignal:Fire(currentCharacter or self.Character)
            self.Character = nil
        end

        function player:FindFirstChildOfClass(className)
            if className == "PlayerGui" then
                return playerGui
            end
            return nil
        end

        function player:FindFirstChild(childName)
            if childName == "PlayerGui" then
                return playerGui
            end
            return nil
        end

        function player:WaitForChild(childName)
            if childName == "PlayerGui" then
                return playerGui
            end
            return nil
        end
    end

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

    services.VirtualInputManager = {
        SendKeyEvent = function(_, _isPressed, _keyCode, _isRepeat, _target)
            return true
        end,
    }

    local remoteOptions = options.remote or {}
    local parryContainer, remote = Harness.createParryButtonPress({
        scheduler = scheduler,
        remoteKind = remoteOptions.kind,
        remoteClassName = remoteOptions.className,
    })
    remotes:Add(parryContainer)

    local ballsFolder = BallsFolder.new("Balls")

    local workspaceStub = {
        Name = "Workspace",
        FindFirstChild = function(_, name)
            if name == ballsFolder.Name then
                return ballsFolder
            end
            return nil
        end,
        WaitForChild = function(_, name)
            if name == ballsFolder.Name then
                return ballsFolder
            end
            return nil
        end,
        GetChildren = function()
            return { ballsFolder }
        end,
    }

    ballsFolder.Parent = workspaceStub
    services.Workspace = workspaceStub
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
        local methodName = remoteInstance._parryMethod or "Fire"
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

    local activeRemoteContainer = parryContainer

    local function setActiveRemote(remoteInstance, containerInstance)
        local methodName = hookRemote(remoteInstance)
        if containerInstance then
            activeRemoteContainer = containerInstance
        end
        if context then
            context.remote = remoteInstance
            context.remoteMethod = methodName
            context.remoteContainer = activeRemoteContainer
        end
        return methodName
    end

    local parryMethodName = setActiveRemote(remote, parryContainer)

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
        remoteContainer = parryContainer,
        remotes = remotes,
        remoteLog = remoteLog,
        parryLog = parryLog,
        ballsFolder = ballsFolder,
        rootPart = rootPart,
        character = character,
        setHighlightEnabled = function(_, flag)
            highlightEnabled = flag
        end,
    }

    function context:_advanceBalls(deltaTime)
        local dt = deltaTime or 0
        if dt <= 0 then
            return
        end

        for _, ball in ipairs(self.ballsFolder:GetChildren()) do
            local advance = ball._advance
            if type(advance) == "function" then
                advance(ball, dt)
            else
                local velocity = ball.AssemblyLinearVelocity
                if velocity then
                    ball:SetPosition(ball.Position + velocity * dt)
                end
            end
        end
    end

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
        self:_advanceBalls(dt)
        self.runService:step(dt)
    end

    function context:stepUntil(predicate, options)
        options = options or {}
        local stepSize = options.step or 1 / 240
        local maxSteps = options.maxSteps or 240

        for _ = 1, maxSteps do
            self:step(stepSize)
            if predicate() then
                return true
            end
        end

        return false
    end

    function context:advance(duration, options)
        options = options or {}
        local stepSize = options.step or 1 / 240
        local remaining = duration or 0
        while remaining > 0 do
            local dt = math.min(stepSize, remaining)
            self:step(dt)
            remaining = remaining - dt
        end
    end

    function context:getSmartPressState()
        local getter = self.autoparry and self.autoparry.getSmartPressState
        if type(getter) ~= "function" then
            error("AutoParry.getSmartPressState is not available", 0)
        end
        return getter()
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

        local container = self.remoteContainer
        local targetName = container and container.Name
        if not targetName then
            return nil
        end

        local removed = self.remotes:Remove(targetName)
        if removed == container then
            self.remote = nil
            self.remoteMethod = nil
            self.remoteContainer = nil
        end

        return removed
    end

    function context:attachParryRemote(remoteOptions)
        if not self.remotes then
            return nil
        end

        local newContainer, newRemote = Harness.createParryButtonPress({
            scheduler = scheduler,
            remoteKind = remoteOptions and remoteOptions.kind,
            remoteClassName = remoteOptions and remoteOptions.className,
        })
        self.remotes:Add(newContainer)
        local methodName = setActiveRemote(newRemote, newContainer)
        self.remote = newRemote
        self.remoteMethod = methodName
        self.remoteContainer = newContainer
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
        context:stepUntil(function()
            return #context.parryLog > 0
        end)

        expect(#context.parryLog):toEqual(1)
        expect(context.parryLog[1].ball):toEqual(ball)

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
        context:stepUntil(function()
            return #context.parryLog > 0
        end)

        expect(#context.parryLog):toEqual(1)
        expect(autoparry.getLastParryTime()):toBeCloseTo(context.parryLog[1].timestamp, 1e-3)
        local firstParryTime = autoparry.getLastParryTime()

        -- remove the first ball to mirror game behaviour where successful parries
        -- despawn the projectile immediately.
        local firstBall = context.parryLog[1].ball
        context.ballsFolder:Remove(firstBall)

        context:step(0.05)
        expect(#context.parryLog):toEqual(1)
        expect(autoparry.getLastParryTime()):toEqual(firstParryTime)

        context:step(0.15)
        expect(#context.parryLog):toEqual(2)
        expect(context.parryLog[2].ball):toEqual(secondBall)
        expect(autoparry.getLastParryTime() > firstParryTime):toBeTruthy()
        expect(autoparry.getLastParryTime()):toBeCloseTo(context.parryLog[2].timestamp, 1e-3)

        context:destroy()
    end)

    t.test("parry loop waits for the highlight gate before firing", function(expect)
        local context = createContext()
        local autoparry = context.autoparry

        context:setHighlightEnabled(false)
        expect(context.character:FindFirstChild("Highlight")):toEqual(nil)

        autoparry.resetConfig()
        autoparry.configure({
            minTTI = 0,
            pingOffset = 0,
            cooldown = 0.12,
        })
        expect(autoparry.getConfig().targetHighlightName):toEqual("Highlight")

        local ball = context:addBall({
            name = "HighlightGatedThreat",
            position = Vector3.new(0, 0, 48),
            velocity = Vector3.new(0, 0, -120),
        })

        autoparry.setEnabled(true)
        context:advance(0.2)

        expect(#context.parryLog):toEqual(0)
        expect(autoparry.getLastParryTime()):toEqual(0)

        context:setHighlightEnabled(true)
        context:stepUntil(function()
            return #context.parryLog > 0
        end)

        expect(#context.parryLog):toEqual(1)
        expect(context.parryLog[1].ball):toEqual(ball)
        expect(autoparry.getLastParryTime()):toBeCloseTo(context.parryLog[1].timestamp, 1e-3)

        context:destroy()
    end)

    t.test("parry loop keeps firing when the parry remote is missing and recovers once replaced", function(expect)
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
        context:stepUntil(function()
            return #context.parryLog > 0
        end)

        expect(#context.parryLog):toEqual(1)
        expect(context.parryLog[1].ball):toEqual(firstBall)
        expect(autoparry.getLastParryTime()):toBeCloseTo(context.parryLog[1].timestamp, 1e-3)
        local firstParryTime = autoparry.getLastParryTime()

        context:clearBalls()
        context:clearParryLog()

        local remoteMissingBall = context:addBall({
            name = "RemoteMissingThreat",
            position = Vector3.new(0, 0, 36),
            velocity = Vector3.new(0, 0, -180),
        })

        context:removeParryRemote()

        context:stepUntil(function()
            return #context.parryLog > 0
        end)

        expect(#context.parryLog):toEqual(1)
        expect(context.parryLog[1].ball):toEqual(remoteMissingBall)
        expect(autoparry.getLastParryTime() > firstParryTime):toBeTruthy()
        local missingParryTime = autoparry.getLastParryTime()

        context:clearBalls()
        context:clearParryLog()

        context:attachParryRemote()

        local readyObserved = false
        for _ = 1, 60 do
            context:step(1 / 60)
            if autoparry.getInitProgress().stage == "ready" then
                readyObserved = true
                break
            end
        end

        expect(readyObserved):toEqual(true)

        local recoveredBall = context:addBall({
            name = "RecoveredThreat",
            position = Vector3.new(0, 0, 36),
            velocity = Vector3.new(0, 0, -180),
        })

        context:stepUntil(function()
            return #context.parryLog > 0
        end)

        expect(#context.parryLog):toEqual(1)
        expect(context.parryLog[1].ball):toEqual(recoveredBall)
        expect(autoparry.getLastParryTime() > missingParryTime):toBeTruthy()
        expect(autoparry.getLastParryTime()):toBeCloseTo(context.parryLog[1].timestamp, 1e-3)

        context:destroy()
    end)

    t.test("parry loop surfaces smart press telemetry for scheduled threats", function(expect)
        local context = createContext()
        local autoparry = context.autoparry

        autoparry.resetConfig()
        autoparry.configure({
            minTTI = 0,
            pingOffset = 0,
            cooldown = 0.12,
            activationLatency = 0.1,
        })

        local ball = context:addBall({
            name = "TelemetryThreat",
            position = Vector3.new(0, 0, 200),
            velocity = Vector3.new(0, 0, -180),
        })

        autoparry.setEnabled(true)

        local scheduleSample
        local maxSteps = 600
        for _ = 1, maxSteps do
            context:step(1 / 240)
            local smart = context:getSmartPressState()
            if smart.ballId and not scheduleSample then
                scheduleSample = smart
            end
            if #context.parryLog > 0 then
                break
            end
        end

        expect(scheduleSample):toBeTruthy()
        expect(#context.parryLog):toEqual(1)

        local parryEntry = context.parryLog[1]
        expect(parryEntry.ball):toEqual(ball)
        expect(parryEntry.timestamp):toBeCloseTo(scheduleSample.pressAt, 2e-2)

        local sampleTime = scheduleSample.sampleTime or scheduleSample.lastUpdate or 0
        local predictedImpact = scheduleSample.predictedImpact or 0
        local lead = scheduleSample.lead or 0
        local observedDelay = (scheduleSample.pressAt or 0) - sampleTime
        local expectedDelay = math.max(predictedImpact - lead, 0)
        expect(observedDelay):toBeCloseTo(expectedDelay, 2e-2)

        local expectedImpact = sampleTime + predictedImpact
        expect(parryEntry.timestamp + lead):toBeCloseTo(expectedImpact, 2e-2)

        local function summariseRemoteLogs(entries)
            local summary = {}
            for index, entry in ipairs(entries) do
                summary[index] = {
                    timestamp = entry.timestamp,
                    payloadSize = entry.payload and #entry.payload or 0,
                }
            end
            return summary
        end

        t.artifact("parry_timeline", {
            schedule = {
                ballId = scheduleSample.ballId,
                pressAt = scheduleSample.pressAt,
                predictedImpact = predictedImpact,
                lead = lead,
                slack = scheduleSample.slack,
                reason = scheduleSample.reason,
                sampleTime = sampleTime,
                timeSinceUpdate = scheduleSample.timeSinceUpdate,
                latency = scheduleSample.latency,
                remoteLatencyActive = scheduleSample.remoteLatencyActive,
                pressEta = scheduleSample.pressEta,
                latencySamples = scheduleSample.latencySamples,
                pendingLatencyPresses = scheduleSample.pendingLatencyPresses,
                telemetry = scheduleSample.telemetry,
            },
            parry = {
                timestamp = parryEntry.timestamp,
                ballName = parryEntry.ball and parryEntry.ball.Name or nil,
            },
            remoteCalls = summariseRemoteLogs(context.remoteLog),
        })

        context:destroy()
    end)
end
