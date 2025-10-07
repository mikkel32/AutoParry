-- mikkel32/AutoParry : src/core/autoparry.lua
-- selene: allow(global_usage)
-- Auto-parry implementation that mirrors the "Auto-Parry (F-Key Proximity)" logic
-- shared by the user: it presses the local "F" key via VirtualInputManager when a
-- tracked projectile is about to reach the player. The module keeps the public
-- AutoParry API that the rest of the experience relies on (configure, signals,
-- destroy, etc.) while swapping the internal behaviour for the requested
-- proximity/TTI based approach.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Stats = game:FindService("Stats")
local VirtualInputManager = game:GetService("VirtualInputManager")

local Require = rawget(_G, "ARequire")
local Util = Require and Require("src/shared/util.lua") or require(script.Parent.Parent.shared.util)

local Signal = Util.Signal

local DEFAULT_CONFIG = {
    -- legacy configuration keys kept for compatibility with the public API
    cooldown = 0.10,
    minSpeed = 10,
    pingOffset = 0,
    minTTI = 0.12,
    maxTTI = 0.55,
    safeRadius = 10,
    targetHighlightName = "Highlight",
    ballsFolderName = "Balls",
    playerTimeout = 10,
    remotesTimeout = 10,
    parryRemoteTimeout = 10,
    ballsFolderTimeout = 5,
    verificationRetryInterval = 0,

    -- new configuration exposed by the requested logic
    proximityStuds = 5,
    useTTIWindow = true,
    staticTTIWindow = 0.50,
    dynamicWindow = true,
    ballSpeedCheck = true,
    pingBased = true,
    pingBasedOffset = 0,
    fHoldTime = 0.06,
    reactionLeeway = 0.025,
    directionSensitivity = 0.35,
    minApproachSpeed = 14,
    predictionHorizon = 2.75,
    predictionSamples = 96,
    predictionRefinementSteps = 4,
    predictionConfidenceMin = 0.35,
    predictionConfidenceAggressive = 0.75,
    velocitySmoothing = 0.55,
    accelerationSmoothing = 0.52,
    jerkSmoothing = 0.48,
    hysteresisSeconds = 0.05,
    hysteresisDistance = 0.75,
}

local TARGET_WINDOW_BANDS = {
    { threshold = 160, window = 0.22 },
    { threshold = 120, window = 0.28 },
    { threshold = 90, window = 0.35 },
    { threshold = 60, window = 0.45 },
    { threshold = 0, window = 0.58 },
}

local function getGlobalTable()
    local ok, env = pcall(function()
        if typeof(getgenv) == "function" then
            return getgenv()
        end
        return nil
    end)

    if ok and typeof(env) == "table" then
        return env
    end

    _G.__AUTO_PARRY_GLOBAL = _G.__AUTO_PARRY_GLOBAL or {}
    return _G.__AUTO_PARRY_GLOBAL
end

local GlobalEnv = getGlobalTable()
GlobalEnv.Paws = GlobalEnv.Paws or {}

local config = Util.deepCopy(DEFAULT_CONFIG)
local state = {
    enabled = false,
    connection = nil,
    lastParry = 0,
    lastSuccess = 0,
    lastBroadcast = 0,
}

local initialization = {
    started = false,
    completed = false,
    destroyed = false,
    error = nil,
}

local initStatus = Signal.new()
local initProgress = { stage = "waiting-player" }
local stateChanged = Signal.new()
local parryEvent = Signal.new()
local parrySuccessSignal = Signal.new()
local parryBroadcastSignal = Signal.new()

local LocalPlayer: Player?
local Character: Model?
local RootPart: BasePart?
local Humanoid: Humanoid?
local BallsFolder: Instance?

local UiRoot: ScreenGui?
local ToggleButton: TextButton?
local RemoveButton: TextButton?
local StatusLabel: TextLabel?
local BallHighlight: Highlight?
local BallBillboard: BillboardGui?
local BallStatsLabel: TextLabel?

local loopConnection: RBXScriptConnection?
local humanoidDiedConnection: RBXScriptConnection?
local characterAddedConnection: RBXScriptConnection?
local characterRemovingConnection: RBXScriptConnection?

local lastFiredTime = 0
local trackedBall: BasePart?
local lastBallDecision = {
    ball = nil :: BasePart?,
    timestamp = 0,
    predictedTTI = math.huge,
    predictedDistance = math.huge,
    confidence = 0,
}

local ballStateCache = setmetatable({}, { __mode = "k" })

local playerKinematics = {
    position = Vector3.zero,
    velocity = Vector3.zero,
    acceleration = Vector3.zero,
    jerk = Vector3.zero,
    timestamp = 0,
}

local AutoParry

local function cloneTable(tbl)
    return Util.deepCopy(tbl)
end

local function applyInitStatus(update)
    for key in pairs(initProgress) do
        if update[key] == nil and key ~= "stage" then
            initProgress[key] = initProgress[key]
        end
    end

    for key, value in pairs(update) do
        initProgress[key] = value
    end

    initStatus:fire(cloneTable(initProgress))
end

local function setStage(stage, extra)
    local payload = { stage = stage }
    if typeof(extra) == "table" then
        for key, value in pairs(extra) do
            payload[key] = value
        end
    end
    applyInitStatus(payload)
end

