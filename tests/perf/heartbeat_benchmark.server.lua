local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestHarness = ReplicatedStorage:WaitForChild("TestHarness")
local SourceMap = require(TestHarness:WaitForChild("AutoParrySourceMap"))

local function cloneTable(source)
    return table.clone(source)
end

local function loadConfig()
    local defaults = {
        warmupFrames = 5,
        samplesPerBatch = 90,
        frameDuration = 1 / 120,
        ballPopulations = { 0, 24, 48, 72, 96 },
        ballSpawn = {
            baseDistance = 26,
            distanceJitter = 6,
            speedBase = 120,
            speedJitter = 18,
        },
        thresholds = {
            average = 0.002,
            p95 = 0.004,
        },
    }

    local source = SourceMap["tests/perf/config.lua"]
    if not source then
        return defaults
    end

    local chunk, err = loadstring(source, "=tests/perf/config.lua")
    if not chunk then
        warn("[HeartbeatBenchmark] Failed to compile config:", err)
        return defaults
    end

    local ok, result = pcall(chunk)
    if not ok then
        warn("[HeartbeatBenchmark] Config execution failed:", result)
        return defaults
    end

    if typeof(result) ~= "table" then
        warn("[HeartbeatBenchmark] Config module must return a table")
        return defaults
    end

    local config = table.clone(defaults)
    for key, value in pairs(result) do
        config[key] = value
    end

    return config
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

        function connection.Disconnect()
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

