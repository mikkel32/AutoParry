-- mikkel32/AutoParry : src/ui/init.lua
-- selene: allow(global_usage)
-- Professional dashboard controller for AutoParry with status, telemetry,
-- control toggles, and hotkey support. The module exposes a lightweight API
-- used by the runtime to keep the UI in sync with the parry core while giving
-- downstream experiences room to customise the presentation.

local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")

local Require = rawget(_G, "ARequire")
local Util = Require("src/shared/util.lua")
local LoadingOverlay = Require("src/ui/loading_overlay.lua")

local UI = {}

local Controller = {}
Controller.__index = Controller

local DASHBOARD_THEME = {
    width = 460,
    backgroundColor = Color3.fromRGB(24, 28, 36),
    backgroundTransparency = 0.05,
    strokeColor = Color3.fromRGB(94, 148, 214),
    strokeTransparency = 0.5,
    gradient = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(28, 32, 42)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(82, 156, 255)),
    }),
    gradientTransparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.9),
        NumberSequenceKeypoint.new(1, 0.35),
    }),
    glowColor = Color3.fromRGB(82, 156, 255),
    glowTransparency = 0.85,
    headingColor = Color3.fromRGB(232, 238, 248),
    subheadingColor = Color3.fromRGB(188, 202, 224),
    badgeActiveColor = Color3.fromRGB(88, 206, 157),
    badgeIdleColor = Color3.fromRGB(56, 64, 82),
    badgeTextActive = Color3.fromRGB(12, 16, 26),
    badgeTextIdle = Color3.fromRGB(216, 226, 244),
    toggleOnColor = Color3.fromRGB(82, 156, 255),
    toggleOffColor = Color3.fromRGB(44, 50, 62),
    toggleOnTextColor = Color3.fromRGB(12, 16, 26),
    toggleOffTextColor = Color3.fromRGB(216, 226, 244),
    telemetryCardColor = Color3.fromRGB(26, 30, 40),
    telemetryStrokeColor = Color3.fromRGB(94, 148, 214),
    controlCardColor = Color3.fromRGB(24, 28, 36),
    controlStrokeColor = Color3.fromRGB(94, 148, 214),
}

local DEFAULT_TELEMETRY_CARDS = {
    {
        id = "latency",
        label = "Network Latency",
        value = "-- ms",
        hint = "Round-trip time to the Blade Ball server.",
    },
    {
        id = "uptime",
        label = "Session Length",
        value = "00:00",
        hint = "Elapsed runtime since activation.",
    },
    {
        id = "assist",
        label = "Timing Engine",
        value = "Calibrating",
        hint = "Status of AutoParry's adaptive timing model.",
    },
}

local DEFAULT_CONTROL_SWITCHES = {
    {
        id = "adaptive",
        title = "Adaptive Timing",
        description = "Adjusts parry timing from recent plays.",
        default = true,
        badge = "SMART",
    },
    {
        id = "failsafe",
        title = "Safety Net",
        description = "Returns control to you if anomalies spike.",
        default = true,
        badge = "SAFE",
    },
    {
        id = "edge",
        title = "Advanced Prediction",
        description = "Forecasts ricochet chains before they happen.",
        default = false,
    },
    {
        id = "sync",
        title = "Team Sync",
        description = "Shares telemetry with party members instantly.",
        default = true,
        badge = "LINK",
    },
}

local function ensureGuiRoot(name)
    local existing = CoreGui:FindFirstChild(name)
    if existing then
        existing:Destroy()
    end

    local sg = Instance.new("ScreenGui")
    sg.Name = name
    sg.ResetOnSpawn = false
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    sg.IgnoreGuiInset = true
    sg.Parent = CoreGui
    return sg
end

local function formatHotkeyDisplay(hotkey)
    if typeof(hotkey) == "EnumItem" then
        return hotkey.Name
    end

    if typeof(hotkey) == "table" then
        local parts = {}
        local modifiers = hotkey.modifiers or hotkey.Modifiers
        if typeof(modifiers) == "table" then
            for _, modifier in ipairs(modifiers) do
                if typeof(modifier) == "EnumItem" then
                    table.insert(parts, modifier.Name)
                elseif typeof(modifier) == "string" and modifier ~= "" then
                    table.insert(parts, modifier)
                end
            end
        end

        local key = hotkey.key or hotkey.Key
        if typeof(key) == "EnumItem" then
            table.insert(parts, key.Name)
        elseif typeof(key) == "string" and key ~= "" then
            table.insert(parts, key)
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

