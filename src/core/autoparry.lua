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
    predictionHorizon = 1.75,
    predictionSteps = 36,
    impactSolveIterations = 12,
    impactTolerance = 0.0025,
    certaintyWeight = 0.65,
    certaintyThreshold = 0.9,
    certaintyDecay = 0.4,
    guaranteeWindow = 0.28,
    guaranteeDistance = 4.25,
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
}

local lastPlayerVelocity = Vector3.zero
local lastPlayerVelocityTime = 0
local ballHistory = setmetatable({}, { __mode = "k" })

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
    settings.ReactionLeeway = config.reactionLeeway
    settings.DirectionSensitivity = config.directionSensitivity
    settings.MinApproachSpeed = config.minApproachSpeed
    settings.LookAheadTime = config.lookAheadTime
    settings.LookAheadSteps = config.lookAheadSteps
    settings.TTIHysteresis = config.ttiHysteresis
    settings.ProximityHysteresis = config.proximityHysteresis
    settings.PredictionHorizon = config.predictionHorizon
    settings.PredictionSteps = config.predictionSteps
    settings.ImpactSolveIterations = config.impactSolveIterations
    settings.ImpactTolerance = config.impactTolerance
    settings.CertaintyWeight = config.certaintyWeight
    settings.CertaintyThreshold = config.certaintyThreshold
    settings.CertaintyDecay = config.certaintyDecay
    settings.GuaranteeWindow = config.guaranteeWindow
    settings.GuaranteeDistance = config.guaranteeDistance
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

local function getPlayerVelocity()
    if not RootPart then
        return Vector3.zero
    end

    local velocity = RootPart.AssemblyLinearVelocity or RootPart.Velocity
    if typeof(velocity) == "Vector3" then
        return velocity
    end

    return Vector3.zero
end

local function evaluateRelativePosition(relativePosition, relativeVelocity, relativeAcceleration, t)
    if t <= 0 then
        return relativePosition
    end

    local accelerationComponent = relativeAcceleration * (0.5 * t * t)
    return relativePosition + relativeVelocity * t + accelerationComponent
end

local function solveImpactTime(relativePosition, relativeVelocity, relativeAcceleration, safeRadius, horizon, tolerance, iterations)
    safeRadius = math.max(safeRadius or 0, 0)
    if safeRadius <= 0 then
        return math.huge
    end

    local relativeAccelerationValue = relativeAcceleration or Vector3.zero
    local distance = relativePosition.Magnitude
    if distance <= safeRadius then
        return 0
    end

    local velocityMagnitudeSquared = relativeVelocity:Dot(relativeVelocity)
    local guess = math.huge
    if velocityMagnitudeSquared > 1e-6 then
        local b = 2 * relativePosition:Dot(relativeVelocity)
        local c = relativePosition:Dot(relativePosition) - (safeRadius * safeRadius)
        local discriminant = b * b - 4 * velocityMagnitudeSquared * c
        if discriminant >= 0 then
            local sqrtDisc = math.sqrt(discriminant)
            local denom = 2 * velocityMagnitudeSquared
            local t1 = (-b - sqrtDisc) / denom
            local t2 = (-b + sqrtDisc) / denom
            if t1 > 0 then
                guess = t1
            end
            if t2 > 0 then
                if guess == math.huge or t2 < guess then
                    guess = t2
                end
            end
        end
    end

    if guess == math.huge then
        local speed = math.sqrt(velocityMagnitudeSquared)
        if speed > 1e-6 then
            guess = math.max((distance - safeRadius) / speed, 0)
        else
            guess = horizon or 0
        end
    end

    guess = math.clamp(guess, 0, math.max(horizon or 0, 0))

    local result = guess
    local maxIterations = math.max(iterations or 0, 0)
    local epsilon = math.max(tolerance or 0.001, 1e-4)

    for _ = 1, maxIterations do
        local position = evaluateRelativePosition(relativePosition, relativeVelocity, relativeAccelerationValue, result)
        local magnitude = position.Magnitude
        local difference = magnitude - safeRadius
        if math.abs(difference) <= epsilon then
            return math.max(result, 0)
        end

        local velocityAtTime = relativeVelocity + relativeAccelerationValue * result
        local derivative = 0
        if magnitude > 1e-6 then
            derivative = position:Dot(velocityAtTime) / magnitude
        end

        if math.abs(derivative) < 1e-6 then
            break
        end

        result -= difference / derivative
        if result < 0 then
            result = 0
        end
        if result > (horizon or math.huge) then
            result = horizon or math.huge
        end
    end

    local finalPosition = evaluateRelativePosition(relativePosition, relativeVelocity, relativeAccelerationValue, result)
    if finalPosition.Magnitude <= safeRadius + epsilon then
        return math.max(result, 0)
    end

    return math.huge
