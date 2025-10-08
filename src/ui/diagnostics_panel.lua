-- mikkel32/AutoParry : src/ui/diagnostics_panel.lua
-- Diagnostics side panel that visualises verification stages, loader/parry
-- event history, and surfaced errors. Built to remain available after the
-- onboarding overlay fades so players can keep digging into what happened.

local TweenService = game:GetService("TweenService")

local Require = rawget(_G, "ARequire")
local Util = Require and Require("src/shared/util.lua")

local DiagnosticsPanel = {}
DiagnosticsPanel.__index = DiagnosticsPanel

local DEFAULT_THEME = {
    backgroundColor = Color3.fromRGB(20, 24, 32),
    backgroundTransparency = 0.08,
    strokeColor = Color3.fromRGB(72, 108, 172),
    strokeTransparency = 0.65,
    sectionCorner = UDim.new(0, 14),
    sectionPadding = 16,
    sectionSpacing = 12,
    headerFont = Enum.Font.GothamSemibold,
    headerTextSize = 18,
    headerTextColor = Color3.fromRGB(210, 224, 250),
    headerInactiveColor = Color3.fromRGB(140, 156, 190),
    headerIcon = "rbxassetid://6031090990",
    bodyPadding = 14,
    statusFonts = {
        title = Enum.Font.GothamSemibold,
        message = Enum.Font.Gotham,
        detail = Enum.Font.Gotham,
    },
    statusTextSizes = {
        title = 16,
        message = 14,
        detail = 13,
    },
    stageBackground = Color3.fromRGB(26, 30, 40),
    stageTransparency = 0.05,
    stageStrokeColor = Color3.fromRGB(82, 132, 200),
    stageStrokeTransparency = 0.52,
    stageCorner = UDim.new(0, 12),
    stageSpacing = 10,
    statusColors = {
        pending = Color3.fromRGB(132, 148, 188),
        active = Color3.fromRGB(112, 198, 255),
        ok = Color3.fromRGB(118, 228, 182),
        warning = Color3.fromRGB(255, 198, 110),
        failed = Color3.fromRGB(248, 110, 128),
    },
    statusTextColor = Color3.fromRGB(198, 212, 240),
    statusDetailColor = Color3.fromRGB(160, 176, 210),
    statusDetailTransparency = 0.2,
    iconAssets = {
        pending = "rbxassetid://6031071050",
        active = "rbxassetid://6031075929",
        ok = "rbxassetid://6031068421",
        warning = "rbxassetid://6031071051",
        failed = "rbxassetid://6031094678",
    },
    filterButton = {
        font = Enum.Font.Gotham,
        textSize = 14,
        activeColor = Color3.fromRGB(82, 156, 255),
        inactiveColor = Color3.fromRGB(48, 60, 86),
        activeText = Color3.fromRGB(12, 16, 26),
        inactiveText = Color3.fromRGB(198, 212, 240),
        corner = UDim.new(0, 10),
        padding = Vector2.new(12, 6),
    },
    eventBackground = Color3.fromRGB(24, 28, 36),
    eventTransparency = 0.04,
    eventStrokeColor = Color3.fromRGB(70, 106, 170),
    eventStrokeTransparency = 0.65,
    eventCorner = UDim.new(0, 10),
    eventListHeight = 240,
    eventListPadding = Vector2.new(10, 8),
    eventScrollBarThickness = 6,
    eventScrollBarColor = Color3.fromRGB(82, 156, 255),
    eventScrollBarTransparency = 0.25,
    eventMessageFont = Enum.Font.Gotham,
    eventMessageSize = 14,
    eventDetailSize = 13,
    eventTagFont = Enum.Font.GothamSemibold,
    eventTagSize = 13,
    severityColors = {
        info = Color3.fromRGB(120, 170, 240),
        success = Color3.fromRGB(118, 228, 182),
        warning = Color3.fromRGB(255, 198, 110),
        error = Color3.fromRGB(248, 110, 128),
    },
    badge = {
        background = Color3.fromRGB(48, 56, 76),
        backgroundResolved = Color3.fromRGB(36, 42, 58),
        textActive = Color3.fromRGB(232, 242, 255),
        textResolved = Color3.fromRGB(160, 176, 210),
        corner = UDim.new(0, 10),
        font = Enum.Font.GothamSemibold,
        textSize = 14,
        padding = Vector2.new(12, 8),
    },
    overview = {
        backgroundColor = Color3.fromRGB(26, 30, 40),
        backgroundTransparency = 0.08,
        strokeColor = Color3.fromRGB(82, 156, 255),
        strokeTransparency = 0.6,
        accentColor = Color3.fromRGB(112, 198, 255),
        successColor = Color3.fromRGB(118, 228, 182),
        warningColor = Color3.fromRGB(255, 198, 110),
        dangerColor = Color3.fromRGB(248, 110, 128),
        headerFont = Enum.Font.GothamSemibold,
        headerTextSize = 13,
        headerColor = Color3.fromRGB(176, 192, 224),
        valueFont = Enum.Font.GothamBlack,
        valueTextSize = 24,
        valueColor = Color3.fromRGB(232, 242, 255),
        detailFont = Enum.Font.Gotham,
        detailTextSize = 13,
        detailColor = Color3.fromRGB(160, 176, 210),
        chipCorner = UDim.new(0, 12),
        padding = Vector2.new(18, 16),
    },
}

local DEFAULT_STAGES = {
    { id = "player", title = "Player readiness", description = "Ensure your avatar is loaded." },
    { id = "remotes", title = "Game remotes", description = "Connect to Blade Ball remotes." },
    { id = "success", title = "Success feedback", description = "Listen for parry success events." },
    { id = "balls", title = "Ball telemetry", description = "Track balls for prediction." },
}

local DEFAULT_FILTERS = {
    { id = "all", label = "All" },
    { id = "loader", label = "Loader" },
    { id = "parry", label = "Parry" },
    { id = "warnings", label = "Warnings" },
    { id = "errors", label = "Errors" },
}

local DEFAULT_STAGE_MAP = {}
for _, definition in ipairs(DEFAULT_STAGES) do
    DEFAULT_STAGE_MAP[definition.id] = definition
end

local STAGE_STATUS_PRIORITY = {
    failed = 5,
    warning = 4,
    active = 3,
    pending = 2,
    ok = 1,
}

local function deepCopy(data)
    if Util and Util.deepCopy then
        return Util.deepCopy(data)
    end

    if typeof(data) ~= "table" then
        return data
    end

    local copy = {}
    for key, value in pairs(data) do
        copy[key] = deepCopy(value)
    end
    return copy
end

local function mergeTheme(theme)
    if typeof(theme) ~= "table" then
        return deepCopy(DEFAULT_THEME)
    end

    local merged = deepCopy(DEFAULT_THEME)
    for key, value in pairs(theme) do
        merged[key] = value
    end
    return merged
