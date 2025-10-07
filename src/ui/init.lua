-- mikkel32/AutoParry : src/ui/init.lua
-- selene: allow(global_usage)
-- Lightweight, developer-friendly UI controller with toggle button + hotkey support.

local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")

local Require = rawget(_G, "ARequire")
local Util = Require("src/shared/util.lua")

local UI = {}

local Controller = {}
Controller.__index = Controller

local function ensureGuiRoot(name)
    local existing = CoreGui:FindFirstChild(name)
    if existing then
        existing:Destroy()
    end

    local sg = Instance.new("ScreenGui")
    sg.Name = name
    sg.ResetOnSpawn = false
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    sg.Parent = CoreGui
    return sg
end

local function makeFrame(parent)
    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(0, 200, 0, 64)
    frame.Position = UDim2.new(0, 32, 0, 180)
    frame.BackgroundColor3 = Color3.fromRGB(24, 24, 24)
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Draggable = true
    frame.Parent = parent
    return frame
end

local function makeTitle(frame, title)
    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, -80, 1, -8)
    label.Position = UDim2.new(0, 12, 0, 4)
    label.BackgroundTransparency = 1
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Top
    label.Text = tostring(title or "AutoParry")
    label.Font = Enum.Font.GothamBold
    label.TextSize = 18
    label.TextColor3 = Color3.fromRGB(235, 235, 235)
    label.Parent = frame
    return label
end

local function makeButton(frame)
    local button = Instance.new("TextButton")
    button.Name = "ToggleButton"
    button.Size = UDim2.new(0, 72, 0, 30)
    button.Position = UDim2.new(1, -88, 0.5, -15)
    button.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
    button.AutoButtonColor = true
    button.Text = "OFF"
    button.Font = Enum.Font.GothamBold
    button.TextSize = 16
    button.TextColor3 = Color3.fromRGB(255, 255, 255)
    button.Parent = frame
    return button
end

local function makeHotkeyLabel(frame, hotkeyText)
    if not hotkeyText or hotkeyText == "" then
        return nil
    end

    local label = Instance.new("TextLabel")
    label.Name = "HotkeyLabel"
    label.Size = UDim2.new(1, -24, 0, 16)
    label.Position = UDim2.new(0, 12, 1, -20)
    label.BackgroundTransparency = 1
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = hotkeyText
    label.Font = Enum.Font.Gotham
    label.TextSize = 12
    label.TextColor3 = Color3.fromRGB(200, 200, 200)
    label.Parent = frame
    return label
end

local function makeTooltip(frame, text)
    if not text or text == "" then
        return nil
    end

    local label = Instance.new("TextLabel")
    label.Name = "Tooltip"
    label.Size = UDim2.new(1, -24, 0, 16)
    label.Position = UDim2.new(0, 12, 1, -4)
    label.BackgroundTransparency = 1
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Bottom
    label.Text = text
    label.Font = Enum.Font.Gotham
    label.TextSize = 12
    label.TextColor3 = Color3.fromRGB(160, 160, 160)
    label.Parent = frame
    return label
end

local function formatHotkeyDisplay(hotkey)
    if typeof(hotkey) == "EnumItem" then
        return hotkey.Name
    end

    if typeof(hotkey) == "table" then
        local parts = {}
        if hotkey.modifiers then
            for _, mod in ipairs(hotkey.modifiers) do
                table.insert(parts, mod.Name)
            end
        end
        if hotkey.key then
            table.insert(parts, hotkey.key.Name)
        end
        if #parts > 0 then
            return table.concat(parts, " + ")
        end
    end

    if typeof(hotkey) == "string" and hotkey ~= "" then
        return hotkey
    end

    return nil
end

local lowerKeyCodeLookup

local function resolveKeyCodeFromString(name)
    if typeof(name) ~= "string" then
        return nil
    end

    local trimmed = name:match("^%s*(.-)%s*$")
    if trimmed == "" then
        return nil
    end

    local enumValue = Enum.KeyCode[trimmed]
    if enumValue then
        return enumValue
    end

    if not lowerKeyCodeLookup then
        lowerKeyCodeLookup = {}
        for _, item in ipairs(Enum.KeyCode:GetEnumItems()) do
            lowerKeyCodeLookup[item.Name:lower()] = item
        end
    end

    return lowerKeyCodeLookup[trimmed:lower()]
end

