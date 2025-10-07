-- mikkel32/AutoParry : src/core/autoparry.lua
-- selene: allow(global_usage)
-- Frame-driven parry engine with developer-friendly configuration hooks.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Replicated = game:GetService("ReplicatedStorage")
local Stats = game:GetService("Stats")

local Require = rawget(_G, "ARequire")
local Util = Require("src/shared/util.lua")

local luauTypeof = rawget(_G, "typeof")
local arrayUnpack = table.unpack or unpack

local function typeOf(value)
    if luauTypeof then
        local ok, result = pcall(luauTypeof, value)
        if ok then
            return result
        end
    end

    return type(value)
end

local function isCallable(value)
    return typeOf(value) == "function"
end

local function safeDisconnect(connection)
    if not connection then
        return
    end

    local okMethod, disconnectMethod = pcall(function()
        return connection.Disconnect or connection.disconnect
    end)

    if okMethod and isCallable(disconnectMethod) then
        pcall(disconnectMethod, connection)
    end
end

local function connectClientEvent(remote, handler)
    if not remote or not handler then
        return nil
    end

    local okEvent, event = pcall(function()
        return remote.OnClientEvent
    end)
    if not okEvent or event == nil then
        return nil
    end

    local okConnect, connection = pcall(function()
        return event:Connect(handler)
    end)
    if okConnect and connection then
        return connection
    end

    local okMethod, connectMethod = pcall(function()
        return event.Connect or event.connect
    end)
    if okMethod and isCallable(connectMethod) then
        local success, result = pcall(connectMethod, event, handler)
        if success then
            return result
        end
    end

    return nil
end

local function connectSignal(signal, handler)
    if not signal or not handler then
        return nil
    end

    local okMethod, connectMethod = pcall(function()
        return signal.Connect or signal.connect
    end)

    if okMethod and isCallable(connectMethod) then
        local success, connection = pcall(connectMethod, signal, handler)
        if success then
            return connection
        end
    end

    return nil
end

local function connectInstanceEvent(instance, eventName, handler)
    if not instance or not handler then
        return nil
    end

    local okEvent, event = pcall(function()
        return instance[eventName]
    end)

    if not okEvent or event == nil then
        return nil
    end

    return connectSignal(event, handler)
end

local function connectPropertyChangedSignal(instance, propertyName, handler)
    if not instance or not handler then
        return nil
    end

    local okGetter, getSignal = pcall(function()
        return instance.GetPropertyChangedSignal
    end)

    if not okGetter or not isCallable(getSignal) then
        return nil
    end

    local okSignal, signal = pcall(getSignal, instance, propertyName)
    if not okSignal or signal == nil then
        return nil
    end

    return connectSignal(signal, handler)
end

local function getClassName(instance)
    if instance == nil then
        return "nil"
    end

    local okClass, className = pcall(function()
        return instance.ClassName
    end)
    if okClass and type(className) == "string" then
        return className
    end

    local okType, typeName = pcall(typeOf, instance)
    if okType and type(typeName) == "string" then
        return typeName
    end

    return type(instance)
end

local function isRemoteEvent(remote)
    if remote == nil then
        return false, "nil"
    end

    local okIsA, result = pcall(function()
        local method = remote.IsA
        if not isCallable(method) then
            return nil
        end
        return method(remote, "RemoteEvent")
    end)

    if okIsA and result == true then
        return true, getClassName(remote)
    end

    local className = getClassName(remote)
    if className == "RemoteEvent" then
        return true, className
    end

    return false, className
end

local function locateSuccessRemotes(remotes)
    local success = {}
    if not remotes or typeOf(remotes.FindFirstChild) ~= "function" then
        return success
    end

    local definitions = {
        { key = "ParrySuccess", name = "ParrySuccess" },
        { key = "ParrySuccessAll", name = "ParrySuccessAll" },
    }

    for _, definition in ipairs(definitions) do
        local okRemote, remote = pcall(remotes.FindFirstChild, remotes, definition.name)
        if okRemote and remote then
            local isEvent = isRemoteEvent(remote)
            if isEvent then
                success[definition.key] = { remote = remote, name = definition.name }
            end
        end
    end

    return success
