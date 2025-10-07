-- mikkel32/AutoParry : src/core/verification.lua
-- Sequences verification steps for AutoParry startup, emitting granular
-- status updates for observers and returning the discovered resources.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")


local luauTypeof = rawget(_G, "typeof")

local Verification = {}

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

local function cloneTable(tbl)
    local result = {}
    for key, value in pairs(tbl) do
        result[key] = value
    end
    return result
end

local function classifyParryRemote(remote)
    if remote == nil then
        return false, "nil", nil
    end

    local cachedClassName = nil

    local function getClassName()
        if cachedClassName ~= nil then
            return cachedClassName
        end

        local okClass, className = pcall(function()
            return remote.ClassName
        end)

        if okClass and type(className) == "string" then
            cachedClassName = className
        end

        return cachedClassName
    end

    local function isInstanceOf(target)
        local okIsA, result = pcall(function()
            local method = remote.IsA
            if not isCallable(method) then
                return nil
            end

            return method(remote, target)
        end)

        return okIsA and result == true
    end

    if isInstanceOf("RemoteEvent") then
        return true, getClassName() or "RemoteEvent", "RemoteEvent"
    end

    if isInstanceOf("BindableEvent") then
        return true, getClassName() or "BindableEvent", "BindableEvent"
    end

    local className = getClassName()
    if className == "RemoteEvent" or className == "BindableEvent" then
        return true, className, className
    end

    return false, className or typeOf(remote), nil
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
    local okFire, fire = pcall(function()
        return remote.Fire
    end)
    if okFire and isCallable(fire) then
        return "Fire", createRemoteFireWrapper(remote, "Fire")
    end

    local okServer, fireServer = pcall(function()
        return remote.FireServer
    end)
    if okServer and isCallable(fireServer) then
        return "FireServer", createRemoteFireWrapper(remote, "FireServer")
    end

    return nil, nil
end

local function locateSuccessRemotes(remotes)
    local definitions = {
        { key = "ParrySuccess", name = "ParrySuccess" },
        { key = "ParrySuccessAll", name = "ParrySuccessAll" },
    }

    local success = {}

    if not remotes or typeOf(remotes.FindFirstChild) ~= "function" then
        return success
    end

    for _, definition in ipairs(definitions) do
        local okRemote, remote = pcall(remotes.FindFirstChild, remotes, definition.name)
        if okRemote and remote then
            local isSupported, className = classifyParryRemote(remote)
            if isSupported then
                success[definition.key] = {
                    remote = remote,
                    name = definition.name,
                    className = className,
                }
            else
                success[definition.key] = {
                    remote = nil,
                    name = definition.name,
                    className = className,
                    unsupported = true,
                }
            end
        else
            success[definition.key] = {
                remote = nil,
                name = definition.name,
            }
        end
    end

    return success
end

local function summarizeSuccessRemotes(successRemotes)
    local summary = {}

    for key, entry in pairs(successRemotes or {}) do
        summary[key] = {
            name = entry.name,
            available = entry.remote ~= nil and not entry.unsupported,
            unsupported = entry.unsupported == true,
            className = entry.className,
        }
    end

    return summary
end

local function waitInterval(interval)
    if interval and interval > 0 then
        task.wait(interval)
    else
        task.wait()
    end
end

local function emit(report, status)
    if report then
        report(cloneTable(status))
    end
end

local function ensurePlayer(report, timeout, retryInterval)
    emit(report, {
        stage = "waiting-player",
        step = "local-player",
        status = "pending",
        elapsed = 0,
    })

    local player = Players.LocalPlayer
    if player then
        emit(report, {
            stage = "waiting-player",
            step = "local-player",
            status = "ok",
            elapsed = 0,
        })
        return player
    end

    local start = os.clock()

    while true do
        waitInterval(retryInterval)
        player = Players.LocalPlayer

        if player then
            emit(report, {
                stage = "waiting-player",
                step = "local-player",
                status = "ok",
                elapsed = os.clock() - start,
            })
            return player
        end

        local elapsed = os.clock() - start
        emit(report, {
            stage = "waiting-player",
            step = "local-player",
            status = "waiting",
            elapsed = elapsed,
        })

        if timeout and elapsed >= timeout then
            emit(report, {
                stage = "timeout",
                step = "local-player",
                status = "failed",
                reason = "local-player",
                elapsed = elapsed,
            })

            error("AutoParry: LocalPlayer unavailable", 0)
        end
    end