local function formatToggleText(enabled)
    return enabled and "Auto-Parry: ON" or "Auto-Parry: OFF"
end

local function formatToggleColor(enabled)
    if enabled then
        return Color3.fromRGB(0, 120, 0)
    end
    return Color3.fromRGB(40, 40, 40)
end

local function syncGlobalSettings()
    local settings = GlobalEnv.Paws
    if typeof(settings) ~= "table" then
        settings = {}
        GlobalEnv.Paws = settings
    end

    settings.AutoParry = state.enabled
    settings.ProximityStuds = config.proximityStuds
    settings.UseTTIWindow = config.useTTIWindow
    settings.StaticTTIWindow = config.staticTTIWindow
    settings.DynamicWindow = config.dynamicWindow
    settings.BallSpeedCheck = config.ballSpeedCheck
    settings.PingBased = config.pingBased
    settings.PingBasedOffset = config.pingBasedOffset
    settings.FHoldTime = config.fHoldTime
    settings.AntiSpam = config.cooldown
end

local function updateToggleButton()
    if not ToggleButton then
        return
    end

    ToggleButton.Text = formatToggleText(state.enabled)
    ToggleButton.BackgroundColor3 = formatToggleColor(state.enabled)
end

local function updateStatusLabel(lines)
    if not StatusLabel then
        return
    end

    if typeof(lines) == "table" then
        StatusLabel.Text = table.concat(lines, "\n")
    else
        StatusLabel.Text = tostring(lines)
    end
end

local function resetBallTracking()
    lastBallDecision.ball = nil
    lastBallDecision.timestamp = 0
    lastBallDecision.predictedTTI = math.huge
    lastBallDecision.predictedDistance = math.huge
    lastBallDecision.confidence = 0

    for key in pairs(ballStateCache) do
        ballStateCache[key] = nil
    end
end

local function now()
    return os.clock()
end

local function blendVector3(previous: Vector3?, target: Vector3, alpha: number)
    if typeof(target) ~= "Vector3" then
        return previous or Vector3.zero
    end

    if typeof(previous) ~= "Vector3" then
        return target
    end

    alpha = math.clamp(alpha or 0.5, 0, 1)
    return previous:Lerp(target, alpha)
end

local function integrateKinematics(position: Vector3, velocity: Vector3, acceleration: Vector3, jerk: Vector3, t: number)
    if t <= 0 then
        return position
    end

    local t2 = t * t
    local t3 = t2 * t

    local half = 0.5 * t2
    local sixth = (1 / 6) * t3

    return position + velocity * t + acceleration * half + jerk * sixth
end

local function updatePlayerState()
    if not RootPart then
        return playerKinematics
    end

    local currentPosition = RootPart.Position
    local currentTime = now()

    local previousTime = playerKinematics.timestamp
    local dt = currentTime - previousTime

    if dt > 0 then
        local measuredVelocity = (currentPosition - playerKinematics.position) / dt
        local velocity = blendVector3(playerKinematics.velocity, measuredVelocity, 1 - math.clamp(config.velocitySmoothing or 0.55, 0, 1))

        local measuredAcceleration = Vector3.zero
        if typeof(playerKinematics.velocity) == "Vector3" then
            measuredAcceleration = (velocity - playerKinematics.velocity) / dt
        end
        local acceleration = blendVector3(playerKinematics.acceleration, measuredAcceleration, 1 - math.clamp(config.accelerationSmoothing or 0.52, 0, 1))

        local measuredJerk = Vector3.zero
        if typeof(playerKinematics.acceleration) == "Vector3" then
            measuredJerk = (acceleration - playerKinematics.acceleration) / dt
        end
        local jerk = blendVector3(playerKinematics.jerk, measuredJerk, 1 - math.clamp(config.jerkSmoothing or 0.48, 0, 1))

        playerKinematics.velocity = velocity
        playerKinematics.acceleration = acceleration
        playerKinematics.jerk = jerk
    end

    playerKinematics.position = currentPosition
    playerKinematics.timestamp = currentTime

    return playerKinematics
end

local function getBallState(ball: BasePart)
    local state = ballStateCache[ball]
    if not state then
        state = {
            position = ball.Position,
            velocity = ball.AssemblyLinearVelocity or ball.Velocity or Vector3.zero,
            acceleration = Vector3.zero,
            jerk = Vector3.zero,
            timestamp = now(),
        }
        ballStateCache[ball] = state
    end
    return state
end

