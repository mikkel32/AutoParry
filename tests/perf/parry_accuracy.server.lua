-- selene: allow(global_usage)
-- selene: allow(incorrect_standard_library_use)
-- selene: allow(shadowing)
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestHarness = ReplicatedStorage:WaitForChild("TestHarness")
local SourceMap = require(TestHarness:WaitForChild("AutoParrySourceMap"))

local function cloneTable(source)
    local copy = {}
    for key, value in pairs(source) do
        if typeof(value) == "table" then
            copy[key] = cloneTable(value)
        else
            copy[key] = value
        end
    end
    return copy
end

local function deepMerge(defaults, overrides)
    local merged = cloneTable(defaults)
    for key, value in pairs(overrides) do
        if typeof(value) == "table" and typeof(defaults[key]) == "table" then
            if #value > 0 then
                merged[key] = value
            else
                merged[key] = deepMerge(defaults[key], value)
            end
        else
            merged[key] = value
        end
    end
    return merged
end

local function loadConfig()
    local defaults = {
        frameDuration = 1 / 120,
        warmupFrames = 6,
        ping = 95,
        thresholds = {
            minAccuracy = 1,
            maxFalsePositives = 0,
            maxZeroExpectedFalsePositives = 0,
            maxFrameViolations = 0,
            maxSpacingViolations = 0,
            maxTargetingViolations = 0,
        },
        scenarios = {
            {
                name = "direct_approach",
                frames = 12,
                highlight = { start = true },
                spawnSchedule = {
                    { frame = 1, distance = 56, speed = 160 },
                },
                expected = {
                    parries = 1,
                    earliestFrame = 1,
                    latestFrame = 3,
                },
            },
            {
                name = "safe_radius_snap",
                frames = 6,
                highlight = { start = true },
                spawnSchedule = {
                    { frame = 1, distance = 8, speed = 20 },
                },
                expected = {
                    parries = 1,
                    earliestFrame = 1,
                    latestFrame = 1,
                },
            },
            {
                name = "highlight_gate",
                frames = 14,
                highlight = { start = false, enableFrame = 6 },
                spawnSchedule = {
                    { frame = 1, distance = 62, speed = 180 },
                },
                expected = {
                    parries = 1,
                    earliestFrame = 6,
                    latestFrame = 8,
                },
            },
            {
                name = "non_target_ignore",
                frames = 10,
                highlight = { start = false },
                spawnSchedule = {
                    { frame = 1, distance = 60, speed = 180 },
                },
                expected = {
                    parries = 0,
                },
            },
            {
                name = "slow_ball_ignore",
                frames = 10,
                highlight = { start = true },
                spawnSchedule = {
                    { frame = 1, distance = 60, speed = 6 },
                },
                expected = {
                    parries = 0,
                },
            },
            {
                name = "fake_ball_ignore",
                frames = 10,
                highlight = { start = true },
                spawnSchedule = {
                    { frame = 1, distance = 58, speed = 170, realBall = false },
                },
                expected = {
                    parries = 0,
                },
            },
            {
                name = "cooldown_sequence",
                frames = 64,
                highlight = { start = true },
                spawnSchedule = {
                    { frame = 1, distance = 58, speed = 180 },
                    { frame = 18, distance = 58, speed = 180 },
                    { frame = 36, distance = 58, speed = 180 },
                },
                expected = {
                    parries = 3,
                    frameSpacing = 10,
                },
            },
            {
                name = "tti_priority",
                frames = 48,
                highlight = { start = true },
                spawnSchedule = {
                    { frame = 1, name = "FarThreat", distance = 72, speed = 180 },
                    { frame = 1, name = "CloseThreat", distance = 62, speed = 240 },
                },
                expected = {
                    parries = 2,
                    earliestFrame = 1,
                    firstBallName = "CloseThreat",
                    frameSpacing = 10,
                },
            },
        },
    }

    local source = SourceMap["tests/perf/parry_accuracy.config.lua"]
    if not source then
        return defaults
    end

    local chunk, err = loadstring(source, "=tests/perf/parry_accuracy.config.lua")
    if not chunk then
        warn("[ParryAccuracy] Failed to compile config:", err)
        return defaults
    end

    local ok, result = pcall(chunk)
    if not ok then
        warn("[ParryAccuracy] Config execution failed:", result)
        return defaults
    end

    if typeof(result) ~= "table" then
        warn("[ParryAccuracy] Config module must return a table")
        return defaults
    end

    return deepMerge(defaults, result)
