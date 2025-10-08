-- selene: allow(global_usage)
local TestHarness = script.Parent.Parent
local SourceMap = require(TestHarness:WaitForChild("AutoParrySourceMap"))

local function createVirtualRequire()
    local cache = {}

    local function virtualRequire(path)
        local source = SourceMap[path]
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

local function loadLoadingOverlay(mocks)
    mocks = mocks or {}

    local originalGetService = game.GetService
    local originalRequire = rawget(_G, "ARequire")
    local virtualRequire = createVirtualRequire()

    rawset(_G, "ARequire", virtualRequire)

    game.GetService = function(self, serviceName)
        local mock = mocks[serviceName]
        if mock ~= nil then
            return mock
        end

        return originalGetService(self, serviceName)
    end

    local chunk, err = loadstring(SourceMap["src/ui/loading_overlay.lua"], "=src/ui/loading_overlay.lua")
    assert(chunk, err)

    local ok, result = pcall(chunk)

    game.GetService = originalGetService

    if originalRequire == nil then
        rawset(_G, "ARequire", nil)
    else
        rawset(_G, "ARequire", originalRequire)
    end

    if not ok then
        error(result, 0)
    end

    return result
end

local function withOverlay(options, callback)
    local coreGui = Instance.new("Folder")
    coreGui.Name = "CoreGui"

    local LoadingOverlay = loadLoadingOverlay({
        CoreGui = coreGui,
    })

    local overlay = LoadingOverlay.create(options or {})

    local ok, result = pcall(callback, overlay, coreGui)

    overlay:destroy()
    coreGui:Destroy()

    if not ok then
        error(result, 0)
    end
end

return function(t)
    t.test("defaults to CoreGui when no parent is provided", function(expect)
        withOverlay(nil, function(overlay, coreGui)
            local gui = overlay._gui
            expect(gui ~= nil):toBeTruthy()
            expect(gui.Parent):toEqual(coreGui)
        end)
    end)

    t.test("uses a LayerCollector instance directly", function(expect)
        local screenGui = Instance.new("ScreenGui")
        withOverlay({ parent = screenGui }, function(overlay)
            local gui = overlay._gui
            expect(gui.Parent):toEqual(screenGui)
        end)
        screenGui:Destroy()
    end)

    t.test("ascends through GuiObject ancestors to find a ScreenGui", function(expect)
        local coreGui = Instance.new("Folder")
        coreGui.Name = "CoreGui"

        local rootGui = Instance.new("ScreenGui")
        rootGui.Name = "RootGui"
        rootGui.Parent = coreGui

        local container = Instance.new("Frame")
        container.Name = "GuiMainContainer"
        container.Parent = rootGui

        local LoadingOverlay = loadLoadingOverlay({
            CoreGui = coreGui,
        })

        local overlay = LoadingOverlay.create({ parent = container })
        local gui = overlay._gui

        expect(gui.Parent):toEqual(rootGui)

        overlay:destroy()
        rootGui:Destroy()
        coreGui:Destroy()
    end)

    t.test("respects BasePlayerGui parents", function(expect)
        local playerGui = Instance.new("PlayerGui")
        withOverlay({ parent = playerGui }, function(overlay)
            local gui = overlay._gui
            expect(gui.Parent):toEqual(playerGui)
        end)
        playerGui:Destroy()
    end)

    t.test("falls back to CoreGui when parent is outside the GUI tree", function(expect)
        local folder = Instance.new("Folder")

        withOverlay({ parent = folder }, function(overlay, coreGui)
            local gui = overlay._gui
            expect(gui.Parent):toEqual(coreGui)
        end)

        folder:Destroy()
    end)
end