local function updateBallState(ball: BasePart, playerState)
    local state = getBallState(ball)
    local currentPosition = ball.Position
    local currentVelocity = ball.AssemblyLinearVelocity or ball.Velocity or Vector3.zero
    if typeof(currentVelocity) ~= "Vector3" then
        currentVelocity = Vector3.zero
    end

    local currentTime = now()
    local dt = currentTime - (state.timestamp or 0)

    if dt > 0 then
        local measuredVelocity = (currentPosition - state.position) / dt
        local velocityBlend = math.clamp(config.velocitySmoothing or 0.55, 0, 1)
        local fusedVelocity = blendVector3(state.velocity, currentVelocity, velocityBlend)
        fusedVelocity = blendVector3(fusedVelocity, measuredVelocity, 0.5)

        local measuredAcceleration = Vector3.zero
        if typeof(state.velocity) == "Vector3" then
            measuredAcceleration = (fusedVelocity - state.velocity) / dt
        end
        local accelerationBlend = math.clamp(config.accelerationSmoothing or 0.52, 0, 1)
        local fusedAcceleration = blendVector3(state.acceleration, measuredAcceleration, accelerationBlend)

        local measuredJerk = Vector3.zero
        if typeof(state.acceleration) == "Vector3" then
            measuredJerk = (fusedAcceleration - state.acceleration) / dt
        end
        local jerkBlend = math.clamp(config.jerkSmoothing or 0.48, 0, 1)
        local fusedJerk = blendVector3(state.jerk, measuredJerk, jerkBlend)

        state.velocity = fusedVelocity
        state.acceleration = fusedAcceleration
        state.jerk = fusedJerk
    else
        state.velocity = state.velocity or currentVelocity
        state.acceleration = state.acceleration or Vector3.zero
        state.jerk = state.jerk or Vector3.zero
    end

    state.position = currentPosition
    state.timestamp = currentTime

    return state
end

local function computeBallTelemetry(ball: BasePart, playerState)
    if not RootPart then
        return nil
    end

    playerState = playerState or updatePlayerState()
    local ballState = updateBallState(ball, playerState)

    local ballPosition = ballState.position
    local playerPosition = playerState.position
    local toPlayer = playerPosition - ballPosition
    local distance = toPlayer.Magnitude
    if distance == 0 then
        distance = 1e-3
    end

    local directionToPlayer = toPlayer / distance

    local ballVelocity = ballState.velocity or Vector3.zero
    local playerVelocity = playerState.velocity or Vector3.zero
    local relativeVelocity = ballVelocity - playerVelocity
    local speed = ballVelocity.Magnitude
    local relativeSpeed = relativeVelocity.Magnitude
    local approachingSpeed = relativeVelocity:Dot(directionToPlayer)

    local directionDot = 0
    if relativeSpeed > 0 then
        directionDot = approachingSpeed / relativeSpeed
    elseif speed > 0 then
        directionDot = ballVelocity:Dot(directionToPlayer) / speed
    end

    local pingTime = config.pingBased and getPingTime() or 0
    local pingAdjustment = 0
    if config.pingBased then
        pingAdjustment = approachingSpeed * pingTime + (config.pingBasedOffset or 0)
    end

    local adjustedDistance = distance - pingAdjustment
    if adjustedDistance < 0 then
        adjustedDistance = 0
    end

    local tti = math.huge
    if approachingSpeed > 0 then
        tti = adjustedDistance / math.max(approachingSpeed, 1e-3)
        if tti < 0 then
            tti = 0
        end
    end

    local window = config.dynamicWindow and getDynamicWindow(speed) or (config.staticTTIWindow or 0.5)
    local safeRadius = math.max(config.safeRadius or 0, 0)
    local proximityStuds = math.max(config.proximityStuds or 0, 0)
    local horizon = math.max(config.predictionHorizon or 2.5, 0.5)
    local samples = math.max(math.floor(config.predictionSamples or 60), 1)
    local step = horizon / samples

    local minFutureDistance = distance
    local minFutureTime = 0
    local predictedTTI
    local predictedDistance = distance

    for index = 1, samples do
        local t = index * step
        local futureBall = integrateKinematics(ballState.position, ballState.velocity, ballState.acceleration, ballState.jerk, t)
        local futurePlayer = integrateKinematics(playerState.position, playerState.velocity, playerState.acceleration, playerState.jerk, t)
        local delta = futureBall - futurePlayer
        local futureDistance = delta.Magnitude

        if futureDistance < minFutureDistance then
            minFutureDistance = futureDistance
            minFutureTime = t
        end

        if not predictedTTI and futureDistance <= math.max(proximityStuds, safeRadius * 0.5) then
            predictedTTI = t
            predictedDistance = futureDistance
        end
    end

    if not predictedTTI then
        predictedTTI = minFutureTime
        predictedDistance = minFutureDistance
    end

    local refinementSteps = math.max(config.predictionRefinementSteps or 0, 0)
    if refinementSteps > 0 and predictedTTI > 0 then
        local bestTime = predictedTTI
        local bestDistance = predictedDistance
        local searchWindow = step

        for _ = 1, refinementSteps do
            local halfWindow = math.max(searchWindow * 0.5, 1e-3)
            local startT = math.max(bestTime - halfWindow, 0)
            local finishT = bestTime + halfWindow
            local slices = 6
            local subStep = (finishT - startT) / math.max(slices, 1)

            for i = 0, slices do
                local t = startT + i * subStep
                local futureBall = integrateKinematics(ballState.position, ballState.velocity, ballState.acceleration, ballState.jerk, t)
                local futurePlayer = integrateKinematics(playerState.position, playerState.velocity, playerState.acceleration, playerState.jerk, t)
                local delta = futureBall - futurePlayer
                local futureDistance = delta.Magnitude

                if futureDistance < bestDistance then
                    bestDistance = futureDistance
                    bestTime = t
                end
            end

            predictedTTI = bestTime
            predictedDistance = bestDistance
            searchWindow *= 0.35
        end
    end

    local relativeAcceleration = (ballState.acceleration or Vector3.zero) - (playerState.acceleration or Vector3.zero)
    local relativeJerk = (ballState.jerk or Vector3.zero) - (playerState.jerk or Vector3.zero)

    local approachScore = math.clamp(approachingSpeed / math.max(config.minApproachSpeed or 1, 1), 0, 2)
    local directionScore = math.clamp((directionDot + 1) * 0.5, 0, 1)
    local distanceScore = math.clamp(1 - (predictedDistance / math.max(proximityStuds, 1)), 0, 1)
    local futureScore = math.clamp(1 - math.min(minFutureDistance, safeRadius) / math.max(safeRadius, 1), 0, 1)
    local impactConfidence = math.clamp((approachScore * 0.35) + (directionScore * 0.2) + (distanceScore * 0.25) + (futureScore * 0.2), 0, 1)

    local consider = true
    if config.ballSpeedCheck and speed <= 0 then
        consider = false
    end

    if approachingSpeed <= 0 and predictedDistance > proximityStuds * 1.5 and minFutureDistance > safeRadius then
        consider = false
    end

    return {
        ball = ball,
        player = playerState,
        position = ballPosition,
        velocity = ballVelocity,
        acceleration = ballState.acceleration or Vector3.zero,
        jerk = ballState.jerk or Vector3.zero,
        relativeVelocity = relativeVelocity,
        relativeAcceleration = relativeAcceleration,
        relativeJerk = relativeJerk,
        distance = distance,
        adjustedDistance = adjustedDistance,
        minFutureDistance = minFutureDistance,
        predictedDistance = predictedDistance,
        predictedTTI = predictedTTI,
        tti = tti,
        approachingSpeed = approachingSpeed,
        speed = speed,
        relativeSpeed = relativeSpeed,
        directionDot = directionDot,
        impactConfidence = impactConfidence,
        consider = consider,
        pingAdjustment = pingAdjustment,
        window = window,
    }
