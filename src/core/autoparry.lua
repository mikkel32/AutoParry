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
    reactionLeeway = 0,
    directionSensitivity = 0.35,
    minApproachSpeed = 14,
    lookAheadTime = 0.35,
    lookAheadSteps = 4,
    ttiHysteresis = 0.03,
    proximityHysteresis = 1.25,
    predictionHorizon = 2.75,
    predictionSamples = 24,
    predictionRefinementSteps = 6,
    predictionConfidenceThreshold = 0.35,
    ballVelocitySmoothing = 0.6,
    accelerationSmoothing = 0.72,
    jerkSmoothing = 0.55,
    kinematicsSmoothing = 0.65,
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
    fireTime = 0,
    tti = math.huge,
    distance = math.huge,
    predictedTTI = math.huge,
    predictedDistance = math.huge,
    confidence = 0,
}

local AutoParry

local ballMemory = setmetatable({}, { __mode = "k" })

local playerKinematics = {
    velocity = Vector3.zero,
    acceleration = Vector3.zero,
    jerk = Vector3.zero,
    timestamp = 0,
}

local clearTable = table.clear or function(tbl)
    for key in pairs(tbl) do
        tbl[key] = nil
    end
end

local function cloneTable(tbl)
    return Util.deepCopy(tbl)
end

local function now()
    return os.clock()
end

local function blendVector3(previous: Vector3?, target: Vector3, alpha: number)
    if typeof(target) ~= "Vector3" then
        return previous or Vector3.zero
    end

    if typeof(previous) == "Vector3" then
        alpha = math.clamp(alpha or 0.5, 0, 1)
        return previous:Lerp(target, alpha)
    end

    return target
end

local function integrateRelativeMotion(position: Vector3, velocity: Vector3, acceleration: Vector3, jerk: Vector3, t: number)
    if t <= 0 then
        return position
    end

    local t2 = t * t
    local t3 = t2 * t

    local half = 0.5 * t2
    local sixth = (1 / 6) * t3

    return position + velocity * t + acceleration * half + jerk * sixth
end

local function samplePlayerKinematics()
    if not RootPart then
        return Vector3.zero, Vector3.zero, Vector3.zero
    end

    local currentTime = now()
    local velocity = RootPart.AssemblyLinearVelocity or RootPart.Velocity or Vector3.zero
    if typeof(velocity) ~= "Vector3" then
        velocity = Vector3.zero
    end

    local dt = currentTime - (playerKinematics.timestamp or 0)
    local smoothing = math.clamp(config.kinematicsSmoothing or 0.65, 0, 1)
    local acceleration = playerKinematics.acceleration or Vector3.zero
    local jerk = playerKinematics.jerk or Vector3.zero

    if dt > 0 then
        local previousVelocity = playerKinematics.velocity or Vector3.zero
        local measuredAcceleration = (velocity - previousVelocity) / dt
        acceleration = blendVector3(playerKinematics.acceleration, measuredAcceleration, smoothing)

        local measuredJerk = Vector3.zero
        if typeof(playerKinematics.acceleration) == "Vector3" then
            measuredJerk = (measuredAcceleration - playerKinematics.acceleration) / dt
        end

        jerk = blendVector3(playerKinematics.jerk, measuredJerk, 0.5)
    end

    playerKinematics.velocity = velocity
    playerKinematics.acceleration = acceleration
    playerKinematics.jerk = jerk
    playerKinematics.timestamp = currentTime

    return velocity, acceleration, jerk
end

