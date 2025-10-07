-- selene: allow(global_usage)
-- selene: allow(incorrect_standard_library_use)
local TestHarness = script.Parent
local SourceMap = require(TestHarness:WaitForChild("AutoParrySourceMap"))

local Harness = {}

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

Harness.Scheduler = Scheduler

local function createContainer(scheduler, name)
    local children = {}
    local container = { Name = name }

    function container:Add(child)
        children[child.Name] = child
        child.Parent = container
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

    return container
end

Harness.createContainer = createContainer

function Harness.createRemote(options)
    options = options or {}

    local kind = options.kind or "RemoteEvent"
    local name = options.name or "ParryButtonPress"
    local className = options.className

    local remote = { Name = name }

    local function assign(methodName, impl)
        remote[methodName] = impl
        remote._parryMethod = methodName
    end

    if kind == "RemoteEvent" then
        remote.ClassName = className or "RemoteEvent"

        assign("FireServer", function(self, ...)
            self.lastPayload = { ... }
        end)
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

    return remote
end

function Harness.createRunService()
    local heartbeat = {}

    function heartbeat:Connect()
        return {
            Disconnect = function() end,
            disconnect = function(connection)
                connection:Disconnect()
            end,
        }
    end

    return { Heartbeat = heartbeat }
end

local function copyResponse(response)
    return table.clone(response)
end

function Harness.createStats(options)
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

local function createVirtualRequire()
    local cache = {}

    local function virtualRequire(path)
        local source = SourceMap[path]
        assert(source, "Missing source map entry for " .. tostring(path))

        if cache[path] ~= nil then
            return cache[path]
        end

        local chunk, err = loadstring(source, "=" .. path)
        assert(chunk, err)

        local previous = rawget(_G, "ARequire")
        rawset(_G, "ARequire", virtualRequire)

        local ok, result = pcall(chunk)

        if previous == nil then
            rawset(_G, "ARequire", nil)
        else
            rawset(_G, "ARequire", previous)
        end

        if not ok then
            error(result, 0)
        end

        cache[path] = result
        return result
    end

    return virtualRequire
end

function Harness.loadAutoparry(options)
    local scheduler = options.scheduler
    local services = options.services

    local originalWait = task.wait
    local originalClock = os.clock
    local originalGetService = game.GetService
    local previousRequire = rawget(_G, "ARequire")

    task.wait = function(duration)
        return scheduler:wait(duration)
    end

    -- selene: allow(incorrect_standard_library_use)
    os.clock = function()
        return scheduler:clock()
    end

    game.GetService = function(self, name)
        local stub = services[name]
        if stub ~= nil then
            return stub
        end
        return originalGetService(self, name)
    end

    rawset(_G, "ARequire", createVirtualRequire())

    local chunk, err = loadstring(SourceMap["src/core/autoparry.lua"], "=src/core/autoparry.lua")
    assert(chunk, err)

    local function cleanup()
        task.wait = originalWait
        -- selene: allow(incorrect_standard_library_use)
        os.clock = originalClock
        game.GetService = originalGetService
        if previousRequire == nil then
            rawset(_G, "ARequire", nil)
        else
            rawset(_G, "ARequire", previousRequire)
        end
    end

    local ok, result = pcall(chunk)
    cleanup()

    if not ok then
        error(result, 0)
    end

    return result
end

function Harness.createBaseServices(scheduler, options)
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
        RunService = options.runService or Harness.createRunService(),
        Stats = options.stats or Harness.createStats(options.statsOptions),
    }

    return services, remotes, players
end

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

function Harness.extractInternals(api)
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

return Harness