local function parseHotkey(hotkey)
    if not hotkey then
        return nil
    end

    if typeof(hotkey) == "EnumItem" then
        return { key = hotkey, modifiers = {} }
    end

    if typeof(hotkey) == "table" then
        local key = hotkey.key or hotkey.Key
        if typeof(key) ~= "EnumItem" then
            key = resolveKeyCodeFromString(key)
        end

        if typeof(key) == "EnumItem" then
            local parsedModifiers = {}
            local modifiers = hotkey.modifiers or hotkey.Modifiers or {}

            if typeof(modifiers) == "table" then
                for _, modifier in ipairs(modifiers) do
                    if typeof(modifier) == "EnumItem" then
                        table.insert(parsedModifiers, modifier)
                    else
                        local resolvedModifier = resolveKeyCodeFromString(modifier)
                        if typeof(resolvedModifier) == "EnumItem" then
                            table.insert(parsedModifiers, resolvedModifier)
                        end
                    end
                end
            end

            return {
                key = key,
                modifiers = parsedModifiers,
                allowGameProcessed = hotkey.allowGameProcessed == true,
            }
        end
    end

    if typeof(hotkey) == "string" then
        local enumValue = resolveKeyCodeFromString(hotkey)

        if enumValue then
            return { key = enumValue, modifiers = {} }
        end
    end

    return nil
end

local function matchesHotkey(input, descriptor)
    if not descriptor then
        return false
    end

    if input.KeyCode ~= descriptor.key then
        return false
    end

    if descriptor.modifiers then
        for _, modifier in ipairs(descriptor.modifiers) do
            if not UserInputService:IsKeyDown(modifier) then
                return false
            end
        end
    end

    return true
end

function Controller:setEnabled(enabled, context)
    if self._destroyed then
        return self._enabled
    end

    enabled = not not enabled
    context = context or {}

    if self._enabled == enabled then
        return self._enabled
    end

    self._enabled = enabled
    self.button.Text = enabled and "ON" or "OFF"
    self.button.BackgroundColor3 = enabled and Color3.fromRGB(0, 160, 80) or Color3.fromRGB(60, 60, 60)

    if not context.silent and typeof(self._onToggle) == "function" then
        task.spawn(self._onToggle, enabled, context)
    end

    if self._changed then
        self._changed:fire(enabled, context)
    end

    return self._enabled
end

function Controller:toggle()
    return self:setEnabled(not self._enabled)
end

function Controller:isEnabled()
    return self._enabled
end

function Controller:getGui()
    return self.gui
end

function Controller:onChanged(callback)
    assert(typeof(callback) == "function", "UI.onChanged expects a function")
    return self._changed:connect(callback)
end

function Controller:destroy()
    if self._destroyed then
        return
    end

    self._destroyed = true
    for _, connection in ipairs(self._connections) do
        connection:Disconnect()
    end
    self._connections = {}
    if self._hotkeyConnection then
        self._hotkeyConnection:Disconnect()
        self._hotkeyConnection = nil
    end
    if self.gui then
        self.gui:Destroy()
        self.gui = nil
    end
    if self._changed then
        self._changed:destroy()
        self._changed = nil
    end
    self.button = nil
end

function UI.mount(options)
    options = options or {}
    local gui = ensureGuiRoot("AutoParryUI")
    local frame = makeFrame(gui)
    makeTitle(frame, options.title or "AutoParry")
    local button = makeButton(frame)

    local controller = setmetatable({
        gui = gui,
        button = button,
        _enabled = false,
        _onToggle = options.onToggle,
        _connections = {},
        _changed = Util.Signal.new(),
    }, Controller)

    local hotkeyDescriptor = parseHotkey(options.hotkey)
    local hotkeyDisplay = formatHotkeyDisplay(hotkeyDescriptor and hotkeyDescriptor.key and hotkeyDescriptor or options.hotkey)
    makeHotkeyLabel(frame, hotkeyDisplay and ("Hotkey: %s"):format(hotkeyDisplay) or nil)
    makeTooltip(frame, options.tooltip)

    table.insert(controller._connections, button.MouseButton1Click:Connect(function()
        controller:toggle()
    end))

    if hotkeyDescriptor then
        controller._hotkeyConnection = UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
            if gameProcessedEvent and hotkeyDescriptor.allowGameProcessed ~= true then
                return
            end
            if matchesHotkey(input, hotkeyDescriptor) then
                controller:toggle()
            end
        end)
        table.insert(controller._connections, controller._hotkeyConnection)
    end

    controller:setEnabled(options.initialState == true, { silent = true })

    return controller
end

return UI