end

local function createSection(theme, parent, name, layoutOrder)
    local container = Instance.new("Frame")
    container.Name = name .. "Section"
    container.BackgroundColor3 = theme.backgroundColor
    container.BackgroundTransparency = theme.backgroundTransparency
    container.BorderSizePixel = 0
    container.AutomaticSize = Enum.AutomaticSize.Y
    container.Size = UDim2.new(1, 0, 0, 0)
    container.LayoutOrder = layoutOrder or 1
    container.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = theme.sectionCorner
    corner.Parent = container

    local stroke = Instance.new("UIStroke")
    stroke.Color = theme.strokeColor
    stroke.Transparency = theme.strokeTransparency
    stroke.Parent = container

    local header = Instance.new("TextButton")
    header.Name = "Header"
    header.AutoButtonColor = false
    header.BackgroundTransparency = 1
    header.BorderSizePixel = 0
    header.Size = UDim2.new(1, -theme.sectionPadding * 2, 0, 36)
    header.Position = UDim2.new(0, theme.sectionPadding, 0, theme.sectionPadding)
    header.Font = theme.headerFont
    header.TextSize = theme.headerTextSize
    header.TextColor3 = theme.headerTextColor
    header.TextXAlignment = Enum.TextXAlignment.Left
    header.Text = name
    header.Parent = container

    local icon = Instance.new("ImageLabel")
    icon.Name = "Chevron"
    icon.BackgroundTransparency = 1
    icon.Size = UDim2.new(0, 16, 0, 16)
    icon.Position = UDim2.new(1, -4, 0.5, 0)
    icon.AnchorPoint = Vector2.new(1, 0.5)
    icon.Image = theme.headerIcon
    icon.ImageColor3 = theme.headerTextColor
    icon.Parent = header

    local body = Instance.new("Frame")
    body.Name = "Body"
    body.BackgroundTransparency = 1
    body.Position = UDim2.new(0, theme.sectionPadding, 0, theme.sectionPadding + header.Size.Y.Offset + theme.sectionSpacing)
    body.Size = UDim2.new(1, -theme.sectionPadding * 2, 0, 0)
    body.AutomaticSize = Enum.AutomaticSize.Y
    body.Parent = container

    local bodyLayout = Instance.new("UIListLayout")
    bodyLayout.FillDirection = Enum.FillDirection.Vertical
    bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
    bodyLayout.Padding = UDim.new(0, theme.sectionSpacing)
    bodyLayout.Parent = body

    local section = {
        frame = container,
        header = header,
        chevron = icon,
        body = body,
        layout = bodyLayout,
        collapsed = false,
        theme = theme,
    }

    function section:setCollapsed(collapsed)
        collapsed = not not collapsed
        if self.collapsed == collapsed then
            return
        end

        self.collapsed = collapsed
        body.Visible = not collapsed
        header.TextColor3 = collapsed and theme.headerInactiveColor or theme.headerTextColor

        local rotation = collapsed and 90 or 0
        local tween = TweenService:Create(icon, TweenInfo.new(0.18, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {
            Rotation = rotation,
        })
        tween:Play()

        if collapsed then
            container.AutomaticSize = Enum.AutomaticSize.None
            container.Size = UDim2.new(1, 0, 0, header.Size.Y.Offset + theme.sectionPadding * 2)
        else
            container.AutomaticSize = Enum.AutomaticSize.Y
            container.Size = UDim2.new(1, 0, 0, 0)
        end
    end

    header.MouseButton1Click:Connect(function()
        section:setCollapsed(not section.collapsed)
    end)

    return section
end

local function createStageRow(theme, parent, definition)
    local frame = Instance.new("Frame")
    frame.Name = definition.id or "Stage"
    frame.BackgroundColor3 = theme.stageBackground
    frame.BackgroundTransparency = theme.stageTransparency
    frame.BorderSizePixel = 0
    frame.AutomaticSize = Enum.AutomaticSize.None
    frame.Size = UDim2.new(1, 0, 0, 90)
    frame.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = theme.stageCorner
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color = theme.stageStrokeColor
    stroke.Transparency = theme.stageStrokeTransparency
    stroke.Parent = frame

    local accent = Instance.new("Frame")
    accent.Name = "Accent"
    accent.AnchorPoint = Vector2.new(0, 0.5)
    accent.Position = UDim2.new(0, -2, 0.5, 0)
    accent.Size = UDim2.new(0, 6, 1, -24)
    accent.BorderSizePixel = 0
    accent.BackgroundColor3 = theme.statusColors.pending
    accent.BackgroundTransparency = 0.35
    accent.Parent = frame

    local accentCorner = Instance.new("UICorner")
    accentCorner.CornerRadius = UDim.new(1, 0)
    accentCorner.Parent = accent

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, theme.bodyPadding)
    padding.PaddingBottom = UDim.new(0, theme.bodyPadding)
    padding.PaddingLeft = UDim.new(0, theme.bodyPadding)
    padding.PaddingRight = UDim.new(0, theme.bodyPadding)
    padding.Parent = frame

    local icon = Instance.new("ImageLabel")
    icon.Name = "StatusIcon"
    icon.BackgroundTransparency = 1
    icon.Size = UDim2.new(0, 24, 0, 24)
    icon.Position = UDim2.new(0, 0, 0, 0)
    icon.Image = theme.iconAssets.pending
    icon.ImageColor3 = theme.statusColors.pending
    icon.Parent = frame

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.BackgroundTransparency = 1
    title.Position = UDim2.new(0, 32, 0, 0)
    title.Size = UDim2.new(1, -32, 0, 20)
    title.Font = theme.statusFonts.title
    title.TextSize = theme.statusTextSizes.title
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextColor3 = theme.statusTextColor
    title.Text = definition.title or "Stage"
    title.Parent = frame

    local message = Instance.new("TextLabel")
    message.Name = "Message"
    message.BackgroundTransparency = 1
    message.Position = UDim2.new(0, 32, 0, 22)
    message.Size = UDim2.new(1, -32, 0, 18)
    message.Font = theme.statusFonts.message
    message.TextSize = theme.statusTextSizes.message
    message.TextXAlignment = Enum.TextXAlignment.Left
    message.TextColor3 = theme.statusDetailColor
    message.Text = definition.description or ""
    message.TextWrapped = true
    message.Parent = frame

    local detail = Instance.new("TextLabel")
    detail.Name = "Detail"
    detail.BackgroundTransparency = 1
    detail.Position = UDim2.new(0, 32, 0, 42)
    detail.Size = UDim2.new(1, -32, 0, 16)
    detail.Font = theme.statusFonts.detail
    detail.TextSize = theme.statusTextSizes.detail
    detail.TextXAlignment = Enum.TextXAlignment.Left
    detail.TextColor3 = theme.statusDetailColor
    detail.TextTransparency = theme.statusDetailTransparency
    detail.TextWrapped = true
    detail.Visible = false
    detail.Parent = frame

    return {
        frame = frame,
        accent = accent,
        icon = icon,
        title = title,
        message = message,
        detail = detail,
    }
