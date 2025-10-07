-- selene: allow(global_usage)
-- selene: allow(incorrect_standard_library_use)
local TestHarness = script.Parent.Parent
local Harness = require(TestHarness:WaitForChild("Harness"))

local Scheduler = Harness.Scheduler

local function createRunServiceProbe()
    local probe = {
        connectCount = 0,
        disconnectCount = 0,
        lastCallback = nil,
        lastConnection = nil,
    }

    local heartbeat = {}

    function heartbeat:Connect(callback)
        probe.connectCount += 1
        probe.lastCallback = callback

        local connection = { _probe = probe, disconnected = false }

        function connection.Disconnect(conn)
            if not conn.disconnected then
                conn.disconnected = true
                conn._probe.disconnectCount += 1
            end
        end

        connection.disconnect = connection.Disconnect
        probe.lastConnection = connection
        return connection
    end

    function probe:step(deltaTime)
        if self.lastCallback then
            self.lastCallback(deltaTime or 0)
        end
    end

    probe.Heartbeat = heartbeat
    return probe
end

local BallsFolder = {}
BallsFolder.__index = BallsFolder

function BallsFolder.new()
    return setmetatable({
        Name = "Balls",
        _children = {},
    }, BallsFolder)
end

function BallsFolder:Add(ball)
    table.insert(self._children, ball)
    ball.Parent = self
    return ball
end

function BallsFolder:GetChildren()
    return table.clone(self._children)
end