local function findImpactTime(relativePosition: Vector3, relativeVelocity: Vector3, relativeAcceleration: Vector3, relativeJerk: Vector3, safeRadius: number, horizon: number, samples: number, refinement: number)
    safeRadius = math.max(safeRadius, 0)
    horizon = math.max(horizon, 0)
    samples = math.max(math.floor(samples), 1)
    refinement = math.max(math.floor(refinement), 0)

    local function distanceAt(t)
        local projected = integrateRelativeMotion(relativePosition, relativeVelocity, relativeAcceleration, relativeJerk, t)
        return projected.Magnitude
    end

    local step = horizon / samples
    local previousTime = 0
    local previousDistance = distanceAt(0)

    if previousDistance <= safeRadius then
        return 0, previousDistance
    end

    for index = 1, samples do
        local timePoint = step * index
        local distance = distanceAt(timePoint)
        if distance <= safeRadius then
            local lower = previousTime
            local upper = timePoint

            for _ = 1, refinement do
                local mid = (lower + upper) / 2
                if distanceAt(mid) <= safeRadius then
                    upper = mid
                else
                    lower = mid
                end
            end

            local impactTime = (lower + upper) / 2
            return impactTime, distanceAt(impactTime)
        end

        if distance > previousDistance and index > 1 and previousDistance <= safeRadius * 1.25 then
            break
        end

        previousDistance = distance
        previousTime = timePoint
    end

    return nil, nil
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
    settings.ReactionLeeway = config.reactionLeeway
    settings.DirectionSensitivity = config.directionSensitivity
    settings.MinApproachSpeed = config.minApproachSpeed
    settings.LookAheadTime = config.lookAheadTime
    settings.LookAheadSteps = config.lookAheadSteps
    settings.TTIHysteresis = config.ttiHysteresis
    settings.ProximityHysteresis = config.proximityHysteresis
    settings.PredictionHorizon = config.predictionHorizon
    settings.PredictionSamples = config.predictionSamples
    settings.PredictionRefinementSteps = config.predictionRefinementSteps
    settings.PredictionConfidenceThreshold = config.predictionConfidenceThreshold
    settings.BallVelocitySmoothing = config.ballVelocitySmoothing
    settings.AccelerationSmoothing = config.accelerationSmoothing
    settings.JerkSmoothing = config.jerkSmoothing
    settings.KinematicsSmoothing = config.kinematicsSmoothing
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
    lastBallDecision.ball = nil
    lastBallDecision.fireTime = 0
    lastBallDecision.tti = math.huge
    lastBallDecision.distance = math.huge
    lastBallDecision.predictedTTI = math.huge
    lastBallDecision.predictedDistance = math.huge
    lastBallDecision.confidence = 0
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

local function findRealBall(folder)
    if not folder then
        return nil
    end

    local best
    for _, child in ipairs(folder:GetChildren()) do
        if child:IsA("BasePart") then
            local okAttr, isReal = pcall(child.GetAttribute, child, "realBall")
            if okAttr and isReal == true then
                return child
            elseif not best and child.Name == "Ball" then
                best = child
            end
        end
    end

    return best
end