end

local function createRemoteFireWrapper(remote, methodName)
    return function(...)
        local current = remote[methodName]
        if not isCallable(current) then
            error(
                string.format(
                    "AutoParry: parry remote missing %s",
                    methodName
                ),
                0
            )
        end

        return current(remote, ...)
    end
end

local function findRemoteFire(remote)
    local okServer, fireServer = pcall(function()
        return remote.FireServer
    end)
    if okServer and isCallable(fireServer) then
        return "FireServer", createRemoteFireWrapper(remote, "FireServer")
    end

    local okFire, fire = pcall(function()
        return remote.Fire
    end)
    if okFire and isCallable(fire) then
        return "Fire", createRemoteFireWrapper(remote, "Fire")
    end

    return nil, nil
end

local function clone(tbl)
    return Util.deepCopy(tbl)
end

local function deferTask(callback)
    local okDefer, deferImpl = pcall(function()
        return task.defer
    end)

    if okDefer and isCallable(deferImpl) then
        return deferImpl(callback)
    end

    return task.spawn(callback)
end

local initStatus = Util.Signal.new()
local initProgress = { stage = "waiting-player" }

local state
local parrySuccessSignal
local parryBroadcastSignal
local ParrySuccessConnection = nil
local ParrySuccessAllConnection = nil
local ParrySuccessRemote = nil
local ParrySuccessAllRemote = nil
local configureSuccessListeners
local disconnectSuccessListeners
local monitorParryRemote
local handleParryRemoteInvalidated
local disconnectParryRemoteMonitors
local scheduleParryRemoteRestart

local PARRY_REMOTE_CANDIDATES = { "ParryButtonPress", "ParryAttempt" }

local function disconnectSuccessListeners()
    safeDisconnect(ParrySuccessConnection)
    safeDisconnect(ParrySuccessAllConnection)
    ParrySuccessConnection = nil
    ParrySuccessAllConnection = nil
    ParrySuccessRemote = nil
    ParrySuccessAllRemote = nil
end

local function createArray(count)
    if table.create then
        return table.create(count)
    end

    return {}
end

local function updateInitProgress(stage, details)
    for key in pairs(initProgress) do
        initProgress[key] = nil
    end

    initProgress.stage = stage

    if details then
        for key, value in pairs(details) do
            initProgress[key] = value
        end
    end

    initStatus:fire(clone(initProgress))
end

local function resolveLocalPlayer(report)
    report("waiting-player", { elapsed = 0 })

    local player = Players.LocalPlayer
    if player then
        return player
    end

    local start = os.clock()

    while not player do
        local elapsed = os.clock() - start
        if elapsed >= 10 then
            report("timeout", {
                stage = "waiting-player",
                elapsed = elapsed,
                reason = "local-player",
            })
            break
        end

        report("waiting-player", { elapsed = elapsed })
        task.wait()
        player = Players.LocalPlayer
    end

    assert(player, "AutoParry: LocalPlayer unavailable")
    return player
end

