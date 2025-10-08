-- mikkel32/AutoParry : src/core/immortal.lua
-- Teleport-focused evasion controller that implements the "Immortal" mode
-- described in the provided GodTeleportCore specification. The controller is
-- inert until enabled, after which it drives humanoid root-part teleports
-- using a constant-time MPC planner constrained to the 80-stud ball radius.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Stats = game:FindService("Stats")

local Immortal = {}
Immortal.__index = Immortal

local min = math.min
local max = math.max
local sin = math.sin
local cos = math.cos
local sqrt = math.sqrt
local TAU = 2 * math.pi

local MAX_RANGE_FROM_BALL = 80.0
local HUMANOID_RADIUS = 2.1
local SAFE_MARGIN = 1.1
local Y_HOVER = 6.0

local H_BASE = 1.0
local H_SPEED_GAIN = 0.007
local H_PING_GAIN = 0.8
local H_MIN = 0.7
local H_MAX = 2.0

local N_T_FINE = 8
local N_T_COARSE = 8
local CENTER_FRACTIONS = { 0.0, 0.15, 0.3, 0.5, 0.7, 1.0 }

local RADII_PRIMARY = { 44.0, 56.0, 68.0, 76.0, 80.0 }
local RADII_BACKUP = { 80.0, 72.0, 64.0 }
local EXTRA_LAYERS_Y = { -2.0, 0.0, 2.0 }
local N_DIRS = 44

local PING_MULT = 1.30
local LATENCY_FACTOR = 1.0

local ACCEL_DECAY = 0.92
local ACCEL_FLOOR = 60.0
local ACCEL_CAP = 500.0
local CURV_DECAY = 0.90
local CURV_CAP = 0.60
local CURV_SCALE = 0.72

local IMMEDIATE_DANGER_TTI = 0.075
local IMMEDIATE_DANGER_RAD = 6.0

local TP_CD_SAFE = 0.012
local TP_CD_DANGER = 0.005

local SAFE_MARGIN2_STRONG = 81.0
local SAFE_MARGIN2_MIN = 9.0
local NUDGE_PROB = 0.06
local NUDGE_GAIN2 = 8.0

local CONE_BASE_DEG = 28.0
local CONE_SPEED_GAIN = 0.10

local DRIFT_GUARD = 2.5
local HYSTERESIS_WEIGHT2 = 6.0
local CHAIN_TRIGGER2 = 4.0

local function safeUnit(v)
    local m = v.Magnitude
    if m > 1e-6 then
        return v / m
    end
    return Vector3.zero
end

local function ballRadiusOf(part)
    local s = part.Size
    return 0.5 * math.max(s.X, math.max(s.Y, s.Z))
end

local function clampToRange(currentBallPos, p)
    local d = p - currentBallPos
    local m = d.Magnitude
    if m > MAX_RANGE_FROM_BALL and m > 1e-6 then
        return currentBallPos + d * (MAX_RANGE_FROM_BALL / m)
    end
    return p
end

local function isInstanceDestroyed(instance)
    if not instance then
        return true
    end

    if instance.Parent then
        return false
    end

    local ok, isDescendant = pcall(function()
        return instance:IsDescendantOf(game)
    end)

    return not ok or not isDescendant
end

local function futureBallPos(bPos, bVel, t, ping)
    local look = t + ping * PING_MULT
    if look < 0 then
        look = 0
    end
    return bPos + bVel * look
end

local function getPingSeconds()
    local seconds = 0
    if not Stats then
        return seconds
    end

    local okStat, stat = pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]
    end)

    if not okStat or not stat then
        return seconds
    end

    local okValue, value = pcall(stat.GetValue, stat)
    if okValue and value then
        seconds = (value or 0) / 1000
    end

    return seconds
end