local function computeBallTelemetry(ball)
    if not RootPart or not ball or not ball:IsA("BasePart") then
        return nil
    end

    local ballPosition = ball.Position
    local playerPosition = RootPart.Position
    local toPlayer = playerPosition - ballPosition
    local distance = toPlayer.Magnitude
    if distance == 0 then
        return nil
    end

    local directionToPlayer = toPlayer / distance
    local rawVelocity = ball.AssemblyLinearVelocity or ball.Velocity or Vector3.zero
    if typeof(rawVelocity) ~= "Vector3" then
        rawVelocity = Vector3.zero
    end

    local currentTime = now()
    local playerVelocity, playerAcceleration, playerJerk = samplePlayerKinematics()

    local smoothingVelocity = math.clamp(config.ballVelocitySmoothing or 0.6, 0, 1)
    local accelerationSmoothing = math.clamp(config.accelerationSmoothing or 0.72, 0, 1)
    local jerkSmoothing = math.clamp(config.jerkSmoothing or 0.55, 0, 1)

    local memory = ballMemory[ball]
    local fusedVelocity = rawVelocity
    local acceleration = Vector3.zero
    local jerk = Vector3.zero

    if memory then
        local dt = currentTime - (memory.timestamp or 0)
        if dt > 0 then
            local measuredVelocity = (ballPosition - memory.position) / dt
            fusedVelocity = blendVector3(memory.velocity, fusedVelocity, smoothingVelocity)
            fusedVelocity = blendVector3(fusedVelocity, measuredVelocity, 0.5)

            local previousVelocity = memory.velocity or fusedVelocity
            local measuredAcceleration = (fusedVelocity - previousVelocity) / dt
            acceleration = blendVector3(memory.acceleration, measuredAcceleration, accelerationSmoothing)

            local measuredJerk = Vector3.zero
            if typeof(memory.acceleration) == "Vector3" then
                measuredJerk = (measuredAcceleration - memory.acceleration) / dt
            end
            jerk = blendVector3(memory.jerk, measuredJerk, jerkSmoothing)
        else
            fusedVelocity = memory.velocity or fusedVelocity
            acceleration = memory.acceleration or Vector3.zero
            jerk = memory.jerk or Vector3.zero
        end
    end

    ballMemory[ball] = {
        position = ballPosition,
        velocity = fusedVelocity,
        acceleration = acceleration,
        jerk = jerk,
        timestamp = currentTime,
    }

    local speed = fusedVelocity.Magnitude
    local relativeVelocity = fusedVelocity - playerVelocity
    local relativeSpeed = relativeVelocity.Magnitude
    local approachingSpeed = relativeVelocity:Dot(directionToPlayer)
    local rawDirectionDot = speed > 0 and fusedVelocity:Dot(directionToPlayer) / speed or 0
    local directionDot = relativeSpeed > 0 and approachingSpeed / relativeSpeed or rawDirectionDot

    local pingTime = config.pingBased and getPingTime() or 0
    local pingAdjustment = 0
    if config.pingBased then
        pingAdjustment = relativeSpeed * pingTime + (config.pingBasedOffset or 0)
    end

    local adjustedDistance = math.max(distance - pingAdjustment, 0)

    local tti = math.huge
    if approachingSpeed > 0 then
        tti = adjustedDistance / approachingSpeed
        if tti < 0 then
            tti = 0
        end
    end

    local window = config.dynamicWindow and getDynamicWindow(relativeSpeed > 0 and relativeSpeed or speed) or (config.staticTTIWindow or 0.5)

    local lookAheadTime = math.max(config.lookAheadTime or 0, 0)
    local lookAheadSteps = math.max(config.lookAheadSteps or 0, 0)
    local minFutureDistance = distance
    if lookAheadTime > 0 and lookAheadSteps > 0 then
        local stepDuration = lookAheadTime / lookAheadSteps
        for step = 1, lookAheadSteps do
            local dt = stepDuration * step
            local futureBallPosition = integrateRelativeMotion(ballPosition, fusedVelocity, acceleration, jerk, dt)
            local futurePlayerPosition = integrateRelativeMotion(playerPosition, playerVelocity, playerAcceleration, playerJerk, dt)
            local projected = (futurePlayerPosition - futureBallPosition).Magnitude
            if projected < minFutureDistance then
                minFutureDistance = projected
            end
        end
    end

    local relativeAcceleration = acceleration - playerAcceleration
    local relativeJerk = jerk - playerJerk
    local relativePosition = ballPosition - playerPosition

    local horizon = math.max(config.predictionHorizon or 2.75, lookAheadTime, config.maxTTI or 0.55)
    local samples = math.max(math.floor(config.predictionSamples or 24), 4)
    local refinement = math.max(math.floor(config.predictionRefinementSteps or 6), 1)
    local safeRadius = math.max(math.max(config.safeRadius or 0, config.proximityStuds or 0), 0)

    local predictionOrigin = integrateRelativeMotion(relativePosition, relativeVelocity, relativeAcceleration, relativeJerk, pingTime)
    local predictedTTI, predictedDistance = findImpactTime(predictionOrigin, relativeVelocity, relativeAcceleration, relativeJerk, safeRadius, horizon, samples, refinement)

    if predictedDistance then
        predictedDistance = math.max(predictedDistance - (config.pingBasedOffset or 0), 0)
    end

    if predictedTTI and predictedTTI < 0 then
        predictedTTI = 0
    end

    local consider = true
    if approachingSpeed <= 0 then
        consider = false
    end

    if speed < (config.minSpeed or 0) and relativeSpeed < (config.minSpeed or 0) then
        consider = false
    end

    if approachingSpeed < (config.minApproachSpeed or config.minSpeed or 0) then
        consider = false
    end

    if directionDot < (config.directionSensitivity or 0) then
        consider = false
    end

    if config.ballSpeedCheck and speed == 0 and relativeSpeed == 0 then
        consider = false
    end

    local velocityError = (rawVelocity - fusedVelocity).Magnitude
    local velocityQuality = speed > 0 and 1 - math.clamp(velocityError / (speed + 1e-3), 0, 1) or 1
    local approachQuality = math.clamp(directionDot, 0, 1)
    local horizonQuality = predictedTTI and (1 - math.clamp(predictedTTI / math.max(horizon, 0.001), 0, 1)) or 0
    local distanceQuality = minFutureDistance > 0 and 1 - math.clamp(minFutureDistance / math.max(safeRadius * 2, 1), 0, 1) or 1

    local impactConfidence = math.clamp((velocityQuality * 0.35) + (approachQuality * 0.35) + (horizonQuality * 0.15) + (distanceQuality * 0.15), 0, 1)
    if predictedDistance then
        local predictiveQuality = safeRadius > 0 and 1 - math.clamp(predictedDistance / math.max(safeRadius, 1), 0, 1) or 0
        impactConfidence = math.clamp(impactConfidence + predictiveQuality * 0.25, 0, 1)
    end

    return {
        ball = ball,
        position = ballPosition,
        velocity = fusedVelocity,
        acceleration = acceleration,
        jerk = jerk,
        playerVelocity = playerVelocity,
        playerAcceleration = playerAcceleration,
        playerJerk = playerJerk,
        relativeVelocity = relativeVelocity,
        relativeAcceleration = relativeAcceleration,
        relativeJerk = relativeJerk,
        speed = speed,
        relativeSpeed = relativeSpeed,
        distance = distance,
        approachingSpeed = approachingSpeed,
        directionDot = directionDot,
        rawDirectionDot = rawDirectionDot,
        pingAdjustment = pingAdjustment,
        adjustedDistance = adjustedDistance,
        tti = tti,
        window = window,
        minFutureDistance = minFutureDistance,
        predictedTTI = predictedTTI or tti,
        predictedDistance = predictedDistance or minFutureDistance,
        impactConfidence = impactConfidence,
        consider = consider,
    }