end

local function makeSignal(onConnect)
    local handlers = {}

    local signal = {}

    function signal:Connect(handler)
        table.insert(handlers, handler)
        if onConnect then
            onConnect(handler)
        end

        local connection = {}

        -- selene: allow(shadowing)
        function connection:Disconnect()
            for index, fn in ipairs(handlers) do
                if fn == handler then
                    table.remove(handlers, index)
                    break
                end
            end
        end

        connection.disconnect = connection.Disconnect
        return connection
    end

    function signal:Fire(...)
        for _, handler in ipairs(handlers) do
            handler(...)
        end
    end

    return signal
end

local Environment = {}
Environment.__index = Environment

function Environment.new(config)
    local env = setmetatable({}, Environment)
    env.config = config
    env.frameDuration = config.frameDuration or (1 / 120)
    env.warmupFrames = config.warmupFrames or 0
    env.simulatedTime = 0
    env.currentFrame = 0
    env.currentScenario = nil
    env.parryEvents = {}
    env.remoteLog = {}
    env.activeBalls = {}
    env.ballCounter = 0

    local heartbeatSignal
    heartbeatSignal = makeSignal(function(handler)
        env.heartbeatStep = handler
    end)

    env.runServiceStub = { Heartbeat = heartbeatSignal }

    env.statsStub = {
        Network = {
            ServerStatsItem = {
                ["Data Ping"] = {
                    GetValue = function()
                        return config.ping or 95
                    end,
                },
            },
        },
    }

    env.userInputStub = {}
    env.userInputStub.InputBegan = makeSignal()
    env.userInputStub.InputEnded = makeSignal()
    function env.userInputStub:IsKeyDown()
        return false
    end

    env.character = Instance.new("Model")
    env.character.Name = "ParryAccuracyCharacter"
    env.character.Parent = workspace

    env.root = Instance.new("Part")
    env.root.Name = "HumanoidRootPart"
    env.root.Anchored = true
    env.root.Size = Vector3.new(2, 2, 2)
    env.root.Position = Vector3.new(0, 5, 0)
    env.root.Parent = env.character
    env.character.PrimaryPart = env.root

    env.highlight = Instance.new("Folder")
    env.highlight.Name = "Highlight"
    env.highlight.Parent = env.character

    env.playersStub = {
        LocalPlayer = {
            Name = "ParryAccuracyPlayer",
            Character = env.character,
        },
    }

    env.ballsFolder = workspace:FindFirstChild("Balls")
    if not env.ballsFolder then
        env.ballsFolder = Instance.new("Folder")
        env.ballsFolder.Name = "Balls"
        env.ballsFolder.Parent = workspace
    end
    env.ballsFolder:ClearAllChildren()

    local statsStub = env.statsStub
    local runServiceStub = env.runServiceStub
    local userInputStub = env.userInputStub
    local playersStub = env.playersStub

    local originalGetService = game.GetService
    env.originalGetService = originalGetService

    function game:GetService(name)
        if name == "Stats" then
            return statsStub
        elseif name == "RunService" then
            return runServiceStub
        elseif name == "UserInputService" then
            return userInputStub
        elseif name == "Players" then
            return playersStub
        end
        return originalGetService(game, name)
    end

    local loaderChunk = assert(loadstring(SourceMap["loader.lua"], "=loader.lua"))
    local ok, apiResult = pcall(loaderChunk, {
        repo = "mikkel32/AutoParry",
        branch = "main",
        entrypoint = "src/main.lua",
        refresh = true,
    })

    assert(ok, apiResult)
    assert(typeof(apiResult) == "table", "Loader did not return the API table")

    env.api = apiResult
    env.api.resetConfig()
    env.api.setEnabled(false)

    env.parryRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("ParryButtonPress")
    env.parryAttempts = 0

    local remote = env.parryRemote
    local originalFireServer = remote.FireServer
    env.originalFireServer = originalFireServer
    local environment = env

    function remote:FireServer(...)
        environment.parryAttempts += 1
        local payload = { ... }
        table.insert(environment.remoteLog, {
            frame = environment.currentFrame,
            timestamp = environment.simulatedTime,
            scenario = environment.currentScenario,
            payload = payload,
        })
        return originalFireServer(self, ...)
    end

    env.parryConnection = env.api.onParry(function(ball, timestamp)
        local event = {
            frame = env.currentFrame,
            timestamp = timestamp,
            scenario = env.currentScenario,
            ballName = ball and ball.Name or nil,
        }
        table.insert(env.parryEvents, event)

        if ball then
            for index, active in ipairs(env.activeBalls) do
                if active == ball then
                    table.remove(env.activeBalls, index)
                    break
                end
            end
            ball:Destroy()
        end
    end)

    env.originalClock = os.clock
    -- selene: allow(incorrect_standard_library_use)
    os.clock = function()
        return env.simulatedTime
    end

    return env
