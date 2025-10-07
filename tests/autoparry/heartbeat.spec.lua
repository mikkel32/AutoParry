local TestHarness = script.Parent.Parent
local Harness = require(TestHarness:WaitForChild("Harness"))

local Scheduler = Harness.Scheduler

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
    local copy = {}
    for index, child in ipairs(self._children) do
        copy[index] = child
    end
    return copy
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

        function connection:Disconnect()
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

        local services, remotes = Harness.createBaseServices(scheduler, {
            initialLocalPlayer = player,
            runService = runService,
        })

        local remote = Harness.createRemote()
        remotes:Add(remote)

        local parryLog = {}
        local currentFrame = 0

        local originalFireServer = remote.FireServer
        remote.FireServer = function(self, ...)
            table.insert(parryLog, {
                frame = currentFrame,
                time = scheduler:clock(),
                payload = { ... },
            })
            return originalFireServer(self, ...)
        end

        local autoparry = Harness.loadAutoparry({
            scheduler = scheduler,
            services = services,
        })

        local parriedByFrame = {}
        autoparry.onParry(function(ball)
            table.insert(parriedByFrame, {
                frame = currentFrame,
                ball = ball,
            })
        end)

        local safeBall = ballsFolder:Add(createBall({
            name = "SafeBall",
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
            scheduler:wait(deltaTime or 0)
            currentFrame += 1
            runService:step(deltaTime)
        end

        local function cleanup()
            if autoparry then
                autoparry.destroy()
            end
            rawset(_G, "workspace", originalWorkspace)
        end

        local ok, err = pcall(function()
            autoparry.enable()

            advanceFrame(0)

            expect(#parryLog):toEqual(1)
            expect(parryLog[1].frame):toEqual(1)
            expect(parriedByFrame[1].ball):toEqual(safeBall)

            ballsFolder:Remove(safeBall)

            soonBall = ballsFolder:Add(createBall({
                name = "SoonBall",
                position = Vector3.new(0, 0, 60),
                velocity = Vector3.new(0, 0, -120),
            }))

            advanceFrame(0.2)

            expect(#parryLog):toEqual(2)
            expect(parryLog[2].frame):toEqual(2)
            expect(parriedByFrame[2].ball):toEqual(soonBall)

            ballsFolder:Remove(soonBall)

            advanceFrame(0.2)

            expect(#parryLog):toEqual(3)
            expect(parryLog[3].frame):toEqual(3)
            expect(parriedByFrame[3].ball):toEqual(laterBall)

            for frame = 1, 3 do
                local attempts = 0
                for _, entry in ipairs(parryLog) do
                    if entry.frame == frame then
                        attempts += 1
                    end
                end
                expect(attempts):toEqual(1)
            end
        end)

        cleanup()

        if not ok then
            error(err, 0)
        end
    end)
end
