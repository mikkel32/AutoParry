-- selene: allow(global_usage)
local TestHarness = script.Parent.Parent
local SourceMap = require(TestHarness:WaitForChild("AutoParrySourceMap"))
local HttpService = game:GetService("HttpService")

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

local function serializeUDim2(value)
    return {
        x = { scale = value.X.Scale, offset = value.X.Offset },
        y = { scale = value.Y.Scale, offset = value.Y.Offset },
    }
end

local function serializeColor3(color)
    local function to255(component)
        return math.floor(component * 255 + 0.5)
    end

    return {
        r = to255(color.R),
        g = to255(color.G),
        b = to255(color.B),
    }
end

local function serializeTextLabel(label)
    return {
        text = label.Text,
        font = label.Font.Name,
        textSize = label.TextSize,
        textColor3 = serializeColor3(label.TextColor3),
        size = serializeUDim2(label.Size),
        position = serializeUDim2(label.Position),
        textXAlignment = label.TextXAlignment.Name,
        textYAlignment = label.TextYAlignment.Name,
        backgroundTransparency = label.BackgroundTransparency,
    }
end

local function serializeButton(button)
    return {
        name = button.Name,
        text = button.Text,
        font = button.Font.Name,
        textSize = button.TextSize,
        textColor3 = serializeColor3(button.TextColor3),
        size = serializeUDim2(button.Size),
        position = serializeUDim2(button.Position),
        backgroundColor3 = serializeColor3(button.BackgroundColor3),
        autoButtonColor = button.AutoButtonColor,
    }
end

local function serializeTelemetryCards(cardsFrame)
    local cards = {}

    if not cardsFrame then
        return cards
    end

    for _, child in ipairs(cardsFrame:GetChildren()) do
        if child:IsA("Frame") then
            table.insert(cards, {
                name = child.Name,
                size = serializeUDim2(child.Size),
                backgroundColor3 = serializeColor3(child.BackgroundColor3),
                label = child:FindFirstChild("Label") and serializeTextLabel(child.Label) or nil,
                value = child:FindFirstChild("Value") and serializeTextLabel(child.Value) or nil,
                hint = child:FindFirstChild("Hint") and serializeTextLabel(child.Hint) or nil,
            })
        end
    end

    table.sort(cards, function(a, b)
        return tostring(a.name) < tostring(b.name)
    end)

    return cards
end

local function serializeControlToggles(list)
    local toggles = {}

    if not list then
        return toggles
    end

    for _, child in ipairs(list:GetChildren()) do
        if child:IsA("Frame") then
            table.insert(toggles, {
                name = child.Name,
                title = child:FindFirstChild("Title") and serializeTextLabel(child.Title) or nil,
                description = child:FindFirstChild("Description") and serializeTextLabel(child.Description) or nil,
                badge = child:FindFirstChild("Badge") and serializeTextLabel(child.Badge) or nil,
                switch = child:FindFirstChild("Switch") and serializeButton(child.Switch) or nil,
            })
        end
    end

    table.sort(toggles, function(a, b)
        return tostring(a.name) < tostring(b.name)
    end)

    return toggles
end

