-- mikkel32/AutoParry : src/ui/init.lua
-- selene: allow(global_usage)
-- Professional dashboard controller for AutoParry with status, telemetry,
-- control toggles, and hotkey support. The module exposes a lightweight API
-- used by the runtime to keep the UI in sync with the parry core while giving
-- downstream experiences room to customise the presentation.

local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Require = rawget(_G, "ARequire")
local Util = Require("src/shared/util.lua")
local LoadingOverlay = Require("src/ui/loading_overlay.lua")
local DiagnosticsPanel = Require("src/ui/diagnostics_panel.lua")

local UI = {}

local Controller = {}
Controller.__index = Controller

local DASHBOARD_THEME = {
    widths = {
        min = 360,
        medium = 480,
        large = 620,
    },
    minContentWidth = 280,
    breakpoints = {
        medium = 900,
        large = 1280,
    },
    spacing = {
        padding = {
            min = 18,
            medium = 22,
            large = 26,
        },
        paddingY = {
            min = 20,
            medium = 26,
            large = 30,
        },
        blockGap = {
            min = 14,
            medium = 18,
            large = 22,
        },
        columnGap = {
            min = 0,
            medium = 18,
            large = 24,
        },
        sectionGap = {
            min = 14,
            medium = 16,
            large = 18,
        },
        cardGap = {
            min = 12,
            medium = 14,
            large = 16,
        },
        cardPadding = {
            min = 16,
            medium = 20,
            large = 24,
        },
        controlPadding = {
            min = 18,
            medium = 22,
            large = 26,
        },
        marginX = {
            min = 20,
            medium = 40,
            large = 48,
        },
        marginTop = {
            min = 70,
            medium = 120,
            large = 140,
        },
        minMargin = 12,
    },
    telemetryCardHeight = 116,
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

local DEFAULT_VIEWPORT_SIZE = Vector2.new(DASHBOARD_THEME.widths.medium, 720)

local function getLoaderProgressAndSignals()
    local loaderState = rawget(_G, "AutoParryLoader")
    if typeof(loaderState) ~= "table" then
        return nil, nil
    end

    local context = loaderState.context
    local progress = (typeof(context) == "table" and context.progress) or loaderState.progress
    local signals = (typeof(context) == "table" and context.signals) or loaderState.signals

    if typeof(progress) ~= "table" then
        progress = nil
    end
    if typeof(signals) ~= "table" then
        signals = nil
    end

    return progress, signals
end

local function isLoaderInProgress(progress)
    if typeof(progress) ~= "table" then
        return false
    end

    local started = tonumber(progress.started) or 0
    local finished = tonumber(progress.finished) or 0
    local failed = tonumber(progress.failed) or 0

    if started <= 0 then
        return false
    end

    return finished + failed < started
end

local function getActiveOverlay()
    if typeof(LoadingOverlay) == "table" and typeof(LoadingOverlay.getActive) == "function" then
        local ok, overlayInstance = pcall(LoadingOverlay.getActive)
        if ok then
            return overlayInstance
        end
    end

    return nil
end

local function getBreakpointForViewport(viewportSize)
    local width = viewportSize and viewportSize.X or DEFAULT_VIEWPORT_SIZE.X
    if DASHBOARD_THEME.breakpoints and DASHBOARD_THEME.breakpoints.large and width >= DASHBOARD_THEME.breakpoints.large then
        return "large"
    end
    if DASHBOARD_THEME.breakpoints and DASHBOARD_THEME.breakpoints.medium and width >= DASHBOARD_THEME.breakpoints.medium then
        return "medium"
    end
    return "min"
end

local function getResponsiveValue(values, breakpoint)
    if not values then
        return nil
    end

    local value = values[breakpoint]
    if value ~= nil then
        return value
    end

    if breakpoint == "large" then
        value = values.medium or values.min
    elseif breakpoint == "medium" then
        value = values.large or values.min
    else
        value = values.medium or values.large
    end

    if value ~= nil then
        return value
    end

    return values.default or values.min or values.medium or values.large
end

local function resolveLayoutMetrics(viewportSize)
    viewportSize = viewportSize or DEFAULT_VIEWPORT_SIZE
    local viewportWidth = viewportSize.X
    if viewportWidth <= 0 then
        viewportWidth = DEFAULT_VIEWPORT_SIZE.X
    end

    local breakpoint = getBreakpointForViewport(viewportSize)
    local desiredWidth = getResponsiveValue(DASHBOARD_THEME.widths, breakpoint) or DASHBOARD_THEME.widths.medium
    local minContentWidth = DASHBOARD_THEME.minContentWidth or desiredWidth
    local marginX = getResponsiveValue(DASHBOARD_THEME.spacing.marginX, breakpoint) or 24
    local minMargin = DASHBOARD_THEME.spacing.minMargin or 12
    marginX = math.max(minMargin, marginX)

    local availableWidth = math.max(viewportWidth - (marginX * 2), 0)
    if availableWidth < minContentWidth then
        local adjustedMargin = math.max(minMargin, math.floor((viewportWidth - minContentWidth) / 2))
        marginX = adjustedMargin
        availableWidth = math.max(viewportWidth - (marginX * 2), 0)
    end

    local effectiveMin = math.min(minContentWidth, availableWidth)
    if effectiveMin <= 0 then
        effectiveMin = math.min(minContentWidth, math.max(viewportWidth - (minMargin * 2), 0))
    end

    local effectiveMax = math.max(availableWidth, effectiveMin)
    if effectiveMax <= 0 then
        effectiveMax = math.max(effectiveMin, math.max(viewportWidth - (minMargin * 2), 0))
    end

    local resolvedWidth = math.clamp(desiredWidth, effectiveMin, effectiveMax)
    if resolvedWidth <= 0 then
        resolvedWidth = effectiveMax > 0 and effectiveMax or math.max(desiredWidth, math.max(viewportWidth - (minMargin * 2), 0))
    end
    resolvedWidth = math.min(resolvedWidth, viewportWidth)

    local topOffset = getResponsiveValue(DASHBOARD_THEME.spacing.marginTop, breakpoint) or 120
    local paddingX = getResponsiveValue(DASHBOARD_THEME.spacing.padding, breakpoint) or 20
    local paddingY = getResponsiveValue(DASHBOARD_THEME.spacing.paddingY, breakpoint) or paddingX
    local blockGap = getResponsiveValue(DASHBOARD_THEME.spacing.blockGap, breakpoint) or 16
    local columnGap = getResponsiveValue(DASHBOARD_THEME.spacing.columnGap, breakpoint) or 0
    local sectionGap = getResponsiveValue(DASHBOARD_THEME.spacing.sectionGap, breakpoint) or 14
    local cardGap = getResponsiveValue(DASHBOARD_THEME.spacing.cardGap, breakpoint) or sectionGap
    local cardPadding = getResponsiveValue(DASHBOARD_THEME.spacing.cardPadding, breakpoint) or 18
    local controlPadding = getResponsiveValue(DASHBOARD_THEME.spacing.controlPadding, breakpoint) or cardPadding
    local splitColumns = breakpoint ~= "min"
    local telemetryColumns = splitColumns and 2 or 1
    local controlSwitchWidth = splitColumns and 120 or 108

    return {
        breakpoint = breakpoint,
        width = math.floor(resolvedWidth + 0.5),
        sideMargin = marginX,
        topOffset = topOffset,
        paddingX = paddingX,
        paddingY = paddingY,
        blockGap = blockGap,
        columnGap = columnGap,
        sectionGap = sectionGap,
        cardGap = cardGap,
        cardPadding = cardPadding,
        controlPadding = controlPadding,
        splitColumns = splitColumns,
        telemetryColumns = telemetryColumns,
        telemetryCardHeight = DASHBOARD_THEME.telemetryCardHeight,
        controlSwitchWidth = controlSwitchWidth,
    }
end

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
    frame.AnchorPoint = Vector2.new(0.5, 0)
    frame.Position = UDim2.new(0.5, 0, 0, 0)
    frame.Size = UDim2.new(0, DASHBOARD_THEME.widths.medium, 0, 0)
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
    content.Size = UDim2.new(1, 0, 0, 0)
    content.AutomaticSize = Enum.AutomaticSize.Y
    content.Parent = frame

    local padding = Instance.new("UIPadding")
    padding.Parent = content

    local layout = Instance.new("UIFlexLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    layout.VerticalAlignment = Enum.VerticalAlignment.Top
    layout.Wraps = false
    layout.Padding = UDim.new(0, DASHBOARD_THEME.spacing.blockGap.min)
    layout.Parent = content

    local columnsContainer = Instance.new("Frame")
    columnsContainer.Name = "Columns"
    columnsContainer.BackgroundTransparency = 1
    columnsContainer.Size = UDim2.new(1, 0, 0, 0)
    columnsContainer.AutomaticSize = Enum.AutomaticSize.Y
    columnsContainer.LayoutOrder = 3
    columnsContainer.Parent = content

    local columnsLayout = Instance.new("UIFlexLayout")
    columnsLayout.FillDirection = Enum.FillDirection.Horizontal
    columnsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    columnsLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    columnsLayout.Wraps = true
    columnsLayout.SortOrder = Enum.SortOrder.LayoutOrder
    columnsLayout.Parent = columnsContainer

    local leftColumn = Instance.new("Frame")
    leftColumn.Name = "LeftColumn"
    leftColumn.BackgroundTransparency = 1
    leftColumn.Size = UDim2.new(1, 0, 0, 0)
    leftColumn.AutomaticSize = Enum.AutomaticSize.Y
    leftColumn.LayoutOrder = 1
    leftColumn.Parent = columnsContainer

    local leftLayout = Instance.new("UIListLayout")
    leftLayout.FillDirection = Enum.FillDirection.Vertical
    leftLayout.SortOrder = Enum.SortOrder.LayoutOrder
    leftLayout.Padding = UDim.new(0, DASHBOARD_THEME.spacing.sectionGap.min)
    leftLayout.Parent = leftColumn

    local rightColumn = Instance.new("Frame")
    rightColumn.Name = "RightColumn"
    rightColumn.BackgroundTransparency = 1
    rightColumn.Size = UDim2.new(1, 0, 0, 0)
    rightColumn.AutomaticSize = Enum.AutomaticSize.Y
    rightColumn.LayoutOrder = 2
    rightColumn.Parent = columnsContainer

    local rightLayout = Instance.new("UIListLayout")
    rightLayout.FillDirection = Enum.FillDirection.Vertical
    rightLayout.SortOrder = Enum.SortOrder.LayoutOrder
    rightLayout.Padding = UDim.new(0, DASHBOARD_THEME.spacing.sectionGap.min)
    rightLayout.Parent = rightColumn

    local shell = {}
    local metricListeners = {}
    local currentMetrics

    function shell:getMetrics()
        return currentMetrics
    end

    function shell:addMetricListener(callback)
        assert(typeof(callback) == "function", "Dashboard shell expects a function listener")
        local listener = {
            callback = callback,
            connected = true,
        }
        table.insert(metricListeners, listener)
        if currentMetrics then
            callback(currentMetrics)
        end

        return function()
            listener.connected = false
        end
    end

    function shell:applyMetrics(metrics)
        if not metrics then
            return
        end

        currentMetrics = metrics

        frame.Size = UDim2.new(0, metrics.width, 0, 0)
        frame.Position = UDim2.new(0.5, 0, 0, metrics.topOffset)

        padding.PaddingLeft = UDim.new(0, metrics.paddingX)
        padding.PaddingRight = UDim.new(0, metrics.paddingX)
        padding.PaddingTop = UDim.new(0, metrics.paddingY)
        padding.PaddingBottom = UDim.new(0, metrics.paddingY)

        layout.Padding = UDim.new(0, metrics.blockGap)

        columnsLayout.Padding = UDim.new(0, metrics.columnGap)
        columnsLayout.HorizontalAlignment = metrics.splitColumns and Enum.HorizontalAlignment.Left or Enum.HorizontalAlignment.Center

        local columnOffset = math.floor((metrics.columnGap or 0) / 2)
        if metrics.splitColumns then
            leftColumn.Size = UDim2.new(0.5, -columnOffset, 0, 0)
            rightColumn.Size = UDim2.new(0.5, -columnOffset, 0, 0)
        else
            leftColumn.Size = UDim2.new(1, 0, 0, 0)
            rightColumn.Size = UDim2.new(1, 0, 0, 0)
        end

        leftLayout.Padding = UDim.new(0, metrics.sectionGap)
        rightLayout.Padding = UDim.new(0, metrics.sectionGap)

        for index = #metricListeners, 1, -1 do
            local listener = metricListeners[index]
            if listener.connected and listener.callback then
                listener.callback(metrics)
            else
                table.remove(metricListeners, index)
            end
        end
    end

    shell.content = content
    shell.layout = layout
    shell.padding = padding
    shell.columns = {
        left = leftColumn,
        right = rightColumn,
    }
    shell.columnLayouts = {
        left = leftLayout,
        right = rightLayout,
    }
    shell.columnsContainer = columnsContainer
    shell.columnsLayout = columnsLayout

    return frame, shell
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

local function createDashboardCard(shell, parent, options)
    options = options or {}

    local card = Instance.new("Frame")
    card.Name = options.name or "Card"
    card.BackgroundColor3 = options.backgroundColor or DASHBOARD_THEME.telemetryCardColor
    card.BackgroundTransparency = options.backgroundTransparency or 0.08
    card.BorderSizePixel = 0
    card.Size = UDim2.new(1, 0, 0, 0)
    card.AutomaticSize = Enum.AutomaticSize.Y
    card.LayoutOrder = options.layoutOrder or 0
    card.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, options.cornerRadius or 14)
    corner.Parent = card

    if options.strokeColor then
        local stroke = Instance.new("UIStroke")
        stroke.Thickness = options.strokeThickness or 1
        stroke.Transparency = options.strokeTransparency or 0.5
        stroke.Color = options.strokeColor
        stroke.Parent = card
    end

    local padding = Instance.new("UIPadding")
    padding.Parent = card

    local function apply(metrics)
        local basePadding
        if options.paddingToken == "control" then
            basePadding = metrics and metrics.controlPadding or DASHBOARD_THEME.spacing.controlPadding.medium
        else
            basePadding = metrics and metrics.cardPadding or DASHBOARD_THEME.spacing.cardPadding.medium
        end

        local top = options.paddingTop or basePadding
        local bottom = options.paddingBottom or basePadding
        local left = options.paddingLeft or options.horizontalPadding or basePadding
        local right = options.paddingRight or options.horizontalPadding or basePadding

        if typeof(options.padding) == "function" then
            local resolved = options.padding(metrics) or {}
            top = resolved.top or resolved.y or resolved.vertical or top
            bottom = resolved.bottom or resolved.y or resolved.vertical or bottom
            left = resolved.left or resolved.x or resolved.horizontal or left
            right = resolved.right or resolved.x or resolved.horizontal or right
        elseif typeof(options.padding) == "table" then
            top = options.padding.top or options.padding[1] or options.padding.y or options.padding.vertical or top
            bottom = options.padding.bottom or options.padding[2] or options.padding.y or options.padding.vertical or bottom
            left = options.padding.left or options.padding[3] or options.padding.x or options.padding.horizontal or left
            right = options.padding.right or options.padding[4] or options.padding.x or options.padding.horizontal or right
        end

        padding.PaddingTop = UDim.new(0, top)
        padding.PaddingBottom = UDim.new(0, bottom)
        padding.PaddingLeft = UDim.new(0, left)
        padding.PaddingRight = UDim.new(0, right)
    end

    apply(nil)

    local disconnect
    if shell and shell.addMetricListener then
        local function onMetrics(metrics)
            if not card.Parent then
                if disconnect then
                    disconnect()
                    disconnect = nil
                end
                return
            end

            apply(metrics)
        end

        local remover = shell:addMetricListener(onMetrics)
        disconnect = function()
            remover()
        end

        card.AncestryChanged:Connect(function(_, parent)
            if not parent and disconnect then
                disconnect()
                disconnect = nil
            end
        end)
    end

    return card, padding
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

local function createTelemetryCard(shell, parent, definition)
    local card = createDashboardCard(shell, parent, {
        name = definition.id or "Telemetry",
        backgroundColor = DASHBOARD_THEME.telemetryCardColor,
        backgroundTransparency = 0.1,
        strokeColor = DASHBOARD_THEME.telemetryStrokeColor,
        strokeTransparency = 0.5,
        padding = function(metrics)
            local base = metrics and metrics.cardPadding or DASHBOARD_THEME.spacing.cardPadding.medium
            return {
                top = base,
                bottom = base,
                horizontal = base + 2,
            }
        end,
    })

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

local function createTelemetrySection(shell, definitions)
    local section = Instance.new("Frame")
    section.Name = "Telemetry"
    section.BackgroundTransparency = 1
    section.LayoutOrder = 3
    section.Size = UDim2.new(1, 0, 0, 0)
    section.AutomaticSize = Enum.AutomaticSize.Y
    local targetParent
    if shell then
        if shell.columns and shell.columns.left then
            targetParent = shell.columns.left
        elseif shell.content then
            targetParent = shell.content
        end
    end
    section.Parent = targetParent

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

    local function applyMetrics(metrics)
        if not layout.Parent then
            return
        end

        local columns = metrics and metrics.telemetryColumns or 1
        local gap = metrics and metrics.cardGap or 12
        local height = metrics and metrics.telemetryCardHeight or DASHBOARD_THEME.telemetryCardHeight

        if columns > 1 then
            layout.CellSize = UDim2.new(1 / columns, -gap, 0, height)
        else
            layout.CellSize = UDim2.new(1, 0, 0, height)
        end
        layout.CellPadding = UDim2.new(0, gap, 0, gap)
    end

    if shell and shell.addMetricListener then
        local disconnect = shell:addMetricListener(applyMetrics)
        section.AncestryChanged:Connect(function(_, parentFrame)
            if not parentFrame then
                disconnect()
            end
        end)
    else
        applyMetrics(nil)
    end

    for _, definition in ipairs(definitions) do
        local card = createTelemetryCard(shell, grid, definition)
        cards[definition.id or definition.label] = card
    end

    return {
        frame = section,
        grid = grid,
        layout = layout,
        cards = cards,
        applyMetrics = applyMetrics,
    }
end

local function createControlToggle(shell, parent, definition, onToggle)
    local row = createDashboardCard(shell, parent, {
        name = definition.id or (definition.title or "Control"),
        backgroundColor = DASHBOARD_THEME.controlCardColor,
        backgroundTransparency = 0.08,
        strokeColor = DASHBOARD_THEME.controlStrokeColor,
        paddingToken = "control",
        padding = function(metrics)
            local base = metrics and metrics.controlPadding or DASHBOARD_THEME.spacing.controlPadding.medium
            return {
                top = base,
                bottom = base,
                horizontal = base + 2,
            }
        end,
    })

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamSemibold
    title.TextSize = 17
    title.TextColor3 = DASHBOARD_THEME.headingColor
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = definition.title or "Control"
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

    local function applyResponsiveMetrics(metrics)
        local switchWidth = metrics and metrics.controlSwitchWidth or 120
        local spacing = 24
        switch.Size = UDim2.new(0, switchWidth, 0, 34)
        title.Size = UDim2.new(1, -(switchWidth + spacing), 0, 20)
        description.Size = UDim2.new(1, -(switchWidth + spacing), 0, 34)
    end

    applyResponsiveMetrics(shell and shell:getMetrics())

    if shell and shell.addMetricListener then
        local disconnect = shell:addMetricListener(function(metrics)
            if not row.Parent then
                disconnect()
                return
            end
            applyResponsiveMetrics(metrics)
        end)

        row.AncestryChanged:Connect(function(_, parentFrame)
            if not parentFrame then
                disconnect()
            end
        end)
    end

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

local function createControlsSection(shell, definitions, onToggle)
    local section = Instance.new("Frame")
    section.Name = "Controls"
    section.BackgroundTransparency = 1
    section.LayoutOrder = 4
    section.Size = UDim2.new(1, 0, 0, 0)
    section.AutomaticSize = Enum.AutomaticSize.Y
    local targetParent
    if shell then
        if shell.columns and shell.columns.right then
            targetParent = shell.columns.right
        elseif shell.content then
            targetParent = shell.content
        end
    end
    section.Parent = targetParent

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
    layout.Padding = UDim.new(0, 12)
    layout.Parent = list

    local function applyMetrics(metrics)
        if metrics then
            layout.Padding = UDim.new(0, metrics.sectionGap)
        end
    end

    if shell and shell.addMetricListener then
        local disconnect = shell:addMetricListener(function(metrics)
            if not section.Parent then
                disconnect()
                return
            end
            applyMetrics(metrics)
        end)

        section.AncestryChanged:Connect(function(_, parentFrame)
            if not parentFrame then
                disconnect()
            end
        end)
    end

    local toggles = {}
    for _, definition in ipairs(definitions) do
        local toggle = createControlToggle(shell, list, definition, function(state)
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

local function createDiagnosticsSection(shell, options)
    local section = Instance.new("Frame")
    section.Name = "Diagnostics"
    section.BackgroundTransparency = 1
    section.Size = UDim2.new(1, 0, 0, 0)
    section.AutomaticSize = Enum.AutomaticSize.Y
    section.LayoutOrder = 1

    local targetParent
    if shell then
        if shell.columns and shell.columns.right then
            targetParent = shell.columns.right
        elseif shell.content then
            targetParent = shell.content
        end
    end

    section.Parent = targetParent

    local panel = DiagnosticsPanel.new({
        parent = section,
        theme = options and options.theme,
    })

    return {
        frame = section,
        panel = panel,
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

function Controller:getColumns()
    if self._shell and self._shell.columns then
        return self._shell.columns
    end
    return nil
end

function Controller:getLayoutMetrics()
    if self._shell and self._shell.getMetrics then
        self._layoutMetrics = self._layoutMetrics or self._shell:getMetrics()
    end
    return self._layoutMetrics
end

function Controller:getDiagnosticsPanel()
    return self._diagnostics
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
        local card = createTelemetryCard(self._shell, self._telemetrySection.grid, definition)
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
        local toggle = createControlToggle(self._shell, self._controlsSection.list, definition, function(state)
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

function Controller:resetDiagnostics()
    if self._diagnostics then
        self._diagnostics:reset()
    end
end

function Controller:setDiagnosticsStages(stages)
    if self._diagnostics then
        self._diagnostics:setStages(stages)
    end
end

function Controller:pushDiagnosticsEvent(event)
    if self._diagnostics then
        self._diagnostics:pushEvent(event)
    end
end

function Controller:showDiagnosticsError(errorInfo)
    if self._diagnostics then
        self._diagnostics:showError(errorInfo)
    end
end

function Controller:setDiagnosticsFilter(filterId)
    if self._diagnostics and self._diagnostics.setFilter then
        self._diagnostics:setFilter(filterId)
    end
end

function Controller:setDiagnosticsCollapsed(sectionId, collapsed)
    if self._diagnostics and self._diagnostics.setCollapsed then
        self._diagnostics:setCollapsed(sectionId, collapsed)
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

    if self._diagnostics then
        self._diagnostics:destroy()
        self._diagnostics = nil
    end

    if self.gui then
        self.gui:Destroy()
        self.gui = nil
    end

    if self._viewportSizeConnection then
        self._viewportSizeConnection:Disconnect()
        self._viewportSizeConnection = nil
    end

    if self._workspaceCameraConnection then
        self._workspaceCameraConnection:Disconnect()
        self._workspaceCameraConnection = nil
    end

    self.dashboard = nil
    self.button = nil
    self._header = nil
    self._statusCard = nil
    self._telemetrySection = nil
    self._telemetryCards = nil
    self._controlsSection = nil
    self._diagnosticsSection = nil
    self._actionsRow = nil
    self._shell = nil
    self._columns = nil
    self._layoutMetrics = nil

    if self._changed then
        self._changed:destroy()
        self._changed = nil
    end
end

function UI.mount(options)
    options = options or {}

    local gui = ensureGuiRoot("AutoParryUI")
    local dashboard, shell = createDashboardFrame(gui)

    if dashboard then
        dashboard.Visible = false
    end
    if gui then
        gui.Enabled = false
    end

    local camera = Workspace.CurrentCamera
    if camera then
        shell:applyMetrics(resolveLayoutMetrics(camera.ViewportSize))
    else
        shell:applyMetrics(resolveLayoutMetrics(DEFAULT_VIEWPORT_SIZE))
    end

    local rawHotkey = options.hotkey
    local hotkeyDescriptor = parseHotkey(rawHotkey)
    local hotkeyDisplay = formatHotkeyDisplay(hotkeyDescriptor and hotkeyDescriptor.key and hotkeyDescriptor or rawHotkey)

    local header = createHeader(shell.content, options.title or "AutoParry", hotkeyDisplay)
    if typeof(options.tagline) == "string" then
        header.tagline.Text = options.tagline
    end

    local statusCard = createStatusCard(shell.content)
    statusCard.tooltip.Text = options.tooltip or ""
    statusCard.tooltip.Visible = options.tooltip ~= nil and options.tooltip ~= ""
    statusCard.hotkeyLabel.Text = hotkeyDisplay and ("Hotkey: %s"):format(hotkeyDisplay) or ""

    local telemetryDefinitions = options.telemetry or DEFAULT_TELEMETRY_CARDS
    local telemetry = createTelemetrySection(shell, telemetryDefinitions)

    local diagnostics = createDiagnosticsSection(shell, options and options.diagnostics)

    local controlSignal = Util.Signal.new()
    local controlDefinitions = options.controls or DEFAULT_CONTROL_SWITCHES
    local controls = createControlsSection(shell, controlDefinitions, function(definition, state)
        controlSignal:fire(definition.id or definition.title, state, definition)
    end)

    local actions = createActionsRow(shell.content)

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
        _shell = shell,
        _columns = shell.columns,
        _layoutMetrics = shell:getMetrics(),
        _diagnosticsSection = diagnostics,
        _diagnostics = diagnostics and diagnostics.panel,
        _loaderPending = false,
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

    if shell and shell.addMetricListener then
        local metricDisconnect = shell:addMetricListener(function(metrics)
            controller._layoutMetrics = metrics
        end)
        table.insert(controller._connections, {
            Disconnect = function()
                metricDisconnect()
            end,
        })
    end

    local function applyViewportMetrics(currentCamera)
        if controller._destroyed then
            return
        end

        if currentCamera then
            shell:applyMetrics(resolveLayoutMetrics(currentCamera.ViewportSize))
        else
            shell:applyMetrics(resolveLayoutMetrics(DEFAULT_VIEWPORT_SIZE))
        end
    end

    local function bindCamera(newCamera)
        if controller._viewportSizeConnection then
            controller._viewportSizeConnection:Disconnect()
            controller._viewportSizeConnection = nil
        end

        if not newCamera then
            applyViewportMetrics(nil)
            return
        end

        applyViewportMetrics(newCamera)

        controller._viewportSizeConnection = newCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
            if controller._destroyed then
                return
            end
            applyViewportMetrics(newCamera)
        end)
    end

    bindCamera(camera)

    controller._workspaceCameraConnection = Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
        if controller._destroyed then
            return
        end
        bindCamera(Workspace.CurrentCamera)
    end)

    controller:_applyVisualState({ forceStatusRefresh = true })
    controller:setTooltip(options.tooltip)

    local function trackConnection(connection)
        if connection ~= nil then
            table.insert(controller._connections, connection)
        end
    end

    local function updateVisibility()
        if controller._destroyed then
            return
        end

        local overlayInstance = getActiveOverlay()
        local overlayBlocking = overlayInstance and not overlayInstance:isComplete()
        local shouldShow = not overlayBlocking and not controller._loaderPending

        if dashboard then
            dashboard.Visible = shouldShow
        end
        if gui then
            gui.Enabled = shouldShow
        end
    end

    local overlayInstance = getActiveOverlay()
    if overlayInstance and not overlayInstance:isComplete() then
        trackConnection(overlayInstance:onCompleted(function()
            updateVisibility()
        end))
    end

    local refreshLoaderPending

    local function attachLoaderSignals(signals)
        if typeof(signals) ~= "table" then
            return
        end

        local function attach(signal)
            if typeof(signal) == "table" and typeof(signal.Connect) == "function" then
                local ok, connection = pcall(function()
                    return signal:Connect(function()
                        refreshLoaderPending()
                    end)
                end)
                if ok and connection then
                    trackConnection(connection)
                end
            end
        end

        attach(signals.onFetchStarted)
        attach(signals.onFetchCompleted)
        attach(signals.onFetchFailed)
        attach(signals.onAllComplete)
    end

    local loaderProgress, loaderSignals = getLoaderProgressAndSignals()
    controller._loaderPending = isLoaderInProgress(loaderProgress)

    refreshLoaderPending = function()
        local progress, signals = getLoaderProgressAndSignals()
        controller._loaderPending = isLoaderInProgress(progress)
        if signals and signals ~= loaderSignals then
            loaderSignals = signals
            attachLoaderSignals(signals)
        end
        updateVisibility()
    end

    if loaderSignals then
        attachLoaderSignals(loaderSignals)
    end

    updateVisibility()

    task.spawn(function()
        local observedOverlay = overlayInstance
        while not controller._destroyed do
            refreshLoaderPending()

            local currentOverlay = getActiveOverlay()
            if currentOverlay ~= observedOverlay then
                observedOverlay = currentOverlay
                if currentOverlay and not currentOverlay:isComplete() then
                    trackConnection(currentOverlay:onCompleted(function()
                        updateVisibility()
                    end))
                end
                updateVisibility()
            elseif currentOverlay and not currentOverlay:isComplete() and controller._loaderPending then
                updateVisibility()
            end

            if not controller._loaderPending and (not currentOverlay or currentOverlay:isComplete()) then
                task.wait(0.5)
            else
                task.wait(0.15)
            end
        end
    end)

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