end

function Environment:setHighlightEnabled(flag)
    if flag then
        self.highlight.Parent = self.character
    else
        self.highlight.Parent = nil
    end
end

function Environment:clearBalls()
    for index = #self.activeBalls, 1, -1 do
        local ball = self.activeBalls[index]
        if ball then
            ball:Destroy()
        end
        table.remove(self.activeBalls, index)
    end
    self.ballsFolder:ClearAllChildren()
end

function Environment:spawnBall(descriptor)
    descriptor = descriptor or {}

    local ball = Instance.new("Part")
    ball.Name = descriptor.name or string.format("ParryAccuracyBall_%03d", self.ballCounter + 1)
    ball.Shape = Enum.PartType.Ball
    ball.Material = Enum.Material.SmoothPlastic
    ball.Color = Color3.fromRGB(255, 170, 0)
    ball.CanCollide = false
    ball.Anchored = true
    ball.Size = Vector3.new(1, 1, 1)

    local distance = descriptor.distance or 56
    local lateral = descriptor.lateral or 0
    local height = descriptor.height or 5

    ball.Position = Vector3.new(lateral, height, distance)

    local velocity
    if descriptor.velocity then
        velocity = descriptor.velocity
    else
        local speed = math.abs(descriptor.speed or 160)
        local lateralVelocity = descriptor.lateralVelocity or 0
        local verticalVelocity = descriptor.verticalVelocity or 0
        velocity = Vector3.new(-lateralVelocity, verticalVelocity, -speed)
    end

    ball.AssemblyLinearVelocity = velocity
    ball:SetAttribute("realBall", descriptor.realBall ~= false)
    ball.Parent = self.ballsFolder

    self.ballCounter += 1
    table.insert(self.activeBalls, ball)
    return ball
end

function Environment:prepareScenario(name)
    self.currentScenario = name
    self.parryBaseline = #self.parryEvents
    self.remoteBaseline = #self.remoteLog
end

function Environment:getScenarioParries()
    local events = {}
    for index = self.parryBaseline + 1, #self.parryEvents do
        local event = self.parryEvents[index]
        table.insert(events, {
            frame = event.frame,
            timestamp = event.timestamp,
            ballName = event.ballName,
        })
    end
    return events
end

function Environment:getScenarioAttempts()
    local events = {}
    for index = self.remoteBaseline + 1, #self.remoteLog do
        local event = self.remoteLog[index]
        table.insert(events, {
            frame = event.frame,
            timestamp = event.timestamp,
            payload = event.payload,
        })
    end
    return events
end

function Environment:setFrame(frame)
    self.currentFrame = frame
end

function Environment:advanceFrame()
    if not self.heartbeatStep then
        error("[ParryAccuracy] AutoParry did not attach a heartbeat listener", 0)
    end
    self.simulatedTime += self.frameDuration
    self.heartbeatStep(self.frameDuration)
end

function Environment:cleanup()
    local destroyOk, destroyErr = pcall(function()
        if self.api then
            self.api.destroy()
        end
    end)

    if not destroyOk then
        warn("[ParryAccuracy] Failed to destroy AutoParry API:", destroyErr)
    end

    if self.parryConnection then
        self.parryConnection:Disconnect()
        self.parryConnection = nil
    end

    if self.parryRemote and self.originalFireServer then
        self.parryRemote.FireServer = self.originalFireServer
    end

    if self.originalGetService then
        game.GetService = self.originalGetService
    end

    -- selene: allow(incorrect_standard_library_use)
    os.clock = self.originalClock

    self:clearBalls()

    if self.highlight then
        self.highlight:Destroy()
        self.highlight = nil
    end

    if self.character then
        self.character:Destroy()
        self.character = nil
    end