end

local function clearBallVisuals()
    if BallHighlight then
        BallHighlight.Enabled = false
        BallHighlight.Adornee = nil
    end
    if BallBillboard then
        BallBillboard.Enabled = false
        BallBillboard.Adornee = nil
    end
    trackedBall = nil
end

local function ensureUi()
    if UiRoot or not LocalPlayer then
        return
    end

    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not playerGui then
        playerGui = LocalPlayer:WaitForChild("PlayerGui", 5)
    end

    if not playerGui then
        return
    end

    local gui = Instance.new("ScreenGui")
    gui.Name = "AutoParryF_UI"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.Parent = playerGui

    local toggleBtn = Instance.new("TextButton")
    toggleBtn.Size = UDim2.fromOffset(180, 40)
    toggleBtn.Position = UDim2.fromOffset(10, 10)
    toggleBtn.BackgroundColor3 = formatToggleColor(state.enabled)
    toggleBtn.TextColor3 = Color3.new(1, 1, 1)
    toggleBtn.Font = Enum.Font.GothamBold
    toggleBtn.TextSize = 20
    toggleBtn.BorderSizePixel = 0
    toggleBtn.Text = formatToggleText(state.enabled)
    toggleBtn.Parent = gui
    toggleBtn.MouseButton1Click:Connect(function()
        AutoParry.toggle()
    end)

    local removeBtn = Instance.new("TextButton")
    removeBtn.Size = UDim2.fromOffset(180, 30)
    removeBtn.Position = UDim2.fromOffset(10, 54)
    removeBtn.BackgroundColor3 = Color3.fromRGB(120, 0, 0)
    removeBtn.TextColor3 = Color3.new(1, 1, 1)
    removeBtn.Font = Enum.Font.GothamBold
    removeBtn.TextSize = 18
    removeBtn.BorderSizePixel = 0
    removeBtn.Text = "REMOVE Auto-Parry"
    removeBtn.Parent = gui
    removeBtn.MouseButton1Click:Connect(function()
        AutoParry.destroy()
        GlobalEnv.Paws = nil
    end)

    local status = Instance.new("TextLabel")
    status.Size = UDim2.fromOffset(320, 80)
    status.Position = UDim2.fromOffset(10, 90)
    status.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
    status.BackgroundTransparency = 0.25
    status.TextColor3 = Color3.new(1, 1, 1)
    status.TextXAlignment = Enum.TextXAlignment.Left
    status.TextYAlignment = Enum.TextYAlignment.Top
    status.Font = Enum.Font.Gotham
    status.TextSize = 14
    status.BorderSizePixel = 0
    status.Text = "Auto-Parry F loaded."
    status.Parent = gui

    local highlight = Instance.new("Highlight")
    highlight.Name = "BallHighlight"
    highlight.FillColor = Color3.fromRGB(0, 255, 0)
    highlight.OutlineColor = Color3.fromRGB(0, 255, 0)
    highlight.FillTransparency = 0.6
    highlight.OutlineTransparency = 0
    highlight.Enabled = false
    highlight.Parent = gui

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "BallStats"
    billboard.Size = UDim2.new(0, 220, 0, 60)
    billboard.StudsOffset = Vector3.new(0, 3.5, 0)
    billboard.AlwaysOnTop = true
    billboard.Enabled = false
    billboard.Parent = gui

    local statsLabel = Instance.new("TextLabel")
    statsLabel.Size = UDim2.fromScale(1, 1)
    statsLabel.BackgroundTransparency = 0.25
    statsLabel.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    statsLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    statsLabel.TextStrokeTransparency = 0.2
    statsLabel.Font = Enum.Font.GothamBold
    statsLabel.TextSize = 16
    statsLabel.Text = ""
    statsLabel.Parent = billboard

    UiRoot = gui
    ToggleButton = toggleBtn
    RemoveButton = removeBtn
    StatusLabel = status
    BallHighlight = highlight
    BallBillboard = billboard
    BallStatsLabel = statsLabel

    updateToggleButton()
    updateStatusLabel({ "Auto-Parry F", "Status: initializing" })
