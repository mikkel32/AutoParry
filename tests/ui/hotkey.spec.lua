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

local function createController(options)
    local inputService = createMockInputService()
    local coreGui = Instance.new("Folder")
    coreGui.Name = "CoreGui"

    local UI = loadUi({
        UserInputService = inputService,
        CoreGui = coreGui,
    })

    local toggles = {}
    local controller = UI.mount({
        title = "Test AutoParry",
        hotkey = options.hotkey,
        onToggle = function(enabled)
            table.insert(toggles, enabled)
        end,
    })

    local frame = controller.button.Parent

    local function cleanup()
        controller:destroy()
        inputService:Destroy()
        coreGui:Destroy()
    end

    return controller, inputService, frame, toggles, cleanup
end

local function withController(options, callback)
    local controller, inputService, frame, toggles, cleanup = createController(options)
    local ok, result = pcall(callback, controller, inputService, frame, toggles)
    cleanup()

    if not ok then
        error(result, 0)
    end
end

return function(t)
    t.test("string hotkey toggles only on matching unprocessed input", function(expect)
        withController({ hotkey = "f" }, function(controller, inputService, frame, toggles)
            local label = frame:FindFirstChild("HotkeyLabel")
            expect(label ~= nil):toBeTruthy()
            expect(label.Text):toEqual("Hotkey: F")

            expect(controller:isEnabled()):toEqual(false)

            inputService:FireInput(Enum.KeyCode.G, false)
            expect(controller:isEnabled()):toEqual(false)

            inputService:FireInput(Enum.KeyCode.F, true)
            expect(controller:isEnabled()):toEqual(false)

            inputService:FireInput(Enum.KeyCode.F, false)
            expect(controller:isEnabled()):toEqual(true)
            expect(toggles[#toggles]):toEqual(true)
        end)
    end)

    t.test("enum hotkey toggles state on repeated presses", function(expect)
        withController({ hotkey = Enum.KeyCode.J }, function(controller, inputService, frame, toggles)
            local label = frame:FindFirstChild("HotkeyLabel")
            expect(label ~= nil):toBeTruthy()
            expect(label.Text):toEqual("Hotkey: J")

            inputService:FireInput(Enum.KeyCode.J, false)
            expect(controller:isEnabled()):toEqual(true)
            expect(toggles[#toggles]):toEqual(true)

            inputService:FireInput(Enum.KeyCode.J, false)
            expect(controller:isEnabled()):toEqual(false)
            expect(toggles[#toggles]):toEqual(false)
        end)
    end)

    t.test("table hotkey enforces modifiers and allowGameProcessed", function(expect)
        local descriptor = {
            key = Enum.KeyCode.B,
            modifiers = { Enum.KeyCode.LeftShift, Enum.KeyCode.LeftControl },
            allowGameProcessed = true,
        }

        withController({ hotkey = descriptor }, function(controller, inputService, frame, toggles)
            local label = frame:FindFirstChild("HotkeyLabel")
            expect(label ~= nil):toBeTruthy()
            expect(label.Text):toEqual("Hotkey: LeftShift + LeftControl + B")

            inputService:FireInput(Enum.KeyCode.B, false)
            expect(controller:isEnabled()):toEqual(false)

            inputService:SetKeyDown(Enum.KeyCode.LeftShift, true)
            inputService:FireInput(Enum.KeyCode.B, false)
            expect(controller:isEnabled()):toEqual(false)

            inputService:SetKeyDown(Enum.KeyCode.LeftControl, true)
            inputService:FireInput(Enum.KeyCode.B, true)
            expect(controller:isEnabled()):toEqual(true)
            expect(toggles[#toggles]):toEqual(true)
        end)
    end)
end