end

local function runScenario(environment, config, scenario)
    environment:clearBalls()
    environment.api.resetConfig()

    if scenario.config then
        environment.api.configure(cloneTable(scenario.config))
    end

    local highlightEnabled = true
    if scenario.highlight then
        if scenario.highlight.start ~= nil then
            highlightEnabled = scenario.highlight.start
        end
    end
    environment:setHighlightEnabled(highlightEnabled)

    environment:setFrame(0)
    environment:prepareScenario(scenario.name)

    local spawnSchedule = scenario.spawnSchedule or {}
    for _, spawn in ipairs(spawnSchedule) do
        if spawn.frame == 0 then
            environment:spawnBall(spawn)
        end
    end

    environment.api.setEnabled(true)

    for index = 1, config.warmupFrames do
        environment:setFrame(-index)
        environment:advanceFrame()
    end

    for frame = 1, scenario.frames do
        environment:setFrame(frame)

        if scenario.highlight then
            if scenario.highlight.enableFrame == frame then
                environment:setHighlightEnabled(true)
            end
            if scenario.highlight.disableFrame == frame then
                environment:setHighlightEnabled(false)
            end
        end

        for _, spawn in ipairs(spawnSchedule) do
            if spawn.frame == frame then
                environment:spawnBall(spawn)
            end
        end

        environment:advanceFrame()
    end

    environment.api.setEnabled(false)

    local parries = environment:getScenarioParries()
    local attempts = environment:getScenarioAttempts()

    environment:clearBalls()
    environment:setHighlightEnabled(true)

    return {
        name = scenario.name,
        expected = scenario.expected or { parries = 0 },
        parries = parries,
        attempts = attempts,
    }
end

