-- selene: allow(global_usage)
-- selene: allow(incorrect_standard_library_use)

local Runtime = {}

local Scheduler = {}
Scheduler.__index = Scheduler

function Scheduler.new(step)
    return setmetatable({
        now = 0,
        step = step or 1,
        queue = {},
    }, Scheduler)
end

function Scheduler:clock()
    return self.now
end

function Scheduler:_runDueEvents()
    local index = 1
    while index <= #self.queue do
        local item = self.queue[index]
        if item.time <= self.now then
            table.remove(self.queue, index)
            item.callback()
        else
            index += 1
        end
    end
end

function Scheduler:wait(duration)
    duration = duration or self.step
    self.now += duration
    self:_runDueEvents()
    return duration
end

function Scheduler:schedule(delay, callback)
    table.insert(self.queue, {
        time = self.now + delay,
        callback = callback,
    })
end

Runtime.Scheduler = Scheduler

local function createSignal()
    local handlers = {}
    local nextId = 0

    local signal = {}

    function signal:Connect(callback)
        nextId += 1
        handlers[nextId] = callback

        local connection = { _id = nextId }

        function connection:Disconnect()
            handlers[connection._id] = nil
        end

        connection.disconnect = connection.Disconnect

        return connection
    end

    signal.connect = signal.Connect

    function signal:Fire(...)
        for _, callback in pairs(handlers) do
            callback(...)
        end
    end

    signal.fire = signal.Fire

    return signal
end

Runtime.createSignal = createSignal

local function createContainer(scheduler, name)
    local children = {}
    local container = { Name = name }
    local childAdded = createSignal()
    local childRemoved = createSignal()
    local destroyingSignal = createSignal()

    container.ChildAdded = childAdded
    container.ChildRemoved = childRemoved
    container.Destroying = destroyingSignal

    function container:Add(child)
        children[child.Name] = child
        if type(child._mockSetParent) == "function" then
            child:_mockSetParent(container)
        else
            child.Parent = container
        end
        childAdded:Fire(child)
        return child
    end

    function container:Remove(childName)
        local child = children[childName]
        if not child then
            return nil
        end

        children[childName] = nil

        if type(child._mockSetParent) == "function" then
            child:_mockSetParent(nil)
        else
            child.Parent = nil
        end

        childRemoved:Fire(child)
        return child
    end

    function container:FindFirstChild(childName)
        return children[childName]
    end

    function container:WaitForChild(childName, timeout)
        timeout = timeout or math.huge
        local start = scheduler:clock()
        local child = children[childName]
        while not child do
            if scheduler:clock() - start >= timeout then
                break
            end
            scheduler:wait()
            child = children[childName]
        end
        return child
    end

    function container:GetChildren()
        local result = {}
        for _, child in pairs(children) do
            table.insert(result, child)
        end
        return result
    end

    function container:_mockDestroy()
        destroyingSignal:Fire(container)
        for key in pairs(children) do
            children[key] = nil
        end
    end

    return container
end

Runtime.createContainer = createContainer

local function createRemote(options)
    options = options or {}

    local kind = options.kind or "RemoteEvent"
    local name = options.name or "ParryButtonPress"
    local className = options.className

    local remote = { Name = name, Parent = nil }
    local propertySignals = {}

    local function ensurePropertySignal(propertyName)
        local signal = propertySignals[propertyName]
        if not signal then
            signal = createSignal()
            propertySignals[propertyName] = signal
        end

        return signal
    end

    function remote:GetPropertyChangedSignal(propertyName)
        return ensurePropertySignal(propertyName)
    end

    local ancestrySignal = createSignal()
    local destroyingSignal = createSignal()
    remote.AncestryChanged = ancestrySignal
    remote.Destroying = destroyingSignal

    function remote:_mockSetParent(newParent)
        if remote.Parent == newParent then
            return
        end

        remote.Parent = newParent

        local parentSignal = propertySignals.Parent
        if parentSignal then
            parentSignal:Fire()
        end

        ancestrySignal:Fire(remote, newParent)
    end

    function remote:_mockDestroy()
        remote:_mockSetParent(nil)
        destroyingSignal:Fire(remote)
    end

    local function assign(methodName, impl)
        remote[methodName] = impl
        remote._parryMethod = methodName
    end

    if kind == "RemoteEvent" then
        remote.ClassName = className or "RemoteEvent"

        assign("FireServer", function(self, ...)
            self.lastPayload = { ... }
        end)

        local signal = createSignal()
        remote.OnClientEvent = signal
        remote._mockFireClient = function(_, ...)
            signal:Fire(...)
        end
        remote._mockFireAllClients = remote._mockFireClient
    elseif kind == "BindableEvent" then
        remote.ClassName = className or "BindableEvent"

        assign("Fire", function(self, ...)
            self.lastPayload = { ... }
        end)
    elseif kind == "RemoteFunction" then
        remote.ClassName = className or "RemoteFunction"

        assign("InvokeServer", function(self, ...)
            self.lastPayload = { ... }
        end)
    elseif kind == "BindableFunction" then
        remote.ClassName = className or "BindableFunction"

        assign("Invoke", function(self, ...)
            self.lastPayload = { ... }
        end)
    else
        error(string.format("Unsupported remote kind: %s", tostring(kind)))
    end

    function remote:IsA(className)
        return self.ClassName == className
    end

    return remote