end

local function destroyUi()
    clearBallVisuals()
    if UiRoot then
        UiRoot:Destroy()
    end
    UiRoot = nil
    ToggleButton = nil
    RemoveButton = nil
    StatusLabel = nil
    BallHighlight = nil
    BallBillboard = nil
    BallStatsLabel = nil
end

local function getPingTime()
    if not Stats then
        return 0
    end

    local okStat, stat = pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]
    end)

    if not okStat or not stat then
        return 0
    end

    local okValue, value = pcall(stat.GetValue, stat)
    if not okValue or not value then
        return 0
    end

    return value / 1000
end

local function isTargetingMe()
    if not Character then
        return false
    end

    local highlightName = config.targetHighlightName
    if not highlightName or highlightName == "" then
        return true
    end

    local ok, result = pcall(function()
        return Character:FindFirstChild(highlightName)
    end)

    return ok and result ~= nil
end

local function getDynamicWindow(speed)
    for _, entry in ipairs(TARGET_WINDOW_BANDS) do
        if speed > entry.threshold then
            return entry.window
        end
    end
    return TARGET_WINDOW_BANDS[#TARGET_WINDOW_BANDS].window
end

local function ensureBallsFolder()
    local name = config.ballsFolderName
    if BallsFolder and BallsFolder.Parent then
        if BallsFolder.Name == name then
            return BallsFolder
        end
    end

    local folder = Workspace:FindFirstChild(name)
    if folder then
        BallsFolder = folder
        return folder
    end

    local ok, result = pcall(function()
        return Workspace:WaitForChild(name, 0.5)
    end)

    if ok then
        BallsFolder = result
    end

    return BallsFolder
end

local function setBallVisuals(ball, text)
    if BallHighlight then
        BallHighlight.Adornee = ball
        BallHighlight.Enabled = ball ~= nil
    end
    if BallBillboard then
        BallBillboard.Adornee = ball
        BallBillboard.Enabled = ball ~= nil
    end
    if BallStatsLabel then
        BallStatsLabel.Text = text or ""
    end
    trackedBall = ball
end

local function sendKeyPress(ball, candidate)
    local currentTime = now()
    local cooldown = config.cooldown or 0.1

    if candidate and lastBallDecision.ball ~= candidate.ball then
        cooldown = math.min(cooldown, math.max(config.reactionLeeway or 0, 0))
    end

    if currentTime - lastFiredTime < cooldown then
        return false
    end

    if candidate and lastBallDecision.ball == candidate.ball then
        local hysteresisSeconds = math.max(config.hysteresisSeconds or 0, 0)
        local hysteresisDistance = math.max(config.hysteresisDistance or 0, 0)
        local previousTTI = lastBallDecision.predictedTTI or math.huge
        local previousDistance = lastBallDecision.predictedDistance or math.huge
        local newTTI = candidate.predictedTTI or candidate.tti or math.huge
        local newDistance = candidate.predictedDistance or candidate.distance or math.huge

        if newTTI >= previousTTI - hysteresisSeconds and newDistance >= previousDistance - hysteresisDistance and currentTime - (lastBallDecision.timestamp or 0) < hysteresisSeconds * 3 + 0.02 then
            return false
        end
    end

    lastFiredTime = currentTime
    state.lastParry = currentTime

    task.spawn(function()
        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.F, false, game)
        task.wait(config.fHoldTime or 0.06)
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.F, false, game)
    end)

    if candidate then
        lastBallDecision.ball = candidate.ball
        lastBallDecision.timestamp = currentTime
        lastBallDecision.predictedTTI = candidate.predictedTTI or candidate.tti or math.huge
        lastBallDecision.predictedDistance = candidate.predictedDistance or candidate.distance or math.huge
        lastBallDecision.confidence = candidate.impactConfidence or 0
    else
        lastBallDecision.ball = ball
        lastBallDecision.timestamp = currentTime
        lastBallDecision.predictedTTI = math.huge
        lastBallDecision.predictedDistance = math.huge
        lastBallDecision.confidence = 0
    end

    parryEvent:fire(ball, currentTime)
    return true
end

local function updateCharacter(character)
    Character = character
    RootPart = nil
    Humanoid = nil

    if humanoidDiedConnection then
        humanoidDiedConnection:Disconnect()
        humanoidDiedConnection = nil
    end

    if not character then
        return
    end

    RootPart = character:FindFirstChild("HumanoidRootPart")
    if not RootPart then
        local ok, root = pcall(function()
            return character:WaitForChild("HumanoidRootPart", 5)
        end)
        if ok then
            RootPart = root
        end
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid then
        local ok, value = pcall(function()
            return character:WaitForChild("Humanoid", 5)
        end)
        if ok then
            humanoid = value
        end
    end

    Humanoid = humanoid

    if humanoid then
        humanoidDiedConnection = humanoid.Died:Connect(function()
            AutoParry.disable()
            destroyUi()
            GlobalEnv.Paws = nil
        end)
    end