local function resolveParryRemote(report)
    report("waiting-remotes", { target = "folder", elapsed = 0 })

    local remotes = Replicated:FindFirstChild("Remotes")
    if not remotes then
        local start = os.clock()
        while not remotes do
            local elapsed = os.clock() - start
            if elapsed >= 10 then
                report("timeout", {
                    stage = "waiting-remotes",
                    target = "folder",
                    elapsed = elapsed,
                    reason = "remotes-folder",
                })
                break
            end

            report("waiting-remotes", {
                target = "folder",
                elapsed = elapsed,
            })
            task.wait()
            remotes = Replicated:FindFirstChild("Remotes")
        end
    end

    assert(remotes, "AutoParry: ReplicatedStorage.Remotes missing")

    local candidateDefinitions = {
        { name = "ParryButtonPress", variant = "modern" },
        { name = "ParryAttempt", variant = "legacy" },
    }
    local candidateNames = clone(PARRY_REMOTE_CANDIDATES)

    report("waiting-remotes", { target = "remote", elapsed = 0, candidates = candidateNames })

    local remote
    local remoteInfo
    local baseFire

    local function inspectCandidate(candidate)
        local okFound, found = pcall(remotes.FindFirstChild, remotes, candidate.name)
        if not okFound or not found then
            return nil
        end

        local isEvent, className = isRemoteEvent(found)
        if not isEvent then
            return false, {
                reason = "parry-remote-unsupported",
                className = className,
                remoteName = found.Name,
                message = string.format(
                    "AutoParry: parry remote unsupported type (%s)",
                    className
                ),
            }
        end

        local methodName, fire = findRemoteFire(found)
        if not methodName or not fire then
            return false, {
                reason = "parry-remote-missing-method",
                className = className,
                remoteName = found.Name,
                message = "AutoParry: parry remote missing FireServer/Fire",
            }
        end

        local info = {
            method = methodName,
            kind = "RemoteEvent",
            className = className,
            remoteName = found.Name,
            variant = candidate.variant,
        }

        return true, found, fire, info
    end

    local function findCandidate()
        local errorDetails

        for _, candidate in ipairs(candidateDefinitions) do
            local status, found, fire, infoOrError = inspectCandidate(candidate)
            if status == nil then
                continue
            elseif status == true then
                remote = found
                baseFire = fire
                remoteInfo = infoOrError
                if remoteInfo then
                    remoteInfo.successRemotes = locateSuccessRemotes(remotes)
                end
                return true
            else
                errorDetails = infoOrError
            end
        end

        if errorDetails then
            report("error", {
                stage = "waiting-remotes",
                target = "remote",
                reason = errorDetails.reason or "parry-remote-unsupported",
                className = errorDetails.className,
                remoteName = errorDetails.remoteName,
                message = errorDetails.message,
                candidates = candidateNames,
            })

            error(errorDetails.message, 0)
        end

        return false
    end

    if not findCandidate() then
        local start = os.clock()
        while not findCandidate() do
            local elapsed = os.clock() - start
            if elapsed >= 10 then
                report("timeout", {
                    stage = "waiting-remotes",
                    target = "remote",
                    elapsed = elapsed,
                    reason = "parry-remote",
                    candidates = candidateNames,
                })
                break
            end

            report("waiting-remotes", {
                target = "remote",
                elapsed = elapsed,
                candidates = candidateNames,
            })
            task.wait()
        end
    end

    assert(remote and baseFire and remoteInfo, "AutoParry: parry remote missing (ParryButtonPress/ParryAttempt)")

    return remote, baseFire, remoteInfo
end

local function capturePlayerState(player)
    local state = {
        userId = player and player.UserId or 0,
    }

    local character = player and player.Character
    if character then
        state.character = character
        local primary = character.PrimaryPart
        if primary then
            local okPosition, position = pcall(function()
                return primary.Position
            end)

            if okPosition then
                state.position = position
            end

            local okVelocity, velocity = pcall(function()
                return primary.AssemblyLinearVelocity
            end)

            if okVelocity then
                state.velocity = velocity
            end

            local okCFrame, rootCFrame = pcall(function()
                return primary.CFrame
            end)

            if okCFrame then
                state.cframe = rootCFrame
            end
        end
    end

    return state
end

local function snapshotPlayers()
    local snapshot = {}
    local seen = {}

    local function append(player)
        if not player or seen[player] then
            return
        end

        seen[player] = true
        snapshot[player.Name or tostring(player)] = capturePlayerState(player)
    end

    if Players and typeOf(Players.GetPlayers) == "function" then
        local ok, roster = pcall(Players.GetPlayers, Players)
        if ok and type(roster) == "table" then
            for _, player in ipairs(roster) do
                append(player)
            end
        end
    end

    if Players and Players.LocalPlayer then
        append(Players.LocalPlayer)
    end

    return snapshot
end