local function createDashboardFrame(parent)
    local frame = Instance.new("Frame")
    frame.Name = "Dashboard"
    frame.AnchorPoint = Vector2.new(0, 0)
    frame.Position = UDim2.new(0, 36, 0, 140)
    frame.Size = UDim2.new(0, DASHBOARD_THEME.width, 0, 0)
    frame.AutomaticSize = Enum.AutomaticSize.Y
    frame.BackgroundColor3 = DASHBOARD_THEME.backgroundColor
    frame.BackgroundTransparency = DASHBOARD_THEME.backgroundTransparency
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Draggable = true
    frame.ClipsDescendants = false
    frame.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 18)
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 2
    stroke.Transparency = DASHBOARD_THEME.strokeTransparency
    stroke.Color = DASHBOARD_THEME.strokeColor
    stroke.Parent = frame

    local gradient = Instance.new("UIGradient")
    gradient.Color = DASHBOARD_THEME.gradient
    gradient.Transparency = DASHBOARD_THEME.gradientTransparency
    gradient.Rotation = 125
    gradient.Parent = frame

    local glow = Instance.new("Frame")
    glow.Name = "Glow"
    glow.AnchorPoint = Vector2.new(0.5, 0)
    glow.Position = UDim2.new(0.5, 0, 0, -64)
    glow.Size = UDim2.new(0.85, 0, 0, 180)
    glow.BackgroundTransparency = 1
    glow.Parent = frame

    local glowGradient = Instance.new("UIGradient")
    glowGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, DASHBOARD_THEME.glowColor),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 255, 255)),
    })
    glowGradient.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1),
        NumberSequenceKeypoint.new(0.5, DASHBOARD_THEME.glowTransparency),
        NumberSequenceKeypoint.new(1, 1),
    })
    glowGradient.Rotation = 90
    glowGradient.Parent = glow

    local content = Instance.new("Frame")
    content.Name = "Content"
    content.BackgroundTransparency = 1
    content.Position = UDim2.new(0, 24, 0, 24)
    content.Size = UDim2.new(1, -48, 0, 0)
    content.AutomaticSize = Enum.AutomaticSize.Y
    content.Parent = frame

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 14)
    layout.Parent = content

    return frame, content
end

local function createHeader(parent, titleText, hotkeyText)
    local header = Instance.new("Frame")
    header.Name = "Header"
    header.BackgroundTransparency = 1
    header.Size = UDim2.new(1, 0, 0, 0)
    header.AutomaticSize = Enum.AutomaticSize.Y
    header.LayoutOrder = 1
    header.Parent = parent

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBlack
    title.TextSize = 30
    title.TextColor3 = DASHBOARD_THEME.headingColor
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextYAlignment = Enum.TextYAlignment.Bottom
    title.Text = tostring(titleText or "AutoParry")
    title.Size = UDim2.new(1, 0, 0, 34)
    title.Parent = header

    local tagline = Instance.new("TextLabel")
    tagline.Name = "Tagline"
    tagline.BackgroundTransparency = 1
    tagline.Font = Enum.Font.Gotham
    tagline.TextSize = 18
    tagline.TextColor3 = DASHBOARD_THEME.subheadingColor
    tagline.TextXAlignment = Enum.TextXAlignment.Left
    tagline.TextYAlignment = Enum.TextYAlignment.Top
    tagline.Text = "Precision parry automation"
    tagline.Position = UDim2.new(0, 0, 0, 38)
    tagline.Size = UDim2.new(1, 0, 0, 26)
    tagline.Parent = header

    local badge = Instance.new("Frame")
    badge.Name = "StatusBadge"
    badge.AnchorPoint = Vector2.new(1, 0)
    badge.Position = UDim2.new(1, 0, 0, 2)
    badge.Size = UDim2.new(0, 120, 0, 30)
    badge.BackgroundColor3 = DASHBOARD_THEME.badgeIdleColor
    badge.BackgroundTransparency = 0.15
    badge.BorderSizePixel = 0
    badge.Parent = header

    local badgeCorner = Instance.new("UICorner")
    badgeCorner.CornerRadius = UDim.new(0, 14)
    badgeCorner.Parent = badge

    local badgeStroke = Instance.new("UIStroke")
    badgeStroke.Thickness = 1.5
    badgeStroke.Transparency = 0.4
    badgeStroke.Color = DASHBOARD_THEME.strokeColor
    badgeStroke.Parent = badge

    local badgeLabel = Instance.new("TextLabel")
    badgeLabel.Name = "Label"
    badgeLabel.BackgroundTransparency = 1
    badgeLabel.Font = Enum.Font.GothamSemibold
    badgeLabel.TextSize = 14
    badgeLabel.TextColor3 = DASHBOARD_THEME.badgeTextIdle
    badgeLabel.TextXAlignment = Enum.TextXAlignment.Center
    badgeLabel.Text = "IDLE"
    badgeLabel.Size = UDim2.new(1, 0, 1, 0)
    badgeLabel.Parent = badge

    local hotkeyLabel = Instance.new("TextLabel")
    hotkeyLabel.Name = "HotkeyLabel"
    hotkeyLabel.AnchorPoint = Vector2.new(1, 0)
    hotkeyLabel.Position = UDim2.new(1, 0, 1, 6)
    hotkeyLabel.BackgroundTransparency = 1
    hotkeyLabel.Font = Enum.Font.Gotham
    hotkeyLabel.TextSize = 14
    hotkeyLabel.TextColor3 = Color3.fromRGB(170, 188, 220)
    hotkeyLabel.TextXAlignment = Enum.TextXAlignment.Right
    hotkeyLabel.Text = hotkeyText and ("Hotkey: %s"):format(hotkeyText) or ""
    hotkeyLabel.Size = UDim2.new(0, 240, 0, 20)
    hotkeyLabel.Parent = header

    return {
        frame = header,
        title = title,
        tagline = tagline,
        badge = badge,
        badgeLabel = badgeLabel,
        hotkeyLabel = hotkeyLabel,
    }