end

local function handleCharacterAdded(character)
    updateCharacter(character)
end

local function handleCharacterRemoving()
    updateCharacter(nil)
    clearBallVisuals()
    resetBallTracking()
end

local function beginInitialization()
    if initialization.started or initialization.destroyed then
        return
    end

    initialization.started = true

    task.spawn(function()
        local ok, err = pcall(function()
            setStage("waiting-player")

            LocalPlayer = Players.LocalPlayer
            if not LocalPlayer then
                LocalPlayer = Players.PlayerAdded:Wait()
            end

            setStage("waiting-character", { player = LocalPlayer and LocalPlayer.Name or "Unknown" })

            if LocalPlayer then
                updateCharacter(LocalPlayer.Character)

                characterAddedConnection = LocalPlayer.CharacterAdded:Connect(handleCharacterAdded)
                characterRemovingConnection = LocalPlayer.CharacterRemoving:Connect(handleCharacterRemoving)

                if not Character then
                    Character = LocalPlayer.CharacterAdded:Wait()
                    updateCharacter(Character)
                end
            end

            ensureUi()

            setStage("waiting-balls")
            ensureBallsFolder()

            local folderLabel = config.ballsFolderName
            if BallsFolder then
                local okName, fullName = pcall(BallsFolder.GetFullName, BallsFolder)
                if okName and typeof(fullName) == "string" then
                    folderLabel = fullName
                else
                    folderLabel = BallsFolder.Name
                end
            end

            setStage("ready", {
                player = LocalPlayer and LocalPlayer.Name or "Unknown",
                ballsFolder = folderLabel,
            })

            initialization.completed = true
        end)

        if not ok then
            initialization.error = err
            setStage("error", { error = tostring(err) })
        end
    end)
end

local function ensureInitialization()
    if initialization.destroyed then
        initialization.destroyed = false
    end
    if initialization.completed or initialization.started then
        return
    end
    beginInitialization()
end

local function scoreCandidate(candidate)
    local predictedTTI = math.min(candidate.predictedTTI or math.huge, candidate.tti or math.huge)
    local distanceComponent = (candidate.predictedDistance or candidate.minFutureDistance or candidate.distance) / math.max(candidate.speed + candidate.relativeSpeed, 1)
    local directionPenalty = 1 - math.clamp(candidate.directionDot or 0, 0, 1)
    local confidenceBonus = candidate.impactConfidence or 0
    local approachPenalty = candidate.approachingSpeed > 0 and 0 or 0.25

    return predictedTTI + distanceComponent * 0.05 + directionPenalty * 0.12 + approachPenalty - confidenceBonus * 0.35
end

local function selectBestBall(folder, playerState)
    if not folder then
        return nil
    end

    local best
    local fallback

    for _, child in ipairs(folder:GetChildren()) do
        if child:IsA("BasePart") then
            local telemetry = computeBallTelemetry(child, playerState)
            if telemetry then
                if not fallback then
                    fallback = telemetry
                end

                if telemetry.consider then
                    telemetry.score = scoreCandidate(telemetry)
                    if not best or telemetry.score < best.score then
                        best = telemetry
                    end
                end
            end
        end
    end

    return best or fallback
end

local function computeBallDebug(telemetry)
    if not telemetry then
        return ""
    end

    local tti = telemetry.tti == math.huge and -1 or telemetry.tti
    local predicted = telemetry.predictedTTI == math.huge and -1 or telemetry.predictedTTI
    local distance = telemetry.distance or 0
    local predictedDistance = telemetry.predictedDistance or telemetry.minFutureDistance or distance
    local confidence = math.clamp(telemetry.impactConfidence or 0, 0, 1) * 100

    return string.format(
        "💨 Speed: %.1f | Rel: %.1f\n⏱️ TTI: %.3f | Pred: %.3f\n📏 Dist: %.2f | Pred: %.2f\n🔮 Conf: %.1f%%",
        telemetry.speed or 0,
        telemetry.relativeSpeed or 0,
        tti,
        predicted,
        distance,
        predictedDistance,
        confidence
    )
end

local function shouldTriggerParry(candidate)
    if not candidate then
        return false, "no-ball"
    end

    if config.ballSpeedCheck and (candidate.speed or 0) <= 0 then
        return false, "stationary"
    end

    local proximityStuds = math.max(config.proximityStuds or 0, 0)
    local safeRadius = math.max(config.safeRadius or 0, 0)
    local horizon = math.max(config.predictionHorizon or 2.5, 0.5)
    local minConfidence = math.clamp(config.predictionConfidenceMin or 0.35, 0, 1)
    local aggressiveConfidence = math.clamp(config.predictionConfidenceAggressive or 0.75, 0, 1)

    local predictedDistance = candidate.predictedDistance or candidate.minFutureDistance or math.huge
    local predictedTTI = math.min(candidate.predictedTTI or math.huge, candidate.tti or math.huge)
    local confidence = candidate.impactConfidence or 0
    local window = candidate.window or (config.staticTTIWindow or 0.5)

    if candidate.distance <= proximityStuds then
        return true, "proximity-now"
    end

    if predictedDistance <= proximityStuds then
        return true, "proximity-predict"
    end

    if predictedDistance <= math.max(proximityStuds * 0.75, safeRadius * 0.4) then
        return true, "future-collapse"
    end

    if confidence >= aggressiveConfidence and predictedTTI <= math.min(window + 0.05, horizon) then
        return true, "confidence-window"
    end

    if confidence >= minConfidence and predictedDistance <= math.max(safeRadius * 0.5, proximityStuds) then
        return true, "confidence-distance"
    end

    if config.useTTIWindow and predictedTTI <= math.max(window - (config.reactionLeeway or 0), 0) then
        return true, "tti-window"
    end

    if predictedTTI <= (config.minTTI or 0.12) then
        return true, "min-tti"
    end

    if candidate.adjustedDistance <= safeRadius and candidate.approachingSpeed > math.max(config.minApproachSpeed or 0, 0) * 0.5 then
        return true, "safe-radius"
    end

    return false, "tracking"