end

local function formatElapsed(startClock, timestamp)
    if not timestamp or not startClock then
        return nil
    end
    local seconds = math.max(0, timestamp - startClock)
    if seconds >= 120 then
        return string.format("+%d s", math.floor(seconds + 0.5))
    end
    return string.format("+%.1f s", seconds)
end

local function createEventRow(theme, parent, event, startClock)
    local frame = Instance.new("Frame")
    frame.Name = string.format("Event%d", event.sequence or 0)
    frame.BackgroundColor3 = theme.eventBackground
    frame.BackgroundTransparency = theme.eventTransparency
    frame.BorderSizePixel = 0
    frame.AutomaticSize = Enum.AutomaticSize.Y
    frame.Size = UDim2.new(1, 0, 0, 48)
    frame.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = theme.eventCorner
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color = theme.eventStrokeColor
    stroke.Transparency = theme.eventStrokeTransparency
    stroke.Parent = frame

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, theme.bodyPadding)
    padding.PaddingBottom = UDim.new(0, theme.bodyPadding)
    padding.PaddingLeft = UDim.new(0, theme.bodyPadding)
    padding.PaddingRight = UDim.new(0, theme.bodyPadding)
    padding.Parent = frame

    local tag = Instance.new("TextLabel")
    tag.Name = "Tag"
    tag.BackgroundTransparency = 1
    tag.Size = UDim2.new(0, 70, 0, 18)
    tag.Font = theme.eventTagFont
    tag.TextSize = theme.eventTagSize
    tag.TextXAlignment = Enum.TextXAlignment.Left
    tag.TextColor3 = theme.statusDetailColor
    tag.Text = string.upper(event.kind or "")
    tag.Parent = frame

    local timeLabel = Instance.new("TextLabel")
    timeLabel.Name = "Timestamp"
    timeLabel.BackgroundTransparency = 1
    timeLabel.Size = UDim2.new(0, 70, 0, 18)
    timeLabel.Position = UDim2.new(1, -70, 0, 0)
    timeLabel.Font = theme.eventTagFont
    timeLabel.TextSize = theme.eventTagSize
    timeLabel.TextXAlignment = Enum.TextXAlignment.Right
    timeLabel.TextColor3 = theme.statusDetailColor
    timeLabel.Text = formatElapsed(startClock, event.timestamp)
    timeLabel.Parent = frame

    local message = Instance.new("TextLabel")
    message.Name = "Message"
    message.BackgroundTransparency = 1
    message.Position = UDim2.new(0, 0, 0, 20)
    message.Size = UDim2.new(1, 0, 0, 20)
    message.Font = theme.eventMessageFont
    message.TextSize = theme.eventMessageSize
    message.TextXAlignment = Enum.TextXAlignment.Left
    message.TextColor3 = theme.statusTextColor
    message.TextWrapped = true
    message.Text = event.message or ""
    message.Parent = frame

    local detail = Instance.new("TextLabel")
    detail.Name = "Detail"
    detail.BackgroundTransparency = 1
    detail.Position = UDim2.new(0, 0, 0, 40)
    detail.Size = UDim2.new(1, 0, 0, 16)
    detail.Font = theme.eventMessageFont
    detail.TextSize = theme.eventDetailSize
    detail.TextXAlignment = Enum.TextXAlignment.Left
    detail.TextColor3 = theme.statusDetailColor
    detail.TextTransparency = 0.1
    detail.TextWrapped = true
    detail.Visible = false
    detail.Parent = frame

    return {
        frame = frame,
        tag = tag,
        timestamp = timeLabel,
        message = message,
        detail = detail,
    }
end

local function createBadge(theme, parent, id)
    local frame = Instance.new("Frame")
    frame.Name = id or "Badge"
    frame.BackgroundColor3 = theme.badge.background
    frame.BackgroundTransparency = 0
    frame.BorderSizePixel = 0
    frame.Size = UDim2.new(0, 0, 0, 30)
    frame.AutomaticSize = Enum.AutomaticSize.X
    frame.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = theme.badge.corner
    corner.Parent = frame

    local padding = Instance.new("UIPadding")
    padding.PaddingLeft = UDim.new(0, theme.badge.padding.X)
    padding.PaddingRight = UDim.new(0, theme.badge.padding.X)
    padding.PaddingTop = UDim.new(0, theme.badge.padding.Y)
    padding.PaddingBottom = UDim.new(0, theme.badge.padding.Y)
    padding.Parent = frame

    local label = Instance.new("TextLabel")
    label.Name = "Label"
    label.BackgroundTransparency = 1
    label.Font = theme.badge.font
    label.TextSize = theme.badge.textSize
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextColor3 = theme.badge.textActive
    label.Text = id or "Error"
    label.Parent = frame

    return {
        frame = frame,
        label = label,
    }
end