end

local function createStatusCard(parent)
    local card = Instance.new("Frame")
    card.Name = "StatusCard"
    card.BackgroundColor3 = Color3.fromRGB(16, 24, 44)
    card.BackgroundTransparency = 0.08
    card.BorderSizePixel = 0
    card.LayoutOrder = 2
    card.Size = UDim2.new(1, 0, 0, 0)
    card.AutomaticSize = Enum.AutomaticSize.Y
    card.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 16)
    corner.Parent = card

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1.5
    stroke.Transparency = 0.45
    stroke.Color = DASHBOARD_THEME.strokeColor
    stroke.Parent = card

    local gradient = Instance.new("UIGradient")
    gradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(12, 18, 34)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 105, 180)),
    })
    gradient.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.88),
        NumberSequenceKeypoint.new(1, 0.4),
    })
    gradient.Rotation = 130
    gradient.Parent = card

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 24)
    padding.PaddingBottom = UDim.new(0, 24)
    padding.PaddingLeft = UDim.new(0, 24)
    padding.PaddingRight = UDim.new(0, 24)
    padding.Parent = card

    local header = Instance.new("TextLabel")
    header.Name = "Heading"
    header.BackgroundTransparency = 1
    header.Font = Enum.Font.GothamSemibold
    header.TextSize = 16
    header.TextColor3 = Color3.fromRGB(170, 188, 220)
    header.TextXAlignment = Enum.TextXAlignment.Left
    header.Text = "Control status"
    header.Size = UDim2.new(1, -160, 0, 18)
    header.Parent = card

    local statusHeading = Instance.new("TextLabel")
    statusHeading.Name = "StatusHeading"
    statusHeading.BackgroundTransparency = 1
    statusHeading.Font = Enum.Font.GothamBlack
    statusHeading.TextSize = 26
    statusHeading.TextColor3 = DASHBOARD_THEME.headingColor
    statusHeading.TextXAlignment = Enum.TextXAlignment.Left
    statusHeading.Text = "AutoParry standby"
    statusHeading.Position = UDim2.new(0, 0, 0, 32)
    statusHeading.Size = UDim2.new(1, -160, 0, 32)
    statusHeading.Parent = card

    local statusSupport = Instance.new("TextLabel")
    statusSupport.Name = "StatusSupport"
    statusSupport.BackgroundTransparency = 1
    statusSupport.Font = Enum.Font.Gotham
    statusSupport.TextSize = 17
    statusSupport.TextColor3 = DASHBOARD_THEME.subheadingColor
    statusSupport.TextXAlignment = Enum.TextXAlignment.Left
    statusSupport.TextWrapped = true
    statusSupport.Text = "Assist engine standing by for activation."
    statusSupport.Position = UDim2.new(0, 0, 0, 66)
    statusSupport.Size = UDim2.new(1, -160, 0, 44)
    statusSupport.Parent = card

    local toggleButton = Instance.new("TextButton")
    toggleButton.Name = "ToggleButton"
    toggleButton.AutoButtonColor = false
    toggleButton.AnchorPoint = Vector2.new(1, 0)
    toggleButton.Position = UDim2.new(1, 0, 0, 20)
    toggleButton.Size = UDim2.new(0, 160, 0, 46)
    toggleButton.BackgroundColor3 = DASHBOARD_THEME.toggleOffColor
    toggleButton.TextColor3 = DASHBOARD_THEME.toggleOffTextColor
    toggleButton.Font = Enum.Font.GothamBold
    toggleButton.TextSize = 19
    toggleButton.Text = "Enable AutoParry"
    toggleButton.BorderSizePixel = 0
    toggleButton.Parent = card

    local toggleCorner = Instance.new("UICorner")
    toggleCorner.CornerRadius = UDim.new(0, 12)
    toggleCorner.Parent = toggleButton

    local tooltip = Instance.new("TextLabel")
    tooltip.Name = "Tooltip"
    tooltip.BackgroundTransparency = 1
    tooltip.Font = Enum.Font.Gotham
    tooltip.TextSize = 14
    tooltip.TextColor3 = Color3.fromRGB(150, 168, 205)
    tooltip.TextXAlignment = Enum.TextXAlignment.Left
    tooltip.TextWrapped = true
    tooltip.Position = UDim2.new(0, 0, 0, 118)
    tooltip.Size = UDim2.new(1, 0, 0, 20)
    tooltip.Text = ""
    tooltip.Parent = card

    local hotkeyLabel = Instance.new("TextLabel")
    hotkeyLabel.Name = "HotkeyLabel"
    hotkeyLabel.BackgroundTransparency = 1
    hotkeyLabel.Font = Enum.Font.Gotham
    hotkeyLabel.TextSize = 14
    hotkeyLabel.TextColor3 = Color3.fromRGB(170, 188, 220)
    hotkeyLabel.TextXAlignment = Enum.TextXAlignment.Right
    hotkeyLabel.AnchorPoint = Vector2.new(1, 0)
    hotkeyLabel.Position = UDim2.new(1, 0, 0, 118)
    hotkeyLabel.Size = UDim2.new(0, 160, 0, 20)
    hotkeyLabel.Text = ""
    hotkeyLabel.Parent = card

    return {
        frame = card,
        heading = statusHeading,
        support = statusSupport,
        tooltip = tooltip,
        hotkeyLabel = hotkeyLabel,
        button = toggleButton,
    }