end

Runtime.createRemote = createRemote

local function createParryButtonPress(options)
    options = options or {}
    local scheduler = options.scheduler
    if not scheduler then
        error("createParryButtonPress requires a scheduler", 0)
    end

    local containerName = options.name or "ParryButtonPress"
    local childName = options.childName or "parryButtonPress"
    local container = createContainer(scheduler, containerName)
    container.ClassName = options.className or "Folder"

    local remote = createRemote({
        kind = options.remoteKind or "BindableEvent",
        name = childName,
        className = options.remoteClassName,
    })

    container:Add(remote)
    container._parryRemote = remote

    return container, remote
end

Runtime.createParryButtonPress = createParryButtonPress

local function fireRemoteClient(remote, ...)
    if not remote then
        return
    end

    local signal = remote.OnClientEvent
    if not signal then
        return
    end

    local ok, fire = pcall(function()
        return signal.Fire or signal.fire
    end)

    if ok and fire then
        fire(signal, ...)
    elseif type(signal) == "function" then
        signal(...)
    end
end

Runtime.fireRemoteClient = fireRemoteClient

local function createRunService()
    local function createStubSignal()
        local signal = {}

        function signal:Connect()
            local connection = {}

            function connection:Disconnect() end

            connection.disconnect = connection.Disconnect

            return connection
        end

        function signal:Wait() end

        return signal
    end

    local heartbeat = createStubSignal()
    local preRender = createStubSignal()

    return { Heartbeat = heartbeat, PreRender = preRender }
end

Runtime.createRunService = createRunService

local function copyResponse(response)
    return table.clone(response)
end

local function createStats(options)
    options = options or {}
    local responses = {}

    if options.pingResponses then
        for _, response in ipairs(options.pingResponses) do
            table.insert(responses, copyResponse(response))
        end
    else
        responses[1] = { value = 95 }
    end

    if #responses == 0 then
        error("createStats requires at least one ping response", 0)
    end

    local lastIndex = #responses
    local responseIndex = 0
    local onPingRequested = options.onPingRequested

    local function selectResponse()
        if responseIndex < lastIndex then
            responseIndex += 1
        end
        local response = responses[math.max(responseIndex, 1)]
        if onPingRequested then
            onPingRequested(response, responseIndex)
        end
        return response
    end

    local serverStatsItem = {}

    setmetatable(serverStatsItem, {
        __index = function(_, key)
            if key ~= "Data Ping" then
                return nil
            end

            local response = selectResponse()

            if response.statError then
                error(response.statError)
            end

            if response.statMissing then
                return nil
            end

            local item = {}

            function item:GetValue()
                if response.valueError then
                    error(response.valueError)
                end

                if response.valueIsNil then
                    return nil
                end

                return response.value
            end

            return item
        end,
    })

    local stats = {
        Network = {
            ServerStatsItem = serverStatsItem,
        },
    }

    stats._pingResponses = responses
    stats._responseIndex = function()
        return responseIndex
    end

    return stats
end

Runtime.createStats = createStats

local function createDataStore(options)
    options = options or {}
    local state = {}

    if options.initialState then
        for key, value in pairs(options.initialState) do
            state[key] = value
        end
    end

    local dataStore = { _state = state }

    function dataStore:GetAsync(key)
        local value = state[key]
        if type(value) == "table" then
            return table.clone(value)
        end
        return value
    end

    function dataStore:SetAsync(key, value)
        state[key] = value
        return value
    end

    function dataStore:UpdateAsync(key, transform)
        local current = state[key]
        local nextValue = transform(current)
        state[key] = nextValue
        return nextValue
    end

    function dataStore:RemoveAsync(key)
        local value = state[key]
        state[key] = nil
        return value
    end

    return dataStore