local function createOverviewCard(theme, parent, id, title)
    local config = theme.overview or DEFAULT_THEME.overview

    local frame = Instance.new("Frame")
    frame.Name = string.format("Overview_%s", id or "Card")
    frame.BackgroundColor3 = config.backgroundColor or DEFAULT_THEME.overview.backgroundColor
    frame.BackgroundTransparency = config.backgroundTransparency or DEFAULT_THEME.overview.backgroundTransparency or 0.08
    frame.BorderSizePixel = 0
    frame.AutomaticSize = Enum.AutomaticSize.Y
    frame.Size = UDim2.new(1, 0, 0, 0)
    frame.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = config.chipCorner or DEFAULT_THEME.overview.chipCorner or UDim.new(0, 12)
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color = config.strokeColor or DEFAULT_THEME.overview.strokeColor
    stroke.Transparency = config.strokeTransparency or DEFAULT_THEME.overview.strokeTransparency or 0.6
    stroke.Thickness = 1.2
    stroke.Parent = frame

    local padding = config.padding or DEFAULT_THEME.overview.padding or Vector2.new(18, 16)
    local contentPadding = Instance.new("UIPadding")
    contentPadding.PaddingTop = UDim.new(0, padding.Y)
    contentPadding.PaddingBottom = UDim.new(0, padding.Y)
    contentPadding.PaddingLeft = UDim.new(0, padding.X)
    contentPadding.PaddingRight = UDim.new(0, padding.X)
    contentPadding.Parent = frame

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 6)
    layout.Parent = frame

    local header = Instance.new("TextLabel")
    header.Name = "Label"
    header.BackgroundTransparency = 1
    header.Font = config.headerFont or DEFAULT_THEME.overview.headerFont
    header.TextSize = config.headerTextSize or DEFAULT_THEME.overview.headerTextSize
    header.TextColor3 = config.headerColor or DEFAULT_THEME.overview.headerColor
    header.TextXAlignment = Enum.TextXAlignment.Left
    header.Text = string.upper(title or id or "Overview")
    header.Size = UDim2.new(1, 0, 0, math.max(20, (config.headerTextSize or DEFAULT_THEME.overview.headerTextSize) + 6))
    header.LayoutOrder = 1
    header.Parent = frame

    local value = Instance.new("TextLabel")
    value.Name = "Value"
    value.BackgroundTransparency = 1
    value.Font = config.valueFont or DEFAULT_THEME.overview.valueFont
    value.TextSize = config.valueTextSize or DEFAULT_THEME.overview.valueTextSize
    value.TextColor3 = config.valueColor or DEFAULT_THEME.overview.valueColor
    value.TextXAlignment = Enum.TextXAlignment.Left
    value.Text = "--"
    value.Size = UDim2.new(1, 0, 0, value.TextSize + 6)
    value.LayoutOrder = 2
    value.Parent = frame

    local detail = Instance.new("TextLabel")
    detail.Name = "Detail"
    detail.BackgroundTransparency = 1
    detail.Font = config.detailFont or DEFAULT_THEME.overview.detailFont
    detail.TextSize = config.detailTextSize or DEFAULT_THEME.overview.detailTextSize
    detail.TextColor3 = config.detailColor or DEFAULT_THEME.overview.detailColor
    detail.TextXAlignment = Enum.TextXAlignment.Left
    detail.TextWrapped = true
    detail.Text = "Awaiting data"
    detail.Size = UDim2.new(1, 0, 0, math.max(18, detail.TextSize + 4))
    detail.LayoutOrder = 3
    detail.Parent = frame

    return {
        frame = frame,
        stroke = stroke,
        title = header,
        value = value,
        detail = detail,
    }
end