end

local function createTelemetryCard(parent, definition)
    local card = Instance.new("Frame")
    card.Name = definition.id or "Telemetry"
    card.BackgroundColor3 = DASHBOARD_THEME.telemetryCardColor
    card.BackgroundTransparency = 0.1
    card.BorderSizePixel = 0
    card.Size = UDim2.new(0, 0, 0, 100)
    card.AutomaticSize = Enum.AutomaticSize.Y
    card.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 14)
    corner.Parent = card

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1
    stroke.Transparency = 0.5
    stroke.Color = DASHBOARD_THEME.telemetryStrokeColor
    stroke.Parent = card

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 16)
    padding.PaddingBottom = UDim.new(0, 16)
    padding.PaddingLeft = UDim.new(0, 18)
    padding.PaddingRight = UDim.new(0, 18)
    padding.Parent = card

    local label = Instance.new("TextLabel")
    label.Name = "Label"
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamSemibold
    label.TextSize = 16
    label.TextColor3 = Color3.fromRGB(185, 205, 240)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = definition.label or "Telemetry"
    label.Size = UDim2.new(1, 0, 0, 18)
    label.Parent = card

    local value = Instance.new("TextLabel")
    value.Name = "Value"
    value.BackgroundTransparency = 1
    value.Font = Enum.Font.GothamBlack
    value.TextSize = 26
    value.TextColor3 = DASHBOARD_THEME.headingColor
    value.TextXAlignment = Enum.TextXAlignment.Left
    value.Text = definition.value or "--"
    value.Position = UDim2.new(0, 0, 0, 26)
    value.Size = UDim2.new(1, 0, 0, 28)
    value.Parent = card

    local hint = Instance.new("TextLabel")
    hint.Name = "Hint"
    hint.BackgroundTransparency = 1
    hint.Font = Enum.Font.Gotham
    hint.TextSize = 14
    hint.TextColor3 = Color3.fromRGB(150, 168, 205)
    hint.TextXAlignment = Enum.TextXAlignment.Left
    hint.TextWrapped = true
    hint.Text = definition.hint or ""
    hint.Position = UDim2.new(0, 0, 0, 58)
    hint.Size = UDim2.new(1, 0, 0, 28)
    hint.Parent = card

    return {
        frame = card,
        label = label,
        value = value,
        hint = hint,
    }
end

