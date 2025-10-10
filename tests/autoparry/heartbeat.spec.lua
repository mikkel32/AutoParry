-- selene: allow(global_usage)
-- selene: allow(incorrect_standard_library_use)
local TestHarness = script.Parent.Parent
local RuntimeFolder = TestHarness:WaitForChild("engine")
local Runtime = require(RuntimeFolder:WaitForChild("runtime"))

local Scheduler = Runtime.Scheduler

local function createBall(options)
    local ball = {
        Name = options.name,
        Position = options.position,
        AssemblyLinearVelocity = options.velocity,
        Parent = nil,
        _attributes = {
            realBall = true,
        },
    }

    function ball:IsA(className)
        return className == "BasePart"
    end

    function ball:GetAttribute(name)
        return self._attributes[name]
    end

    return ball
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

local function createRunServiceStub()
    local stub = {
        _connections = {},
    }

    local heartbeat = {}

    function heartbeat:Connect(callback)
        table.insert(stub._connections, callback)
        local index = #stub._connections
        local connection = {}

        function connection.Disconnect()
            stub._connections[index] = nil
        end

        connection.disconnect = connection.Disconnect
        return connection
    end

    function stub:step(deltaTime)
        for _, callback in ipairs(self._connections) do
            if callback then
                callback(deltaTime)
            end
        end
    end

    stub.Heartbeat = heartbeat
    return stub
end