local function computeBallCFrame(ball, fallbackPosition)
    if not ball then
        return CFrame.new(fallbackPosition or Vector3.new())
    end

    local okExisting, existing = pcall(function()
        return ball.CFrame
    end)

    if okExisting and typeOf(existing) == "CFrame" then
        return existing
    end

    local position
    local okPosition, value = pcall(function()
        return ball.Position
    end)

    if okPosition and typeOf(value) == "Vector3" then
        position = value
    else
        position = fallbackPosition or Vector3.new()
    end

    local okVelocity, velocity = pcall(function()
        return ball.AssemblyLinearVelocity
    end)

    if okVelocity and typeOf(velocity) == "Vector3" and velocity.Magnitude > 1e-3 then
        return CFrame.new(position, position + velocity.Unit)
    end

    return CFrame.new(position)
end

local legacyPayloadBuilder = nil
local randomGenerator = typeOf(Random) == "table" and Random.new() or nil

local function randomInteger(minimum, maximum)
    if randomGenerator then
        return randomGenerator:NextInteger(minimum, maximum)
    end

    return math.random(minimum, maximum)
end

local function buildLegacyPayload(context)
    local builder = legacyPayloadBuilder
    if builder then
        local payload = builder(context)
        assert(type(payload) == "table", "legacy payload builder must return an array of arguments")
        return payload
    end

    local payload = createArray(5)
    payload[1] = context.timestamp
    payload[2] = context.ballCFrame
    payload[3] = context.playersSnapshot
    payload[4] = randomInteger(100000, 999999999)
    payload[5] = randomInteger(100000, 999999999)
    payload.n = 5
    return payload
end

local function createLegacyContext(ball, analysis)
    local now = os.clock()
    local rootPosition = analysis and analysis.rootPosition or nil
    local ballPosition
    local okPosition, value = pcall(function()
        return ball and ball.Position
    end)
    if okPosition and typeOf(value) == "Vector3" then
        ballPosition = value
    end

    local okVelocity, velocity = pcall(function()
        return ball and ball.AssemblyLinearVelocity
    end)
    if not okVelocity or typeOf(velocity) ~= "Vector3" then
        velocity = Vector3.new()
    end

    local tti = analysis and analysis.tti or 0

    return {
        timestamp = now,
        ball = ball,
        ballPosition = ballPosition or Vector3.new(),
        ballVelocity = velocity,
        ballCFrame = computeBallCFrame(ball, rootPosition),
        rootPosition = rootPosition,
        predictedImpact = now + math.max(tti, 0),
        ping = analysis and analysis.ping or 0,
        tti = tti,
        localPlayer = LocalPlayer,
        playersSnapshot = snapshotPlayers(),
    }
end

local function configureParryRemoteInvoker(remoteInfo)
    if not ParryRemoteBaseFire then
        ParryRemoteFire = nil
        return
    end

    local variant = remoteInfo and remoteInfo.variant or ParryRemoteVariant
    if not variant and ParryRemote then
        variant = ParryRemote.Name == "ParryAttempt" and "legacy" or "modern"
    end

    ParryRemoteVariant = variant

    if variant == "legacy" then
        ParryRemoteFire = function(ball, analysis)
            local context = createLegacyContext(ball, analysis)
            local payload = buildLegacyPayload(context)
            local length = payload.n or #payload
            return ParryRemoteBaseFire(arrayUnpack(payload, 1, length))
        end
    else
        ParryRemoteFire = function()
            return ParryRemoteBaseFire()
        end
    end
end

local LocalPlayer = nil
local ParryRemote = nil
local ParryRemoteFire = nil
local ParryRemoteVariant = nil
local ParryRemoteBaseFire = nil
local ParryRemoteInfo = nil
local ParryRemoteParentChangedConnection = nil
local ParryRemoteAncestryConnection = nil
local ParryRemoteDestroyingConnection = nil
local ParryRemoteRestartPending = false

local initialization = {
    started = false,
    completed = false,
    error = nil,
    token = 0,
    destroyed = false,
}