local function captureSnapshot(gui)
    local dashboard = gui:FindFirstChild("Dashboard")
    assert(dashboard, "Dashboard frame missing from AutoParry UI")

    local content = dashboard:FindFirstChild("Content")
    assert(content, "Dashboard content missing")

    local header = content:FindFirstChild("Header")
    local statusCard = content:FindFirstChild("StatusCard")
    local telemetry = content:FindFirstChild("Telemetry")
    local controls = content:FindFirstChild("Controls")
    local actions = content:FindFirstChild("Actions")

    assert(header, "Dashboard header missing")
    assert(statusCard, "Status card missing from AutoParry UI")

    local badge = header:FindFirstChild("StatusBadge")
    local badgeLabel = badge and badge:FindFirstChild("Label")

    local telemetryCards = telemetry and telemetry:FindFirstChild("Cards")
    local controlList = controls and controls:FindFirstChild("List")

    local toggleButton = statusCard:FindFirstChild("ToggleButton")
    assert(toggleButton, "Toggle button missing from AutoParry UI")

    local snapshot = {
        screenGui = {
            name = gui.Name,
            resetOnSpawn = gui.ResetOnSpawn,
            zIndexBehavior = gui.ZIndexBehavior.Name,
            dashboard = {
                size = serializeUDim2(dashboard.Size),
                position = serializeUDim2(dashboard.Position),
                backgroundColor3 = serializeColor3(dashboard.BackgroundColor3),
                automaticSize = dashboard.AutomaticSize.Name,
                borderSizePixel = dashboard.BorderSizePixel,
                active = dashboard.Active,
                draggable = dashboard.Draggable,
                header = {
                    title = header:FindFirstChild("Title") and serializeTextLabel(header.Title) or nil,
                    tagline = header:FindFirstChild("Tagline") and serializeTextLabel(header.Tagline) or nil,
                    hotkeyLabel = header:FindFirstChild("HotkeyLabel") and serializeTextLabel(header.HotkeyLabel) or nil,
                    badge = badge and {
                        backgroundColor3 = serializeColor3(badge.BackgroundColor3),
                        text = badgeLabel and badgeLabel.Text or nil,
                        textColor3 = badgeLabel and serializeColor3(badgeLabel.TextColor3) or nil,
                    } or nil,
                },
                statusCard = {
                    backgroundColor3 = serializeColor3(statusCard.BackgroundColor3),
                    heading = statusCard:FindFirstChild("StatusHeading") and serializeTextLabel(statusCard.StatusHeading) or nil,
                    support = statusCard:FindFirstChild("StatusSupport") and serializeTextLabel(statusCard.StatusSupport) or nil,
                    hotkeyLabel = statusCard:FindFirstChild("HotkeyLabel") and serializeTextLabel(statusCard.HotkeyLabel) or nil,
                    tooltip = statusCard:FindFirstChild("Tooltip") and serializeTextLabel(statusCard.Tooltip) or nil,
                    button = serializeButton(toggleButton),
                },
                telemetry = {
                    title = telemetry and telemetry:FindFirstChild("Title") and serializeTextLabel(telemetry.Title) or nil,
                    cards = serializeTelemetryCards(telemetryCards),
                },
                controls = {
                    title = controls and controls:FindFirstChild("Title") and serializeTextLabel(controls.Title) or nil,
                    toggles = serializeControlToggles(controlList),
                },
                actions = (function()
                    local visible = actions and actions.Visible or false
                    local buttonCount = 0

                    if actions then
                        for _, child in ipairs(actions:GetChildren()) do
                            if child:IsA("TextButton") then
                                buttonCount += 1
                            end
                        end
                    end

                    return {
                        visible = visible,
                        buttonCount = buttonCount,
                    }
                end)(),
            },
        },
    }

    return snapshot
end

local function readBaseline()
    local source = SourceMap["tests/fixtures/ui_snapshot.json"]
    assert(source, "UI snapshot baseline missing from source map")

    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, source)
    assert(ok, "Failed to decode UI snapshot baseline")

    return decoded
end

local function formatValue(value)
    if type(value) == "table" then
        local ok, encoded = pcall(HttpService.JSONEncode, HttpService, value)
        if ok then
            return encoded
        end
    end
    return tostring(value)
end

local function accumulateDifferences(expected, actual, path, differences)
    if actual == nil then
        table.insert(differences, string.format("%s is missing (expected %s)", path, formatValue(expected)))
        return
    end

    local expectedType = typeof(expected)
    local actualType = typeof(actual)

    if expectedType ~= actualType then
        table.insert(differences, string.format("%s type mismatch: expected %s but got %s", path, expectedType, actualType))
        return
    end

    if expectedType ~= "table" then
        if expected ~= actual then
            table.insert(differences, string.format("%s expected %s but got %s", path, formatValue(expected), formatValue(actual)))
        end
        return
    end

    local visited = {}

    for key, value in pairs(expected) do
        accumulateDifferences(value, actual[key], path .. "." .. tostring(key), differences)
        visited[key] = true
    end

    for key, value in pairs(actual) do
        if not visited[key] then
            table.insert(differences, string.format("%s.%s unexpected value %s", path, tostring(key), formatValue(value)))
        end
    end
end

local function compareSnapshots(expected, actual)
    local differences = {}
    accumulateDifferences(expected, actual, "snapshot", differences)
    return differences
end

return function(t)
    t.test("AutoParry UI matches the recorded snapshot", function()
        local harness = createHarness()
        local controller = harness:mount({
            title = "Snapshot Title",
            hotkey = Enum.KeyCode.G,
            tooltip = "Tap to toggle",
        })

        local gui = controller.gui
        assert(gui, "Controller did not expose a ScreenGui")

        local currentSnapshot = captureSnapshot(gui)
        local baseline = readBaseline()
        local differences = compareSnapshots(baseline, currentSnapshot)

        harness:cleanup()

        t.artifact("ui-snapshot", {
            expected = baseline,
            actual = currentSnapshot,
            differences = differences,
        })

        if #differences > 0 then
            error(table.concat({
                "AutoParry UI snapshot drift detected.",
                "Review the ui-snapshot artifact and confirm the changes are intentional.",
                "If the new layout is correct, update tests/fixtures/ui_snapshot.json after manual approval.",
                "Refer to tests/README.md for the review workflow.",
                "Differences:\n- " .. table.concat(differences, "\n- "),
            }, "\n"), 0)
        end
    end)
end