end

local function scoreCandidate(candidate)
    local primaryTTI = math.min(candidate.predictedTTI or math.huge, candidate.tti or math.huge)
    local ttiScore = primaryTTI
    if ttiScore == math.huge then
        ttiScore = 10
    end

    local distanceScore = (candidate.predictedDistance or candidate.adjustedDistance or candidate.distance) / math.max(candidate.relativeSpeed or candidate.speed or 1, 1)
    local directionPenalty = 1 - math.clamp(candidate.directionDot or 0, 0, 1)
    local futurePenalty = (candidate.minFutureDistance or candidate.distance) / math.max(config.safeRadius or 1, 1)
    local confidencePenalty = 1 - math.clamp(candidate.impactConfidence or 0, 0, 1)

    return ttiScore + (distanceScore * 0.04) + (directionPenalty * 0.1) + (futurePenalty * 0.015) + (confidencePenalty * 0.08)
end

local function selectBestBall(folder)
    if not folder then
        return nil
    end

    local bestCandidate
    local fallback

    for _, child in ipairs(folder:GetChildren()) do
        if child:IsA("BasePart") then
            local telemetry = computeBallTelemetry(child)
            if telemetry then
                if not fallback then
                    fallback = telemetry
                end

                if telemetry.consider then
                    telemetry.score = scoreCandidate(telemetry)
                    if not bestCandidate or telemetry.score < bestCandidate.score then
                        bestCandidate = telemetry
                    end
                end
            end
        end
    end

    return bestCandidate or fallback
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