local function createTelemetrySection(parent, definitions)
    local section = Instance.new("Frame")
    section.Name = "Telemetry"
    section.BackgroundTransparency = 1
    section.LayoutOrder = 3
    section.Size = UDim2.new(1, 0, 0, 0)
    section.AutomaticSize = Enum.AutomaticSize.Y
    section.Parent = parent

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamSemibold
    title.TextSize = 18
    title.TextColor3 = Color3.fromRGB(185, 205, 240)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "Mission telemetry"
    title.Size = UDim2.new(1, 0, 0, 22)
    title.Parent = section

    local grid = Instance.new("Frame")
    grid.Name = "Cards"
    grid.BackgroundTransparency = 1
    grid.Position = UDim2.new(0, 0, 0, 30)
    grid.Size = UDim2.new(1, 0, 0, 0)
    grid.AutomaticSize = Enum.AutomaticSize.Y
    grid.Parent = section

    local layout = Instance.new("UIGridLayout")
    layout.FillDirection = Enum.FillDirection.Horizontal
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.CellSize = UDim2.new(0.5, -12, 0, 110)
    layout.CellPadding = UDim2.new(0, 12, 0, 12)
    layout.VerticalAlignment = Enum.VerticalAlignment.Top
    layout.Parent = grid

    local cards = {}
    for _, definition in ipairs(definitions) do
        local card = createTelemetryCard(grid, definition)
        cards[definition.id or definition.label] = card
    end

    return {
        frame = section,
        grid = grid,
        layout = layout,
        cards = cards,
    }
end

local function createControlToggle(parent, definition, onToggle)
    local row = Instance.new("Frame")
    row.Name = definition.id or (definition.title or "Control")
    row.BackgroundColor3 = DASHBOARD_THEME.controlCardColor
    row.BackgroundTransparency = 0.08
    row.BorderSizePixel = 0
    row.Size = UDim2.new(1, 0, 0, 80)
    row.AutomaticSize = Enum.AutomaticSize.Y
    row.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 14)
    corner.Parent = row

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1
    stroke.Transparency = 0.5
    stroke.Color = DASHBOARD_THEME.controlStrokeColor
    stroke.Parent = row

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 18)
    padding.PaddingBottom = UDim.new(0, 18)
    padding.PaddingLeft = UDim.new(0, 20)
    padding.PaddingRight = UDim.new(0, 20)
    padding.Parent = row

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamSemibold
    title.TextSize = 17
    title.TextColor3 = DASHBOARD_THEME.headingColor
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = definition.title or "Control"
    title.Size = UDim2.new(1, -150, 0, 20)
    title.Parent = row

    local description = Instance.new("TextLabel")
    description.Name = "Description"
    description.BackgroundTransparency = 1
    description.Font = Enum.Font.Gotham
    description.TextSize = 14
    description.TextColor3 = Color3.fromRGB(160, 178, 210)
    description.TextWrapped = true
    description.TextXAlignment = Enum.TextXAlignment.Left
    description.Text = definition.description or ""
    description.Position = UDim2.new(0, 0, 0, 24)
    description.Size = UDim2.new(1, -150, 0, 34)
    description.Parent = row

    local badge
    if definition.badge then
        badge = Instance.new("TextLabel")
        badge.Name = "Badge"
        badge.BackgroundTransparency = 1
        badge.Font = Enum.Font.GothamSemibold
        badge.TextSize = 13
        badge.TextColor3 = Color3.fromRGB(180, 205, 255)
        badge.Text = definition.badge
        badge.TextXAlignment = Enum.TextXAlignment.Left
        badge.Position = UDim2.new(0, 0, 0, 58)
        badge.Size = UDim2.new(0, 80, 0, 18)
        badge.Parent = row
    end

    local switch = Instance.new("TextButton")
    switch.Name = "Switch"
    switch.AutoButtonColor = false
    switch.AnchorPoint = Vector2.new(1, 0.5)
    switch.Position = UDim2.new(1, 0, 0.5, 0)
    switch.Size = UDim2.new(0, 120, 0, 34)
    switch.BackgroundColor3 = DASHBOARD_THEME.toggleOffColor
    switch.TextColor3 = DASHBOARD_THEME.toggleOffTextColor
    switch.Font = Enum.Font.GothamBold
    switch.TextSize = 16
    switch.Text = "OFF"
    switch.BorderSizePixel = 0
    switch.Parent = row

    local switchCorner = Instance.new("UICorner")
    switchCorner.CornerRadius = UDim.new(0, 12)
    switchCorner.Parent = switch

    local currentState = definition.default == true

    local function applyState(state)
        currentState = state
        if state then
            switch.Text = "ON"
            switch.BackgroundColor3 = DASHBOARD_THEME.toggleOnColor
            switch.TextColor3 = DASHBOARD_THEME.toggleOnTextColor
        else
            switch.Text = "OFF"
            switch.BackgroundColor3 = DASHBOARD_THEME.toggleOffColor
            switch.TextColor3 = DASHBOARD_THEME.toggleOffTextColor
        end
    end

    applyState(currentState)

    local connection = switch.MouseButton1Click:Connect(function()
        local nextState = not currentState
        applyState(nextState)
        if typeof(onToggle) == "function" then
            onToggle(nextState)
        end
    end)

    return {
        frame = row,
        badge = badge,
        title = title,
        description = description,
        switch = switch,
        setState = applyState,
        getState = function()
            return currentState
        end,
        connection = connection,
    }
end