end

local function sweepClosestDistance(relativePosition, relativeVelocity, relativeAcceleration, horizon, steps)
    local minimum = relativePosition.Magnitude
    local stepCount = math.max(math.floor(steps or 0), 0)
    if stepCount == 0 then
        return minimum
    end

    local delta = (math.max(horizon or 0, 0)) / stepCount
    for index = 1, stepCount do
        local timePosition = delta * index
        local position = evaluateRelativePosition(relativePosition, relativeVelocity, relativeAcceleration, timePosition)
        local magnitude = position.Magnitude
        if magnitude < minimum then
            minimum = magnitude
        end
    end

    return minimum
end

local function computeAdvancedPrediction(relativePosition, relativeVelocity, relativeAcceleration, safeRadius, horizon, steps, tolerance, iterations)
    local impactTime = solveImpactTime(relativePosition, relativeVelocity, relativeAcceleration, safeRadius, horizon, tolerance, iterations)
    local minDistance = sweepClosestDistance(relativePosition, relativeVelocity, relativeAcceleration, horizon, steps)
    local impactDistance = math.huge

    if impactTime ~= math.huge then
        local positionAtImpact = evaluateRelativePosition(relativePosition, relativeVelocity, relativeAcceleration, impactTime)
        impactDistance = positionAtImpact.Magnitude
        if impactDistance < minDistance then
            minDistance = impactDistance
        end
    end

    return impactTime, impactDistance, minDistance
end

