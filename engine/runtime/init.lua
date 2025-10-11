-- selene: allow(global_usage)
-- selene: allow(incorrect_standard_library_use)

local Runtime = {}

local Scheduler = {}
Scheduler.__index = Scheduler

local systemClock = os.clock
local okTick, tickFn = pcall(function()
    -- selene: allow(undefined_variable)
    return tick
end)
if not okTick or type(tickFn) ~= "function" then
    tickFn = nil
end

local function monotonicTime()
    if type(systemClock) == "function" then
        local ok, value = pcall(systemClock)
        if ok and type(value) == "number" then
            return value
        end
    end

    if tickFn then
        local ok, value = pcall(tickFn)
        if ok and type(value) == "number" then
            return value
        end
    end

    return nil
end

local function sampleGc(profile)
    if not profile then
        return
    end

    local ok, value = pcall(collectgarbage, "count")
    if not ok or type(value) ~= "number" then
        return
    end

    local gc = profile.gc
    if not gc then
        gc = { samples = 0 }
        profile.gc = gc
    end

    gc.samples = (gc.samples or 0) + 1
    gc.last = value

    if gc.samples == 1 then
        gc.start = value
        gc.min = value
        gc.max = value
    else
        if not gc.min or value < gc.min then
            gc.min = value
        end
        if not gc.max or value > gc.max then
            gc.max = value
        end
    end
end

local function createProfile()
    local profile = {
        totalAdvance = 0,
        waitCount = 0,
        minStep = nil,
        maxStep = 0,
        queueSamples = 0,
        totalQueueDepth = 0,
        maxQueueDepth = 0,
        eventsTriggered = 0,
        maxEventsPerStep = 0,
        eventfulSteps = 0,
        scheduledEvents = 0,
        hostWaitRuntime = 0,
        hostEventRuntime = 0,
        hostStart = monotonicTime(),
        latenessSamples = 0,
        onTimeSamples = 0,
        totalLateness = 0,
        maxLateness = nil,
        minLateness = nil,
    }

    sampleGc(profile)

    return profile
end

local function sanitiseNumber(value)
    if type(value) ~= "number" then
        return nil
    end
    if value ~= value then
        return nil
    end
    if value == math.huge or value == -math.huge then
        return nil
    end
    return value
end

local function compareEvents(a, b)
    if a.time == b.time then
        return (a.sequence or 0) < (b.sequence or 0)
    end
    return a.time < b.time
end

local function heapSwap(heap, a, b)
    heap[a], heap[b] = heap[b], heap[a]
end

local function heapBubbleUp(heap, index)
    while index > 1 do
        local parent = math.floor(index / 2)
        local node = heap[index]
        local parentNode = heap[parent]
        if not parentNode or compareEvents(parentNode, node) then
            break
        end
        heapSwap(heap, parent, index)
        index = parent
    end
end

local function heapBubbleDown(heap, index)
    local size = #heap
    while true do
        local left = index * 2
        local right = left + 1
        local smallest = index

        if left <= size and not compareEvents(heap[smallest], heap[left]) then
            smallest = left
        end

        if right <= size and not compareEvents(heap[smallest], heap[right]) then
            smallest = right
        end

        if smallest == index then
            break
        end

        heapSwap(heap, index, smallest)
        index = smallest
    end
end

function Scheduler.new(step)
    local self = setmetatable({
        now = 0,
        step = step or 1,
        queue = {},
        _sequence = 0,
    }, Scheduler)

    self._profile = createProfile()

    return self
end

function Scheduler:clock()
    return self.now
end

function Scheduler:_runDueEvents(profile)
    local executed = 0
    local hostStart = monotonicTime()
    while true do
        local nextEvent = self.queue[1]
        if not nextEvent or nextEvent.time > self.now then
            break
        end

        local event = self:_popEvent()
        if profile then
            local lateness = self.now - event.time
            if lateness < 0 then
                lateness = 0
            elseif lateness < 1e-6 then
                lateness = 0
            end

            profile.totalLateness += lateness
            profile.latenessSamples += 1

            if not profile.minLateness or lateness < profile.minLateness then
                profile.minLateness = lateness
            end

            if not profile.maxLateness or lateness > profile.maxLateness then
                profile.maxLateness = lateness
            end

            if lateness == 0 then
                profile.onTimeSamples += 1
            end
        end

        event.callback()
        executed += 1
    end
    if profile and hostStart then
        local hostEnd = monotonicTime()
        if hostEnd then
            profile.hostEventRuntime += math.max(hostEnd - hostStart, 0)
        end
    end
    return executed
end

function Scheduler:wait(duration)
    duration = duration or self.step
    local profile = self._profile
    local hostStart = monotonicTime()

    self.now += duration

    if profile then
        profile.totalAdvance += duration
        profile.waitCount += 1

        if not profile.minStep or duration < profile.minStep then
            profile.minStep = duration
        end

        if duration > profile.maxStep then
            profile.maxStep = duration
        end

        local depth = #self.queue
        profile.queueSamples += 1
        profile.totalQueueDepth += depth
        if depth > profile.maxQueueDepth then
            profile.maxQueueDepth = depth
        end
    end

    local executed = self:_runDueEvents(profile)

    if profile then
        profile.eventsTriggered += executed
        if executed > 0 then
            profile.eventfulSteps = (profile.eventfulSteps or 0) + 1
            if executed > profile.maxEventsPerStep then
                profile.maxEventsPerStep = executed
            end
        end

        local hostEnd = monotonicTime()
        if hostStart and hostEnd then
            profile.hostWaitRuntime += math.max(hostEnd - hostStart, 0)
        end

        sampleGc(profile)
    end

    return duration
