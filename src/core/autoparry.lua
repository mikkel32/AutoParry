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
    cooldown = 0,
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
    reactionWindowMultiplier = 1.35,
    minimumTTIWindow = 0.05,
    antiSpamHoldTime = 0.25,
    curveDetection = true,
    curveAngleThreshold = 25,
    curveHoldTime = 0.12,
    curveIntensityMultiplier = 1.2,
    curveResumeSpeed = 80,
    curveStateTimeout = 2,
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
local lastParriedBallId: string?
local antiSpamHoldUntil = 0
local curveStates: { [string]: {
    lastVelocity: Vector3?,
    lastSpeed: number?,
    curveHoldUntil: number?,
    curveResumeSpeed: number?,
    lastUpdate: number?,
} } = {}

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
    settings.ReactionWindowMultiplier = config.reactionWindowMultiplier
    settings.MinimumTTIWindow = config.minimumTTIWindow
    settings.AntiSpamHoldTime = config.antiSpamHoldTime
    settings.CurveDetection = config.curveDetection
    settings.CurveAngleThreshold = config.curveAngleThreshold
    settings.CurveHoldTime = config.curveHoldTime
    settings.CurveIntensityMultiplier = config.curveIntensityMultiplier
    settings.CurveResumeSpeed = config.curveResumeSpeed
    settings.CurveStateTimeout = config.curveStateTimeout
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

local function getBallIdentifier(ball)
    if not ball then
        return nil
    end

    local ok, id = pcall(ball.GetDebugId, ball, 0)
    if ok and typeof(id) == "string" then
        return id
    end

    return tostring(ball)
end

local function getCurveState(ballId)
    if not ballId then
        return nil
    end

    local state = curveStates[ballId]
    if not state then
        state = {}
        curveStates[ballId] = state
    end

    return state
end

local function cleanupCurveStates(now)
    local timeout = config.curveStateTimeout or 0
    if timeout <= 0 then
        return
    end

    for id, entry in pairs(curveStates) do
        local lastUpdate = entry.lastUpdate or 0
        if now - lastUpdate > timeout then
            curveStates[id] = nil
        end
    end
end

local function sendKeyPress(ball)
    local now = os.clock()
    local cooldown = config.cooldown or 0
    local holdTime = config.antiSpamHoldTime or 0
    local ballId = getBallIdentifier(ball)

    if holdTime > 0 and now < antiSpamHoldUntil then
        if ballId == nil or ballId == lastParriedBallId then
            return false
        end
    end

    if cooldown > 0 and (now - lastFiredTime) < cooldown then
        if ballId == nil or ballId == lastParriedBallId then
            return false
        end
    end

    lastFiredTime = now
    state.lastParry = now
    lastParriedBallId = ballId
    if holdTime > 0 then
        antiSpamHoldUntil = now + holdTime
    else
        antiSpamHoldUntil = 0
    end

    if ballId and curveStates[ballId] then
        curveStates[ballId].curveHoldUntil = 0
        curveStates[ballId].curveResumeSpeed = 0
    end

    task.spawn(function()
        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.F, false, game)
        task.wait(config.fHoldTime or 0.06)
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.F, false, game)
    end)

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