local function beginInitialization()
    initialization.token += 1
    local token = initialization.token
    initialization.started = true
    initialization.completed = false
    initialization.error = nil
    initialization.destroyed = false
    ParryRemote = nil
    ParryRemoteFire = nil
    ParryRemoteBaseFire = nil
    ParryRemoteVariant = nil
    ParryRemoteInfo = nil
    disconnectSuccessListeners()
    disconnectParryRemoteMonitors()
    ParryRemoteRestartPending = false

    updateInitProgress("waiting-player", { elapsed = 0 })

    local initStart = os.clock()

    task.spawn(function()
        local function report(stage, details)
            if initialization.token ~= token then
                return
            end

            updateInitProgress(stage, details)
        end

        local ok, player, remoteOrError, fire, remoteInfo = pcall(function()
            local player = resolveLocalPlayer(report)
            if initialization.token ~= token then
                return nil, nil, nil, nil
            end

            local remote, parryFire, info = resolveParryRemote(report)
            return player, remote, parryFire, info
        end)

        if initialization.token ~= token then
            return
        end

        if ok then
            if not player or not remoteOrError or not fire then
                return
            end

            LocalPlayer = player
            ParryRemote = remoteOrError
            ParryRemoteBaseFire = fire
            ParryRemoteVariant = remoteInfo and remoteInfo.variant or nil
            configureParryRemoteInvoker(remoteInfo)
            monitorParryRemote(remoteOrError, remoteInfo)
            local successStatus = configureSuccessListeners and configureSuccessListeners(remoteInfo and remoteInfo.successRemotes or nil) or nil
            initialization.completed = true
            local readyDetails = { elapsed = os.clock() - initStart }

            if remoteInfo then
                if remoteInfo.kind then
                    readyDetails.remoteKind = remoteInfo.kind
                end

                if remoteInfo.method then
                    readyDetails.remoteMethod = remoteInfo.method
                end

                if remoteInfo.className then
                    readyDetails.remoteClass = remoteInfo.className
                end

                if remoteInfo.remoteName then
                    readyDetails.remoteName = remoteInfo.remoteName
                end

                if remoteInfo.variant then
                    readyDetails.remoteVariant = remoteInfo.variant
                end
            end

            if successStatus then
                readyDetails.successEvents = successStatus
            end

            if not readyDetails.remoteClass then
                local okClass, className = pcall(function()
                    return ParryRemote.ClassName
                end)

                if okClass then
                    readyDetails.remoteClass = className
                end
            end

            report("ready", readyDetails)
        else
            initialization.error = player
            local details = { message = player }

            if initProgress.stage == "error" then
                if initProgress.reason then
                    details.reason = initProgress.reason
                end

                if initProgress.target then
                    details.target = initProgress.target
                end

                if initProgress.className then
                    details.className = initProgress.className
                end

                if initProgress.elapsed then
                    details.elapsed = initProgress.elapsed
                end
            end

            report("error", details)
        end
    end)
end

local function ensureInitialization()
    if initialization.started then
        return
    end

    beginInitialization()
end

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
    lastSuccess = 0,
    lastBroadcast = 0,
}

local stateChanged = Util.Signal.new()
local parryEvent = Util.Signal.new()
parrySuccessSignal = Util.Signal.new()
parryBroadcastSignal = Util.Signal.new()
local logger = nil

local function waitForReady()
    ensureInitialization()

    if initialization.completed then
        return true
    end

    if initialization.error then
        error(initialization.error, 0)
    end

    while true do
        task.wait()

        if initialization.completed then
            return true
        end

        if initialization.error then
            error(initialization.error, 0)
        end
    end
end

local function log(...)
    if logger then
        logger(...)
    end
end

disconnectParryRemoteMonitors = function()
    safeDisconnect(ParryRemoteParentChangedConnection)
    safeDisconnect(ParryRemoteAncestryConnection)
    safeDisconnect(ParryRemoteDestroyingConnection)
    ParryRemoteParentChangedConnection = nil
    ParryRemoteAncestryConnection = nil
    ParryRemoteDestroyingConnection = nil
end

scheduleParryRemoteRestart = function(reason)
    if ParryRemoteRestartPending or initialization.destroyed then
        return
    end

    ParryRemoteRestartPending = true

    deferTask(function()
        ParryRemoteRestartPending = false
        if initialization.destroyed or ParryRemote then
            return
        end

        log("AutoParry: restarting initialization after", reason or "parry remote loss")
        beginInitialization()
    end)
end