end

local function describeReason(reason)
    local mapping = {
        ["no-ball"] = "No ball",
        stationary = "Stationary hold",
        ["proximity-now"] = "Immediate proximity",
        ["proximity-predict"] = "Predicted proximity",
        ["future-collapse"] = "Trajectory collapse",
        ["confidence-window"] = "Confidence window",
        ["confidence-distance"] = "Confidence distance",
        ["tti-window"] = "TTI window",
        ["min-tti"] = "Minimum TTI",
        ["safe-radius"] = "Safe radius",
        tracking = "Tracking",
        ["not-targeting"] = "Not targeting",
        cooldown = "Cooldown guard",
    }

    return mapping[reason] or reason
end

local function renderLoop()
    if initialization.destroyed then
        return
    end

    if not LocalPlayer then
        return
    end

    if not Character or not RootPart then
        updateStatusLabel({ "Auto-Parry F", "Status: waiting for character" })
        clearBallVisuals()
        return
    end

    ensureBallsFolder()
    local folder = BallsFolder
    if not folder then
        updateStatusLabel({ "Auto-Parry F", "Ball: none", "Info: waiting for balls folder" })
        clearBallVisuals()
        return
    end

    if not state.enabled then
        updateStatusLabel({ "Auto-Parry F", "Status: OFF" })
        clearBallVisuals()
        updateToggleButton()
        return
    end

    local playerState = updatePlayerState()
    local telemetry = selectBestBall(folder, playerState)
    if not telemetry or not telemetry.ball or not telemetry.ball:IsDescendantOf(Workspace) then
        updateStatusLabel({ "Auto-Parry F", "Ball: none", "TTI: -", "Info: waiting for realBall..." })
        clearBallVisuals()
        return
    end

    local ball = telemetry.ball
    local targeting = isTargetingMe()
    local fired = false
    local reasonCode = "tracking"

    if targeting then
        local shouldFire, code = shouldTriggerParry(telemetry)
        reasonCode = code

        if shouldFire then
            fired = sendKeyPress(ball, telemetry)
            if not fired then
                reasonCode = "cooldown"
            end
        end
    else
        reasonCode = "not-targeting"
    end

    local debugLines = {
        "Auto-Parry F",
        string.format("Ball: %s", ball.Name or "unknown"),
        string.format(
            "Speed: %.1f | Rel: %.1f | Dot: %.2f",
            telemetry.speed or 0,
            telemetry.relativeSpeed or 0,
            telemetry.directionDot or 0
        ),
        string.format(
            "Dist: %.2f | Adj: %.2f | Pred: %.2f",
            telemetry.distance or 0,
            telemetry.adjustedDistance or 0,
            telemetry.predictedDistance or -1
        ),
        string.format(
            "TTI: %.3f | Pred: %.3f | Window: %.3f",
            telemetry.tti == math.huge and -1 or telemetry.tti,
            telemetry.predictedTTI == math.huge and -1 or telemetry.predictedTTI,
            telemetry.window or (config.staticTTIWindow or 0.5)
        ),
        string.format(
            "Conf: %.0f%% | TargetingMe: %s | Fire: %s",
            math.clamp(telemetry.impactConfidence or 0, 0, 1) * 100,
            tostring(targeting),
            fired and "YES" or "no"
        ),
        "Reason: " .. describeReason(reasonCode),
    }

    updateStatusLabel(debugLines)
    setBallVisuals(ball, computeBallDebug(telemetry))
end

local function ensureLoop()
    if loopConnection then
        return
    end

    loopConnection = RunService.PreRender:Connect(renderLoop)
end