end

Runtime.createDataStore = createDataStore

local function createBaseServices(scheduler, options)
    options = options or {}
    local players = options.players or {}

    local rosterList = {}
    local rosterSet = {}

    local function addPlayer(player)
        if player and not rosterSet[player] then
            rosterSet[player] = true
            table.insert(rosterList, player)
        end
    end

    function players:GetPlayers()
        local result = {}
        for index, player in ipairs(rosterList) do
            result[index] = player
        end
        return result
    end

    function players:_setLocalPlayer(player)
        rawset(self, "LocalPlayer", player)
        addPlayer(player)
    end

    function players:_addPlayer(player)
        addPlayer(player)
    end

    if options.initialLocalPlayer ~= nil then
        players:_setLocalPlayer(options.initialLocalPlayer)
    elseif players.LocalPlayer ~= nil then
        addPlayer(players.LocalPlayer)
    end

    if options.playersList then
        for _, player in ipairs(options.playersList) do
            addPlayer(player)
        end
    end

    local replicated = options.replicated or createContainer(scheduler, "ReplicatedStorage")
    local remotes

    if options.includeRemotes ~= false then
        remotes = options.remotes or createContainer(scheduler, "Remotes")
        replicated:Add(remotes)
    end

    local services = {
        Players = players,
        ReplicatedStorage = replicated,
        RunService = options.runService or createRunService(),
        Stats = options.stats or createStats(options.statsOptions),
    }

    return services, remotes, players
end

Runtime.createBaseServices = createBaseServices

local function findUpvalue(fn, target)
    local index = 1
    while true do
        local name, value = debug.getupvalue(fn, index)
        if not name then
            break
        end
        if name == target then
            return value
        end
        index += 1
    end
end

function Runtime.extractInternals(api)
    local step = findUpvalue(api.enable, "step")
    if not step then
        return {}
    end

    local internals = {}
    internals.step = step
    internals.evaluateBall = findUpvalue(step, "evaluateBall")
    internals.currentPing = findUpvalue(step, "currentPing")

    return internals
end

local function findTestHarness(instance)
    local current = instance
    while current do
        if current.Name == "TestHarness" then
            return current
        end
        current = current.Parent
    end
    return nil
end

local TestHarness = findTestHarness(script)
local SourceMap
if TestHarness then
    local ok, module = pcall(function()
        return TestHarness:WaitForChild("AutoParrySourceMap")
    end)
    if ok and module then
        SourceMap = require(module)
    end
end

Runtime.SourceMap = SourceMap

local Bootstrap = require(script:WaitForChild("bootstrap"))
Runtime.bootstrap = Bootstrap

function Runtime.loadAutoParry(options)
    options = options or {}
    if not options.scheduler then
        error("loadAutoParry requires a scheduler", 0)
    end
    if not options.services then
        error("loadAutoParry requires services", 0)
    end

    if options.sourceMap == nil then
        options.sourceMap = SourceMap
    end

    return Bootstrap.load(options)
end

function Runtime.newEngine(options)
    options = options or {}
    local scheduler = options.scheduler
    if not scheduler then
        scheduler = Scheduler.new(options.step)
    end

    local serviceOptions = {}
    if options.servicesOptions then
        for key, value in pairs(options.servicesOptions) do
            serviceOptions[key] = value
        end
    end

    local propagatedKeys = {
        "players",
        "replicated",
        "remotes",
        "includeRemotes",
        "initialLocalPlayer",
        "playersList",
        "runService",
        "stats",
        "statsOptions",
    }

    for _, key in ipairs(propagatedKeys) do
        if options[key] ~= nil and serviceOptions[key] == nil then
            serviceOptions[key] = options[key]
        end
    end

    local services, remotes, players = createBaseServices(scheduler, serviceOptions)
    local datastore = options.datastore or createDataStore(options.datastoreOptions)

    local engine = {
        services = services,
        scheduler = scheduler,
        remotes = remotes,
        datastore = datastore,
        players = players,
    }

    if type(options.onInit) == "function" then
        options.onInit(engine)
    end

    return engine
end

return Runtime