handleParryRemoteInvalidated = function(reason)
    if not ParryRemote then
        return
    end

    log("AutoParry: parry remote invalidated", reason)

    disconnectParryRemoteMonitors()
    disconnectSuccessListeners()

    local info = ParryRemoteInfo
    ParryRemoteInfo = nil
    ParryRemote = nil
    ParryRemoteFire = nil
    ParryRemoteBaseFire = nil
    ParryRemoteVariant = nil
    initialization.completed = false

    local details = {
        reason = reason or "parry-remote-invalidated",
        candidates = clone(PARRY_REMOTE_CANDIDATES),
    }

    if info then
        if info.remoteName then
            details.remoteName = info.remoteName
        end
        if info.variant then
            details.remoteVariant = info.variant
        end
        if info.className then
            details.remoteClass = info.className
        end
    end

    updateInitProgress("restarting", details)
    scheduleParryRemoteRestart(reason)
end

monitorParryRemote = function(remote, info)
    disconnectParryRemoteMonitors()

    if not remote then
        return
    end

    ParryRemoteRestartPending = false

    local function parent()
        local okParent, parentInstance = pcall(function()
            return remote.Parent
        end)

        return okParent and parentInstance or nil
    end

    if parent() == nil then
        handleParryRemoteInvalidated("parry-remote-removed")
        return
    end

    ParryRemoteParentChangedConnection = connectPropertyChangedSignal(remote, "Parent", function()
        if parent() == nil then
            handleParryRemoteInvalidated("parry-remote-removed")
        end
    end)

    ParryRemoteAncestryConnection = connectInstanceEvent(remote, "AncestryChanged", function(_, parentInstance)
        if parentInstance == nil then
            handleParryRemoteInvalidated("parry-remote-ancestry")
        end
    end)

    ParryRemoteDestroyingConnection = connectInstanceEvent(remote, "Destroying", function()
        handleParryRemoteInvalidated("parry-remote-destroyed")
    end)

    if info then
        ParryRemoteInfo = {
            remoteName = info.remoteName,
            variant = info.variant,
            className = info.className,
        }
    else
        ParryRemoteInfo = {
            remoteName = remote.Name,
            variant = ParryRemoteVariant,
            className = getClassName(remote),
        }
    end
end

configureSuccessListeners = function(successRemotes)
    disconnectSuccessListeners()

    local status = {
        ParrySuccess = false,
        ParrySuccessAll = false,
    }

    if not successRemotes then
        return status
    end

    local localEntry = successRemotes.ParrySuccess
    if localEntry and localEntry.remote then
        ParrySuccessRemote = localEntry.remote
        local connection = connectClientEvent(ParrySuccessRemote, function(...)
            state.lastSuccess = os.clock()
            parrySuccessSignal:fire(...)
            log("AutoParry: observed ParrySuccess event")
        end)

        if connection then
            ParrySuccessConnection = connection
            status.ParrySuccess = true
            log("AutoParry: listening for ParrySuccess events")
        else
            ParrySuccessRemote = nil
        end
    end

    local broadcastEntry = successRemotes.ParrySuccessAll
    if broadcastEntry and broadcastEntry.remote then
        ParrySuccessAllRemote = broadcastEntry.remote
        local connection = connectClientEvent(ParrySuccessAllRemote, function(...)
            state.lastBroadcast = os.clock()
            parryBroadcastSignal:fire(...)
            log("AutoParry: observed ParrySuccessAll event")
        end)

        if connection then
            ParrySuccessAllConnection = connection
            status.ParrySuccessAll = true
            log("AutoParry: listening for ParrySuccessAll events")
        else
            ParrySuccessAllRemote = nil
        end
    end

    if not status.ParrySuccess then
        state.lastSuccess = 0
    end

    if not status.ParrySuccessAll then
        state.lastBroadcast = 0
    end

    return status
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