local function createBall()
    local ball = {
        Name = "BladeBall",
        Position = Vector3.new(0, 0, 5),
        AssemblyLinearVelocity = Vector3.new(0, 0, -60),
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

local function createWorkspaceStub(ballsFolder)
    return {
        Name = "Workspace",
        FindFirstChild = function(_, name)
            if name == ballsFolder.Name then
                return ballsFolder
            end
            return nil
        end,
    }
end

local function createPlayerCharacter()
    local highlight = { Name = "Highlight" }
    local root = { Position = Vector3.new(0, 0, 0) }
    local character = {
        PrimaryPart = root,
        FindFirstChild = function(_, name)
            if name == "Highlight" then
                return highlight
            end
            return nil
        end,
    }

    return character
end

return function(t)
    t.test("destroy resets signals, state, and heartbeat across sessions", function(expect)
        local cleanupTasks = {}

        local function addCleanup(fn)
            table.insert(cleanupTasks, fn)
        end

        local function cleanup()
            for index = #cleanupTasks, 1, -1 do
                cleanupTasks[index]()
            end
        end

        local ok, err = pcall(function()
            local runServiceProbe = createRunServiceProbe()

            local originalSpawn = task.spawn
            task.spawn = function(fn, ...)
                return fn(...)
            end
            addCleanup(function()
                task.spawn = originalSpawn
            end)

            local originalClock = os.clock
            addCleanup(function()
                -- selene: allow(incorrect_standard_library_use)
                os.clock = originalClock
            end)

            local originalWorkspace = rawget(_G, "workspace")
            addCleanup(function()
                rawset(_G, "workspace", originalWorkspace)
            end)

            -- First session setup
            local scheduler1 = Scheduler.new(0.05)
            local ballsFolder1 = BallsFolder.new()
            local workspaceStub1 = createWorkspaceStub(ballsFolder1)
            rawset(_G, "workspace", workspaceStub1)

            local character1 = createPlayerCharacter()
            local player1 = {
                Name = "LocalPlayer",
                Character = character1,
            }

            local services1, remotes1 = Harness.createBaseServices(scheduler1, {
                initialLocalPlayer = player1,
                runService = runServiceProbe,
            })

            local remote1 = Harness.createRemote()
            remotes1:Add(remote1)

            local autoparry1 = Harness.loadAutoparry({
                scheduler = scheduler1,
                services = services1,
            })

            addCleanup(function()
                if autoparry1 then
                    autoparry1.destroy()
                end
            end)

            -- selene: allow(incorrect_standard_library_use)
            os.clock = function()
                return scheduler1:clock()
            end

            local defaults = autoparry1.getConfig()
            local mutatedCooldown = defaults.cooldown + 0.15
            local configured = autoparry1.configure({ cooldown = mutatedCooldown })
            expect(configured.cooldown):toEqual(mutatedCooldown)

            local firstRunStateEvents = {}
            autoparry1.onStateChanged(function(enabled)
                table.insert(firstRunStateEvents, enabled)
            end)

            local firstRunParryEvents = {}
            autoparry1.onParry(function(ball, timestamp)
                table.insert(firstRunParryEvents, {
                    ball = ball,
                    time = timestamp,
                })
            end)

            ballsFolder1:Add(createBall())

            autoparry1.enable()
            expect(runServiceProbe.connectCount):toEqual(1)
            local firstConnection = runServiceProbe.lastConnection
            expect(firstConnection ~= nil):toBeTruthy()

            scheduler1:wait(0.05)
            runServiceProbe:step(0.05)

            expect(#firstRunParryEvents):toEqual(1)
            local lastParryBeforeDestroy = autoparry1.getLastParryTime()
            expect(lastParryBeforeDestroy > 0):toBeTruthy()
            expect(autoparry1.getConfig().cooldown):toEqual(mutatedCooldown)

            autoparry1.destroy()

            expect(#firstRunStateEvents):toEqual(2)
            expect(firstRunStateEvents[1]):toEqual(true)
            expect(firstRunStateEvents[2]):toEqual(false)
            expect(firstConnection.disconnected):toBeTruthy()
            expect(runServiceProbe.disconnectCount):toEqual(1)
            expect(autoparry1.getLastParryTime()):toEqual(0)
            expect(autoparry1.getConfig().cooldown):toEqual(defaults.cooldown)

            -- Second session setup via loader
            local scheduler2 = Scheduler.new(0.05)
            local ballsFolder2 = BallsFolder.new()
            local workspaceStub2 = createWorkspaceStub(ballsFolder2)
            rawset(_G, "workspace", workspaceStub2)
            runServiceProbe.lastCallback = nil

            local character2 = createPlayerCharacter()
            local player2 = {
                Name = "LocalPlayer",
                Character = character2,
            }

            local services2, remotes2 = Harness.createBaseServices(scheduler2, {
                initialLocalPlayer = player2,
                runService = runServiceProbe,
            })

            local remote2 = Harness.createRemote()
            remotes2:Add(remote2)

            local autoparry2 = Harness.loadAutoparry({
                scheduler = scheduler2,
                services = services2,
            })

            addCleanup(function()
                if autoparry2 then
                    autoparry2.destroy()
                end
            end)

            -- selene: allow(incorrect_standard_library_use)
            os.clock = function()
                return scheduler2:clock()
            end

            local secondRunStateEvents = {}
            autoparry2.onStateChanged(function(enabled)
                table.insert(secondRunStateEvents, enabled)
            end)

            local secondRunParryEvents = {}
            autoparry2.onParry(function(ball, timestamp)
                table.insert(secondRunParryEvents, {
                    ball = ball,
                    time = timestamp,
                })
            end)

            ballsFolder2:Add(createBall())

            local secondDefaults = autoparry2.getConfig()
            for key, value in pairs(defaults) do
                expect(secondDefaults[key]):toEqual(value)
            end
            expect(autoparry2.getLastParryTime()):toEqual(0)

            autoparry2.enable()
            expect(runServiceProbe.connectCount):toEqual(2)
            local secondConnection = runServiceProbe.lastConnection
            expect(secondConnection ~= nil):toBeTruthy()
            expect(secondConnection.disconnected):toEqual(false)

            scheduler2:wait(0.05)
            runServiceProbe:step(0.05)

            expect(#secondRunParryEvents):toEqual(1)
            expect(autoparry2.getLastParryTime() > 0):toBeTruthy()
            expect(#firstRunParryEvents):toEqual(1)
            expect(#firstRunStateEvents):toEqual(2)

            autoparry2.destroy()

            expect(#secondRunStateEvents):toEqual(2)
            expect(secondRunStateEvents[1]):toEqual(true)
            expect(secondRunStateEvents[2]):toEqual(false)
            expect(secondConnection.disconnected):toBeTruthy()
            expect(runServiceProbe.disconnectCount):toEqual(2)
            expect(autoparry2.getLastParryTime()):toEqual(0)

            -- Ensure final config reset matches defaults again
            local finalConfig = autoparry2.getConfig()
            for key, value in pairs(defaults) do
                expect(finalConfig[key]):toEqual(value)
            end
        end)

        cleanup()

        if not ok then
            error(err, 0)
        end
    end)
end
