local TestHarness = script.Parent.Parent
local SourceMap = require(TestHarness:WaitForChild("AutoParrySourceMap"))

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

local function createRemote()
    local remote = { Name = "ParryButtonPress" }

    function remote:FireServer(...)
        self.lastPayload = { ... }
    end

    return remote
end

local function createRunService()
    local heartbeat = {}

    function heartbeat:Connect()
        return {
            Disconnect = function() end,
            disconnect = function(self)
                self:Disconnect()
            end,
        }
    end

    return { Heartbeat = heartbeat }
end

local function createStats()
    return {
        Network = {
            ServerStatsItem = {
                ["Data Ping"] = {
                    GetValue = function()
                        return 95
                    end,
                },
            },
        },
    }
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

local function loadAutoparry(options)
    local scheduler = options.scheduler
    local services = options.services

    local originalWait = task.wait
    local originalClock = os.clock
    local originalGetService = game.GetService
    local previousRequire = rawget(_G, "ARequire")

    task.wait = function(duration)
        return scheduler:wait(duration)
    end

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

local function createBaseServices(scheduler, options)
    options = options or {}
    local players = options.players or { LocalPlayer = options.initialLocalPlayer }

    if players.LocalPlayer == nil and options.initialLocalPlayer ~= nil then
        players.LocalPlayer = options.initialLocalPlayer
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
        Stats = options.stats or createStats(),
    }

    return services, remotes, players
end

return function(t)
    t.test("resolves the local player once it becomes available", function(expect)
        local scheduler = Scheduler.new(1)
        local services, remotes, players = createBaseServices(scheduler)
        remotes:Add(createRemote())

        local stubPlayer = { Name = "LocalPlayer" }
        scheduler:schedule(3, function()
            players.LocalPlayer = stubPlayer
        end)

        local autoparry = loadAutoparry({
            scheduler = scheduler,
            services = services,
        })

        expect(autoparry ~= nil):toBeTruthy()
        expect(players.LocalPlayer):toEqual(stubPlayer)
        expect(scheduler:clock()):toBeCloseTo(3, 1e-3)
    end)

    t.test("resolves the parry remote after it is created", function(expect)
        local scheduler = Scheduler.new(1)
        local services, remotes, players = createBaseServices(scheduler, {
            initialLocalPlayer = { Name = "LocalPlayer" },
        })

        scheduler:schedule(4, function()
            remotes:Add(createRemote())
        end)

        local autoparry = loadAutoparry({
            scheduler = scheduler,
            services = services,
        })

        expect(autoparry ~= nil):toBeTruthy()
        expect(remotes:FindFirstChild("ParryButtonPress") ~= nil):toBeTruthy()
        expect(scheduler:clock()):toBeCloseTo(4, 1e-3)
    end)

    t.test("errors after 10 seconds when the local player never appears", function(expect)
        local scheduler = Scheduler.new(1)
        local services, remotes = createBaseServices(scheduler)
        remotes:Add(createRemote())

        local ok, err = pcall(function()
            loadAutoparry({
                scheduler = scheduler,
                services = services,
            })
        end)

        expect(ok):toEqual(false)
        expect(err):toEqual("AutoParry: LocalPlayer unavailable")
        expect(scheduler:clock()):toBeGreaterThanOrEqual(11)
    end)

    t.test("errors after 10 seconds when the remotes folder is absent", function(expect)
        local scheduler = Scheduler.new(1)
        local services = createBaseServices(scheduler, {
            includeRemotes = false,
            initialLocalPlayer = { Name = "LocalPlayer" },
        })

        local ok, err = pcall(function()
            loadAutoparry({
                scheduler = scheduler,
                services = services,
            })
        end)

        expect(ok):toEqual(false)
        expect(err):toEqual("AutoParry: ReplicatedStorage.Remotes missing")
        expect(scheduler:clock()):toBeGreaterThanOrEqual(10)
    end)

    t.test("errors after 10 seconds when the parry remote never appears", function(expect)
        local scheduler = Scheduler.new(1)
        local services = createBaseServices(scheduler, {
            initialLocalPlayer = { Name = "LocalPlayer" },
        })

        local ok, err = pcall(function()
            loadAutoparry({
                scheduler = scheduler,
                services = services,
            })
        end)

        expect(ok):toEqual(false)
        expect(err):toEqual("AutoParry: ParryButtonPress remote missing")
        expect(scheduler:clock()):toBeGreaterThanOrEqual(10)
    end)
end