end

function Scheduler:schedule(delay, callback)
    self._sequence += 1
    local event = {
        time = self.now + delay,
        callback = callback,
        sequence = self._sequence,
    }
    self:_pushEvent(event)
    local profile = self._profile
    if profile then
        profile.scheduledEvents += 1
        local depth = #self.queue
        if depth > profile.maxQueueDepth then
            profile.maxQueueDepth = depth
        end
    end
end

function Scheduler:resetProfiling()
    self._profile = createProfile()
    return self._profile
end

function Scheduler:_pushEvent(event)
    local queue = self.queue
    queue[#queue + 1] = event
    heapBubbleUp(queue, #queue)
end

function Scheduler:_popEvent()
    local queue = self.queue
    local size = #queue
    if size == 0 then
        return nil
    end

    local root = queue[1]
    local last = queue[size]
    queue[size] = nil
    if size > 1 then
        queue[1] = last
        heapBubbleDown(queue, 1)
    end

    return root
end

local function summariseGc(gc)
    if not gc then
        return nil
    end

    local delta
    if gc.start ~= nil and gc.last ~= nil then
        delta = gc.last - gc.start
    end

    return {
        samples = gc.samples or 0,
        startKb = gc.start,
        minKb = gc.min,
        maxKb = gc.max,
        endKb = gc.last,
        deltaKb = delta,
    }
end

function Scheduler:getProfilingData()
    local profile = self._profile or createProfile()
    local nowHost = monotonicTime()
    local elapsed
    if profile.hostStart and nowHost then
        elapsed = math.max(nowHost - profile.hostStart, 0)
    end

    local averageStep = 0
    if profile.waitCount > 0 then
        averageStep = profile.totalAdvance / profile.waitCount
    end

    local averageQueueDepth = 0
    if profile.queueSamples > 0 then
        averageQueueDepth = profile.totalQueueDepth / profile.queueSamples
    end

    local eventsPerStep = 0
    if profile.waitCount > 0 then
        eventsPerStep = profile.eventsTriggered / profile.waitCount
    end

    local utilisation
    if elapsed and elapsed > 0 then
        utilisation = profile.totalAdvance / elapsed
    end

    local minStep = sanitiseNumber(profile.minStep) or 0
    local maxStep = sanitiseNumber(profile.maxStep) or 0

    local averageLateness = 0
    if profile.latenessSamples > 0 then
        averageLateness = profile.totalLateness / profile.latenessSamples
    end
    averageLateness = sanitiseNumber(averageLateness) or 0

    local minLateness = sanitiseNumber(profile.minLateness)
    local maxLateness = sanitiseNumber(profile.maxLateness)

    return {
        stepCount = profile.waitCount,
        totalSimulated = profile.totalAdvance,
        minStep = minStep,
        maxStep = maxStep,
        averageStep = averageStep,
        scheduledEvents = profile.scheduledEvents,
        queue = {
            samples = profile.queueSamples,
            totalDepth = profile.totalQueueDepth,
            averageDepth = averageQueueDepth,
            maxDepth = profile.maxQueueDepth,
        },
        events = {
            triggered = profile.eventsTriggered,
            perStep = eventsPerStep,
            maxPerStep = profile.maxEventsPerStep,
            eventfulSteps = profile.eventfulSteps or 0,
        },
        gc = summariseGc(profile.gc),
        host = {
            startedAt = profile.hostStart,
            elapsed = elapsed,
            waitRuntime = profile.hostWaitRuntime,
            eventRuntime = profile.hostEventRuntime,
        },
        lateness = {
            samples = profile.latenessSamples,
            onTime = profile.onTimeSamples,
            total = profile.totalLateness,
            average = averageLateness,
            min = minLateness,
            max = maxLateness,
        },
        utilisation = utilisation,
        generatedAt = monotonicTime(),
    }
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

local function safeWaitForChild(container, childName, timeout)
    if container == nil then
        return nil
    end

    local waitForChild = container.WaitForChild
    if typeof(waitForChild) == "function" then
        local ok, child = pcall(waitForChild, container, childName, timeout)
        if ok then
            return child
        end
        warn("[runtime] WaitForChild", childName, "failed", child)
    end

    local findFirstChild = container.FindFirstChild
    if typeof(findFirstChild) == "function" then
        local ok, child = pcall(findFirstChild, container, childName)
        if ok then
            return child
        end
        warn("[runtime] FindFirstChild", childName, "failed", child)
    end

    if typeof(container) == "table" then
        return container[childName]
    end

    return nil
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
    local function resolveSourceMap(module)
        if module == nil then
            return nil
        end

        local ok, map = pcall(require, module)
        if ok then
            return map
        end

        warn("[runtime] failed to require AutoParrySourceMap", map)
        return nil
    end

    SourceMap = resolveSourceMap(safeWaitForChild(TestHarness, "AutoParrySourceMap"))

    if not SourceMap then
        SourceMap = resolveSourceMap(TestHarness.AutoParrySourceMap)
    end
end

Runtime.SourceMap = SourceMap

local bootstrapModule = safeWaitForChild(script, "bootstrap")
if not bootstrapModule then
    bootstrapModule = safeWaitForChild(script and script.Parent, "bootstrap")
end
if not bootstrapModule then
    error("runtime bootstrap module missing", 0)
end

local Bootstrap = require(bootstrapModule)
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
