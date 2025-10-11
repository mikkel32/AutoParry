-- selene: allow(global_usage)
-- selene: allow(incorrect_standard_library_use)

local function findTestHarness(instance)
    local current = instance
    while current do
        if current.Name == "TestHarness" then
            return current
        end
        current = current.Parent
    end

    error("Failed to locate TestHarness ancestor from Context module")
end

local TestHarness = findTestHarness(script)
local RuntimeFolder = TestHarness:WaitForChild("engine")
local Runtime = require(RuntimeFolder:WaitForChild("runtime"))
local Physics = require(RuntimeFolder:WaitForChild("physics"))

local Context = {}

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
        local v = self.AssemblyLinearVelocity
        if v then
            local newPosition = self.Position + v * dt
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

        function player:_mockClearCharacter()
            local current = self.Character
            self.Character = nil
            removingSignal:Fire(current)
        end
    end

    local stats = Runtime.createStats({})

    local virtualInputLog = {}

    local services, remotes = Runtime.createBaseServices(scheduler, {
        initialLocalPlayer = player,
        runService = runService,
        stats = stats,
    })

    if not services.VirtualInputManager then
        services.VirtualInputManager = {
            SendKeyEvent = function(_, isPressed, keyCode, isRepeat, target)
                table.insert(virtualInputLog, {
                    timestamp = scheduler:clock(),
                    isPressed = isPressed,
                    keyCode = keyCode,
                    isRepeat = isRepeat,
                    target = target,
                })
                return true
            end,
        }
    end

    local parryContainer, remote = Runtime.createParryButtonPress({
        scheduler = scheduler,
    })
    remotes:Add(parryContainer)

    local ballsFolder = BallsFolder.new("Balls")
    local replicated = services.ReplicatedStorage
    replicated:Add(ballsFolder)

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

    local autoparryConfig = {}
    if type(autoparry.getConfig) == "function" then
        autoparryConfig = autoparry.getConfig()
    end

    local world = Physics.World.new({
        scheduler = scheduler,
        now = scheduler:clock(),
        ballsFolder = ballsFolder,
        config = autoparryConfig,
    })

    local playerAgent = world:addAgent({
        name = "player",
        instance = rootPart,
        safeRadius = autoparryConfig.safeRadius,
        latency = options.playerLatency or 0,
    })

    local originalClock = os.clock
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
        world = world,
        playerAgent = playerAgent,
        setHighlightEnabled = function(_, flag)
            highlightEnabled = flag
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

        if self.world then
            local getter = self.autoparry and self.autoparry.getConfig
            if type(getter) == "function" then
                self.world:updateConfig(getter())
            end
            self.world:step(dt)
        end
    end

    function context:addBall(options)
        if self.world then
            return self.world:addProjectile(options)
        end

        local fallback = createBall(options)
        self.ballsFolder:Add(fallback)
        return fallback
    end

    function context:clearBalls()
        if self.world then
            self.world:clearProjectiles()
        end
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
            remaining -= dt
        end
    end

    function context:resetPerformanceMetrics()
        if typeof(self.scheduler.resetProfiling) == "function" then
            self.scheduler:resetProfiling()
        end
        if self.world and typeof(self.world.resetProfiling) == "function" then
            self.world:resetProfiling()
        end
    end

    function context:getPerformanceSummary()
        local summary = {}
        if typeof(self.scheduler.getProfilingData) == "function" then
            summary.scheduler = self.scheduler:getProfilingData()
        end
        local ok, kb = pcall(collectgarbage, "count")
        if ok and type(kb) == "number" then
            summary.luaMemoryKb = kb
        end
        return summary
    end

    function context:getSmartPressState()
        local getter = self.autoparry and self.autoparry.getSmartPressState
        if type(getter) ~= "function" then
            error("AutoParry.getSmartPressState is not available", 0)
        end
        return getter()
    end

    function context:getSmartTuningSnapshot()
        local getter = self.autoparry and self.autoparry.getSmartTuningSnapshot
        if type(getter) ~= "function" then
            error("AutoParry.getSmartTuningSnapshot is not available", 0)
        end
        return getter()
    end

    function context:getTelemetryStats()
        local getter = self.autoparry and self.autoparry.getTelemetryStats
        if type(getter) ~= "function" then
            error("AutoParry.getTelemetryStats is not available", 0)
        end
        return getter()
    end

    function context:getDiagnosticsReport()
        local getter = self.autoparry and self.autoparry.getDiagnosticsReport
        if type(getter) ~= "function" then
            error("AutoParry.getDiagnosticsReport is not available", 0)
        end
        return getter()
    end

    function context:clearParryLog()
        table.clear(parryLog)
        table.clear(remoteLog)
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
        if self.world then
            self.world:destroy()
        end
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

Context.Scheduler = Scheduler
Context.createBall = createBall
Context.BallsFolder = BallsFolder
Context.createRunServiceStub = createRunServiceStub
Context.createContext = createContext
Context.World = Physics.World

return Context