function DiagnosticsPanel.new(options)
    options = options or {}
    local parent = assert(options.parent, "DiagnosticsPanel.new requires a parent")

    local theme = mergeTheme(options.theme)

    local frame = Instance.new("Frame")
    frame.Name = options.name or "DiagnosticsPanel"
    frame.BackgroundTransparency = 1
    frame.Size = UDim2.new(1, 0, 0, 0)
    frame.AutomaticSize = Enum.AutomaticSize.Y
    frame.Parent = parent

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, (theme.sectionSpacing or 12) + 4)
    layout.Parent = frame

    local overviewRow = Instance.new("Frame")
    overviewRow.Name = "OverviewRow"
    overviewRow.BackgroundTransparency = 1
    overviewRow.Size = UDim2.new(1, 0, 0, 0)
    overviewRow.AutomaticSize = Enum.AutomaticSize.Y
    overviewRow.LayoutOrder = 1
    overviewRow.Parent = frame

    local overviewLayout = Instance.new("UIListLayout")
    overviewLayout.FillDirection = Enum.FillDirection.Horizontal
    overviewLayout.SortOrder = Enum.SortOrder.LayoutOrder
    overviewLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    overviewLayout.Padding = UDim.new(0, theme.sectionSpacing or 12)
    overviewLayout.Parent = overviewRow

    local overviewCards = {
        status = createOverviewCard(theme, overviewRow, "status", "Verification"),
        events = createOverviewCard(theme, overviewRow, "events", "Events"),
        alerts = createOverviewCard(theme, overviewRow, "alerts", "Alerts"),
    }
    overviewCards.status.frame.LayoutOrder = 1
    overviewCards.events.frame.LayoutOrder = 2
    overviewCards.alerts.frame.LayoutOrder = 3

    local contentRow = Instance.new("Frame")
    contentRow.Name = "ContentRow"
    contentRow.BackgroundTransparency = 1
    contentRow.Size = UDim2.new(1, 0, 0, 0)
    contentRow.AutomaticSize = Enum.AutomaticSize.Y
    contentRow.LayoutOrder = 2
    contentRow.Parent = frame

    local contentLayout = Instance.new("UIListLayout")
    contentLayout.FillDirection = Enum.FillDirection.Vertical
    contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
    contentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    contentLayout.Padding = UDim.new(0, theme.sectionSpacing or 12)
    contentLayout.Parent = contentRow

    local primaryColumn = Instance.new("Frame")
    primaryColumn.Name = "PrimaryColumn"
    primaryColumn.BackgroundTransparency = 1
    primaryColumn.AutomaticSize = Enum.AutomaticSize.Y
    primaryColumn.Size = UDim2.new(1, 0, 0, 0)
    primaryColumn.LayoutOrder = 1
    primaryColumn.Parent = contentRow

    local primaryLayout = Instance.new("UIListLayout")
    primaryLayout.FillDirection = Enum.FillDirection.Vertical
    primaryLayout.SortOrder = Enum.SortOrder.LayoutOrder
    primaryLayout.Padding = UDim.new(0, theme.sectionSpacing)
    primaryLayout.Parent = primaryColumn

    local secondaryColumn = Instance.new("Frame")
    secondaryColumn.Name = "SecondaryColumn"
    secondaryColumn.BackgroundTransparency = 1
    secondaryColumn.AutomaticSize = Enum.AutomaticSize.Y
    secondaryColumn.Size = UDim2.new(1, 0, 0, 0)
    secondaryColumn.LayoutOrder = 2
    secondaryColumn.Parent = contentRow

    local secondaryLayout = Instance.new("UIListLayout")
    secondaryLayout.FillDirection = Enum.FillDirection.Vertical
    secondaryLayout.SortOrder = Enum.SortOrder.LayoutOrder
    secondaryLayout.Padding = UDim.new(0, theme.sectionSpacing)
    secondaryLayout.Parent = secondaryColumn

    local stagesSection = createSection(theme, primaryColumn, "Verification stages", 1)
    local eventsSection = createSection(theme, secondaryColumn, "Event history", 1)
    local errorsSection = createSection(theme, primaryColumn, "Alerts", 2)

    local stageGrid = Instance.new("Frame")
    stageGrid.Name = "StageGrid"
    stageGrid.BackgroundTransparency = 1
    stageGrid.Size = UDim2.new(1, 0, 0, 0)
    stageGrid.AutomaticSize = Enum.AutomaticSize.Y
    stageGrid.Parent = stagesSection.body

    local stageLayout = Instance.new("UIGridLayout")
    stageLayout.FillDirection = Enum.FillDirection.Horizontal
    stageLayout.SortOrder = Enum.SortOrder.LayoutOrder
    stageLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    stageLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    stageLayout.CellPadding = UDim2.new(0, theme.sectionSpacing, 0, theme.sectionSpacing)
    stageLayout.CellSize = UDim2.new(1, 0, 0, 90)
    stageLayout.Parent = stageGrid

    local stageRows = {}
    local stageOrder = {}
    for index, definition in ipairs(DEFAULT_STAGES) do
        local row = createStageRow(theme, stageGrid, definition)
        row.frame.LayoutOrder = index
        stageRows[definition.id] = row
        stageOrder[index] = definition.id
    end

    local filterRow = Instance.new("Frame")
    filterRow.Name = "Filters"
    filterRow.BackgroundTransparency = 1
    filterRow.Size = UDim2.new(1, 0, 0, 32)
    filterRow.Parent = eventsSection.body

    local filterLayout = Instance.new("UIListLayout")
    filterLayout.FillDirection = Enum.FillDirection.Horizontal
    filterLayout.SortOrder = Enum.SortOrder.LayoutOrder
    filterLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    filterLayout.Padding = UDim.new(0, 8)
    filterLayout.Parent = filterRow

    local filterButtons = {}

    local eventBase = theme.eventBackground or DEFAULT_THEME.eventBackground
    local accentColor = (theme.filterButton and theme.filterButton.activeColor)
        or (theme.statusColors and theme.statusColors.active)
        or (DEFAULT_THEME.statusColors and DEFAULT_THEME.statusColors.active)
        or Color3.fromRGB(112, 198, 255)

    local eventViewport = Instance.new("Frame")
    eventViewport.Name = "EventViewport"
    eventViewport.BackgroundColor3 = eventBase
    eventViewport.BackgroundTransparency = theme.eventTransparency or DEFAULT_THEME.eventTransparency or 0.04
    eventViewport.BorderSizePixel = 0
    eventViewport.AutomaticSize = Enum.AutomaticSize.None
    eventViewport.Size = UDim2.new(1, 0, 0, theme.eventListHeight or DEFAULT_THEME.eventListHeight)
    eventViewport.ClipsDescendants = true
    eventViewport.Parent = eventsSection.body

    local eventViewportCorner = Instance.new("UICorner")
    eventViewportCorner.CornerRadius = theme.eventCorner or DEFAULT_THEME.eventCorner or UDim.new(0, 10)
    eventViewportCorner.Parent = eventViewport

    local eventViewportStroke = Instance.new("UIStroke")
    eventViewportStroke.Color = theme.eventStrokeColor or DEFAULT_THEME.eventStrokeColor
    eventViewportStroke.Transparency = theme.eventStrokeTransparency or DEFAULT_THEME.eventStrokeTransparency or 0.4
    eventViewportStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    eventViewportStroke.Parent = eventViewport

    local viewportGradient = Instance.new("UIGradient")
    viewportGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, eventBase:Lerp(accentColor, 0.08)),
        ColorSequenceKeypoint.new(1, eventBase),
    })
    viewportGradient.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, math.clamp((theme.eventTransparency or 0.04) + 0.05, 0, 1)),
        NumberSequenceKeypoint.new(1, 0.35),
    })
    viewportGradient.Rotation = 90
    viewportGradient.Parent = eventViewport

    local viewportPadding = Instance.new("UIPadding")
    viewportPadding.PaddingTop = UDim.new(0, 6)
    viewportPadding.PaddingBottom = UDim.new(0, 6)
    viewportPadding.PaddingLeft = UDim.new(0, 6)
    viewportPadding.PaddingRight = UDim.new(0, 6)
    viewportPadding.Parent = eventViewport

    local eventList = Instance.new("ScrollingFrame")
    eventList.Name = "Events"
    eventList.Active = true
    eventList.BackgroundTransparency = 1
    eventList.BorderSizePixel = 0
    eventList.AutomaticSize = Enum.AutomaticSize.None
    eventList.Size = UDim2.new(1, 0, 1, 0)
    eventList.CanvasSize = UDim2.new(0, 0, 0, 0)
    eventList.AutomaticCanvasSize = Enum.AutomaticSize.Y
    eventList.ScrollBarThickness = theme.eventScrollBarThickness or DEFAULT_THEME.eventScrollBarThickness or 6
    eventList.ScrollBarImageColor3 = theme.eventScrollBarColor or DEFAULT_THEME.eventScrollBarColor
    eventList.ScrollBarImageTransparency = theme.eventScrollBarTransparency or DEFAULT_THEME.eventScrollBarTransparency or 0.2
    eventList.ScrollingDirection = Enum.ScrollingDirection.Y
    eventList.ElasticBehavior = Enum.ElasticBehavior.Never
    eventList.Parent = eventViewport
    eventsSection.list = eventList

    local eventPadding = theme.eventListPadding or DEFAULT_THEME.eventListPadding or Vector2.new(10, 8)
    local eventListPadding = Instance.new("UIPadding")
    eventListPadding.PaddingTop = UDim.new(0, eventPadding.Y)
    eventListPadding.PaddingBottom = UDim.new(0, eventPadding.Y)
    eventListPadding.PaddingLeft = UDim.new(0, eventPadding.X)
    eventListPadding.PaddingRight = UDim.new(0, eventPadding.X)
    eventListPadding.Parent = eventList

    local eventLayout = Instance.new("UIListLayout")
    eventLayout.FillDirection = Enum.FillDirection.Vertical
    eventLayout.SortOrder = Enum.SortOrder.LayoutOrder
    eventLayout.Padding = UDim.new(0, theme.sectionSpacing)
    eventLayout.Parent = eventList

    local badges = Instance.new("Frame")
    badges.Name = "Badges"
    badges.BackgroundTransparency = 1
    badges.Size = UDim2.new(1, 0, 0, 32)
    badges.AutomaticSize = Enum.AutomaticSize.Y
    badges.Parent = errorsSection.body

    local badgesLayout = Instance.new("UIListLayout")
    badgesLayout.FillDirection = Enum.FillDirection.Horizontal
    badgesLayout.SortOrder = Enum.SortOrder.LayoutOrder
    badgesLayout.Padding = UDim.new(0, 8)
    badgesLayout.Parent = badges

    local self = setmetatable({
        _theme = theme,
        frame = frame,
        _sections = {
            stages = stagesSection,
            events = eventsSection,
            errors = errorsSection,
        },
        _overviewRow = overviewRow,
        _overviewLayout = overviewLayout,
        _overviewCards = overviewCards,
        _contentRow = contentRow,
        _contentLayout = contentLayout,
        _primaryColumn = primaryColumn,
        _secondaryColumn = secondaryColumn,
        _primaryLayout = primaryLayout,
        _secondaryLayout = secondaryLayout,
        _stageGrid = stageGrid,
        _stageLayout = stageLayout,
        _stageRows = stageRows,
        _stageOrder = stageOrder,
        _events = {},
        _eventRows = {},
        _eventsList = eventList,
        _filters = {},
        _filterButtons = filterButtons,
        _filterRow = filterRow,
        _filterLayout = filterLayout,
        _activeFilter = nil,
        _badges = {},
        _badgesFrame = badges,
        _badgesLayout = badgesLayout,
        _startClock = os.clock(),
        _metrics = {
            totalStages = #stageOrder,
            readyStages = 0,
            warningStages = 0,
            failedStages = 0,
            activeStage = nil,
            events = 0,
            loaderEvents = 0,
            parryEvents = 0,
            warnings = 0,
            errors = 0,
            activeAlerts = 0,
            lastEvent = nil,
        },
        _connections = {},
        _destroyed = false,
    }, DiagnosticsPanel)

    for _, filter in ipairs(DEFAULT_FILTERS) do
        local button = Instance.new("TextButton")
        button.Name = string.format("Filter_%s", filter.id)
        button.AutoButtonColor = false
        button.BackgroundColor3 = theme.filterButton.inactiveColor
        button.TextColor3 = theme.filterButton.inactiveText
        button.Font = theme.filterButton.font
        button.TextSize = theme.filterButton.textSize
        button.Text = filter.label or filter.id
        button.BorderSizePixel = 0
        button.Size = UDim2.new(0, math.max(60, button.TextBounds.X + theme.filterButton.padding.X * 2), 0, 26)
        button.Parent = filterRow

        local corner = Instance.new("UICorner")
        corner.CornerRadius = theme.filterButton.corner
        corner.Parent = button

        self._filters[filter.id] = filter
        self._filterButtons[filter.id] = button

        button.MouseButton1Click:Connect(function()
            self:setFilter(filter.id)
        end)
    end

    self:setFilter("all")
    self:_refreshOverview()
    self:_installResponsiveHandlers()

    return self
