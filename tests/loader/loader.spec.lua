-- selene: allow(global_usage)
local TestHarness = script.Parent.Parent
local SourceMap = require(TestHarness:WaitForChild("AutoParrySourceMap"))

local RAW_HOST = "https://raw.githubusercontent.com"

local function buildUrl(repo, branch, path)
    return string.format("%s/%s/%s/%s", RAW_HOST, repo, branch, path)
end

local function countRequests(requests)
    local counts = {}
    for _, url in ipairs(requests) do
        counts[url] = (counts[url] or 0) + 1
    end
    return counts
end

local function loadLoaderChunk()
    local loaderSource = SourceMap["loader.lua"]
    return assert(loadstring(loaderSource, "=loader.lua"))
end

local function runLoaderScenario(config, callback)
    config = config or {}

    local repo = config.repo or "SpecOrg/Loader"
    local branch = config.branch or "spec"
    local entrypoint = config.entrypoint or "entry.lua"
    local sources = config.sources or {}
    local refresh = config.refresh
    local options = {
        repo = repo,
        branch = branch,
        entrypoint = entrypoint,
        refresh = refresh,
    }

    if config.options then
        for key, value in pairs(config.options) do
            options[key] = value
        end
    end

    assert(sources[entrypoint], "missing entrypoint fixture")

    local fixtures = {}
    for path, source in pairs(sources) do
        fixtures[buildUrl(repo, branch, path)] = source
    end

    local requested = {}
    local originalHttpGet = game.HttpGet

    local function httpGet(_, url)
        table.insert(requested, url)
        local source = fixtures[url]
        if source == nil then
            error(string.format("No fixture for %s", url), 0)
        end
        return source
    end

    game.HttpGet = httpGet

    local previousARequire = rawget(_G, "ARequire")
    local previousLoader = rawget(_G, "AutoParryLoader")

    local loaderChunk = loadLoaderChunk()
    local ok, result = pcall(loaderChunk, options)

    local context = {
        ok = ok,
        result = result,
        requests = requested,
        fixtures = fixtures,
        repo = repo,
        branch = branch,
        entrypoint = entrypoint,
        options = options,
        previousARequire = previousARequire,
        previousLoader = previousLoader,
    }

    local success, err = pcall(callback, context)

    game.HttpGet = originalHttpGet
    rawset(_G, "ARequire", previousARequire)
    rawset(_G, "AutoParryLoader", previousLoader)

    if not success then
        error(err, 0)
    end
end

