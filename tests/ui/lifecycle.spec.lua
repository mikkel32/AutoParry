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

local function loadUi(mocks)
    mocks = mocks or {}

    local originalGetService = game.GetService
    local originalRequire = rawget(_G, "ARequire")
    local virtualRequire = createVirtualRequire()

    rawset(_G, "ARequire", virtualRequire)

    game.GetService = function(self, serviceName)
        if serviceName == "UserInputService" and mocks.UserInputService then
            return mocks.UserInputService
        end

        if serviceName == "CoreGui" and mocks.CoreGui then
            return mocks.CoreGui
        end

        return originalGetService(self, serviceName)
    end

    local chunk, err = loadstring(SourceMap["src/ui/init.lua"], "=src/ui/init.lua")
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

local function createMockInputService()
    local event = Instance.new("BindableEvent")
    local service = {
        _event = event,
        InputBegan = event.Event,
        _keys = {},
    }

    function service:IsKeyDown(keyCode)
        return self._keys[keyCode] == true
    end

    function service:SetKeyDown(keyCode, isDown)
        if isDown then
            self._keys[keyCode] = true
        else
            self._keys[keyCode] = nil
        end
    end

    function service:FireInput(keyCode, gameProcessed)
        self._event:Fire({ KeyCode = keyCode }, gameProcessed)
    end

    function service:Destroy()
        self._event:Destroy()
    end

    return service
end

local function createHarness()
    local inputService = createMockInputService()
    local coreGui = Instance.new("Folder")
    coreGui.Name = "CoreGui"

    local UI = loadUi({
        UserInputService = inputService,
        CoreGui = coreGui,
    })

    local controllers = {}

    local harness = {}

    function harness:mount(options)
        local controller = UI.mount(options or {})
        table.insert(controllers, controller)
        return controller
    end

    function harness:getCoreGui()
        return coreGui
    end

    function harness:getInputService()
        return inputService
    end

    function harness:cleanup()
        for _, controller in ipairs(controllers) do
            controller:destroy()
        end
        controllers = {}
        inputService:Destroy()
        coreGui:Destroy()
    end

    return harness
end

local function countScreenGuis(parent)
    local count = 0
    for _, child in ipairs(parent:GetChildren()) do
        if child:IsA("ScreenGui") then
            count += 1
        end
    end
    return count
end

return function(t)
    t.test("mounting twice keeps a single AutoParry screen gui", function(expect)
        local harness = createHarness()
        local coreGui = harness:getCoreGui()

        local firstController = harness:mount({ title = "Test" })
        local firstGui = firstController.gui

        expect(countScreenGuis(coreGui)):toEqual(1)
        expect(coreGui:FindFirstChild("AutoParryUI")):toEqual(firstGui)

        local secondController = harness:mount({ title = "Test Again" })
        local secondGui = secondController.gui

        expect(countScreenGuis(coreGui)):toEqual(1)
        expect(coreGui:FindFirstChild("AutoParryUI")):toEqual(secondGui)
        expect(firstGui.Parent):toEqual(nil)

        harness:cleanup()
    end)

    t.test("destroy removes connections and the screen gui", function(expect)
        local harness = createHarness()
        local coreGui = harness:getCoreGui()

        local controller = harness:mount({
            title = "Destroy Test",
            hotkey = Enum.KeyCode.G,
        })

        local connections = {}
        for _, connection in ipairs(controller._connections) do
            table.insert(connections, connection)
        end

        expect(#connections):toBeGreaterThanOrEqual(2)

        controller:destroy()

        expect(#controller._connections):toEqual(0)
        expect(controller._hotkeyConnection):toEqual(nil)
        expect(controller.gui):toEqual(nil)
        expect(controller.button):toEqual(nil)
        expect(coreGui:FindFirstChild("AutoParryUI")):toEqual(nil)

        for _, connection in ipairs(connections) do
            expect(connection.Connected):toEqual(false)
        end

        harness:cleanup()
    end)

    t.test("remount resets controller state", function(expect)
        local harness = createHarness()
        local coreGui = harness:getCoreGui()

        local controller = harness:mount({
            title = "Initial",
            hotkey = Enum.KeyCode.H,
        })

        controller:destroy()

        expect(coreGui:FindFirstChild("AutoParryUI")):toEqual(nil)

        local nextController = harness:mount({
            title = "Remount",
            hotkey = Enum.KeyCode.H,
        })

        expect(nextController._destroyed):toEqual(nil)
        expect(countScreenGuis(coreGui)):toEqual(1)

        local changedCount = 0
        local changedConnection = nextController:onChanged(function()
            changedCount += 1
        end)

        expect(changedConnection):toBeTruthy()

        nextController:setEnabled(true)
        expect(nextController:isEnabled()):toEqual(true)
        expect(changedCount):toEqual(1)

        changedConnection:Disconnect()

        harness:cleanup()
    end)
end