end

function DiagnosticsPanel:_styleStageRow(row, stage)
    if not row then
        return
    end

    local status = stage.status or "pending"
    local theme = self._theme
    local colors = theme.statusColors
    local iconAssets = theme.iconAssets

    row.title.Text = stage.title or row.title.Text
    row.message.Text = stage.message or stage.description or ""
    row.detail.Visible = stage.detail ~= nil and stage.detail ~= ""
    row.detail.Text = stage.detail or ""

    local color = colors[status] or colors.pending
    row.icon.Image = iconAssets[status] or iconAssets.pending
    row.icon.ImageColor3 = color
    row.title.TextColor3 = color
    row.message.TextColor3 = theme.statusTextColor
    row.detail.TextColor3 = theme.statusDetailColor

    if row.accent then
        row.accent.BackgroundColor3 = color
        row.accent.BackgroundTransparency = (status == "pending" or status == "active") and 0.35 or 0.1
    end

    if row.frame then
        local base = theme.stageBackground
        local emphasis = status == "ok" and 0.08 or (status == "failed" and 0.2 or 0.14)
        row.frame.BackgroundColor3 = base:Lerp(color, emphasis)
    end
end

function DiagnosticsPanel:_updateStageMetrics(stageMap)
    local metrics = self._metrics
    if not metrics then
        return
    end

    local ready = 0
    local warning = 0
    local failed = 0
    local focusScore = -math.huge
    local focusInfo = nil

    for _, id in ipairs(self._stageOrder or {}) do
        local stage = stageMap[id]
        if stage then
            local status = stage.status or "pending"
            if status == "ok" then
                ready += 1
            elseif status == "warning" then
                warning += 1
            elseif status == "failed" then
                failed += 1
            end

            local score = STAGE_STATUS_PRIORITY[status] or 0
            if status ~= "ok" and score >= focusScore then
                focusScore = score
                local label = stage.title or stage.message or stage.description or stage.id or id
                focusInfo = {
                    id = id,
                    title = label,
                    status = status,
                }
            end
        end
    end

    metrics.totalStages = #(self._stageOrder or {})
    metrics.readyStages = ready
    metrics.warningStages = warning
    metrics.failedStages = failed
    metrics.activeStage = focusInfo
end

function DiagnosticsPanel:_registerEventMetrics(event)
    local metrics = self._metrics
    if not metrics then
        return
    end

    metrics.events = (metrics.events or 0) + 1
    if event.kind == "loader" then
        metrics.loaderEvents = (metrics.loaderEvents or 0) + 1
    elseif event.kind == "parry" then
        metrics.parryEvents = (metrics.parryEvents or 0) + 1
    end

    if event.severity == "warning" then
        metrics.warnings = (metrics.warnings or 0) + 1
    elseif event.severity == "error" then
        metrics.errors = (metrics.errors or 0) + 1
    end

    metrics.lastEvent = {
        kind = event.kind,
        message = event.message,
        detail = event.detail,
        timestamp = event.timestamp,
    }
end

function DiagnosticsPanel:_recountActiveAlerts()
    local metrics = self._metrics
    if not metrics then
        return
    end

    local active = 0
    for _, badge in pairs(self._badges) do
        if badge.active then
            active += 1
        end
    end

    metrics.activeAlerts = active
end

