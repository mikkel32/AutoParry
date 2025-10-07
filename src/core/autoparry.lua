-- mikkel32/AutoParry : src/core/autoparry.lua
-- selene: allow(global_usage)
-- Frame-driven parry engine with developer-friendly configuration hooks.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Replicated = game:GetService("ReplicatedStorage")
local Stats = game:GetService("Stats")

local Require = rawget(_G, "ARequire")
local Util = Require("src/shared/util.lua")

local function resolveLocalPlayer()
    local player = Players.LocalPlayer
    if player then
        return player
    end

    local start = os.clock()
    while not player do
        task.wait()
        player = Players.LocalPlayer
        if player or os.clock() - start > 10 then
            break
        end
    end

    assert(player, "AutoParry: LocalPlayer unavailable")
    return player
end

local function resolveParryRemote()
    local remotes = Replicated:FindFirstChild("Remotes")
    if not remotes then
        remotes = Replicated:WaitForChild("Remotes", 10)
    end

    assert(remotes, "AutoParry: ReplicatedStorage.Remotes missing")

    local remote = remotes:FindFirstChild("ParryButtonPress")
    if not remote then
        remote = remotes:WaitForChild("ParryButtonPress", 10)
    end

    assert(remote, "AutoParry: ParryButtonPress remote missing")
    return remote
end

local LocalPlayer = resolveLocalPlayer()
local ParryRemote = resolveParryRemote()

local DEFAULT_CONFIG = {
    cooldown = 0.10,
    minSpeed = 10,
    pingOffset = 0.05,
    minTTI = 0.12,
    maxTTI = 0.55,
    safeRadius = 10,
    targetHighlightName = "Highlight",
    ballsFolderName = "Balls",
}

local AutoParry = {}
local config = Util.deepCopy(DEFAULT_CONFIG)
local state = {
    enabled = false,
    connection = nil,
    lastParry = 0,
}

local stateChanged = Util.Signal.new()
local parryEvent = Util.Signal.new()
local logger = nil

local function log(...)
    if logger then
        logger(...)
    end
end

local function ballsFolder()
    return workspace:FindFirstChild(config.ballsFolderName)
end

local function characterIsTargeted(character)
    if not character then
        return false
    end

    if not config.targetHighlightName then
        return true
    end

    return character:FindFirstChild(config.targetHighlightName) ~= nil
end

local function distance(a, b)
    return (a - b).Magnitude
end

local function currentPing()
    local ok, stat = pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]
    end)
    if not ok or not stat then
        return 0
    end

    local success, value = pcall(stat.GetValue, stat)
    if not success or not value then
        return 0
    end

    return value / 1000
end

local function emitState()
    stateChanged:fire(state.enabled)
end

local function tryParry(ball)
    local now = os.clock()
    if now - state.lastParry < config.cooldown then
        return false
    end

    state.lastParry = now
    ParryRemote:FireServer()
    parryEvent:fire(ball, now)
    log("AutoParry: fired parry for", ball)
    return true
end

local function evaluateBall(ball, rootPos, ping)
    if not ball:IsA("BasePart") then
        return nil
    end

    if ball:GetAttribute("realBall") ~= true then
        return nil
    end

    local velocity = ball.AssemblyLinearVelocity
    local speed = velocity.Magnitude
    if speed < config.minSpeed then
        return nil
    end

    local toPlayer = (rootPos - ball.Position)
    if toPlayer.Magnitude == 0 then
        return 0
    end

    local toward = velocity:Dot(toPlayer.Unit)
    if toward <= 0 then
        return nil
    end

    local distanceToPlayer = distance(ball.Position, rootPos)
    if distanceToPlayer <= config.safeRadius then
        return 0
    end

    local tti = distanceToPlayer / toward
    tti = tti - (ping + config.pingOffset)

    if tti < config.minTTI or tti > config.maxTTI then
        return nil
    end

    return tti
end

local function step()
    local character = LocalPlayer and LocalPlayer.Character
    if not character or not character.PrimaryPart then
        return
    end

    if not characterIsTargeted(character) then
        return
    end

    local folder = ballsFolder()
    if not folder then
        return
    end

    local rootPos = character.PrimaryPart.Position
    local bestBall, bestTti
    local ping = currentPing()

    for _, ball in ipairs(folder:GetChildren()) do
        local tti = evaluateBall(ball, rootPos, ping)
        if tti == 0 then
            if tryParry(ball) then
                return
            end
        elseif tti and (not bestTti or tti < bestTti) then
            bestTti = tti
            bestBall = ball
        end
    end

    if bestBall then
        tryParry(bestBall)
    end
end

function AutoParry.enable()
    if state.enabled then
        return
    end

    state.enabled = true
    if not state.connection then
        state.connection = RunService.Heartbeat:Connect(step)
    end

    emitState()
end

function AutoParry.disable()
    if not state.enabled then
        return
    end

    state.enabled = false
    if state.connection then
        state.connection:Disconnect()
        state.connection = nil
    end

    emitState()
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
}

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
    log("AutoParry: applied config", config)
    return AutoParry.getConfig()
end

function AutoParry.getConfig()
    return Util.deepCopy(config)
end

function AutoParry.resetConfig()
    config = Util.deepCopy(DEFAULT_CONFIG)
    log("AutoParry: reset config to defaults")
    return AutoParry.getConfig()
end

function AutoParry.getLastParryTime()
    return state.lastParry
end

function AutoParry.onStateChanged(callback)
    assert(typeof(callback) == "function", "AutoParry.onStateChanged expects a function")
    return stateChanged:connect(callback)
end

function AutoParry.onParry(callback)
    assert(typeof(callback) == "function", "AutoParry.onParry expects a function")
    return parryEvent:connect(callback)
end

function AutoParry.setLogger(fn)
    if fn ~= nil then
        assert(typeof(fn) == "function", "AutoParry.setLogger expects a function or nil")
    end
    logger = fn
end

function AutoParry.destroy()
    AutoParry.disable()
    stateChanged:destroy()
    parryEvent:destroy()
    stateChanged = Util.Signal.new()
    parryEvent = Util.Signal.new()
    logger = nil
    state.lastParry = 0
    AutoParry.resetConfig()
end

return AutoParry