local function computeBallTelemetry(ball)
    if not RootPart or not ball or not ball:IsA("BasePart") then
        return nil
    end

    local now = os.clock()
    local ballPosition = ball.Position
    local playerPosition = RootPart.Position
    local toPlayer = playerPosition - ballPosition
    local distance = toPlayer.Magnitude
    if distance == 0 then
        return nil
    end

    local directionToPlayer = toPlayer / distance
    local velocity = ball.AssemblyLinearVelocity or ball.Velocity or Vector3.zero
    local speed = velocity.Magnitude
    local playerVelocity = getPlayerVelocity()

    local playerAcceleration = Vector3.zero
    local playerDelta = now - (lastPlayerVelocityTime or 0)
    if playerDelta > 1e-3 then
        playerAcceleration = (playerVelocity - lastPlayerVelocity) / playerDelta
    end
    lastPlayerVelocity = playerVelocity
    lastPlayerVelocityTime = now

    local record = ballHistory[ball]
    if not record then
        record = {
            lastPosition = ballPosition,
            lastVelocity = velocity,
            lastUpdate = now,
            certainty = 0,
        }
        ballHistory[ball] = record
    end

    local deltaTime = now - (record.lastUpdate or now)
    local acceleration = Vector3.zero
    if deltaTime > 1e-3 then
        acceleration = (velocity - record.lastVelocity) / deltaTime
    end

    local approachingSpeed = velocity:Dot(directionToPlayer)
    local directionDot = speed > 0 and approachingSpeed / speed or 0

    local pingAdjustment = 0
    if config.pingBased then
        pingAdjustment = speed * getPingTime() + (config.pingBasedOffset or 0)
    end

    local adjustedDistance = distance - pingAdjustment
    if adjustedDistance < 0 then
        adjustedDistance = 0
    end

    local tti = math.huge
    if approachingSpeed > 0 then
        tti = adjustedDistance / approachingSpeed
        if tti < 0 then
            tti = 0
        end
    end

    local window = config.dynamicWindow and getDynamicWindow(speed) or (config.staticTTIWindow or 0.5)

    local lookAheadTime = math.max(config.lookAheadTime or 0, 0)
    local lookAheadSteps = math.max(config.lookAheadSteps or 0, 0)
    local minFutureDistance = distance
    if lookAheadTime > 0 and lookAheadSteps > 0 then
        local stepDuration = lookAheadTime / lookAheadSteps
        for step = 1, lookAheadSteps do
            local dt = stepDuration * step
            local futureBallPosition = ballPosition + velocity * dt
            local futurePlayerPosition = playerPosition + playerVelocity * dt
            local projected = (futurePlayerPosition - futureBallPosition).Magnitude
            if projected < minFutureDistance then
                minFutureDistance = projected
            end
        end
    end

    local relativePosition = ballPosition - playerPosition
    local relativeVelocity = velocity - playerVelocity
    local relativeAcceleration = acceleration - playerAcceleration

    local predictionHorizon = math.max(config.predictionHorizon or 0, 0)
    local predictionSteps = math.max(math.floor(config.predictionSteps or 0), 0)
    local impactTolerance = math.max(config.impactTolerance or 0.001, 1e-4)
    local impactIterations = math.max(math.floor(config.impactSolveIterations or 0), 0)
    local safeRadius = math.max(config.safeRadius or 0, 0)

    local impactTime, impactDistance, predictedMinDistance = computeAdvancedPrediction(
        relativePosition,
        relativeVelocity,
        relativeAcceleration,
        safeRadius,
        predictionHorizon,
        predictionSteps,
        impactTolerance,
        impactIterations
    )

    if predictedMinDistance < minFutureDistance then
        minFutureDistance = predictedMinDistance
    end

    local decayRate = math.max(config.certaintyDecay or 0.4, 0)
    local retention = math.exp(-deltaTime * decayRate)
    local closeness = 0
    if safeRadius > 0 then
        local delta = math.max(minFutureDistance - safeRadius, 0)
        closeness = math.clamp(1 - (delta / safeRadius), 0, 1)
    else
        closeness = 1
    end

    local timeFactor = 0
    if impactTime ~= math.huge then
        timeFactor = math.exp(-(impactTime) * (decayRate * 0.5 + 0.05))
    end

    local instantaneousCertainty = math.clamp(closeness * timeFactor, 0, 1)
    local certaintyWeight = math.clamp(config.certaintyWeight or 0.65, 0, 1)
    local previousCertainty = (record.certainty or 0) * retention
    local blendedCertainty = previousCertainty * certaintyWeight + instantaneousCertainty * (1 - certaintyWeight)
    blendedCertainty = math.clamp(blendedCertainty, 0, 1)

    record.lastPosition = ballPosition
    record.lastVelocity = velocity
    record.lastUpdate = now
    record.certainty = blendedCertainty

    local consider = true
    if approachingSpeed <= 0 then
        consider = false
    end

    if speed < (config.minSpeed or 0) then
        consider = false
    end

    if approachingSpeed < (config.minApproachSpeed or config.minSpeed or 0) then
        consider = false
    end

    if directionDot < (config.directionSensitivity or 0) then
        consider = false
    end

    if config.ballSpeedCheck and speed == 0 then
        consider = false
    end

    if not consider and impactTime ~= math.huge and impactTime <= predictionHorizon then
        consider = true
    end

    return {
        ball = ball,
        position = ballPosition,
        velocity = velocity,
        playerVelocity = playerVelocity,
        relativeVelocity = relativeVelocity,
        relativeAcceleration = relativeAcceleration,
        speed = speed,
        distance = distance,
        approachingSpeed = approachingSpeed,
        directionDot = directionDot,
        pingAdjustment = pingAdjustment,
        adjustedDistance = adjustedDistance,
        tti = tti,
        window = window,
        minFutureDistance = minFutureDistance,
        impactTime = impactTime,
        impactDistance = impactDistance,
        predictionHorizon = predictionHorizon,
        certainty = blendedCertainty,
        consider = consider,
    }
end