end

local function ensureRemotesFolder(report, timeout, retryInterval)
    emit(report, {
        stage = "waiting-remotes",
        target = "folder",
        status = "pending",
        elapsed = 0,
    })

    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    if remotes then
        emit(report, {
            stage = "waiting-remotes",
            target = "folder",
            status = "ok",
            elapsed = 0,
        })
        return remotes
    end

    local start = os.clock()

    while true do
        waitInterval(retryInterval)
        remotes = ReplicatedStorage:FindFirstChild("Remotes")

        if remotes then
            emit(report, {
                stage = "waiting-remotes",
                target = "folder",
                status = "ok",
                elapsed = os.clock() - start,
            })
            return remotes
        end

        local elapsed = os.clock() - start
        emit(report, {
            stage = "waiting-remotes",
            target = "folder",
            status = "waiting",
            elapsed = elapsed,
        })

        if timeout and elapsed >= timeout then
            emit(report, {
                stage = "timeout",
                target = "folder",
                status = "failed",
                reason = "remotes-folder",
                elapsed = elapsed,
            })

            error("AutoParry: ReplicatedStorage.Remotes missing", 0)
        end
    end
end

local function ensureParryRemote(report, remotes, timeout, retryInterval, candidates)
    local candidateDefinitions = {}
    local candidateNames = {}

    for _, entry in ipairs(candidates) do
        table.insert(candidateDefinitions, entry)
        table.insert(candidateNames, entry.name)
    end

    emit(report, {
        stage = "waiting-remotes",
        target = "remote",
        status = "pending",
        elapsed = 0,
        candidates = candidateNames,
    })

    local start = os.clock()

    local function inspectCandidate(candidate)
        local okFound, found = pcall(remotes.FindFirstChild, remotes, candidate.name)
        if not okFound or not found then
            return nil
        end

        local isSupported, className, kind = classifyParryRemote(found)
        if not isSupported then
            emit(report, {
                stage = "error",
                target = "remote",
                status = "failed",
                reason = "parry-remote-unsupported",
                className = className,
                remoteName = found.Name,
                candidates = candidateNames,
                message = string.format(
                    "AutoParry: parry remote unsupported type (%s)",
                    className
                ),
            })

            error(
                string.format(
                    "AutoParry: parry remote unsupported type (%s)",
                    className
                ),
                0
            )
        end

        local methodName, fire = findRemoteFire(found)
        if not methodName or not fire then
            emit(report, {
                stage = "error",
                target = "remote",
                status = "failed",
                reason = "parry-remote-missing-method",
                className = className,
                remoteName = found.Name,
                candidates = candidateNames,
                message = "AutoParry: parry remote missing Fire/FireServer",
            })

            error("AutoParry: parry remote missing Fire/FireServer", 0)
        end

        local info = {
            method = methodName,
            kind = kind or className,
            className = className,
            remoteName = found.Name,
            variant = candidate.variant,
        }

        return true, found, fire, info
    end

    while true do
        for _, candidate in ipairs(candidateDefinitions) do
            local status, remote, fire, info = inspectCandidate(candidate)
            if status then
                emit(report, {
                    stage = "waiting-remotes",
                    target = "remote",
                    status = "ok",
                    elapsed = os.clock() - start,
                    remoteName = info.remoteName,
                    remoteVariant = info.variant,
                    remoteMethod = info.method,
                    remoteClass = info.className,
                    candidates = candidateNames,
                })

                return remote, fire, info
            end
        end

        local elapsed = os.clock() - start
        emit(report, {
            stage = "waiting-remotes",
            target = "remote",
            status = "waiting",
            elapsed = elapsed,
            candidates = candidateNames,
        })

        if timeout and elapsed >= timeout then
            emit(report, {
                stage = "timeout",
                target = "remote",
                status = "failed",
                reason = "parry-remote",
                elapsed = elapsed,
                candidates = candidateNames,
            })

            error("AutoParry: parry remote missing (ParryButtonPress/ParryAttempt)", 0)
        end

        waitInterval(retryInterval)
    end