local function createControlsSection(parent, definitions, onToggle)
    local section = Instance.new("Frame")
    section.Name = "Controls"
    section.BackgroundTransparency = 1
    section.LayoutOrder = 4
    section.Size = UDim2.new(1, 0, 0, 0)
    section.AutomaticSize = Enum.AutomaticSize.Y
    section.Parent = parent

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamSemibold
    title.TextSize = 18
    title.TextColor3 = Color3.fromRGB(185, 205, 240)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "Control center"
    title.Size = UDim2.new(1, 0, 0, 22)
    title.Parent = section

    local list = Instance.new("Frame")
    list.Name = "List"
    list.BackgroundTransparency = 1
    list.Position = UDim2.new(0, 0, 0, 30)
    list.Size = UDim2.new(1, 0, 0, 0)
    list.AutomaticSize = Enum.AutomaticSize.Y
    list.Parent = section

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 10)
    layout.Parent = list

    local toggles = {}
    for _, definition in ipairs(definitions) do
        local toggle = createControlToggle(list, definition, function(state)
            if typeof(onToggle) == "function" then
                onToggle(definition, state)
            end
        end)
        toggles[definition.id or definition.title] = toggle
    end

    return {
        frame = section,
        list = list,
        layout = layout,
        toggles = toggles,
    }
end

local function createActionsRow(parent)
    local row = Instance.new("Frame")
    row.Name = "Actions"
    row.BackgroundTransparency = 1
    row.LayoutOrder = 5
    row.Size = UDim2.new(1, 0, 0, 0)
    row.AutomaticSize = Enum.AutomaticSize.Y
    row.Visible = false
    row.Parent = parent

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Horizontal
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    layout.Padding = UDim.new(0, 12)
    layout.Parent = row

    return {
        frame = row,
        layout = layout,
    }
end

local function styleActionButton(button, variant)
    if variant == "primary" then
        button.BackgroundColor3 = DASHBOARD_THEME.toggleOnColor
        button.TextColor3 = DASHBOARD_THEME.toggleOnTextColor
    elseif variant == "ghost" then
        button.BackgroundColor3 = Color3.fromRGB(26, 34, 52)
        button.TextColor3 = Color3.fromRGB(200, 216, 245)
    else
        button.BackgroundColor3 = Color3.fromRGB(36, 46, 70)
        button.TextColor3 = Color3.fromRGB(210, 224, 255)
    end
end

function Controller:_applyVisualState(options)
    if self._destroyed then
        return
    end

    options = options or {}
    local enabled = self._enabled

    if self.button then
        if enabled then
            self.button.Text = "Disable AutoParry"
            self.button.BackgroundColor3 = DASHBOARD_THEME.toggleOnColor
            self.button.TextColor3 = DASHBOARD_THEME.toggleOnTextColor
        else
            self.button.Text = "Enable AutoParry"
            self.button.BackgroundColor3 = DASHBOARD_THEME.toggleOffColor
            self.button.TextColor3 = DASHBOARD_THEME.toggleOffTextColor
        end
    end

    if self._header then
        local badge = self._header.badge
        local badgeLabel = self._header.badgeLabel
        if badge and badgeLabel then
            if enabled then
                badge.BackgroundColor3 = DASHBOARD_THEME.badgeActiveColor
                badgeLabel.TextColor3 = DASHBOARD_THEME.badgeTextActive
                badgeLabel.Text = "ACTIVE"
            else
                badge.BackgroundColor3 = DASHBOARD_THEME.badgeIdleColor
                badgeLabel.TextColor3 = DASHBOARD_THEME.badgeTextIdle
                badgeLabel.Text = "IDLE"
            end
        end
    end

    if self._statusCard then
        if (not self._statusManual) or options.forceStatusRefresh then
            if self._statusCard.heading then
                self._statusCard.heading.Text = enabled and "AutoParry active" or "AutoParry standby"
            end
            if self._statusCard.support then
                if enabled then
                    self._statusCard.support.Text = "Assist engine monitoring every ball in play."
                else
                    self._statusCard.support.Text = "Assist engine standing by for activation."
                end
            end
        end
    end
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
    self:_applyVisualState({ forceStatusRefresh = context.forceStatusRefresh })

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

function Controller:getDashboard()
    return self.dashboard
end

function Controller:setTooltip(text)
    if self._statusCard and self._statusCard.tooltip then
        self._statusCard.tooltip.Text = text or ""
        self._statusCard.tooltip.Visible = text ~= nil and text ~= ""
    end
end

function Controller:setHotkeyDisplay(hotkeyText)
    if self._header and self._header.hotkeyLabel then
        self._header.hotkeyLabel.Text = hotkeyText and hotkeyText ~= "" and ("Hotkey: %s"):format(hotkeyText) or ""
    end
    if self._statusCard and self._statusCard.hotkeyLabel then
        self._statusCard.hotkeyLabel.Text = hotkeyText and hotkeyText ~= "" and ("Hotkey: %s"):format(hotkeyText) or ""
    end