local function scoreCandidate(candidate)
    local impactTime = candidate.impactTime or candidate.tti or math.huge
    if impactTime == math.huge then
        impactTime = candidate.tti or 10
    end

    if impactTime == math.huge then
        impactTime = 10
    end

    local distanceScore = math.min(candidate.minFutureDistance or candidate.distance or 0, candidate.distance or 0) /
        math.max(candidate.speed or 0, 1)
    local directionPenalty = 1 - math.clamp(candidate.directionDot or 0, 0, 1)
    local safeRadius = math.max(config.safeRadius or 1, 1)
    local futurePenalty = math.max((candidate.minFutureDistance or candidate.distance or safeRadius) - safeRadius, 0) / safeRadius
    local certaintyBonus = math.clamp(candidate.certainty or 0, 0, 1) * 0.6

    return impactTime + (distanceScore * 0.05) + (directionPenalty * 0.05) + (futurePenalty * 0.03) - certaintyBonus
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

    local now = os.clock()
    for tracked, record in pairs(ballHistory) do
        if typeof(tracked) ~= "Instance" or not tracked:IsDescendantOf(Workspace) then
            ballHistory[tracked] = nil
        elseif record and (now - (record.lastUpdate or now)) > math.max((config.predictionHorizon or 0) + 1, 1) then
            ballHistory[tracked] = nil
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

    local previousTTI = lastBallDecision.tti or math.huge
    local previousDistance = lastBallDecision.distance or math.huge
    local currentTTI = candidate.tti or math.huge
    local currentDistance = candidate.distance or math.huge

    if previousTTI - currentTTI >= hysteresis then
        return true
    end

    if previousDistance - currentDistance >= proximityDelta then
        return true
    end

    if now - (lastBallDecision.fireTime or 0) > math.max(config.cooldown or 0.1, 0) then
        return true
    end

    if candidate.certainty and candidate.certainty >= math.clamp(config.certaintyThreshold or 0.9, 0, 1) then
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

    if candidate and candidate.certainty and candidate.certainty >= math.clamp(config.certaintyThreshold or 0.9, 0, 1) then
        cooldown = math.min(cooldown, 0.015)
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
    else
        lastBallDecision.ball = ball
        lastBallDecision.fireTime = now
        lastBallDecision.tti = math.huge
        lastBallDecision.distance = math.huge
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

    local impactValue = telemetry.impactTime or math.huge
    if impactValue == math.huge then
        impactValue = -1
    end

    local certaintyPct = (telemetry.certainty or 0) * 100
    local closest = telemetry.minFutureDistance or telemetry.distance
    local impactDistance = telemetry.impactDistance or closest

    return string.format(
        "💨 Speed: %.1f\n⏱️ TTI: %.3f\n🔮 Impact: %.3f\n📏 Closest: %.2f\n🎯 ImpactDist: %.2f\n✅ Certainty: %.1f%%",
        telemetry.speed,
        ttiValue,
        impactValue,
        closest,
        impactDistance,
        certaintyPct
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
    local certaintyThreshold = math.clamp(config.certaintyThreshold or 0.9, 0, 1)
    local guaranteeWindow = math.max(config.guaranteeWindow or 0, 0)
    local guaranteeDistance = math.max(config.guaranteeDistance or 0, 0)

    if candidate.certainty and candidate.certainty >= certaintyThreshold then
        return true, "certainty-lock"
    end

    if candidate.impactTime and candidate.impactTime ~= math.huge then
        local limit = candidate.window and math.min(candidate.window, guaranteeWindow > 0 and guaranteeWindow or candidate.window) or guaranteeWindow
        if limit == 0 then
            limit = candidate.window or guaranteeWindow
        end
        if limit == 0 then
            limit = guaranteeWindow
        end
        if limit == 0 then
            limit = 0.3
        end
        if candidate.impactTime <= limit then
            return true, "impact-lock"
        end
    end

    if candidate.impactDistance and candidate.impactDistance <= math.max(guaranteeDistance, safeRadius) then
        return true, "trajectory-commit"
    end

    if candidate.distance <= proximityStuds then
        return true, "proximity"
    end

    if candidate.minFutureDistance <= math.max(proximityStuds, safeRadius * 0.65) then
        return true, "predicted"
    end

    if config.useTTIWindow and candidate.tti <= candidate.window then
        return true, "tti-window"
    end

    if candidate.tti <= (config.minTTI or 0.12) then
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
        ["impact-lock"] = "Impact window",
        ["trajectory-commit"] = "Trajectory commit",
        ["certainty-lock"] = "Certainty lock",
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
    local forcedTargeting = false

    if not targeting then
        local threshold = math.clamp(config.certaintyThreshold or 0.9, 0, 1)
        local guaranteedWindow = math.max(config.guaranteeWindow or 0, 0.05)
        if telemetry.certainty and telemetry.certainty >= threshold then
            if telemetry.impactTime and telemetry.impactTime ~= math.huge and telemetry.impactTime <= guaranteedWindow then
                targeting = true
                forcedTargeting = true
            end
        end
    end

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
            "Speed: %.1f | Dist: %.2f | TTI: %.3f",
            telemetry.speed,
            telemetry.distance,
            telemetry.tti == math.huge and -1 or telemetry.tti
        ),
        string.format(
            "Window: %.3f | Dot: %.2f | Targeting: %s",
            telemetry.window,
            telemetry.directionDot,
            forcedTargeting and "FORCED" or tostring(targeting)
        ),
        string.format(
            "Impact: %.3f | Closest: %.2f | Certainty: %.1f%%",
            telemetry.impactTime == math.huge and -1 or telemetry.impactTime,
            telemetry.minFutureDistance,
            (telemetry.certainty or 0) * 100
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
    predictionSteps = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    impactSolveIterations = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    impactTolerance = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    certaintyWeight = function(value)
        return typeof(value) == "number" and value >= 0 and value <= 1
    end,
    certaintyThreshold = function(value)
        return typeof(value) == "number" and value >= 0 and value <= 1
    end,
    certaintyDecay = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    guaranteeWindow = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    guaranteeDistance = function(value)
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