local function percentile(values, fraction)
    local count = #values
    if count == 0 then
        return 0
    end

    local sorted = cloneTable(values)
    table.sort(sorted)

    if count == 1 then
        return sorted[1]
    end

    local rank = (count - 1) * fraction + 1
    local lowerIndex = math.floor(rank)
    local upperIndex = math.ceil(rank)
    local interpolation = rank - lowerIndex

    local lowerValue = sorted[lowerIndex]
    local upperValue = sorted[upperIndex] or sorted[#sorted]

    if interpolation <= 0 then
        return lowerValue
    end

    if upperIndex == lowerIndex then
        return lowerValue
    end

    return lowerValue + (upperValue - lowerValue) * interpolation
end

local function average(values)
    local count = #values
    if count == 0 then
        return 0
    end

    local total = 0
    for _, value in ipairs(values) do
        total += value
    end

    return total / count
end

local function spawnSyntheticBall(folder, index, settings)
    settings = settings or {}

    local ball = Instance.new("Part")
    ball.Name = string.format("HeartbeatBenchmarkBall_%03d", index)
    ball.Shape = Enum.PartType.Ball
    ball.Material = Enum.Material.SmoothPlastic
    ball.Size = Vector3.new(1, 1, 1)
    ball.Anchored = true
    ball.CanCollide = false

    local distanceBase = settings.baseDistance or 26
    local distanceJitter = settings.distanceJitter or 0
    local speedBase = settings.speedBase or 120
    local speedJitter = settings.speedJitter or 0

    local orbitIndex = (index - 1)
    local ring = math.floor(orbitIndex / math.max(distanceJitter, 1))
    local offset = orbitIndex % math.max(distanceJitter, 1)

    local distance = distanceBase + offset
    local angle = (orbitIndex % 12) * (math.pi / 6)
    local lateral = math.sin(angle) * (distance * 0.35)
    local forward = distance + math.cos(angle) * 2 + ring

    ball.Position = Vector3.new(lateral, 5, forward)

    local jitter = (orbitIndex % math.max(speedJitter + 1, 1)) - math.floor(speedJitter / 2)
    local speed = math.max(10, speedBase + jitter)

    local velocity = Vector3.new(-lateral * 1.25, 0, -speed)
    ball.AssemblyLinearVelocity = velocity

    ball:SetAttribute("realBall", true)
    ball.Parent = folder
    return ball
end

local function main()
    local config = loadConfig()

    local heartbeatStep
    local heartbeatSignal = makeSignal(function(handler)
        heartbeatStep = handler
    end)

    local runServiceStub = { Heartbeat = heartbeatSignal }

    local statsStub = {
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

    local userInputStub = {}
    userInputStub.InputBegan = makeSignal()
    function userInputStub:IsKeyDown()
        return false
    end

    local character = Instance.new("Model")
    character.Name = "BenchmarkCharacter"
    character.Parent = workspace

    local root = Instance.new("Part")
    root.Name = "HumanoidRootPart"
    root.Anchored = true
    root.Size = Vector3.new(2, 2, 2)
    root.Position = Vector3.new(0, 5, 0)
    root.Parent = character
    character.PrimaryPart = root

    local highlight = Instance.new("Part")
    highlight.Name = "Highlight"
    highlight.Anchored = true
    highlight.Transparency = 1
    highlight.CanCollide = false
    highlight.Parent = character

    local playersStub = {
        LocalPlayer = {
            Name = "BenchmarkLocalPlayer",
            Character = character,
        },
    }

    local ballsFolder = workspace:FindFirstChild("Balls")
    assert(ballsFolder, "[HeartbeatBenchmark] workspace.Balls is required")
    ballsFolder:ClearAllChildren()

    local originalGetService = game.GetService
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
        return originalGetService(self, name)
    end

    local parryRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("ParryButtonPress")
    local parryAttempts = 0
    local lastPayload
    function parryRemote:FireServer(...)
        parryAttempts += 1
        lastPayload = { ... }
        return self
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

    local api = apiResult
    local metrics

    local function executeBenchmark()
        api.setEnabled(true)

        if not heartbeatStep then
            error("[HeartbeatBenchmark] AutoParry did not attach a heartbeat listener", 0)
        end

        for _ = 1, config.warmupFrames do
            heartbeatStep(config.frameDuration)
        end

        local allSamples = {}
        local series = {}
        local summarySamples = 0

        for _, targetCount in ipairs(config.ballPopulations) do
            ballsFolder:ClearAllChildren()
            for index = 1, targetCount do
                spawnSyntheticBall(ballsFolder, index, config.ballSpawn)
            end

            for _ = 1, config.warmupFrames do
                heartbeatStep(config.frameDuration)
            end

            local batchSamples = {}
            for _ = 1, config.samplesPerBatch do
                local started = os.clock()
                heartbeatStep(config.frameDuration)
                local elapsed = os.clock() - started
                table.insert(batchSamples, elapsed)
                table.insert(allSamples, elapsed)
            end

            summarySamples += #batchSamples

            table.insert(series, {
                balls = targetCount,
                samples = #batchSamples,
                average = average(batchSamples),
                p95 = percentile(batchSamples, 0.95),
            })
        end

        metrics = {
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            samples = summarySamples,
            config = {
                warmupFrames = config.warmupFrames,
                samplesPerBatch = config.samplesPerBatch,
                frameDuration = config.frameDuration,
                ballPopulations = config.ballPopulations,
            },
            thresholds = config.thresholds,
            series = series,
            summary = {
                samples = #allSamples,
                average = average(allSamples),
                p95 = percentile(allSamples, 0.95),
            },
            parryAttempts = parryAttempts,
        }
    end

    local success, runErr = pcall(executeBenchmark)

    local destroyOk, destroyErr = pcall(function()
        if api then
            api.destroy()
        end
    end)
    if not destroyOk then
        warn("[HeartbeatBenchmark] Failed to destroy AutoParry API:", destroyErr)
    end

    game.GetService = originalGetService

    if character.Parent then
        character:Destroy()
    end

    ballsFolder:ClearAllChildren()

    if not success then
        error(runErr, 0)
    end

    local encoded = HttpService:JSONEncode(metrics)
    print(string.format("[PERF] %s", encoded))

    if lastPayload then
        print(string.format("[HeartbeatBenchmark] last parry payload: %s", HttpService:JSONEncode(lastPayload)))
    end

    local thresholds = config.thresholds or {}
    local failures = {}
    if thresholds.average and metrics.summary.average > thresholds.average then
        table.insert(failures, string.format("average %.6f > %.6f", metrics.summary.average, thresholds.average))
    end
    if thresholds.p95 and metrics.summary.p95 > thresholds.p95 then
        table.insert(failures, string.format("p95 %.6f > %.6f", metrics.summary.p95, thresholds.p95))
    end

    if #failures > 0 then
        error("[HeartbeatBenchmark] Performance regression detected: " .. table.concat(failures, "; "), 0)
    end
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
    warn(err)
    error("[HeartbeatBenchmark] Benchmark failed", 0)
end