local function canFireForBall(candidate, now)
    if not candidate then
        return false
    end

    if lastBallDecision.ball ~= candidate.ball then
        return true
    end

    local hysteresis = math.max(config.ttiHysteresis or 0, 0)
    local proximityDelta = math.max(config.proximityHysteresis or 0, 0)

    local previousTTI = lastBallDecision.predictedTTI or lastBallDecision.tti or math.huge
    local previousDistance = lastBallDecision.predictedDistance or lastBallDecision.distance or math.huge
    local currentTTI = candidate.predictedTTI or candidate.tti or math.huge
    local currentDistance = candidate.predictedDistance or candidate.distance or math.huge

    if previousTTI - currentTTI >= hysteresis then
        return true
    end

    if previousDistance - currentDistance >= proximityDelta then
        return true
    end

    if (candidate.impactConfidence or 0) - (lastBallDecision.confidence or 0) > 0.15 then
        return true
    end

    if now - (lastBallDecision.fireTime or 0) > math.max(config.cooldown or 0.1, 0) then
        return true
    end

    return false
end

local function sendKeyPress(ball, candidate)
    local now = os.clock()
    local sameBall = lastBallDecision.ball == ball and lastBallDecision.ball ~= nil
    local cooldown = config.cooldown or 0.1
    if not sameBall then
        local reactionLeeway = math.max(config.reactionLeeway or 0, 0)
        cooldown = math.min(cooldown, reactionLeeway)
    end

    if cooldown > 0 and now - lastFiredTime < cooldown then
        return false
    end

    if candidate and not canFireForBall(candidate, now) then
        return false
    end

    lastFiredTime = now
    state.lastParry = now

    task.spawn(function()
        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.F, false, game)
        task.wait(config.fHoldTime or 0.06)
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.F, false, game)
    end)

    if candidate then
        lastBallDecision.ball = candidate.ball
        lastBallDecision.fireTime = now
        lastBallDecision.tti = candidate.tti or math.huge
        lastBallDecision.distance = candidate.distance or math.huge
        lastBallDecision.predictedTTI = candidate.predictedTTI or candidate.tti or math.huge
        lastBallDecision.predictedDistance = candidate.predictedDistance or candidate.distance or math.huge
        lastBallDecision.confidence = candidate.impactConfidence or 0
    else
        lastBallDecision.ball = ball
        lastBallDecision.fireTime = now
        lastBallDecision.tti = math.huge
        lastBallDecision.distance = math.huge
        lastBallDecision.predictedTTI = math.huge
        lastBallDecision.predictedDistance = math.huge
        lastBallDecision.confidence = 0
    end

    parryEvent:fire(ball, now)
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

local function computeBallDebug(telemetry)
    if not telemetry then
        return ""
    end

    local ttiValue = telemetry.tti
    if ttiValue == math.huge then
        ttiValue = -1
    end

    local predictedTTI = telemetry.predictedTTI or ttiValue
    local predictedDistance = telemetry.predictedDistance or telemetry.minFutureDistance
    local confidence = math.clamp(telemetry.impactConfidence or 0, 0, 1) * 100

    return string.format(
        "💨 Speed: %.1f | Rel: %.1f\n⏱️ TTI: %.3f | Pred: %.3f\n📏 Dist: %.2f | Pred: %.2f\n🔮 Future: %.2f | Conf: %.0f%%",
        telemetry.speed,
        telemetry.relativeSpeed or 0,
        ttiValue,
        predictedTTI,
        telemetry.distance,
        predictedDistance,
        telemetry.minFutureDistance,
        confidence
    )
end

local function shouldTriggerParry(candidate)
    if not candidate then
        return false, "no-ball"
    end

    if config.ballSpeedCheck and candidate.speed == 0 then
        return false, "stationary"
    end

    local proximityStuds = math.max(config.proximityStuds or 0, 0)
    local safeRadius = math.max(config.safeRadius or 0, 0)

    local predictedTTI = math.min(candidate.predictedTTI or math.huge, candidate.tti or math.huge)
    local predictedDistance = math.min(candidate.predictedDistance or math.huge, candidate.minFutureDistance or math.huge)
    local confidence = candidate.impactConfidence or 0
    local confidenceThreshold = math.clamp(config.predictionConfidenceThreshold or 0.35, 0, 1)

    if confidence >= confidenceThreshold then
        if predictedDistance <= math.max(proximityStuds, safeRadius * 0.5) then
            return true, "predicted-distance"
        end

        if config.useTTIWindow and predictedTTI <= math.max(candidate.window - (config.reactionLeeway or 0), 0) then
            return true, "predicted-window"
        end

        if predictedTTI <= (config.minTTI or 0.12) then
            return true, "predicted-certainty"
        end

        if predictedTTI + (config.ttiHysteresis or 0) <= candidate.tti then
            return true, "prediction-override"
        end
    end

    if candidate.distance <= proximityStuds then
        return true, "proximity"
    end

    if candidate.minFutureDistance <= math.max(proximityStuds, safeRadius * 0.65) then
        return true, "predicted"
    end

    if config.useTTIWindow and predictedTTI <= candidate.window then
        return true, "tti-window"
    end

    if predictedTTI <= (config.minTTI or 0.12) then
        return true, "fast-min-tti"
    end

    if candidate.adjustedDistance <= safeRadius and candidate.directionDot > (config.directionSensitivity or 0) then
        return true, "safe-radius"
    end

    return false, "waiting"