function DiagnosticsPanel:_refreshOverview()
    if self._destroyed then
        return
    end

    local cards = self._overviewCards
    if not cards then
        return
    end

    local theme = self._theme or DEFAULT_THEME
    local overviewTheme = theme.overview or DEFAULT_THEME.overview
    local metrics = self._metrics or {}

    local totalStages = metrics.totalStages or #(self._stageOrder or {})
    local readyStages = metrics.readyStages or 0
    local statusCard = cards.status
    if statusCard then
        statusCard.value.Text = string.format("%d/%d", readyStages, totalStages)
        local focus = metrics.activeStage
        if readyStages >= totalStages and totalStages > 0 then
            statusCard.value.TextColor3 = overviewTheme.successColor or overviewTheme.valueColor
            statusCard.detail.Text = "All verification stages passed"
        else
            statusCard.value.TextColor3 = overviewTheme.accentColor or overviewTheme.valueColor
            if focus then
                statusCard.detail.Text = string.format("Focus: %s", tostring(focus.title or focus.id or "stage"))
            else
                statusCard.detail.Text = "Awaiting verification data"
            end
        end
    end

    local eventsCard = cards.events
    if eventsCard then
        local eventsTotal = metrics.events or 0
        eventsCard.value.Text = tostring(eventsTotal)
        eventsCard.value.TextColor3 = overviewTheme.valueColor or Color3.new(1, 1, 1)
        local loader = metrics.loaderEvents or 0
        local parry = metrics.parryEvents or 0
        local lastEvent = metrics.lastEvent
        local summary = string.format("Loader %d • Parry %d", loader, parry)
        if lastEvent then
            local elapsed = formatElapsed(self._startClock, lastEvent.timestamp) or "now"
            local label = lastEvent.message or lastEvent.detail or lastEvent.kind or "event"
            summary = string.format("%s\nLast: %s (%s)", summary, label, elapsed)
        elseif eventsTotal == 0 then
            summary = string.format("%s\nNo events yet", summary)
        end
        eventsCard.detail.Text = summary
    end

    local alertsCard = cards.alerts
    if alertsCard then
        local active = metrics.activeAlerts or 0
        local warnings = metrics.warnings or 0
        local errors = metrics.errors or 0
        if active > 0 or errors > 0 then
            alertsCard.value.Text = tostring(active > 0 and active or errors)
            alertsCard.value.TextColor3 = overviewTheme.dangerColor or overviewTheme.warningColor
            if active > 0 then
                alertsCard.detail.Text = string.format("%d alert%s requiring action", active, active == 1 and "" or "s")
            else
                alertsCard.detail.Text = string.format("%d error event%s logged", errors, errors == 1 and "" or "s")
            end
        elseif warnings > 0 then
            alertsCard.value.Text = tostring(warnings)
            alertsCard.value.TextColor3 = overviewTheme.warningColor or overviewTheme.accentColor
            alertsCard.detail.Text = string.format("%d warning event%s logged", warnings, warnings == 1 and "" or "s")
        else
            alertsCard.value.Text = "0"
            alertsCard.value.TextColor3 = overviewTheme.successColor or overviewTheme.valueColor
            alertsCard.detail.Text = "No active alerts"
        end
    end
end

function DiagnosticsPanel:_installResponsiveHandlers()
    if self._destroyed or not self.frame then
        return
    end

    local connection = self.frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
        if self._destroyed then
            return
        end
        self:_applyResponsiveLayout(self.frame.AbsoluteSize.X)
    end)
    table.insert(self._connections, connection)

    task.defer(function()
        if self._destroyed then
            return
        end
        self:_applyResponsiveLayout(self.frame.AbsoluteSize.X)
    end)
end

function DiagnosticsPanel:_applyResponsiveLayout(width)
    if self._destroyed then
        return
    end

    width = tonumber(width) or 0
    if width <= 0 and self.frame then
        width = self.frame.AbsoluteSize.X
    end
    if width <= 0 then
        return
    end

    local breakpoint
    if width < 640 then
        breakpoint = "small"
    elseif width < 880 then
        breakpoint = "medium"
    else
        breakpoint = "large"
    end
    self._currentBreakpoint = breakpoint

    if self._overviewLayout then
        if breakpoint == "small" then
            self._overviewLayout.FillDirection = Enum.FillDirection.Vertical
            self._overviewLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
            self._overviewLayout.Padding = UDim.new(0, 10)
        else
            self._overviewLayout.FillDirection = Enum.FillDirection.Horizontal
            self._overviewLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
            self._overviewLayout.Padding = UDim.new(0, self._theme.sectionSpacing or DEFAULT_THEME.sectionSpacing or 12)
        end
    end

    local cards = self._overviewCards
    if cards then
        if breakpoint == "small" then
            for _, card in pairs(cards) do
                if card.frame then
                    card.frame.Size = UDim2.new(1, 0, 0, 0)
                end
            end
        elseif breakpoint == "medium" then
            if cards.status and cards.status.frame then
                cards.status.frame.Size = UDim2.new(0.5, -6, 0, 0)
            end
            if cards.events and cards.events.frame then
                cards.events.frame.Size = UDim2.new(0.5, -6, 0, 0)
            end
            if cards.alerts and cards.alerts.frame then
                cards.alerts.frame.Size = UDim2.new(1, 0, 0, 0)
            end
        else
            local segments = 0
            for _, card in pairs(cards) do
                if card.frame then
                    segments += 1
                end
            end
            segments = math.max(segments, 1)
            local widthScale = 1 / segments
            for _, card in pairs(cards) do
                if card.frame then
                    card.frame.Size = UDim2.new(widthScale, -8, 0, 0)
                end
            end
        end
    end

    if self._contentLayout then
        if breakpoint == "large" then
            self._contentLayout.FillDirection = Enum.FillDirection.Horizontal
            self._contentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
            self._contentLayout.Padding = UDim.new(0, self._theme.sectionSpacing or DEFAULT_THEME.sectionSpacing or 12)
        else
            self._contentLayout.FillDirection = Enum.FillDirection.Vertical
            self._contentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
            self._contentLayout.Padding = UDim.new(0, self._theme.sectionSpacing or DEFAULT_THEME.sectionSpacing or 12)
        end
    end

    if self._primaryColumn and self._secondaryColumn then
        if breakpoint == "large" then
            self._primaryColumn.Size = UDim2.new(0.56, -8, 0, 0)
            self._secondaryColumn.Size = UDim2.new(0.44, -8, 0, 0)
        else
            self._primaryColumn.Size = UDim2.new(1, 0, 0, 0)
            self._secondaryColumn.Size = UDim2.new(1, 0, 0, 0)
        end
    end

    if self._stageLayout then
        if breakpoint == "large" then
            self._stageLayout.CellSize = UDim2.new(0.5, -8, 0, 98)
            self._stageLayout.CellPadding = UDim2.new(0, 12, 0, 12)
        else
            self._stageLayout.CellSize = UDim2.new(1, 0, 0, 98)
            self._stageLayout.CellPadding = UDim2.new(0, 10, 0, 10)
        end
    end

    if self._filterLayout then
        local filterTheme = (self._theme and self._theme.filterButton) or DEFAULT_THEME.filterButton
        if breakpoint == "small" then
            self._filterLayout.FillDirection = Enum.FillDirection.Vertical
            self._filterLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
            self._filterLayout.Padding = UDim.new(0, 6)
            for _, button in pairs(self._filterButtons) do
                button.Size = UDim2.new(1, 0, 0, 28)
                button.TextXAlignment = Enum.TextXAlignment.Left
            end
        else
            self._filterLayout.FillDirection = Enum.FillDirection.Horizontal
            self._filterLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
            self._filterLayout.Padding = UDim.new(0, 8)
            for _, button in pairs(self._filterButtons) do
                local widthEstimate = math.max(60, button.TextBounds.X + filterTheme.padding.X * 2)
                button.Size = UDim2.new(0, widthEstimate, 0, 26)
                button.TextXAlignment = Enum.TextXAlignment.Center
            end
        end
    end

    if self._badgesLayout then
        if breakpoint == "small" then
            self._badgesLayout.FillDirection = Enum.FillDirection.Vertical
            self._badgesLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
        else
            self._badgesLayout.FillDirection = Enum.FillDirection.Horizontal
            self._badgesLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
        end
    end
