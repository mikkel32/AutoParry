-- mikkel32/AutoParry : loader.lua  (Lua / Luau)
-- selene: allow(global_usage)
-- Remote bootstrapper that fetches repository modules, exposes a cached
-- global require, and hands execution to the entrypoint module.

local RAW_HOST = "https://raw.githubusercontent.com"
local DEFAULT_REPO = "mikkel32/AutoParry"
local DEFAULT_BRANCH = "main"
local DEFAULT_ENTRY = "src/main.lua"

local globalSourceCache = {}

local function newSignal()
    local listeners = {}

    local signal = {}

    function signal:Connect(callback)
        assert(type(callback) == "function", "Signal connection requires a callback")

        local connection = {
            Connected = true,
        }

        listeners[connection] = callback

        function connection:Disconnect()
            if not self.Connected then
                return
            end

            self.Connected = false
            listeners[self] = nil
        end

        return connection
    end

    function signal:Fire(...)
        local snapshot = {}
        local count = 0

        for connection, callback in pairs(listeners) do
            if connection.Connected then
                count = count + 1
                snapshot[count] = callback
            end
        end

        for i = 1, count do
            local callback = snapshot[i]
            callback(...)
        end
    end

    return signal
end

local function copyTable(source)
    local target = {}
    for key, value in pairs(source) do
        target[key] = value
    end
    return target
end

local function emit(signal, basePayload, overrides)
    if not signal then
        return
    end

    local payload = copyTable(basePayload)

    if overrides then
        for key, value in pairs(overrides) do
            payload[key] = value
        end
    end

    signal:Fire(payload)
end

local function updateAllComplete(context)
    if context.progress.started == context.progress.finished + context.progress.failed then
        context.signals.onAllComplete:Fire(context.progress)
    end
end

local function buildUrl(repo, branch, path)
    return ("%s/%s/%s/%s"):format(RAW_HOST, repo, branch, path)
end

local function fetch(repo, branch, path, refresh)
    local url = buildUrl(repo, branch, path)
    if not refresh and globalSourceCache[url] then
        return globalSourceCache[url], true
    end

    local ok, res = pcall(game.HttpGet, game, url, true)
    if not ok then
        error(("AutoParry loader: failed to fetch %s\nReason: %s"):format(url, tostring(res)), 0)
    end

    if not refresh then
        globalSourceCache[url] = res
    end

    return res, false
end

local function createContext(options)
    local context = {
        repo = options.repo or DEFAULT_REPO,
        branch = options.branch or DEFAULT_BRANCH,
        entrypoint = options.entrypoint or DEFAULT_ENTRY,
        refresh = options.refresh == true,
        cache = {},
    }

    context.progress = {
        started = 0,
        finished = 0,
        failed = 0,
    }

    context.signals = {
        onFetchStarted = newSignal(),
        onFetchCompleted = newSignal(),
        onFetchFailed = newSignal(),
        onAllComplete = newSignal(),
    }

    local function remoteRequire(path)
        local cacheKey = path
        local url = buildUrl(context.repo, context.branch, path)
        local baseEvent = {
            path = path,
            url = url,
            refresh = context.refresh,
        }

        local function start(overrides)
            context.progress.started = context.progress.started + 1
            emit(context.signals.onFetchStarted, baseEvent, overrides)
        end

        local function succeed(overrides)
            context.progress.finished = context.progress.finished + 1
            emit(context.signals.onFetchCompleted, baseEvent, overrides)
            updateAllComplete(context)
        end

        local function fail(message, overrides)
            context.progress.failed = context.progress.failed + 1
            emit(context.signals.onFetchFailed, baseEvent, overrides)
            updateAllComplete(context)
            error(message, 0)
        end

        if not context.refresh and context.cache[cacheKey] ~= nil then
            local cachedResult = context.cache[cacheKey]
            start({
                status = "started",
                fromCache = true,
                cache = "context",
            })
            succeed({
                status = "completed",
                fromCache = true,
                cache = "context",
                result = cachedResult,
            })
            return cachedResult
        end

        local willUseGlobalCache = not context.refresh and globalSourceCache[url] ~= nil

        start({
            status = "started",
            fromCache = willUseGlobalCache,
            cache = willUseGlobalCache and "global" or nil,
        })

        local fetchOk, fetchResult, fetchFromCache = pcall(fetch, context.repo, context.branch, path, context.refresh)
        if not fetchOk then
            local message = fetchResult
            fail(message, {
                status = "failed",
                fromCache = willUseGlobalCache,
                cache = willUseGlobalCache and "global" or nil,
                error = message,
            })
        end

        local source = fetchResult
        local chunk, err = loadstring(source, "=" .. path)
        if not chunk then
            local message = ("AutoParry loader: compile error in %s\n%s"):format(path, tostring(err))
            fail(message, {
                status = "failed",
                fromCache = fetchFromCache or false,
                cache = fetchFromCache and "global" or nil,
                error = message,
            })
        end

        local previousRequire = rawget(_G, "ARequire")
        rawset(_G, "ARequire", remoteRequire)

        local ok, result = pcall(chunk)

        rawset(_G, "ARequire", previousRequire)

        if not ok then
            local message = ("AutoParry loader: runtime error in %s\n%s"):format(path, tostring(result))
            fail(message, {
                status = "failed",
                fromCache = fetchFromCache or false,
                cache = fetchFromCache and "global" or nil,
                error = message,
            })
        end

        context.cache[cacheKey] = result

        succeed({
            status = "completed",
            fromCache = fetchFromCache or false,
            cache = fetchFromCache and "global" or nil,
            result = result,
        })

        return result
    end

    context.require = remoteRequire
    return context
end

local function bootstrap(options)
    options = options or {}
    local context = createContext(options)

    local previousRequire = rawget(_G, "ARequire")
    local previousLoader = rawget(_G, "AutoParryLoader")

    local function run()
        rawset(_G, "ARequire", context.require)
        rawset(_G, "AutoParryLoader", {
            require = context.require,
            context = context,
            signals = context.signals,
            progress = context.progress,
        })

        local mainModule = context.require(context.entrypoint)
        if typeof(mainModule) == "function" then
            return mainModule(options, context)
        end

        return mainModule
    end

    local ok, result = pcall(run)
    if not ok then
        if previousRequire == nil then
            rawset(_G, "ARequire", nil)
        else
            rawset(_G, "ARequire", previousRequire)
        end

        if previousLoader == nil then
            rawset(_G, "AutoParryLoader", nil)
        else
            rawset(_G, "AutoParryLoader", previousLoader)
        end

        error(result, 0)
    end

    return result
end

return bootstrap(...)