end

local function verifyBallsFolder(report, folderName, timeout, retryInterval)
    if not folderName or folderName == "" then
        return {
            verified = false,
            reason = "disabled",
        }, nil
    end

    emit(report, {
        stage = "verifying-balls",
        status = "pending",
        folderName = folderName,
        elapsed = 0,
    })

    local folder = Workspace:FindFirstChild(folderName)
    if folder then
        emit(report, {
            stage = "verifying-balls",
            status = "ok",
            folderName = folderName,
            elapsed = 0,
        })

        return {
            verified = true,
            elapsed = 0,
        }, folder
    end

    local start = os.clock()
    local limit = timeout and timeout > 0 and timeout or nil

    if limit == nil then
        emit(report, {
            stage = "verifying-balls",
            status = "warning",
            folderName = folderName,
            reason = "timeout",
            elapsed = 0,
        })

        return {
            verified = false,
            reason = "timeout",
            elapsed = 0,
        }, nil
    end

    while true do
        if limit then
            if os.clock() - start >= limit then
                break
            end
        end

        waitInterval(retryInterval)
        folder = Workspace:FindFirstChild(folderName)

        if folder then
            local elapsed = os.clock() - start
            emit(report, {
                stage = "verifying-balls",
                status = "ok",
                folderName = folderName,
                elapsed = elapsed,
            })

            return {
                verified = true,
                elapsed = elapsed,
            }, folder
        end

        local elapsed = os.clock() - start
        emit(report, {
            stage = "verifying-balls",
            status = "waiting",
            folderName = folderName,
            elapsed = elapsed,
        })
    end

    local elapsed = os.clock() - start
    emit(report, {
        stage = "verifying-balls",
        status = "warning",
        folderName = folderName,
        reason = "timeout",
        elapsed = elapsed,
    })

    return {
        verified = false,
        reason = "timeout",
        elapsed = elapsed,
    }, nil
end

function Verification.run(options)
    options = options or {}
    local config = options.config or {}
    local report = options.report
    local retryInterval = options.retryInterval or config.verificationRetryInterval or 0

    local candidateDefinitions = options.candidates or {
        { name = "ParryButtonPress", variant = "modern" },
        { name = "ParryAttempt", variant = "legacy" },
    }

    local playerTimeout = config.playerTimeout or options.playerTimeout or 10
    local remotesTimeout = config.remotesTimeout or options.remotesTimeout or 10
    local parryRemoteTimeout = config.parryRemoteTimeout or options.parryRemoteTimeout or 10
    local ballsFolderTimeout = config.ballsFolderTimeout or options.ballsFolderTimeout or 5

    local player = ensurePlayer(report, playerTimeout, retryInterval)
    local remotes = ensureRemotesFolder(report, remotesTimeout, retryInterval)
    local remote, baseFire, remoteInfo = ensureParryRemote(report, remotes, parryRemoteTimeout, retryInterval, candidateDefinitions)

    local successRemotes = locateSuccessRemotes(remotes)

    emit(report, {
        stage = "verifying-success-remotes",
        status = "observed",
        remotes = summarizeSuccessRemotes(successRemotes),
    })

    remoteInfo = remoteInfo or {}
    remoteInfo.successRemotes = successRemotes

    local ballsStatus, ballsFolder = verifyBallsFolder(report, config.ballsFolderName or "Balls", ballsFolderTimeout, retryInterval)

    return {
        player = player,
        remotesFolder = remotes,
        parryRemote = remote,
        parryRemoteBaseFire = baseFire,
        parryRemoteInfo = remoteInfo,
        successRemotes = successRemotes,
        ballsFolder = ballsFolder,
        ballsStatus = ballsStatus,
    }
end

return Verification