end

function DiagnosticsPanel:_updateEventRow(entry, event)
    if not entry or not event then
        return
    end

    local theme = self._theme
    local severity = event.severity or "info"
    local color = theme.severityColors[severity] or theme.statusDetailColor

    entry.tag.Text = string.upper(event.kind or "")
    entry.tag.TextColor3 = color
    entry.timestamp.Text = formatElapsed(self._startClock, event.timestamp)
    entry.message.Text = event.message or ""

    if event.detail and event.detail ~= "" then
        entry.detail.Visible = true
        entry.detail.Text = event.detail
    else
        entry.detail.Visible = false
    end

    entry.frame.LayoutOrder = -(event.sequence or 0)
end

function DiagnosticsPanel:_isEventVisible(event)
    local filterId = self._activeFilter or "all"
    if filterId == "all" then
        return true
    end

    if filterId == "loader" then
        return event.kind == "loader"
    elseif filterId == "parry" then
        return event.kind == "parry"
    elseif filterId == "warnings" then
        return event.severity == "warning"
    elseif filterId == "errors" then
        return event.severity == "error"
    end

    return true
end

function DiagnosticsPanel:_applyFilter()
    for _, entry in ipairs(self._eventRows) do
        local event = entry.event
        entry.frame.Visible = self:_isEventVisible(event)
    end
end

function DiagnosticsPanel:_styleFilterButtons()
    local theme = self._theme
    for id, button in pairs(self._filterButtons) do
        local active = id == self._activeFilter
        button.BackgroundColor3 = active and theme.filterButton.activeColor or theme.filterButton.inactiveColor
        button.TextColor3 = active and theme.filterButton.activeText or theme.filterButton.inactiveText
    end
end

function DiagnosticsPanel:setFilter(id)
    id = id or "all"
    if not self._filters[id] then
        id = "all"
    end
    self._activeFilter = id
    self:_styleFilterButtons()
    self:_applyFilter()
end

function DiagnosticsPanel:setCollapsed(sectionId, collapsed)
    local section = self._sections[sectionId]
    if section then
        section:setCollapsed(collapsed)
    end
end

function DiagnosticsPanel:setStages(stages)
    local map = {}
    if typeof(stages) == "table" then
        if stages[1] ~= nil then
            for _, stage in ipairs(stages) do
                local id = stage.id or stage.name
                if id then
                    map[id] = stage
                end
            end
        else
            map = stages
        end
    end

    for _, id in ipairs(self._stageOrder) do
        local row = self._stageRows[id]
        if row then
            local stage = map[id] or map[row.frame.Name]
            if stage then
                self:_styleStageRow(row, stage)
            end
        end
    end

    self:_updateStageMetrics(map)
    self:_refreshOverview()
end

function DiagnosticsPanel:pushEvent(event)
    if typeof(event) ~= "table" then
        return
    end

    local copied = deepCopy(event)
    copied.sequence = copied.sequence or (#self._events + 1)
    copied.timestamp = copied.timestamp or os.clock()

    table.insert(self._events, copied)

    local eventsList = self._eventsList
    if not eventsList and self._sections and self._sections.events then
        eventsList = self._sections.events.list
        self._eventsList = eventsList
    end

    if not eventsList then
        return
    end

    local entry = createEventRow(self._theme, eventsList, copied, self._startClock)
    entry.event = copied
    table.insert(self._eventRows, entry)

    self:_updateEventRow(entry, copied)
    self:_applyFilter()
    self:_registerEventMetrics(copied)
    self:_refreshOverview()
end

function DiagnosticsPanel:showError(errorInfo)
    if errorInfo == nil then
        for _, badge in pairs(self._badges) do
            badge.frame:Destroy()
        end
        self._badges = {}
        self:_recountActiveAlerts()
        self:_refreshOverview()
        return
    end

    local id = tostring(errorInfo.id or errorInfo.kind or (#self._badges + 1))
    local badge = self._badges[id]
    if not badge then
        local badgeParent = (self._badgesFrame and self._badgesFrame.Parent) and self._badgesFrame or (self._sections.errors and self._sections.errors.body and self._sections.errors.body.Badges)
        badge = createBadge(self._theme, badgeParent, id)
        self._badges[id] = badge
    end

    local active = errorInfo.active ~= false
    local severity = errorInfo.severity or "error"
    local theme = self._theme

    badge.label.Text = errorInfo.message or errorInfo.text or id
    badge.label.TextColor3 = active and theme.badge.textActive or theme.badge.textResolved
    badge.frame.BackgroundColor3 = active and theme.badge.background or theme.badge.backgroundResolved
    badge.frame.LayoutOrder = active and 0 or 1

    badge.active = active
    badge.severity = severity
    self:_recountActiveAlerts()
    self:_refreshOverview()
end

function DiagnosticsPanel:reset()
    for _, entry in ipairs(self._eventRows) do
        entry.frame:Destroy()
    end
    self._eventRows = {}
    self._events = {}

    for _, badge in pairs(self._badges) do
        badge.frame:Destroy()
    end
    self._badges = {}

    if self._metrics then
        self._metrics.events = 0
        self._metrics.loaderEvents = 0
        self._metrics.parryEvents = 0
        self._metrics.warnings = 0
        self._metrics.errors = 0
        self._metrics.activeAlerts = 0
        self._metrics.lastEvent = nil
        self._metrics.readyStages = 0
        self._metrics.warningStages = 0
        self._metrics.failedStages = 0
        self._metrics.activeStage = nil
    end

    self._startClock = os.clock()
    self:setFilter("all")

    for _, id in ipairs(self._stageOrder) do
        local row = self._stageRows[id]
        if row then
            row.icon.ImageColor3 = self._theme.statusColors.pending
            row.icon.Image = self._theme.iconAssets.pending
            row.title.TextColor3 = self._theme.statusColors.pending
            local definition = DEFAULT_STAGE_MAP[id]
            row.message.Text = definition and definition.description or ""
            row.message.TextColor3 = self._theme.statusDetailColor
            row.detail.Visible = false
            row.detail.Text = ""
        end
    end

    self:_refreshOverview()
end

function DiagnosticsPanel:destroy()
    if self._destroyed then
        return
    end

    self._destroyed = true

    for _, connection in ipairs(self._connections or {}) do
        connection:Disconnect()
    end
    self._connections = nil

    if self.frame then
        self.frame:Destroy()
        self.frame = nil
    end

    self._sections = nil
    self._stageRows = nil
    self._eventRows = nil
    self._eventsList = nil
    self._badges = nil
end

return DiagnosticsPanel