return function(t)
    t.test("heartbeat selects the correct parry target each frame", function(expect)
        local scheduler = Scheduler.new(1 / 60)
        local runService = createRunServiceStub()
        local ballsFolder = BallsFolder.new()

        local originalWorkspace = rawget(_G, "workspace")
        local workspaceStub = {
            Name = "Workspace",
            FindFirstChild = function(_, name)
                if name == ballsFolder.Name then
                    return ballsFolder
                end
                return nil
            end,
        }

        rawset(_G, "workspace", workspaceStub)

        local rootPart = { Position = Vector3.new(0, 0, 0) }
        local highlight = { Name = "Highlight" }
        local character = {
            PrimaryPart = rootPart,
            FindFirstChild = function(_, name)
                if name == "Highlight" then
                    return highlight
                end
                return nil
            end,
        }

        local player = {
            Name = "LocalPlayer",
            Character = character,
        }

        local services, remotes = Runtime.createBaseServices(scheduler, {
            initialLocalPlayer = player,
            runService = runService,
        })

        local remoteContainer, remote = Runtime.createParryButtonPress({ scheduler = scheduler })
        remotes:Add(remoteContainer)

        local parryLog = {}
        local currentFrame = 0

        local originalFire = remote.Fire
        remote.Fire = function(self, ...)
            table.insert(parryLog, {
                frame = currentFrame,
                time = scheduler:clock(),
                payload = { ... },
            })
            return originalFire(self, ...)
        end

        local autoparry = Runtime.loadAutoParry({
            scheduler = scheduler,
            services = services,
        })

        local originalClock = os.clock
        -- selene: allow(incorrect_standard_library_use)
        os.clock = function()
            return scheduler:clock()
        end

        local config = autoparry.getConfig()

        local parriedByFrame = {}
        autoparry.onParry(function(ball, timestamp)
            local event = {
                frame = currentFrame,
                ball = ball,
                timestamp = timestamp,
            }
            table.insert(parriedByFrame, event)
            local lastEntry = parryLog[#parryLog]
            if lastEntry then
                lastEntry.event = event
            end
        end)

        local cooldownBall = ballsFolder:Add(createBall({
            name = "CooldownBall",
            position = Vector3.new(0, 0, 8),
            velocity = Vector3.new(0, 0, -120),
        }))

        local laterBall = ballsFolder:Add(createBall({
            name = "LaterBall",
            position = Vector3.new(0, 0, 72),
            velocity = Vector3.new(0, 0, -120),
        }))

        local soonBall

        local function advanceFrame(deltaTime)
            local dt = deltaTime or 0
            scheduler:wait(dt)
            currentFrame += 1
            runService:step(dt)
        end

        local function cleanup()
            if autoparry then
                autoparry.destroy()
            end
            rawset(_G, "workspace", originalWorkspace)
            -- selene: allow(incorrect_standard_library_use)
            os.clock = originalClock
        end

        local ok, err = pcall(function()
            autoparry.enable()

            advanceFrame(0)

            expect(#parryLog):toEqual(1)
            expect(parryLog[1].frame):toEqual(1)
            expect(type(parryLog[1].time) == "number"):toBeTruthy()
            expect(parriedByFrame[1].ball):toEqual(cooldownBall)
            expect(parriedByFrame[1].timestamp):toEqual(parryLog[1].time)
            expect(autoparry.getLastParryTime()):toEqual(parryLog[1].time)

            advanceFrame(config.cooldown * 0.5)

            expect(#parryLog):toEqual(1)
            expect(autoparry.getLastParryTime()):toEqual(parryLog[1].time)

            advanceFrame(config.cooldown * 0.6)

            expect(#parryLog):toEqual(2)
            expect(parryLog[2].frame):toEqual(3)
            expect(parriedByFrame[2].ball):toEqual(cooldownBall)
            expect(parriedByFrame[2].timestamp):toEqual(parryLog[2].time)
            expect(parryLog[2].time - parryLog[1].time):toBeGreaterThanOrEqual(config.cooldown)

            ballsFolder:Remove(cooldownBall)

            soonBall = ballsFolder:Add(createBall({
                name = "SoonBall",
                position = Vector3.new(0, 0, 60),
                velocity = Vector3.new(0, 0, -120),
            }))

            advanceFrame(0.2)

            expect(#parryLog):toEqual(3)
            expect(parryLog[3].frame):toEqual(4)
            expect(parriedByFrame[3].ball):toEqual(soonBall)
            expect(parriedByFrame[3].timestamp):toEqual(parryLog[3].time)
            expect(parryLog[3].time - parryLog[2].time):toBeGreaterThanOrEqual(config.cooldown)

            ballsFolder:Remove(soonBall)

            advanceFrame(0.2)

            expect(#parryLog):toEqual(4)
            expect(parryLog[4].frame):toEqual(5)
            expect(parriedByFrame[4].ball):toEqual(laterBall)
            expect(parriedByFrame[4].timestamp):toEqual(parryLog[4].time)
            expect(parryLog[4].time - parryLog[3].time):toBeGreaterThanOrEqual(config.cooldown)

            local attemptsByFrame = {}
            for _, entry in ipairs(parryLog) do
                attemptsByFrame[entry.frame] = (attemptsByFrame[entry.frame] or 0) + 1
            end

            for _, attempts in pairs(attemptsByFrame) do
                expect(attempts):toEqual(1)
            end

            expect(#parryLog):toEqual(#parriedByFrame)
            for index, event in ipairs(parriedByFrame) do
                expect(event.timestamp):toEqual(parryLog[index].time)
            end

            if t.artifact then
                local cooldownMetrics = {}
                local previousTime

                for index, entry in ipairs(parryLog) do
                    local delta = previousTime and (entry.time - previousTime) or nil
                    table.insert(cooldownMetrics, {
                        index = index,
                        frame = entry.frame,
                        timestamp = entry.time,
                        deltaFromPrevious = delta,
                        ball = entry.event and entry.event.ball and entry.event.ball.Name or nil,
                    })
                    previousTime = entry.time
                end

                t.artifact("heartbeat-parry-metrics", {
                    cooldown = config.cooldown,
                    framesSimulated = currentFrame,
                    parries = cooldownMetrics,
                })
            end
        end)

        cleanup()

        if not ok then
            error(err, 0)
        end
    end)
end