local function summarise(results, config)
    local totals = {
        expected = 0,
        actual = 0,
        trueParries = 0,
        missed = 0,
        falsePositives = 0,
        zeroExpectedFalsePositives = 0,
        frameViolations = 0,
        spacingViolations = 0,
        targetingViolations = 0,
    }

    local scenarios = {}

    for _, result in ipairs(results) do
        local expectedSpec = result.expected or {}
        local expected = expectedSpec.parries or 0
        local actual = #result.parries

        local scenarioSummary = {
            name = result.name,
            expected = expected,
            actual = actual,
            attempts = #result.attempts,
            parries = result.parries,
        }

        local falsePositives = math.max(0, actual - expected)
        local missed = math.max(0, expected - actual)

        totals.expected += expected
        totals.actual += actual
        totals.falsePositives += falsePositives
        totals.missed += missed

        if expected > 0 then
            totals.trueParries += math.min(actual, expected)
        else
            if actual > 0 then
                totals.zeroExpectedFalsePositives += actual
            end
        end

        scenarioSummary.falsePositives = falsePositives
        scenarioSummary.missed = missed

        if actual > 0 then
            scenarioSummary.firstFrame = result.parries[1].frame
            scenarioSummary.lastFrame = result.parries[#result.parries].frame
            scenarioSummary.firstBallName = result.parries[1].ballName
        end

        if expectedSpec.earliestFrame and actual > 0 then
            if result.parries[1].frame < expectedSpec.earliestFrame then
                scenarioSummary.frameViolation = string.format(
                    "first parry on frame %d before minimum %d",
                    result.parries[1].frame,
                    expectedSpec.earliestFrame
                )
                totals.frameViolations += 1
            end
        end

        if expectedSpec.latestFrame and actual > 0 then
            if result.parries[#result.parries].frame > expectedSpec.latestFrame then
                scenarioSummary.frameViolation = string.format(
                    "last parry on frame %d after maximum %d",
                    result.parries[#result.parries].frame,
                    expectedSpec.latestFrame
                )
                totals.frameViolations += 1
            end
        end

        if expectedSpec.firstBallName and actual > 0 then
            if result.parries[1].ballName ~= expectedSpec.firstBallName then
                scenarioSummary.targetingViolation = string.format(
                    "expected first parry to target %s but got %s",
                    expectedSpec.firstBallName,
                    tostring(result.parries[1].ballName)
                )
                totals.targetingViolations += 1
            end
        end

        if expectedSpec.frameSpacing and actual > 1 then
            for index = 2, actual do
                local spacing = result.parries[index].frame - result.parries[index - 1].frame
                if spacing < expectedSpec.frameSpacing then
                    scenarioSummary.spacingViolation = string.format(
                        "parry spacing %d below minimum %d",
                        spacing,
                        expectedSpec.frameSpacing
                    )
                    totals.spacingViolations += 1
                    break
                end
            end
        end

        table.insert(scenarios, scenarioSummary)
    end

    local accuracy = 1
    local precision = 1

    local positiveExpected = 0
    for _, result in ipairs(results) do
        local expected = (result.expected and result.expected.parries) or 0
        if expected > 0 then
            positiveExpected += expected
        end
    end

    if positiveExpected > 0 then
        accuracy = totals.trueParries / positiveExpected
    end

    if totals.actual > 0 then
        precision = totals.trueParries / totals.actual
    end

    local summary = {
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        frameDuration = config.frameDuration,
        warmupFrames = config.warmupFrames,
        ping = config.ping,
        totals = {
            expected = totals.expected,
            actual = totals.actual,
            trueParries = totals.trueParries,
            missed = totals.missed,
            falsePositives = totals.falsePositives,
            zeroExpectedFalsePositives = totals.zeroExpectedFalsePositives,
            frameViolations = totals.frameViolations,
            spacingViolations = totals.spacingViolations,
            targetingViolations = totals.targetingViolations,
            accuracy = accuracy,
            precision = precision,
        },
        scenarios = scenarios,
        thresholds = config.thresholds,
    }

    local failures = {}
    local thresholds = config.thresholds or {}

    if thresholds.minAccuracy and accuracy < thresholds.minAccuracy then
        table.insert(failures, string.format("accuracy %.4f below %.4f", accuracy, thresholds.minAccuracy))
    end

    if thresholds.maxFalsePositives and totals.falsePositives > thresholds.maxFalsePositives then
        table.insert(failures, string.format("false positives %d above %d", totals.falsePositives, thresholds.maxFalsePositives))
    end

    if thresholds.maxZeroExpectedFalsePositives and totals.zeroExpectedFalsePositives > thresholds.maxZeroExpectedFalsePositives then
        table.insert(failures, string.format(
            "zero-expected false positives %d above %d",
            totals.zeroExpectedFalsePositives,
            thresholds.maxZeroExpectedFalsePositives
        ))
    end

    if thresholds.maxFrameViolations and totals.frameViolations > thresholds.maxFrameViolations then
        table.insert(failures, string.format("frame violations %d above %d", totals.frameViolations, thresholds.maxFrameViolations))
    end

    if thresholds.maxSpacingViolations and totals.spacingViolations > thresholds.maxSpacingViolations then
        table.insert(failures, string.format("spacing violations %d above %d", totals.spacingViolations, thresholds.maxSpacingViolations))
    end

    if thresholds.maxTargetingViolations and totals.targetingViolations > thresholds.maxTargetingViolations then
        table.insert(failures, string.format(
            "targeting violations %d above %d",
            totals.targetingViolations,
            thresholds.maxTargetingViolations
        ))
    end

    summary.failures = failures

    return summary
end

local function main()
    local config = loadConfig()
    local environment = Environment.new(config)

    local results = {}
    local success, runErr = pcall(function()
        for _, scenario in ipairs(config.scenarios) do
            local result = runScenario(environment, config, scenario)
            table.insert(results, result)
        end
    end)

    local cleanupOk, cleanupErr = pcall(function()
        environment:cleanup()
    end)

    if not cleanupOk then
        warn("[ParryAccuracy] Cleanup failed:", cleanupErr)
    end

    if not success then
        error(runErr, 0)
    end

    local summary = summarise(results, config)
    local encoded = HttpService:JSONEncode(summary)
    print(string.format("[ACCURACY] %s", encoded))

    if summary.failures and #summary.failures > 0 then
        error("[ParryAccuracy] Benchmark violations: " .. table.concat(summary.failures, "; "), 0)
    end
end

local ok, err = pcall(main)
if not ok then
    error(err, 0)
end