local function tryParry(ball, analysis)
    local now = os.clock()
    if now - state.lastParry < config.cooldown then
        return false
    end

    if not ParryRemoteFire then
        if initialization.completed then
            scheduleParryRemoteRestart("parry-remote-missing")
        end

        return false
    end

    state.lastParry = now
    ParryRemoteFire(ball, analysis)
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
        return {
            ball = ball,
            rootPosition = rootPos,
            ping = ping,
            tti = 0,
            immediate = true,
            distance = toPlayer.Magnitude,
            velocity = velocity,
        }
    end

    local toward = velocity:Dot(toPlayer.Unit)
    if toward <= 0 then
        return nil
    end

    local distanceToPlayer = distance(ball.Position, rootPos)
    if distanceToPlayer <= config.safeRadius then
        return {
            ball = ball,
            rootPosition = rootPos,
            ping = ping,
            tti = 0,
            immediate = true,
            distance = distanceToPlayer,
            velocity = velocity,
        }
    end

    local tti = distanceToPlayer / toward
    tti = tti - (ping + config.pingOffset)

    if tti < config.minTTI or tti > config.maxTTI then
        return nil
    end

    return {
        ball = ball,
        rootPosition = rootPos,
        ping = ping,
        tti = tti,
        immediate = false,
        distance = distanceToPlayer,
        velocity = velocity,
    }
end

local function step()
    local character = LocalPlayer and LocalPlayer.Character
    if not character or not character.PrimaryPart then
        return
    end

    if not initialization.completed or not ParryRemoteFire then
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
    local bestAnalysis
    local ping = currentPing()

    for _, ball in ipairs(folder:GetChildren()) do
        local analysis = evaluateBall(ball, rootPos, ping)
        if analysis then
            if analysis.tti == 0 then
                if tryParry(ball, analysis) then
                    return
                end
            elseif not bestAnalysis or analysis.tti < bestAnalysis.tti then
                bestAnalysis = analysis
            end
        end
    end

    if bestAnalysis then
        tryParry(bestAnalysis.ball, bestAnalysis)
    end
end

function AutoParry.enable()
    if state.enabled then
        return
    end

    waitForReady()

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
    callback(clone(initProgress))
    return connection
end

function AutoParry.getInitProgress()
    ensureInitialization()
    return clone(initProgress)
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

function AutoParry.setLogger(fn)
    if fn ~= nil then
        assert(typeof(fn) == "function", "AutoParry.setLogger expects a function or nil")
    end
    logger = fn
end

function AutoParry.setLegacyPayloadBuilder(builder)
    if builder ~= nil then
        assert(type(builder) == "function", "AutoParry.setLegacyPayloadBuilder expects a function or nil")
    end

    legacyPayloadBuilder = builder

    if ParryRemoteVariant == "legacy" and ParryRemoteBaseFire then
        configureParryRemoteInvoker({ variant = ParryRemoteVariant })
    end
end

function AutoParry.destroy()
    AutoParry.disable()
    disconnectSuccessListeners()
    disconnectParryRemoteMonitors()
    ParryRemote = nil
    ParryRemoteFire = nil
    ParryRemoteBaseFire = nil
    ParryRemoteVariant = nil
    ParryRemoteInfo = nil
    ParryRemoteRestartPending = false
    initialization.token += 1
    initialization.started = false
    initialization.completed = false
    initialization.error = nil
    initialization.destroyed = true
    stateChanged:destroy()
    parryEvent:destroy()
    initStatus:destroy()
    parrySuccessSignal:destroy()
    parryBroadcastSignal:destroy()

    stateChanged = Util.Signal.new()
    parryEvent = Util.Signal.new()
    initStatus = Util.Signal.new()
    parrySuccessSignal = Util.Signal.new()
    parryBroadcastSignal = Util.Signal.new()
    logger = nil
    state.lastParry = 0
    state.lastSuccess = 0
    state.lastBroadcast = 0
    AutoParry.resetConfig()

    LocalPlayer = nil
    ParryRemote = nil
    ParryRemoteFire = nil
    ParryRemoteBaseFire = nil
    ParryRemoteVariant = nil

    for key in pairs(initProgress) do
        initProgress[key] = nil
    end
    initProgress.stage = "waiting-player"

    initialization.started = false
    initialization.completed = false
    initialization.error = nil

    beginInitialization()
end

ensureInitialization()

return AutoParry