end

local function describeReason(reason)
    local mapping = {
        ["no-ball"] = "No ball",
        stationary = "Stationary hold",
        proximity = "Proximity lock",
        predicted = "Trajectory collapse",
        ["tti-window"] = "TTI window",
        ["fast-min-tti"] = "Aggressive minimum",
        ["safe-radius"] = "Safe radius",
        ["predicted-window"] = "Predictive window",
        ["predicted-distance"] = "Predictive distance",
        ["predicted-certainty"] = "Predictive certainty",
        ["prediction-override"] = "Prediction override",
        waiting = "Tracking",
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

    local telemetry = selectBestBall(folder)
    if not telemetry or not telemetry.ball or not telemetry.ball:IsDescendantOf(Workspace) then
        updateStatusLabel({ "Auto-Parry F", "Ball: none", "TTI: -", "Info: waiting for realBall..." })
        clearBallVisuals()
        return
    end

    local ball = telemetry.ball
    local targeting = isTargetingMe()

    local fired = false
    local reasonCode = "waiting"

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
        "Ball: found",
        string.format(
            "Speed: %.1f | Rel: %.1f | Dot: %.2f",
            telemetry.speed,
            telemetry.relativeSpeed or 0,
            telemetry.directionDot or 0
        ),
        string.format(
            "Dist: %.2f | Adj: %.2f | Pred: %.2f",
            telemetry.distance,
            telemetry.adjustedDistance,
            telemetry.predictedDistance or -1
        ),
        string.format(
            "TTI: %.3f | Pred: %.3f | Window: %.3f",
            telemetry.tti == math.huge and -1 or telemetry.tti,
            telemetry.predictedTTI == math.huge and -1 or telemetry.predictedTTI,
            telemetry.window
        ),
        string.format(
            "Conf: %.1f%% | TargetingMe: %s",
            math.clamp(telemetry.impactConfidence or 0, 0, 1) * 100,
            tostring(targeting)
        ),
    }

    if fired then
        table.insert(debugLines, "🔥 Press F: YES (" .. describeReason(reasonCode) .. ")")
    else
        table.insert(debugLines, "Press F: no (" .. describeReason(reasonCode) .. ")")
    end

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
        return typeof(value) == "number" and value >= 0
    end,
    lookAheadTime = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    lookAheadSteps = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    ttiHysteresis = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    proximityHysteresis = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    predictionHorizon = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    predictionSamples = function(value)
        return typeof(value) == "number" and value >= 1
    end,
    predictionRefinementSteps = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    predictionConfidenceThreshold = function(value)
        return typeof(value) == "number" and value >= 0 and value <= 1
    end,
    ballVelocitySmoothing = function(value)
        return typeof(value) == "number" and value >= 0 and value <= 1
    end,
    accelerationSmoothing = function(value)
        return typeof(value) == "number" and value >= 0 and value <= 1
    end,
    jerkSmoothing = function(value)
        return typeof(value) == "number" and value >= 0 and value <= 1
    end,
    kinematicsSmoothing = function(value)
        return typeof(value) == "number" and value >= 0 and value <= 1
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
    clearTable(ballMemory)
    playerKinematics.velocity = Vector3.zero
    playerKinematics.acceleration = Vector3.zero
    playerKinematics.jerk = Vector3.zero
    playerKinematics.timestamp = 0
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