local function computeBallDebug(speed, tti, dist)
    return string.format("💨 Speed: %.1f\n⏱️ TTI: %.3f\n📏 Dist: %.2f", speed, tti, dist)
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

    local now = os.clock()
    cleanupCurveStates(now)

    local ball = findRealBall(folder)
    if not ball or not ball:IsDescendantOf(Workspace) then
        updateStatusLabel({ "Auto-Parry F", "Ball: none", "TTI: -", "Info: waiting for realBall..." })
        clearBallVisuals()
        return
    end

    local velocity = ball.AssemblyLinearVelocity or ball.Velocity or Vector3.zero
    local speed = velocity.Magnitude
    local ballId = getBallIdentifier(ball)

    local curveState
    local curveHoldActive = false
    local curveHoldRemaining = 0
    local curveResumeTarget = 0

    if config.curveDetection then
        curveState = getCurveState(ballId)
        if curveState then
            local previousVelocity = curveState.lastVelocity
            local previousSpeed = curveState.lastSpeed or (previousVelocity and previousVelocity.Magnitude) or 0

            if previousVelocity and previousVelocity.Magnitude > 0 and speed > 0 then
                local previousDirection = previousVelocity.Unit
                local currentDirection = velocity.Unit
                local dot = math.clamp(previousDirection:Dot(currentDirection), -1, 1)
                local angle = math.deg(math.acos(dot))
                local threshold = config.curveAngleThreshold or 0

                if angle >= threshold then
                    local holdTime = config.curveHoldTime or 0
                    if holdTime > 0 then
                        local newHoldUntil = now + holdTime
                        local existingHold = curveState.curveHoldUntil or 0
                        curveState.curveHoldUntil = math.max(existingHold, newHoldUntil)
                    end

                    local multiplier = config.curveIntensityMultiplier or 1
                    if multiplier < 1 then
                        multiplier = 1
                    end

                    local resumeBaseline = math.max(speed, previousSpeed)
                    local resumeMinimum = config.curveResumeSpeed or 0
                    curveState.curveResumeSpeed = math.max(resumeBaseline * multiplier, resumeMinimum)
                end
            end

            curveState.lastVelocity = velocity
            curveState.lastSpeed = speed
            curveState.lastUpdate = now

            local holdUntil = curveState.curveHoldUntil or 0
            if holdUntil > now then
                curveHoldActive = true
                curveHoldRemaining = holdUntil - now
            end

            local resumeTarget = curveState.curveResumeSpeed or 0
            if resumeTarget > 0 then
                curveResumeTarget = resumeTarget
                if speed >= resumeTarget then
                    curveState.curveResumeSpeed = 0
                    curveState.curveHoldUntil = 0
                else
                    curveHoldActive = true
                end
            end
        end
    end

    if config.ballSpeedCheck and speed == 0 then
        local stationaryDistance = (RootPart.Position - ball.Position).Magnitude
        updateStatusLabel({
            "Auto-Parry F",
            "Ball: found (stationary)",
            string.format("Speed: %.1f | Dist: %.2f", speed, stationaryDistance),
            "Info: speed=0 -> hold",
        })
        setBallVisuals(nil, "")
        return
    end

    local distanceToPlayer = (RootPart.Position - ball.Position).Magnitude

    local adjustedDistance = distanceToPlayer
    if config.pingBased then
        adjustedDistance -= (speed * getPingTime() + (config.pingBasedOffset or 0))
    end

    local toward = speed
    if toward <= 0 then
        toward = 1
    end

    local tti = adjustedDistance / toward
    if tti < 0 then
        tti = 0
    end

    local window = config.dynamicWindow and getDynamicWindow(speed) or (config.staticTTIWindow or 0.5)
    local multiplier = config.reactionWindowMultiplier or 1
    if multiplier > 0 then
        window *= multiplier
    end
    local minWindow = config.minimumTTIWindow or 0
    if window < minWindow then
        window = minWindow
    end

    local fired = false
    local reason = ""

    local canAttemptParry = not curveHoldActive
    local targetingMe = isTargetingMe()

    if targetingMe and canAttemptParry then
        if distanceToPlayer <= (config.proximityStuds or 5) then
            if sendKeyPress(ball) then
                fired = true
                reason = "PROX"
            end
        end

        if not fired and config.useTTIWindow and (tti <= window) then
            if sendKeyPress(ball) then
                fired = true
                reason = "TTI"
            end
        end
    end

    local debugLines = {
        "Auto-Parry F",
        "Ball: found",
        string.format("Speed: %.1f | Dist: %.2f | TTI: %.3f", speed, distanceToPlayer, tti),
        string.format("Window: %.3f | TargetingMe: %s", window, tostring(targetingMe)),
    }

    if curveHoldActive then
        table.insert(debugLines, string.format("Curve hold: %.3fs", math.max(curveHoldRemaining, 0)))
        if curveResumeTarget > 0 then
            table.insert(debugLines, string.format("Resume ≥ %.1f speed", curveResumeTarget))
        end
    end

    if fired then
        table.insert(debugLines, "🔥 Press F: YES (" .. reason .. ")")
    else
        local pressLabel = "Press F: no"
        if not canAttemptParry and curveHoldActive then
            pressLabel = "Press F: hold (curve)"
        end
        table.insert(debugLines, pressLabel)
    end

    updateStatusLabel(debugLines)
    setBallVisuals(ball, computeBallDebug(speed, tti, distanceToPlayer))
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
    reactionWindowMultiplier = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    minimumTTIWindow = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    antiSpamHoldTime = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    curveDetection = function(value)
        return typeof(value) == "boolean"
    end,
    curveAngleThreshold = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    curveHoldTime = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    curveIntensityMultiplier = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    curveResumeSpeed = function(value)
        return typeof(value) == "number" and value >= 0
    end,
    curveStateTimeout = function(value)
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
    antiSpamHoldUntil = 0
    lastParriedBallId = nil
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
    lastParriedBallId = nil
    antiSpamHoldUntil = 0
    curveStates = {}

    initProgress = { stage = "waiting-player" }
    applyInitStatus(cloneTable(initProgress))

    initialization.destroyed = false
end

ensureInitialization()
ensureLoop()
syncGlobalSettings()

return AutoParry
