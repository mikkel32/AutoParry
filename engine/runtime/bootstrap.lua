-- selene: allow(global_usage)
-- selene: allow(incorrect_standard_library_use)

local Bootstrap = {}

local function createVirtualRequire(sourceMap)
    local cache = {}

    local function virtualRequire(path)
        local source = sourceMap[path]
        assert(source, "Missing source map entry for " .. tostring(path))

        if cache[path] ~= nil then
            return cache[path]
        end

        local chunk, err = loadstring(source, "=" .. path)
        assert(chunk, err)

        local previous = rawget(_G, "ARequire")
        rawset(_G, "ARequire", virtualRequire)

        local ok, result = pcall(chunk)

        if previous == nil then
            rawset(_G, "ARequire", nil)
        else
            rawset(_G, "ARequire", previous)
        end

        if not ok then
            error(result, 0)
        end

        cache[path] = result
        return result
    end

    return virtualRequire
end

Bootstrap.createVirtualRequire = createVirtualRequire

function Bootstrap.load(options)
    options = options or {}

    local scheduler = options.scheduler
    if not scheduler then
        error("Bootstrap.load requires a scheduler", 0)
    end

    local services = options.services
    if not services then
        error("Bootstrap.load requires services", 0)
    end

    local sourceMap = options.sourceMap
    if not sourceMap then
        error("Bootstrap.load requires a source map", 0)
    end

    local entryPoint = options.entryPoint or "src/core/autoparry.lua"

    local originalWait = task.wait
    local originalClock = os.clock
    local originalGetService = game.GetService
    local originalFindService = game.FindService
    local previousRequire = rawget(_G, "ARequire")

    task.wait = function(duration)
        return scheduler:wait(duration)
    end

    os.clock = function()
        return scheduler:clock()
    end

    game.GetService = function(self, name)
        local stub = services[name]
        if stub ~= nil then
            return stub
        end
        return originalGetService(self, name)
    end

    game.FindService = function(self, name)
        local stub = services[name]
        if stub ~= nil then
            return stub
        end
        if originalFindService then
            local ok, result = pcall(originalFindService, self, name)
            if ok then
                return result
            end
        end
        return nil
    end

    rawset(_G, "ARequire", createVirtualRequire(sourceMap))

    local chunk, err = loadstring(sourceMap[entryPoint], "=" .. entryPoint)
    assert(chunk, err)

    local function cleanup()
        task.wait = originalWait
        os.clock = originalClock
        game.GetService = originalGetService
        if originalFindService == nil then
            game.FindService = nil
        else
            game.FindService = originalFindService
        end
        if previousRequire == nil then
            rawset(_G, "ARequire", nil)
        else
            rawset(_G, "ARequire", previousRequire)
        end
    end

    local ok, result = pcall(chunk)
    cleanup()

    if not ok then
        error(result, 0)
    end

    return result
end

return Bootstrap