local function createTimeBasis()
    local basis = {}
    if N_T_FINE > 1 then
        for k = 0, N_T_FINE - 1 do
            local f = k / (N_T_FINE - 1)
            table.insert(basis, f * f)
        end
    else
        table.insert(basis, 0.0)
    end

    if N_T_COARSE > 0 then
        local dt = 1 / math.max(N_T_COARSE - 1, 1)
        for j = 0, N_T_COARSE - 1 do
            local f = j * dt
            if f > 0 then
                table.insert(basis, f)
            end
        end
    end

    basis[#basis] = 1.0
    return basis
end

local T_BASIS = createTimeBasis()

local function createDirs(rng)
    local dirs = table.create(N_DIRS)
    local phase = rng:NextNumber(0, TAU)
    for i = 1, N_DIRS do
        local theta = phase + TAU * (i - 1) / N_DIRS
        dirs[i] = Vector3.new(cos(theta), 0, sin(theta))
    end
    return dirs
end

local function isBallValid(ball)
    return ball and ball:IsA("BasePart") and ball:IsDescendantOf(Workspace)
end

function Immortal.new(options)
    local self = setmetatable({}, Immortal)
    self._options = options or {}
    self._enabled = false
    self._player = options and options.player or nil
    self._character = options and options.character or nil
    self._humanoid = options and options.humanoid or nil
    self._rootPart = options and options.rootPart or nil
    self._ballsFolder = options and options.ballsFolder or nil

    self._rng = Random.new()
    self._dirs = createDirs(self._rng)
    self._timeBuffer = table.create(#T_BASIS)
    self._radiusBuffer = table.create(#T_BASIS)
    self._mpcCenters = table.create(#CENTER_FRACTIONS)

    self._highlight = nil
    self._heartbeat = nil

    self._lastBallVel = nil
    self._aWorst = ACCEL_FLOOR
    self._kappaWorst = 0.05
    self._lastTeleport = 0
    self._lastGoodTarget = nil
    self._nextBackupTarget = nil
    self._lastMoveDir = nil

    return self
end

function Immortal:_ensureHighlightParent()
    if not self._highlight then
        return
    end

    if isInstanceDestroyed(self._highlight) then
        self._highlight = nil
        return
    end

    local player = self._player or Players.LocalPlayer
    if not player then
        return
    end

    local playerGui = player:FindFirstChildOfClass("PlayerGui")
    if not playerGui then
        local ok, gui = pcall(function()
            return player:WaitForChild("PlayerGui", 0.1)
        end)
        playerGui = ok and gui or nil
    end

    if playerGui and self._highlight.Parent ~= playerGui then
        local ok = pcall(function()
            self._highlight.Parent = playerGui
        end)
        if not ok then
            self._highlight = nil
        end
    end
end

function Immortal:_ensureHighlight()
    if self._highlight then
        if isInstanceDestroyed(self._highlight) then
            self._highlight = nil
        else
            self:_ensureHighlightParent()
            if self._highlight then
                return self._highlight
            end
        end
    end

    local player = self._player or Players.LocalPlayer
    if not player then
        return nil
    end

    local playerGui = player:FindFirstChildOfClass("PlayerGui")
    if not playerGui then
        local ok, gui = pcall(function()
            return player:WaitForChild("PlayerGui", 0.1)
        end)
        playerGui = ok and gui or nil
    end

    if not playerGui then
        return nil
    end

    local highlight = Instance.new("Highlight")
    highlight.Name = "ImmortalHighlight"
    highlight.FillColor = Color3.fromRGB(0, 255, 0)
    highlight.OutlineColor = Color3.fromRGB(0, 255, 0)
    highlight.FillTransparency = 0.3
    highlight.OutlineTransparency = 0
    highlight.Enabled = false

    local ok = pcall(function()
        highlight.Parent = playerGui
    end)

    if not ok then
        highlight:Destroy()
        return nil
    end

    self._highlight = highlight
    return highlight
end

function Immortal:_setHighlightTarget(ball)
    local highlight = self:_ensureHighlight()
    if not highlight then
        return
    end

    if ball and isBallValid(ball) then
        highlight.Adornee = ball
        highlight.Enabled = true
    else
        highlight.Adornee = nil
        highlight.Enabled = false
    end
end

function Immortal:_clearHighlight()
    if self._highlight then
        self._highlight.Enabled = false
        self._highlight.Adornee = nil
    end
end

function Immortal:_findBall()
    local folder = self._ballsFolder
    if not folder then
        return nil
    end

    local best = nil
    for _, child in ipairs(folder:GetChildren()) do
        if child:IsA("BasePart") then
            if child:GetAttribute("realBall") then
                return child
            elseif not best and child.Name == "Ball" then
                best = child
            end
        end
    end

    return best
end

function Immortal:_updateBounds(vNow, dt)
    local vPrev = self._lastBallVel
    if vPrev and dt > 1e-6 then
        local aVec = (vNow - vPrev) / dt
        local aMag = aVec.Magnitude
        local speed = math.max(vNow.Magnitude, 1e-6)
        local kappaInst = (vNow:Cross(aVec)).Magnitude / (speed * speed * speed)

        self._aWorst = min(ACCEL_CAP, max(ACCEL_FLOOR, ACCEL_DECAY * self._aWorst + (1 - ACCEL_DECAY) * aMag))
        self._kappaWorst = min(CURV_CAP, max(0.0, CURV_DECAY * self._kappaWorst + (1 - CURV_DECAY) * kappaInst))
    end

    self._lastBallVel = vNow
end

function Immortal:_precomputeHorizon(bPos, bVel, bSpeed, bRad, ping, H)
    local CT = self._timeBuffer
    local R2 = self._radiusBuffer
    local MPC = self._mpcCenters

    local latBase = bSpeed * ping * LATENCY_FACTOR * PING_MULT

    for i = 1, #T_BASIS do
        local t = H * T_BASIS[i]
        local c = futureBallPos(bPos, bVel, t, ping)
        CT[i] = c

        local curv = CURV_SCALE * (bSpeed * bSpeed) * self._kappaWorst * t * t
        local R = bRad + (bSpeed * t) + 0.5 * self._aWorst * t * t + latBase + HUMANOID_RADIUS + SAFE_MARGIN + curv
        R2[i] = R * R
    end

    for j = 1, #CENTER_FRACTIONS do
        local f = CENTER_FRACTIONS[j]
        MPC[j] = futureBallPos(bPos, bVel, H * f, ping)
    end
end

function Immortal:_minMargin2(target)
    local CT = self._timeBuffer
    local R2 = self._radiusBuffer
    local minM2 = math.huge

    for i = 1, #CT do
        local c = CT[i]
        local dx = target.X - c.X
        local dy = target.Y - c.Y
        local dz = target.Z - c.Z
        local d2 = dx * dx + dy * dy + dz * dz
        local m2 = d2 - R2[i]
        if m2 < minM2 then
            minM2 = m2
            if minM2 <= 0 then
                return minM2
            end
        end
    end

    return minM2
end

function Immortal:_clearNow2(target)
    local c0 = self._timeBuffer[1]
    if not c0 then
        return math.huge
    end

    local dx = target.X - c0.X
    local dy = target.Y - c0.Y
    local dz = target.Z - c0.Z
    local d2 = dx * dx + dy * dy + dz * dz
    return d2 - self._radiusBuffer[1]
end

function Immortal:_inForbiddenCone(currentBallPos, target, vBall, bSpeed)
    local sp = bSpeed
    if sp < 1e-3 then
        return false
    end

    local bt = target - currentBallPos
    bt = Vector3.new(bt.X, 0, bt.Z)
    local btMag = bt.Magnitude
    if btMag < 1e-3 then
        return true
    end
    local btU = bt / btMag

    local vXZ = Vector3.new(vBall.X, 0, vBall.Z)
    local vm = vXZ.Magnitude
    if vm < 1e-3 then
        return false
    end
    local vU = vXZ / vm

    local coneDeg = CONE_BASE_DEG + CONE_SPEED_GAIN * (sp / 10.0)
    if coneDeg > 75 then
        coneDeg = 75
    end
    local cosTh = math.cos(math.rad(coneDeg))
    local dot = btU:Dot(vU)
    local radiusFrac = btMag / MAX_RANGE_FROM_BALL
    local bias = 0.05 * (1 - radiusFrac)
    return dot > (cosTh - bias)
end

function Immortal:_scoreCandidate(p, currentBallPos)
    if self:_clearNow2(p) <= 0 then
        return -math.huge
    end

    local robustM2 = self:_minMargin2(p)
    local d = currentBallPos - p
    local dm = d.Magnitude
    if dm > 1e-6 then
        local drift = d * (DRIFT_GUARD / dm)
        local m2Drift = self:_minMargin2(p + drift)
        if m2Drift < robustM2 then
            robustM2 = m2Drift
        end
    end

    local lastMoveDir = self._lastMoveDir
    local hrp = self._rootPart
    if lastMoveDir and hrp then
        local step = p - hrp.Position
        step = Vector3.new(step.X, 0, step.Z)
        local sm = step.Magnitude
        if sm > 1e-6 then
            local dir = step / sm
            local dot = dir:Dot(lastMoveDir)
            local penalty = (1 - max(dot, -1.0)) * HYSTERESIS_WEIGHT2
            robustM2 -= penalty
        end
    end

    return robustM2
end

function Immortal:_tryAtRadius(center, radius, currentBallPos, baseUp, vBall, bSpeed)
    local bestTarget = nil
    local bestScore = -math.huge

    local CT = self._timeBuffer
    local dirs = self._dirs

    local vdir = safeUnit((#CT >= 2) and (CT[2] - CT[1]) or Vector3.new(1, 0, 0))
    local hrp = self._rootPart
    local away = safeUnit(hrp and (hrp.Position - center) or Vector3.new(1, 0, 0))
    local tleft = Vector3.new(-vdir.Z, 0, vdir.X)
    local tright = Vector3.new(vdir.Z, 0, -vdir.X)
    local prim = { away, tleft, tright }

    for _, dir in ipairs(prim) do
        if dir.Magnitude > 0.1 then
            for _, yoff in ipairs(EXTRA_LAYERS_Y) do
                local raw = center + dir * radius + Vector3.new(0, baseUp + yoff, 0)
                local p = clampToRange(currentBallPos, raw)
                if not self:_inForbiddenCone(currentBallPos, p, vBall, bSpeed) then
                    local sc = self:_scoreCandidate(p, currentBallPos)
                    if sc > bestScore then
                        bestScore = sc
                        bestTarget = p
                        if sc >= SAFE_MARGIN2_STRONG then
                            return bestTarget, bestScore, true
                        end
                    end
                end
            end
        end
    end

    for i = 1, #dirs do
        local dir = dirs[i]
        for _, yoff in ipairs(EXTRA_LAYERS_Y) do
            local raw = center + dir * radius + Vector3.new(0, baseUp + yoff, 0)
            local p = clampToRange(currentBallPos, raw)
            if not self:_inForbiddenCone(currentBallPos, p, vBall, bSpeed) then
                local sc = self:_scoreCandidate(p, currentBallPos)
                if sc > bestScore then
                    bestScore = sc
                    bestTarget = p
                    if sc >= SAFE_MARGIN2_STRONG then
                        return bestTarget, bestScore, true
                    end
                end
            end
        end
    end

    return bestTarget, bestScore, false
end

function Immortal:_planTargets(currentBallPos, vBall, bSpeed)
    local bestTarget = nil
    local bestScore = -math.huge
    local backup = nil
    local backupScore = -math.huge

    local hrp = self._rootPart

    if self._lastGoodTarget then
        local tgt = clampToRange(currentBallPos, self._lastGoodTarget)
        if not self:_inForbiddenCone(currentBallPos, tgt, vBall, bSpeed) then
            local sc = self:_scoreCandidate(tgt, currentBallPos)
            if sc >= SAFE_MARGIN2_MIN then
                bestTarget = tgt
                bestScore = sc
                backup = tgt
                backupScore = sc
            end
        end
    end

    local MPC = self._mpcCenters
    for ci = 1, #MPC do
        local c = MPC[ci]
        local speedBoostY = min(6.0, (bSpeed / 30.0) * 2.0)
        local up = Y_HOVER + speedBoostY
        for ri = 1, #RADII_PRIMARY do
            local rad = min(RADII_PRIMARY[ri], MAX_RANGE_FROM_BALL)
            local t, sc, ok = self:_tryAtRadius(c, rad, currentBallPos, up, vBall, bSpeed)
            if sc > bestScore then
                bestScore = sc
                bestTarget = t
            end
            if ok or (bestScore >= SAFE_MARGIN2_MIN) then
                local cj = min(#MPC, ci + 2)
                local c2 = MPC[cj]
                for rj = 1, #RADII_BACKUP do
                    local rad2 = min(RADII_BACKUP[rj], MAX_RANGE_FROM_BALL)
                    local tb, sb = self:_tryAtRadius(c2, rad2, currentBallPos, up, vBall, bSpeed)
                    if sb > backupScore then
                        backup = tb
                        backupScore = sb
                    end
                end
                return bestTarget or backup, backup
            end
        end
    end

    if not backup then
        local away = safeUnit(hrp and (hrp.Position - currentBallPos) or Vector3.new(1, 0, 0))
        if away.Magnitude < 1e-6 then
            away = Vector3.new(1, 0, 0)
        end
        backup = clampToRange(currentBallPos, currentBallPos + away * MAX_RANGE_FROM_BALL) + Vector3.new(0, Y_HOVER, 0)
    end

    return bestTarget or backup, backup
end

function Immortal:_doTeleport(target, danger)
    if not self._rootPart or not target then
        return
    end

    local now = os.clock()
    local cd = danger and TP_CD_DANGER or TP_CD_SAFE
    if now - self._lastTeleport < cd then
        return
    end
    self._lastTeleport = now

    local from = self._rootPart.Position
    self._rootPart.CFrame = CFrame.new(target)

    pcall(function()
        self._rootPart.AssemblyLinearVelocity = Vector3.zero
        self._rootPart.AssemblyAngularVelocity = Vector3.zero
    end)

    self._lastGoodTarget = target

    local delta = target - from
    delta = Vector3.new(delta.X, 0, delta.Z)
    local dm = delta.Magnitude
    if dm > 1e-6 then
        self._lastMoveDir = delta / dm
    end
end

function Immortal:_resetPlanner()
    self._nextBackupTarget = nil
    self._lastGoodTarget = nil
    self._lastMoveDir = nil
end

function Immortal:_heartbeatStep(dt)
    if not self._enabled then
        return
    end

    local hrp = self._rootPart
    if not hrp then
        self:_clearHighlight()
        self:_resetPlanner()
        return
    end

    local ball = self:_findBall()
    if not isBallValid(ball) then
        self:_setHighlightTarget(nil)
        self:_resetPlanner()
        return
    end

    self:_setHighlightTarget(ball)

    local bPos = ball.Position
    local bVel = ball.AssemblyLinearVelocity or ball.Velocity
    local bSpeed = bVel.Magnitude
    local ping = getPingSeconds()
    local selfPos = hrp.Position
    local bRad = ballRadiusOf(ball)

    self:_updateBounds(bVel, dt)

    local H = H_BASE + H_SPEED_GAIN * min(bSpeed, 140) + H_PING_GAIN * ping
    H = max(H_MIN, min(H_MAX, H))

    local diff = selfPos - bPos
    if diff.Magnitude > MAX_RANGE_FROM_BALL + 1.0 then
        local clamped = clampToRange(bPos, selfPos)
        self:_doTeleport(Vector3.new(clamped.X, Y_HOVER, clamped.Z), true)
        return
    end

    self:_precomputeHorizon(bPos, bVel, bSpeed, bRad, ping, H)

    do
        local c0 = self._timeBuffer[1]
        local dx = selfPos.X - c0.X
        local dy = selfPos.Y - c0.Y
        local dz = selfPos.Z - c0.Z
        local d2 = dx * dx + dy * dy + dz * dz
        if d2 <= math.max(self._radiusBuffer[1], IMMEDIATE_DANGER_RAD * IMMEDIATE_DANGER_RAD) then
            local away = safeUnit(Vector3.new(dx, dy, dz))
            local desired = bPos + away * MAX_RANGE_FROM_BALL
            self:_doTeleport(Vector3.new(desired.X, Y_HOVER, desired.Z), true)
            return
        end
    end

    do
        local vSelf = hrp.AssemblyLinearVelocity or Vector3.zero
        local r = bPos - selfPos
        local vRel = bVel - vSelf
        local v2 = vRel:Dot(vRel)
        local eta
        local miss
        if v2 < 1e-6 then
            eta = math.huge
            miss = r.Magnitude
        else
            local tStar = -r:Dot(vRel) / v2
            if tStar < 0 then
                tStar = 0
            end
            eta = tStar
            miss = (r + vRel * tStar).Magnitude
        end

        local etaLook = min(eta + ping * PING_MULT, H)
        local touchRad = sqrt(self._radiusBuffer[1])
        if etaLook <= IMMEDIATE_DANGER_TTI or miss <= touchRad then
            local tgt, backup = self:_planTargets(bPos, bVel, bSpeed)
            self._nextBackupTarget = backup
            self:_doTeleport(tgt, true)
            if self:_minMargin2(tgt) < CHAIN_TRIGGER2 and backup then
                self:_doTeleport(backup, true)
            end
            return
        end
    end

    local curM2 = self:_minMargin2(selfPos)
    if curM2 <= 0.0 then
        local tgt, backup = self:_planTargets(bPos, bVel, bSpeed)
        self._nextBackupTarget = backup
        self:_doTeleport(tgt, true)
        if self:_minMargin2(tgt) < CHAIN_TRIGGER2 and backup then
            self:_doTeleport(backup, true)
        end
        return
    end

    if self._nextBackupTarget and curM2 < SAFE_MARGIN2_MIN then
        self:_doTeleport(self._nextBackupTarget, true)
        self._nextBackupTarget = nil
        return
    end

    if curM2 < SAFE_MARGIN2_STRONG and self._rng:NextNumber() < NUDGE_PROB then
        local tgt, backup = self:_planTargets(bPos, bVel, bSpeed)
        if tgt then
            local m2 = self:_minMargin2(tgt)
            if m2 > curM2 + NUDGE_GAIN2 then
                self._nextBackupTarget = backup
                self:_doTeleport(tgt, false)
                return
            end
        end
    end
end

function Immortal:setContext(context)
    context = context or {}
    if context.player ~= nil then
        self._player = context.player
    end
    if context.character ~= nil then
        self._character = context.character
    end
    if context.humanoid ~= nil then
        self._humanoid = context.humanoid
    end
    if context.rootPart ~= nil then
        self._rootPart = context.rootPart
    end
    if context.ballsFolder ~= nil then
        self._ballsFolder = context.ballsFolder
    end

    self:_ensureHighlightParent()

    if not self._character or not self._rootPart then
        self:_clearHighlight()
        self:_resetPlanner()
    end
end

function Immortal:setBallsFolder(folder)
    if self._ballsFolder == folder then
        return
    end
    self._ballsFolder = folder
end

function Immortal:_start()
    if self._heartbeat then
        return
    end

    self:_ensureHighlight()
    self:_resetPlanner()
    self._heartbeat = RunService.Heartbeat:Connect(function(dt)
        self:_heartbeatStep(dt)
    end)
end

function Immortal:_stop()
    if self._heartbeat then
        self._heartbeat:Disconnect()
        self._heartbeat = nil
    end
    self:_clearHighlight()
    self:_resetPlanner()
end

function Immortal:setEnabled(enabled)
    enabled = not not enabled
    if self._enabled == enabled then
        return
    end

    self._enabled = enabled

    if enabled then
        self:_start()
    else
        self:_stop()
    end
end

function Immortal:isEnabled()
    return self._enabled
end

function Immortal:handleHumanoidDied()
    self:_clearHighlight()
    self:_resetPlanner()
end

function Immortal:destroy()
    self:setEnabled(false)
    if self._highlight then
        self._highlight:Destroy()
        self._highlight = nil
    end
end

return Immortal