end

function Controller:setTagline(text)
    if self._header and self._header.tagline and text then
        self._header.tagline.Text = text
    end
end

function Controller:setStatusText(primary, secondary)
    if not self._statusCard then
        return
    end

    if primary ~= nil and self._statusCard.heading then
        self._statusCard.heading.Text = tostring(primary)
        self._statusManual = true
    end

    if secondary ~= nil and self._statusCard.support then
        self._statusCard.support.Text = tostring(secondary)
        self._statusManual = true
    end
end

function Controller:resetStatusText()
    self._statusManual = false
    self:_applyVisualState({ forceStatusRefresh = true })
end

function Controller:updateTelemetry(id, payload)
    if not self._telemetryCards then
        return
    end

    local card = self._telemetryCards[id]
    if not card then
        return
    end

    if typeof(payload) == "table" then
        if payload.label ~= nil and card.label then
            card.label.Text = tostring(payload.label)
        end
        if payload.value ~= nil and card.value then
            card.value.Text = tostring(payload.value)
        end
        if payload.hint ~= nil and card.hint then
            card.hint.Text = tostring(payload.hint)
        end
    else
        if card.value then
            card.value.Text = tostring(payload)
        end
    end
end

function Controller:setTelemetry(definitions)
    definitions = definitions or DEFAULT_TELEMETRY_CARDS

    if not self._telemetrySection then
        return
    end

    for key, card in pairs(self._telemetryCards or {}) do
        if card and card.frame then
            card.frame:Destroy()
        end
        self._telemetryCards[key] = nil
    end

    local cards = {}
    for _, definition in ipairs(definitions) do
        local card = createTelemetryCard(self._telemetrySection.grid, definition)
        cards[definition.id or definition.label] = card
    end

    self._telemetryCards = cards
    self._telemetryDefinitions = definitions
end

function Controller:getTelemetryDefinitions()
    return self._telemetryDefinitions
end

function Controller:setControls(definitions)
    definitions = definitions or DEFAULT_CONTROL_SWITCHES

    if not self._controlsSection then
        return
    end

    for _, toggle in pairs(self._controlToggles or {}) do
        if toggle.connection then
            toggle.connection:Disconnect()
        end
        if toggle.frame then
            toggle.frame:Destroy()
        end
    end

    self._controlToggles = {}
    self._controlDefinitions = definitions

    for _, definition in ipairs(definitions) do
        local toggle = createControlToggle(self._controlsSection.list, definition, function(state)
            if self._controlChanged then
                self._controlChanged:fire(definition.id or definition.title, state, definition)
            end
        end)
        self._controlToggles[definition.id or definition.title] = toggle
    end
end

function Controller:setControlState(id, enabled)
    if not self._controlToggles then
        return
    end

    local toggle = self._controlToggles[id]
    if not toggle or not toggle.setState then
        return
    end

    toggle.setState(not not enabled)
end

function Controller:getControlState(id)
    if not self._controlToggles then
        return nil
    end

    local toggle = self._controlToggles[id]
    if not toggle or not toggle.getState then
        return nil
    end

    return toggle.getState()
end

function Controller:onControlChanged(callback)
    assert(typeof(callback) == "function", "UI.onControlChanged expects a function")
    return self._controlChanged:connect(callback)
end