return function(t)
    t.test("reuses cached modules when refresh is false", function(expect)
        rawset(_G, "__loaderSpecExecutions", 0)

        local modulePath = "modules/feature.lua"
        local repo = "SpecOrg/Loader"
        local branch = "cache"

        runLoaderScenario({
            repo = repo,
            branch = branch,
            entrypoint = "entry.lua",
            sources = {
                ["entry.lua"] = ([[
                    return function()
                        local first = ARequire("%s")
                        local second = ARequire("%s")
                        return {
                            first = first,
                            second = second,
                        }
                    end
                ]]):format(modulePath, modulePath),
                [modulePath] = [[
                    local executions = (rawget(_G, "__loaderSpecExecutions") or 0) + 1
                    rawset(_G, "__loaderSpecExecutions", executions)
                    local result = { execution = executions }
                    rawset(_G, "__loaderSpecLastResult", result)
                    return result
                ]],
            },
        }, function(context)
            expect(context.ok):toEqual(true)
            local result = context.result
            expect(type(result) == "table"):toBeTruthy()
            expect(result.first):toEqual(result.second)

            local loaderState = rawget(_G, "AutoParryLoader")
            expect(type(loaderState) == "table"):toBeTruthy()

            local firstExecutionCount = rawget(_G, "__loaderSpecExecutions")
            expect(firstExecutionCount):toEqual(1)

            local moduleUrl = buildUrl(context.repo, context.branch, modulePath)

            local third = loaderState.require(modulePath)
            expect(third):toEqual(result.first)
            expect(rawget(_G, "__loaderSpecExecutions")):toEqual(1)

            loaderState.context.cache[modulePath] = nil
            local fourth = loaderState.require(modulePath)
            expect(fourth ~= result.first):toBeTruthy()
            expect(rawget(_G, "__loaderSpecExecutions")):toEqual(2)

            local counts = countRequests(context.requests)
            expect(counts[moduleUrl]):toEqual(1)
            expect(counts[buildUrl(context.repo, context.branch, "entry.lua")]):toEqual(1)

            rawset(_G, "__loaderSpecExecutions", nil)
            rawset(_G, "__loaderSpecLastResult", nil)
        end)
    end)

    t.test("emits loader signals for network and cached modules", function(expect)
        rawset(_G, "__loaderSignalCount", 0)

        local modulePath = "modules/signals.lua"

        runLoaderScenario({
            repo = "SpecOrg/Loader",
            branch = "signals",
            entrypoint = "entry.lua",
            sources = {
                ["entry.lua"] = "return {}",
                [modulePath] = [[
                    local executions = (rawget(_G, "__loaderSignalCount") or 0) + 1
                    rawset(_G, "__loaderSignalCount", executions)
                    return { executions = executions }
                ]],
            },
        }, function(context)
            expect(context.ok):toEqual(true)

            local loaderState = rawget(_G, "AutoParryLoader")
            expect(type(loaderState) == "table"):toBeTruthy()

            local signals = loaderState.signals
            local progress = loaderState.progress

            expect(type(signals) == "table"):toBeTruthy()
            expect(type(progress) == "table"):toBeTruthy()

            local startedEvents = {}
            local completedEvents = {}
            local failedEvents = {}
            local allCompleteEvents = {}

            local connections = {
                signals.onFetchStarted:Connect(function(payload)
                    table.insert(startedEvents, payload)
                end),
                signals.onFetchCompleted:Connect(function(payload)
                    table.insert(completedEvents, payload)
                end),
                signals.onFetchFailed:Connect(function(payload)
                    table.insert(failedEvents, payload)
                end),
                signals.onAllComplete:Connect(function(payload)
                    table.insert(allCompleteEvents, payload)
                end),
            }

            local function snapshot()
                return {
                    started = progress.started,
                    finished = progress.finished,
                    failed = progress.failed,
                }
            end

            local baseline = snapshot()

            local first = loaderState.require(modulePath)
            expect(first.executions):toEqual(1)

            expect(#startedEvents):toEqual(1)
            expect(#completedEvents):toEqual(1)
            expect(#failedEvents):toEqual(0)
            expect(#allCompleteEvents):toEqual(1)

            expect(startedEvents[1].path):toEqual(modulePath)
            expect(startedEvents[1].fromCache):toEqual(false)
            expect(startedEvents[1].cache):toEqual(nil)

            expect(completedEvents[1].result):toEqual(first)
            expect(completedEvents[1].fromCache):toEqual(false)
            expect(allCompleteEvents[1]):toEqual(progress)

            expect(progress.started):toEqual(baseline.started + 1)
            expect(progress.finished):toEqual(baseline.finished + 1)
            expect(progress.failed):toEqual(baseline.failed)

            startedEvents = {}
            completedEvents = {}
            failedEvents = {}
            allCompleteEvents = {}

            baseline = snapshot()

            local second = loaderState.require(modulePath)
            expect(second):toEqual(first)

            expect(#startedEvents):toEqual(1)
            expect(#completedEvents):toEqual(1)
            expect(#failedEvents):toEqual(0)
            expect(#allCompleteEvents):toEqual(1)

            expect(startedEvents[1].fromCache):toEqual(true)
            expect(startedEvents[1].cache):toEqual("context")
            expect(completedEvents[1].result):toEqual(first)
            expect(completedEvents[1].cache):toEqual("context")

            expect(progress.started):toEqual(baseline.started + 1)
            expect(progress.finished):toEqual(baseline.finished + 1)
            expect(progress.failed):toEqual(baseline.failed)

            startedEvents = {}
            completedEvents = {}
            failedEvents = {}
            allCompleteEvents = {}

            baseline = snapshot()

            loaderState.context.cache[modulePath] = nil

            local third = loaderState.require(modulePath)
            expect(third.executions):toEqual(2)

            expect(#startedEvents):toEqual(1)
            expect(#completedEvents):toEqual(1)
            expect(#failedEvents):toEqual(0)
            expect(#allCompleteEvents):toEqual(1)

            expect(startedEvents[1].cache):toEqual("global")
            expect(startedEvents[1].fromCache):toEqual(true)
            expect(completedEvents[1].cache):toEqual("global")
            expect(completedEvents[1].result):toEqual(third)

            expect(progress.started):toEqual(baseline.started + 1)
            expect(progress.finished):toEqual(baseline.finished + 1)
            expect(progress.failed):toEqual(baseline.failed)

            for _, connection in ipairs(connections) do
                connection:Disconnect()
            end

            rawset(_G, "__loaderSignalCount", nil)
        end)
    end)

    t.test("refresh=true bypasses global and context caches", function(expect)
        rawset(_G, "__loaderSpecExecutions", 0)

        local modulePath = "modules/feature.lua"

        runLoaderScenario({
            entrypoint = "entry.lua",
            refresh = true,
            sources = {
                ["entry.lua"] = "return function() return \"ok\" end",
                [modulePath] = [[
                    local executions = (rawget(_G, "__loaderSpecExecutions") or 0) + 1
                    rawset(_G, "__loaderSpecExecutions", executions)
                    return { execution = executions }
                ]],
            },
        }, function(context)
            expect(context.ok):toEqual(true)
            expect(context.result):toEqual("ok")

            local loaderState = rawget(_G, "AutoParryLoader")
            expect(type(loaderState) == "table"):toBeTruthy()

            local first = loaderState.require(modulePath)
            expect(first.execution):toEqual(1)

            loaderState.context.cache[modulePath] = first
            local second = loaderState.require(modulePath)
            expect(second.execution):toEqual(2)

            local counts = countRequests(context.requests)
            local moduleUrl = buildUrl(context.repo, context.branch, modulePath)
            expect(counts[moduleUrl]):toEqual(2)

            rawset(_G, "__loaderSpecExecutions", nil)
        end)
    end)

    t.test("restores globals after compile errors", function(expect)
        local sentinelRequire = function() end
        local sentinelLoader = { name = "sentinel" }
        rawset(_G, "ARequire", sentinelRequire)
        rawset(_G, "AutoParryLoader", sentinelLoader)

        local modulePath = "modules/broken.lua"

        runLoaderScenario({
            entrypoint = "entry.lua",
            sources = {
                ["entry.lua"] = ([[
                    return function()
                        return ARequire("%s")
                    end
                ]]):format(modulePath),
                [modulePath] = "return function("
            },
        }, function(context)
            expect(context.ok):toEqual(false)
            expect(string.find(context.result, "compile error in " .. modulePath, 1, true) ~= nil):toBeTruthy()
            expect(rawget(_G, "ARequire")):toEqual(sentinelRequire)
            expect(rawget(_G, "AutoParryLoader")):toEqual(sentinelLoader)
        end)
    end)

    t.test("restores globals after runtime errors", function(expect)
        local sentinelRequire = "previous"
        local sentinelLoader = { key = "value" }
        rawset(_G, "ARequire", sentinelRequire)
        rawset(_G, "AutoParryLoader", sentinelLoader)

        local modulePath = "modules/runtime.lua"

        runLoaderScenario({
            entrypoint = "entry.lua",
            sources = {
                ["entry.lua"] = ([[
                    return function()
                        return ARequire("%s")
                    end
                ]]):format(modulePath),
                [modulePath] = "error('runtime failure')",
            },
        }, function(context)
            expect(context.ok):toEqual(false)
            expect(string.find(context.result, "runtime error in " .. modulePath, 1, true) ~= nil):toBeTruthy()
            expect(rawget(_G, "ARequire")):toEqual(sentinelRequire)
            expect(rawget(_G, "AutoParryLoader")):toEqual(sentinelLoader)
        end)
    end)

    t.test("context requires remain isolated when interleaved", function(expect)
        rawset(_G, "__loaderSpecActiveContext", nil)
        rawset(_G, "__loaderSpecConcurrentExecutions", {})

        local repo = "SpecOrg/Loader"
        local branch = "isolation"
        local entrypoint = "entry.lua"
        local modulePath = "modules/isolation.lua"

        local fixtures = {}
        fixtures[buildUrl(repo, branch, entrypoint)] = [[
            return function(options, context)
                context.contextId = options.contextId
                return {
                    contextId = options.contextId,
                }
            end
        ]]
        fixtures[buildUrl(repo, branch, modulePath)] = [[
            local executions = rawget(_G, "__loaderSpecConcurrentExecutions")
            local active = rawget(_G, "__loaderSpecActiveContext")
            table.insert(executions, active)
            return {
                activeContext = active,
                executions = #executions,
            }
        ]]

        local requested = {}
        local originalHttpGet = game.HttpGet
        local function httpGet(_, url)
            table.insert(requested, url)
            local source = fixtures[url]
            if not source then
                error(string.format("Unexpected request %s", url), 0)
            end
            return source
        end

        game.HttpGet = httpGet

        local previousARequire = rawget(_G, "ARequire")
        local previousLoader = rawget(_G, "AutoParryLoader")

        local loaderChunk = loadLoaderChunk()

        local contexts = {}
        for _, contextId in ipairs({ 1, 2 }) do
            local ok, result = pcall(loaderChunk, {
                repo = repo,
                branch = branch,
                entrypoint = entrypoint,
                contextId = contextId,
            })

            expect(ok):toEqual(true)
            expect(result.contextId):toEqual(contextId)

            local loaderState = rawget(_G, "AutoParryLoader")
            contexts[contextId] = {
                require = loaderState.require,
            }

            rawset(_G, "ARequire", previousARequire)
            rawset(_G, "AutoParryLoader", previousLoader)
        end

        local outputs = {}

        _G.__loaderSpecActiveContext = 1
        outputs[1] = contexts[1].require(modulePath)
        expect(outputs[1].activeContext):toEqual(1)
        expect(outputs[1].executions):toEqual(1)

        _G.__loaderSpecActiveContext = 2
        outputs[2] = contexts[2].require(modulePath)
        expect(outputs[2].activeContext):toEqual(2)
        expect(outputs[2].executions):toEqual(2)

        _G.__loaderSpecActiveContext = 1
        local again1 = contexts[1].require(modulePath)
        expect(again1):toEqual(outputs[1])
        expect(#_G.__loaderSpecConcurrentExecutions):toEqual(2)

        _G.__loaderSpecActiveContext = 2
        local again2 = contexts[2].require(modulePath)
        expect(again2):toEqual(outputs[2])
        expect(#_G.__loaderSpecConcurrentExecutions):toEqual(2)

        local counts = countRequests(requested)
        local moduleUrl = buildUrl(repo, branch, modulePath)
        expect(counts[moduleUrl]):toEqual(2)
        expect(counts[buildUrl(repo, branch, entrypoint)]):toEqual(2)

        rawset(_G, "__loaderSpecActiveContext", nil)
        rawset(_G, "__loaderSpecConcurrentExecutions", nil)

        game.HttpGet = originalHttpGet
        rawset(_G, "ARequire", previousARequire)
        rawset(_G, "AutoParryLoader", previousLoader)
    end)
end