local validators = {
    cooldown = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    minSpeed = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    pingOffset = function(value)
        return typeof(value) == "number"
    end,
    minTTI = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    maxTTI = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    safeRadius = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    targetHighlightName = function(value)
        return value == nil or (typeof(value) == "string" and value ~= "")
    end,
    ballsFolderName = function(value)
        return typeof(value) == "string" and value ~= ""
    end,
    playerTimeout = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    remotesTimeout = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    parryRemoteTimeout = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    ballsFolderTimeout = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    verificationRetryInterval = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    proximityStuds = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    useTTIWindow = function(value)
        return typeof(value) == "boolean"
    end,
    staticTTIWindow = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    dynamicWindow = function(value)
        return typeof(value) == "boolean"
    end,
    ballSpeedCheck = function(value)
        return typeof(value) == "boolean"
    end,
    pingBased = function(value)
        return typeof(value) == "boolean"
    end,
    pingBasedOffset = function(value)
        return typeof(value) == "number"
    end,
    fHoldTime = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    reactionLeeway = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    directionSensitivity = function(value)
        return typeof(value) == "number"
    end,
    minApproachSpeed = function(value)
        return typeof(value) == "number"
    end,
    predictionHorizon = function(value)
        return typeof(value) == "number" and value > 0
    end,
    predictionSamples = function(value)
        return typeof(value) == "number" and value > 0
    end,
    predictionRefinementSteps = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    predictionConfidenceMin = function(value)
        return typeof(value) == "number" and value >= 0 and value <= 1
    end,
    predictionConfidenceAggressive = function(value)
        return typeof(value) == "number" and value >= 0 and value <= 1
    end,
    velocitySmoothing = function(value)
        return typeof(value) == "number" and value >= 0 and value <= 1
    end,
    accelerationSmoothing = function(value)
        return typeof(value) == "number" and value >= 0 and value <= 1
    end,
    jerkSmoothing = function(value)
        return typeof(value) == "number" and value >= 0 and value <= 1
    end,
    hysteresisSeconds = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    hysteresisDistance = function(value)
        return typeof(value) == "number" and value >= 0
    end,
}

AutoParry = {}

function AutoParry.enable()
    ensureInitialization()
    if state.enabled then
        return
    end

    state.enabled = true
    syncGlobalSettings()
    updateToggleButton()
    ensureLoop()
    stateChanged:fire(true)
end

function AutoParry.disable()
    if not state.enabled then
        return
    end

    state.enabled = false
    syncGlobalSettings()
    updateToggleButton()
    resetBallTracking()
    stateChanged:fire(false)
end

function AutoParry.setEnabled(enabled)
    if enabled then
        AutoParry.enable()
    else
        AutoParry.disable()
    end
end

function AutoParry.toggle()
    AutoParry.setEnabled(not state.enabled)
    return state.enabled
end

function AutoParry.isEnabled()
    return state.enabled
end

local function applyConfigOverride(key, value)
    local validator = validators[key]
    if not validator then
        error(("AutoParry.configure: unknown option '%s'"):format(tostring(key)), 0)
    end

    if not validator(value) then
        error(("AutoParry.configure: invalid value for '%s'"):format(tostring(key)), 0)
    end

    config[key] = value
end

function AutoParry.configure(opts)
    assert(typeof(opts) == "table", "AutoParry.configure expects a table")

    for key, value in pairs(opts) do
        applyConfigOverride(key, value)
    end

    syncGlobalSettings()
    return AutoParry.getConfig()
end

function AutoParry.getConfig()
    return cloneTable(config)
end

function AutoParry.resetConfig()
    config = Util.deepCopy(DEFAULT_CONFIG)
    syncGlobalSettings()
    return AutoParry.getConfig()
end

function AutoParry.getLastParryTime()
    return state.lastParry
end

function AutoParry.getLastParrySuccessTime()
    return state.lastSuccess
end

function AutoParry.getLastParryBroadcastTime()
    return state.lastBroadcast
end

function AutoParry.onInitStatus(callback)
    assert(typeof(callback) == "function", "AutoParry.onInitStatus expects a function")
    ensureInitialization()
    local connection = initStatus:connect(callback)
    callback(cloneTable(initProgress))
    return connection
end

function AutoParry.getInitProgress()
    ensureInitialization()
    return cloneTable(initProgress)
end

function AutoParry.onStateChanged(callback)
    assert(typeof(callback) == "function", "AutoParry.onStateChanged expects a function")
    return stateChanged:connect(callback)
end

function AutoParry.onParry(callback)
    assert(typeof(callback) == "function", "AutoParry.onParry expects a function")
    return parryEvent:connect(callback)
end

function AutoParry.onParrySuccess(callback)
    assert(typeof(callback) == "function", "AutoParry.onParrySuccess expects a function")
    return parrySuccessSignal:connect(callback)
end

function AutoParry.onParryBroadcast(callback)
    assert(typeof(callback) == "function", "AutoParry.onParryBroadcast expects a function")
    return parryBroadcastSignal:connect(callback)
end

function AutoParry.setLogger()
    -- retained for API compatibility; logging is no longer used by this module
end

function AutoParry.setLegacyPayloadBuilder()
    -- retained for API compatibility with previous implementations.
end

function AutoParry.destroy()
    AutoParry.disable()

    if loopConnection then
        loopConnection:Disconnect()
        loopConnection = nil
    end

    if humanoidDiedConnection then
        humanoidDiedConnection:Disconnect()
        humanoidDiedConnection = nil
    end

    if characterAddedConnection then
        characterAddedConnection:Disconnect()
        characterAddedConnection = nil
    end

    if characterRemovingConnection then
        characterRemovingConnection:Disconnect()
        characterRemovingConnection = nil
    end

    destroyUi()
    clearBallVisuals()
    resetBallTracking()

    initialization.started = false
    initialization.completed = false
    initialization.destroyed = true
    initialization.error = nil

    state.lastParry = 0
    state.lastSuccess = 0
    state.lastBroadcast = 0

    initProgress = { stage = "waiting-player" }
    applyInitStatus(cloneTable(initProgress))

    initialization.destroyed = false
end

ensureInitialization()
ensureLoop()
syncGlobalSettings()

return AutoParry
