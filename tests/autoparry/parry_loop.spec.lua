-- selene: allow(global_usage)
-- selene: allow(incorrect_standard_library_use)
local TestHarness = script.Parent.Parent
local RuntimeFolder = TestHarness:WaitForChild("engine")
local Runtime = require(RuntimeFolder:WaitForChild("runtime"))

local Scheduler = Runtime.Scheduler

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
            local signal = Runtime.createSignal()
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
        ChildAdded = Runtime.createSignal(),
        ChildRemoved = Runtime.createSignal(),
        Destroying = Runtime.createSignal(),
        AncestryChanged = Runtime.createSignal(),
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
    humanoid.Died = Runtime.createSignal()
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
        local addedSignal = Runtime.createSignal()
        local removingSignal = Runtime.createSignal()
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

    local stats = Runtime.createStats({
        pingResponses = {
            { value = 0 },
        },
    })

    local services, remotes = Runtime.createBaseServices(scheduler, {
        initialLocalPlayer = player,
        runService = runService,
        stats = stats,
    })

    local virtualInputLog = {}
    local virtualInputOptions = options.virtualInput or {}
    local virtualInputManager = virtualInputOptions.manager

    if not virtualInputManager then
        local pressFailuresRemaining = tonumber(virtualInputOptions.failPressCount) or 0
        local releaseFailuresRemaining = tonumber(virtualInputOptions.failReleaseCount) or 0
        local failureMessage = virtualInputOptions.failureMessage or "virtual input failure"
        local returnValue = virtualInputOptions.returnValue
        local callback = virtualInputOptions.onEvent

        virtualInputManager = {
            SendKeyEvent = function(_, isPressed, keyCode, isRepeat, target)
                local entry = {
                    isPressed = isPressed,
                    keyCode = keyCode,
                    isRepeat = isRepeat,
                    target = target,
                    time = scheduler:clock(),
                }

                if callback then
                    local success, err = pcall(callback, entry)
                    if not success then
                        warn("Virtual input callback failed:", err)
                    end
                end

                if isPressed and pressFailuresRemaining > 0 then
                    pressFailuresRemaining -= 1
                    entry.failed = true
                    entry.error = failureMessage
                    table.insert(virtualInputLog, entry)
                    error(failureMessage)
                elseif (not isPressed) and releaseFailuresRemaining > 0 then
                    releaseFailuresRemaining -= 1
                    entry.failed = true
                    entry.error = failureMessage
                    table.insert(virtualInputLog, entry)
                    error(failureMessage)
                end

                table.insert(virtualInputLog, entry)
                if returnValue ~= nil then
                    return returnValue
                end
                return true
            end,
        }
    end

    services.VirtualInputManager = virtualInputManager

    local remoteOptions = options.remote or {}
    local parryContainer, remote = Runtime.createParryButtonPress({
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

    local autoparry = Runtime.loadAutoParry({
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

        assert(isCallable(original), "Runtime remote missing parry method")

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
        virtualInputLog = virtualInputLog,
        ballsFolder = ballsFolder,
        rootPart = rootPart,
        character = character,
        highlightEnabled = highlightEnabled,
        setHighlightEnabled = function(_, flag)
            highlightEnabled = flag
            context.highlightEnabled = flag
        end,
        getStatusText = function()
            local playerGui = player.PlayerGui
            if not playerGui then
                return nil
            end

            local screen = playerGui:FindFirstChild("AutoParryF_UI")
            if not screen then
                return nil
            end

            local status = screen:FindFirstChild("AutoParryStatus", true)
            if status and status:IsA("TextLabel") then
                return status.Text
            end

            return nil
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

    function context:_advancePlayer(deltaTime)
        local dt = deltaTime or 0
        if dt <= 0 then
            return
        end

        local root = self.rootPart
        if not root or typeof(root.AssemblyLinearVelocity) ~= "Vector3" then
            return
        end

        local velocity = root.AssemblyLinearVelocity
        if velocity.Magnitude <= 0 then
            return
        end

        local newPosition = root.Position + velocity * dt
        root.Position = newPosition
        if velocity.Magnitude > 1e-3 then
            root.CFrame = CFrame.new(newPosition, newPosition + velocity.Unit)
        else
            root.CFrame = CFrame.new(newPosition)
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

        local newContainer, newRemote = Runtime.createParryButtonPress({
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

    t.test("parry loop tolerates highlight flicker during final approach", function(expect)
        local context = createContext()
        local autoparry = context.autoparry

        autoparry.resetConfig()
        autoparry.configure({
            minTTI = 0,
            pingOffset = 0,
            cooldown = 0.12,
        })

        autoparry.setEnabled(true)

        local function runFlickerAttempt(attemptIndex)
            context:clearParryLog()
            context:clearBalls()

            local distance = 56 + math.max(attemptIndex - 1, 0) * 6
            local speed = -180 + math.max(attemptIndex - 2, 0) * 20

            local ball = context:addBall({
                name = "HighlightFlickerThreat",
                position = Vector3.new(0, 0, distance),
                velocity = Vector3.new(0, 0, speed),
            })

            context:setHighlightEnabled(true)

            local scheduleSample
            for _ = 1, 600 do
                context:step(1 / 240)

                local smart = context:getSmartPressState()
                if smart.ballId then
                    scheduleSample = smart
                    break
                end

                local last = smart.lastScheduled
                if last and last.ballId then
                    scheduleSample = last
                    break
                end

                if #context.parryLog > 0 then
                    expect(context.parryLog[1].ball):toEqual(ball)
                    return { parriedEarly = true, ball = ball }
                end
            end

            expect(scheduleSample):toBeTruthy()

            if #context.parryLog > 0 then
                expect(context.parryLog[1].ball):toEqual(ball)
                return { parriedEarly = true, ball = ball }
            end

            context:setHighlightEnabled(false)
            expect(context.character:FindFirstChild("Highlight")):toEqual(nil)

            local remaining = 0.12
            while remaining > 0 and #context.parryLog == 0 do
                local dt = math.min(remaining, 1 / 240)
                context:step(dt)
                remaining -= dt
            end

            expect(#context.parryLog > 0):toEqual(true)
            expect(context.highlightEnabled):toEqual(false)
            expect(context.character:FindFirstChild("Highlight")):toEqual(nil)
            expect(#context.parryLog):toEqual(1)
            expect(context.parryLog[1].ball):toEqual(ball)
            expect(autoparry.getLastParryTime()):toBeCloseTo(context.parryLog[1].timestamp, 1e-3)

            return { parriedEarly = false, ball = ball, highlightCleared = true }
        end

        local attemptResult
        for attempt = 1, 3 do
            attemptResult = runFlickerAttempt(attempt)
            if attemptResult.parriedEarly ~= true then
                break
            end
        end

        expect(attemptResult).toBeTruthy()
        expect(attemptResult.parriedEarly):toEqual(false)
        expect(attemptResult.highlightCleared):toEqual(true)
        expect(#context.parryLog):toBeGreaterThanOrEqual(1)
        expect(context.parryLog[1].ball):toEqual(attemptResult.ball)

        context:destroy()
    end)

    t.test("parry loop stays reliable while the player sprints and jumps", function(expect)
        local context = createContext()
        local autoparry = context.autoparry

        autoparry.resetConfig()
        autoparry.configure({
            minTTI = 0,
            pingOffset = 0,
            cooldown = 0.12,
        })

        local ball = context:addBall({
            name = "MovingPlayerThreat",
            position = Vector3.new(0, 0, 42),
            velocity = Vector3.new(0, 0, -180),
        })

        autoparry.setEnabled(true)

        local motionProfile = {
            { velocity = Vector3.new(10, 0, 0), duration = 0.16 },
            { velocity = Vector3.new(-12, 0, 0), duration = 0.14 },
            { velocity = Vector3.new(0, 20, 0), duration = 0.12 },
            { velocity = Vector3.new(0, -18, 0), duration = 0.14 },
            { velocity = Vector3.new(14, 10, 0), duration = 0.18 },
            { velocity = Vector3.new(-6, 0, 18), duration = 0.12 },
        }

        for _, entry in ipairs(motionProfile) do
            context.rootPart.AssemblyLinearVelocity = entry.velocity
            local remaining = entry.duration
            local stepSize = 1 / 240
            while remaining > 0 and #context.parryLog == 0 do
                local dt = math.min(stepSize, remaining)
                context:_advancePlayer(dt)
                context:step(dt)
                remaining -= dt
            end
            if #context.parryLog > 0 then
                break
            end
        end

        context.rootPart.AssemblyLinearVelocity = Vector3.new()

        context:stepUntil(function()
            return #context.parryLog > 0
        end, { step = 1 / 240, maxSteps = 420 })

        expect(#context.parryLog):toEqual(1)
        expect(context.parryLog[1].ball):toEqual(ball)

        context:destroy()
    end)

    t.test("parry loop spams presses when retargeted in rapid succession", function(expect)
        local context = createContext()
        local autoparry = context.autoparry

        autoparry.resetConfig()
        autoparry.configure({
            minTTI = 0,
            pingOffset = 0,
            cooldown = 0,
            oscillationFrequency = 0,
            pressScheduleSlack = 0.008,
            oscillationSpamBurstPresses = 5,
            oscillationSpamBurstGap = 0.05,
            oscillationSpamMinGap = 1 / 240,
        })

        local ball = context:addBall({
            name = "RapidRetargetThreat",
            position = Vector3.new(0, 0, 160),
            velocity = Vector3.new(0, 0, -240),
        })

        autoparry.setEnabled(true)

        local firstParry = context:stepUntil(function()
            return #context.parryLog > 0
        end, { step = 1 / 240, maxSteps = 720 })

        expect(firstParry):toEqual(true)
        expect(context.parryLog[1].ball):toEqual(ball)

        local initialCount = #context.parryLog

        context:advance(0.05, { step = 1 / 240 })

        local toggleCycles = 0
        while toggleCycles < 8 do
            context:setHighlightEnabled(false)
            context:advance(0.03, { step = 1 / 240 })
            context:setHighlightEnabled(true)
            context:advance(0.04, { step = 1 / 240 })
            toggleCycles += 1
            if ball.Position.Z <= -5 then
                break
            end
        end

        context:advance(0.35, { step = 1 / 240 })

        expect(#context.parryLog):toBeGreaterThanOrEqual(initialCount + 2)
        expect(#context.parryLog):toBeGreaterThanOrEqual(3)
        for index = 1, #context.parryLog do
            expect(context.parryLog[index].ball):toEqual(ball)
        end

        local quickGapDetected = false
        for index = 2, #context.parryLog do
            local dt = context.parryLog[index].timestamp - context.parryLog[index - 1].timestamp
            if dt <= 0.2 then
                quickGapDetected = true
                break
            end
        end

        expect(quickGapDetected):toEqual(true)

        context:destroy()
    end)

    t.test("parry loop accelerates spam bursts when retargeting stays relentless", function(expect)
        local context = createContext()
        local autoparry = context.autoparry

        autoparry.resetConfig()
        autoparry.configure({
            minTTI = 0,
            pingOffset = 0,
            cooldown = 0,
            oscillationFrequency = 0,
            pressScheduleSlack = 0.008,
        })

        local ball = context:addBall({
            name = "RelentlessThreat",
            position = Vector3.new(0, 0, 220),
            velocity = Vector3.new(0, 0, -360),
        })

        autoparry.setEnabled(true)
        context:setHighlightEnabled(true)

        local firstParry = context:stepUntil(function()
            return #context.parryLog > 0
        end, { step = 1 / 240, maxSteps = 960 })

        expect(firstParry):toEqual(true)
        expect(context.parryLog[1].ball):toEqual(ball)

        local initialCount = #context.parryLog

        context:advance(0.04, { step = 1 / 240 })

        for cycle = 1, 9 do
            context:setHighlightEnabled(false)
            context:advance(0.012, { step = 1 / 240 })
            context:setHighlightEnabled(true)
            context:advance(0.02, { step = 1 / 240 })
            if ball.Position.Z <= -10 then
                break
            end
        end

        context:advance(0.28, { step = 1 / 240 })

        local totalPresses = #context.parryLog
        expect(totalPresses):toBeGreaterThanOrEqual(initialCount + 3)
        expect(totalPresses):toBeGreaterThanOrEqual(4)

        local minGap = math.huge
        local subOneTenth = 0
        local subEightHundredths = 0
        for index = 2, totalPresses do
            local gap = context.parryLog[index].timestamp - context.parryLog[index - 1].timestamp
            if gap < minGap then
                minGap = gap
            end
            if gap <= 0.1 then
                subOneTenth += 1
            end
            if gap <= 0.08 then
                subEightHundredths += 1
            end
        end

        expect(subOneTenth):toBeGreaterThanOrEqual(3)
        expect(subEightHundredths):toBeGreaterThanOrEqual(1)
        expect(minGap <= 0.08):toEqual(true)

        for index = 1, totalPresses do
            expect(context.parryLog[index].ball):toEqual(ball)
        end

        context:destroy()
    end)

    t.test("parry loop clears a deterministic highlight storm without misses", function(expect)
        local context = createContext()
        local autoparry = context.autoparry

        autoparry.resetConfig()
        autoparry.configure({
            minTTI = 0,
            pingOffset = 0,
            cooldown = 0,
            pressScheduleSlack = 0.008,
            oscillationFrequency = 0,
            oscillationSpamBurstPresses = 6,
            oscillationSpamBurstGap = 0.05,
            oscillationSpamMinGap = 1 / 240,
        })

        autoparry.setEnabled(true)
        context:setHighlightEnabled(false)

        local threatDefinitions = {
            { spawnTime = 0.0, position = Vector3.new(-6, 4, 240), velocity = Vector3.new(12, 6, -260), highlightOn = 0.28, highlightOff = 0.44 },
            { spawnTime = 0.28, position = Vector3.new(14, -6, 236), velocity = Vector3.new(-16, 8, -280), highlightOn = 0.48, highlightOff = 0.64 },
            { spawnTime = 0.52, position = Vector3.new(-18, 2, 228), velocity = Vector3.new(20, 4, -300), highlightOn = 0.72, highlightOff = 0.88 },
            { spawnTime = 0.78, position = Vector3.new(10, 10, 238), velocity = Vector3.new(-14, -10, -295), highlightOn = 0.98, highlightOff = 1.14 },
            { spawnTime = 1.04, position = Vector3.new(-20, -12, 222), velocity = Vector3.new(18, 12, -310), highlightOn = 1.24, highlightOff = 1.4 },
            { spawnTime = 1.26, position = Vector3.new(8, 14, 244), velocity = Vector3.new(-12, -6, -275), highlightOn = 1.46, highlightOff = 1.62 },
            { spawnTime = 1.48, position = Vector3.new(-16, -10, 226), velocity = Vector3.new(22, 8, -320), highlightOn = 1.68, highlightOff = 1.84 },
            { spawnTime = 1.72, position = Vector3.new(18, 6, 236), velocity = Vector3.new(-18, -8, -305), highlightOn = 1.92, highlightOff = 2.08 },
            { spawnTime = 1.94, position = Vector3.new(-12, 12, 218), velocity = Vector3.new(16, -12, -315), highlightOn = 2.14, highlightOff = 2.3 },
            { spawnTime = 2.18, position = Vector3.new(12, -14, 242), velocity = Vector3.new(-20, 6, -330), highlightOn = 2.38, highlightOff = 2.54 },
            { spawnTime = 2.4, position = Vector3.new(-10, 8, 230), velocity = Vector3.new(18, -6, -325), highlightOn = 2.6, highlightOff = 2.76 },
            { spawnTime = 2.64, position = Vector3.new(16, -4, 224), velocity = Vector3.new(-20, 10, -320), highlightOn = 2.8, highlightOff = 3.08 },
        }

        local highlightEvents = {
            { time = 0, enabled = false },
        }

        for _, definition in ipairs(threatDefinitions) do
            table.insert(highlightEvents, { time = definition.highlightOn, enabled = true })
            table.insert(highlightEvents, { time = definition.highlightOff, enabled = false })
        end

        table.sort(highlightEvents, function(a, b)
            if a.time == b.time then
                return (a.enabled and 1 or 0) > (b.enabled and 1 or 0)
            end
            return a.time < b.time
        end)

        local playerMotions = {
            { time = 0.0, velocity = Vector3.new(0, 0, 0) },
            { time = 0.36, velocity = Vector3.new(10, 0, 4) },
            { time = 0.78, velocity = Vector3.new(-12, 6, -6) },
            { time = 1.12, velocity = Vector3.new(14, 12, 8) },
            { time = 1.56, velocity = Vector3.new(-10, -18, 12) },
            { time = 1.96, velocity = Vector3.new(16, 8, -10) },
            { time = 2.32, velocity = Vector3.new(-14, 14, 6) },
            { time = 2.68, velocity = Vector3.new(0, 0, 0) },
        }

        local stepSize = 1 / 240
        local elapsed = 0
        local totalThreats = #threatDefinitions
        local spawnIndex = 1
        local highlightIndex = 1
        local motionIndex = 1
        local parryIndex = 0
        local uniqueParries = 0
        local parriedByBall = {}
        local activeThreats = {}
        local missCount = 0

        local lastEventTime = threatDefinitions[#threatDefinitions].highlightOff
        local settleDuration = 0.6
        local totalDuration = lastEventTime + settleDuration

        context.rootPart.AssemblyLinearVelocity = Vector3.new()

        while elapsed < totalDuration do
            while spawnIndex <= totalThreats and threatDefinitions[spawnIndex].spawnTime <= elapsed + 1e-6 do
                local definition = threatDefinitions[spawnIndex]
                local ball = context:addBall({
                    name = string.format("StormThreat%d", spawnIndex),
                    position = definition.position,
                    velocity = definition.velocity,
                })

                table.insert(activeThreats, {
                    index = spawnIndex,
                    definition = definition,
                    ball = ball,
                    deadline = definition.highlightOff + 0.4,
                })

                spawnIndex += 1
            end

            while highlightIndex <= #highlightEvents and highlightEvents[highlightIndex].time <= elapsed + 1e-6 do
                context:setHighlightEnabled(highlightEvents[highlightIndex].enabled)
                highlightIndex += 1
            end

            while motionIndex <= #playerMotions and playerMotions[motionIndex].time <= elapsed + 1e-6 do
                context.rootPart.AssemblyLinearVelocity = playerMotions[motionIndex].velocity
                motionIndex += 1
            end

            context:_advancePlayer(stepSize)
            context:step(stepSize)
            elapsed += stepSize

            if #context.parryLog > parryIndex then
                for index = parryIndex + 1, #context.parryLog do
                    local entry = context.parryLog[index]
                    local ball = entry.ball
                    if ball ~= nil and parriedByBall[ball] ~= true then
                        parriedByBall[ball] = true
                        uniqueParries += 1
                        context.ballsFolder:Remove(ball)

                        for threatIndex = #activeThreats, 1, -1 do
                            local threat = activeThreats[threatIndex]
                            if threat.ball == ball then
                                threat.parried = true
                                threat.parryTime = entry.timestamp
                                if threat.definition.highlightOff then
                                    expect(entry.timestamp <= threat.definition.highlightOff + 0.36):toEqual(true)
                                end
                                expect(entry.timestamp >= threat.definition.highlightOn - 1e-3):toEqual(true)
                                table.remove(activeThreats, threatIndex)
                                break
                            end
                        end
                    end
                end
                parryIndex = #context.parryLog
            end

            for threatIndex = #activeThreats, 1, -1 do
                local threat = activeThreats[threatIndex]
                local ball = threat.ball
                if threat.parried then
                    table.remove(activeThreats, threatIndex)
                elseif ball and (ball.Position.Z <= 0 or elapsed >= threat.deadline) then
                    missCount += 1
                    context.ballsFolder:Remove(ball)
                    table.remove(activeThreats, threatIndex)
                end
            end
        end

        context:setHighlightEnabled(false)

        expect(missCount):toEqual(0)
        expect(uniqueParries):toEqual(totalThreats)
        expect(#context.parryLog >= totalThreats):toEqual(true)

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

    t.test("parry loop still fires after a long frame hitch", function(expect)
        local context = createContext()
        local autoparry = context.autoparry

        autoparry.resetConfig()
        autoparry.configure({
            minTTI = 0,
            pingOffset = 0,
            cooldown = 0.12,
        })

        local ball = context:addBall({
            name = "FrameHitchThreat",
            position = Vector3.new(0, 0, 80),
            velocity = Vector3.new(0, 0, -220),
        })

        autoparry.setEnabled(true)

        context:advance(0.08, { step = 1 / 240 })
        expect(#context.parryLog):toEqual(0)

        context:step(0.18)

        if #context.parryLog == 0 then
            context:stepUntil(function()
                return #context.parryLog > 0
            end, { step = 1 / 240 })
        end

        expect(#context.parryLog > 0):toEqual(true)
        expect(context.parryLog[1].ball):toEqual(ball)
        expect(autoparry.getLastParryTime()):toBeCloseTo(context.parryLog[1].timestamp, 1e-3)

        context:destroy()
    end)

    t.test("parry loop retries quickly after a transient virtual input failure", function(expect)
        local context = createContext({
            virtualInput = {
                failPressCount = 1,
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
            name = "VirtualInputTransient",
            position = Vector3.new(0, 0, 40),
            velocity = Vector3.new(0, 0, -160),
        })

        autoparry.setEnabled(true)
        context:advance(0.45, { step = 1 / 240 })

        expect(#context.parryLog):toEqual(1)
        expect(context.parryLog[1].ball):toEqual(ball)

        local failureEntry
        local recoveryEntry
        local pressCount = 0
        for _, entry in ipairs(context.virtualInputLog) do
            if entry.isPressed then
                pressCount += 1
                if entry.failed then
                    if not failureEntry then
                        failureEntry = entry
                    end
                else
                    recoveryEntry = entry
                end
            end
        end

        expect(pressCount >= 2):toEqual(true)
        expect(failureEntry ~= nil):toEqual(true)
        expect(recoveryEntry ~= nil):toEqual(true)
        expect(recoveryEntry.failed == true):toEqual(false)
        expect(failureEntry.failed == true):toEqual(true)

        local delay = recoveryEntry.time - failureEntry.time
        expect(delay < 0.4):toEqual(true)

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
            if not scheduleSample then
                if smart.ballId then
                    scheduleSample = smart
                elseif smart.lastScheduled then
                    scheduleSample = smart.lastScheduled
                end
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

        local sampleTime = scheduleSample.sampleTime or scheduleSample.time or scheduleSample.lastUpdate or 0
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

    t.test("parry loop status panel surfaces reaction metrics", function(expect)
        local context = createContext()
        local autoparry = context.autoparry

        autoparry.resetConfig()
        autoparry.configure({
            minTTI = 0,
            pingOffset = 0,
            cooldown = 0,
            activationLatency = 0.08,
        })

        context:addBall({
            name = "UiTelemetryBall",
            position = Vector3.new(0, 0, 150),
            velocity = Vector3.new(0, 0, -140),
        })

        autoparry.setEnabled(true)

        local uiReady = context:stepUntil(function()
            local text = context:getStatusText()
            return type(text) == "string" and text:find("React:") ~= nil and text:find("Decide:") ~= nil
        end, { step = 1 / 240, maxSteps = 720 })

        expect(uiReady):toEqual(true)

        local statusText = context:getStatusText() or ""
        expect(statusText:find("React:")):toBeTruthy()
        expect(statusText:find("Decide:")):toBeTruthy()

        context:destroy()
    end)
end