function Controller:setActions(actions)
    if not self._actionsRow then
        return
    end

    for _, connection in ipairs(self._actionConnections or {}) do
        connection:Disconnect()
    end
    self._actionConnections = {}

    if self._actionsRow.frame then
        for _, child in ipairs(self._actionsRow.frame:GetChildren()) do
            if child:IsA("TextButton") then
                child:Destroy()
            end
        end
    end

    if typeof(actions) ~= "table" or #actions == 0 then
        if self._actionsRow.frame then
            self._actionsRow.frame.Visible = false
        end
        return
    end

    if self._actionsRow.frame then
        self._actionsRow.frame.Visible = true
    end

    for _, action in ipairs(actions) do
        local button = Instance.new("TextButton")
        button.Name = action.id or (action.text or "Action")
        button.AutoButtonColor = false
        button.Size = UDim2.new(0, math.max(130, action.minWidth or 150), 0, 38)
        button.BackgroundColor3 = Color3.fromRGB(36, 46, 70)
        button.TextColor3 = Color3.fromRGB(215, 228, 255)
        button.Font = Enum.Font.GothamBold
        button.TextSize = 17
        button.Text = action.text or action.id or "Action"
        button.BorderSizePixel = 0
        button.Parent = self._actionsRow.frame

        styleActionButton(button, action.variant or (action.primary and "primary") or action.style)

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 12)
        corner.Parent = button

        local connection = button.MouseButton1Click:Connect(function()
            if typeof(action.callback) == "function" then
                action.callback(action, self)
            end
        end)
        table.insert(self._actionConnections, connection)
    end
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

    for _, connection in ipairs(self._actionConnections or {}) do
        connection:Disconnect()
    end
    self._actionConnections = {}

    if self._controlToggles then
        for _, toggle in pairs(self._controlToggles) do
            if toggle.connection then
                toggle.connection:Disconnect()
            end
        end
        self._controlToggles = {}
    end

    if self._controlChanged then
        self._controlChanged:destroy()
        self._controlChanged = nil
    end

    if self._hotkeyConnection then
        self._hotkeyConnection:Disconnect()
        self._hotkeyConnection = nil
    end

    if self.gui then
        self.gui:Destroy()
        self.gui = nil
    end

    self.dashboard = nil
    self.button = nil
    self._header = nil
    self._statusCard = nil
    self._telemetrySection = nil
    self._telemetryCards = nil
    self._controlsSection = nil
    self._actionsRow = nil

    if self._changed then
        self._changed:destroy()
        self._changed = nil
    end
end

function UI.mount(options)
    options = options or {}

    local gui = ensureGuiRoot("AutoParryUI")
    local dashboard, content = createDashboardFrame(gui)

    local rawHotkey = options.hotkey
    local hotkeyDescriptor = parseHotkey(rawHotkey)
    local hotkeyDisplay = formatHotkeyDisplay(hotkeyDescriptor and hotkeyDescriptor.key and hotkeyDescriptor or rawHotkey)

    local header = createHeader(content, options.title or "AutoParry", hotkeyDisplay)
    if typeof(options.tagline) == "string" then
        header.tagline.Text = options.tagline
    end

    local statusCard = createStatusCard(content)
    statusCard.tooltip.Text = options.tooltip or ""
    statusCard.tooltip.Visible = options.tooltip ~= nil and options.tooltip ~= ""
    statusCard.hotkeyLabel.Text = hotkeyDisplay and ("Hotkey: %s"):format(hotkeyDisplay) or ""

    local telemetryDefinitions = options.telemetry or DEFAULT_TELEMETRY_CARDS
    local telemetry = createTelemetrySection(content, telemetryDefinitions)

    local controlSignal = Util.Signal.new()
    local controlDefinitions = options.controls or DEFAULT_CONTROL_SWITCHES
    local controls = createControlsSection(content, controlDefinitions, function(definition, state)
        controlSignal:fire(definition.id or definition.title, state, definition)
    end)

    local actions = createActionsRow(content)

    local controller = setmetatable({
        gui = gui,
        dashboard = dashboard,
        button = statusCard.button,
        _enabled = false,
        _statusManual = false,
        _onToggle = options.onToggle,
        _connections = {},
        _actionConnections = {},
        _telemetrySection = telemetry,
        _telemetryCards = telemetry.cards,
        _telemetryDefinitions = telemetryDefinitions,
        _controlsSection = controls,
        _controlDefinitions = controlDefinitions,
        _controlToggles = controls.toggles,
        _changed = Util.Signal.new(),
        _controlChanged = controlSignal,
        _header = header,
        _statusCard = statusCard,
    }, Controller)

    controller:setHotkeyDisplay(hotkeyDisplay)

    if options.statusText or options.statusSupport then
        controller:setStatusText(options.statusText, options.statusSupport)
    end

    local buttonConnection = statusCard.button.MouseButton1Click:Connect(function()
        controller:toggle()
    end)
    table.insert(controller._connections, buttonConnection)

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

    controller:_applyVisualState({ forceStatusRefresh = true })
    controller:setTooltip(options.tooltip)

    local overlay = LoadingOverlay.getActive and LoadingOverlay.getActive()
    if overlay and not overlay:isComplete() then
        dashboard.Visible = false
        gui.Enabled = false
    else
        gui.Enabled = true
    end

    if overlay and not overlay:isComplete() then
        local connection
        connection = overlay:onCompleted(function()
            if controller._destroyed then
                return
            end
            dashboard.Visible = true
            gui.Enabled = true
            if connection then
                connection:Disconnect()
                connection = nil
            end
        end)
        table.insert(controller._connections, connection)
    end

    controller:setEnabled(options.initialState == true, { silent = true, forceStatusRefresh = true })

    return controller
end

function UI.createLoadingOverlay(options)
    return LoadingOverlay.create(options)
end

function UI.getLoadingOverlay()
    if LoadingOverlay.getActive then
        return LoadingOverlay.getActive()
    end
    return nil
end

return UI

