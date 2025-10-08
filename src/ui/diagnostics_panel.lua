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

local function computeGridCellSize(columns, padding, height)
    columns = math.max(1, math.floor(columns + 0.5))
    padding = math.max(0, math.floor(padding + 0.5))
    local scale = 1 / columns
    local offset = 0
    if columns > 1 then
        offset = -math.floor(((columns - 1) * padding) / columns + 0.5)
    end
    return UDim2.new(scale, offset, 0, math.max(0, math.floor(height + 0.5)))
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
    frame.AutomaticSize = Enum.AutomaticSize.Y
    frame.Size = UDim2.new(1, 0, 0, 72)
    frame.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = theme.stageCorner
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color = theme.stageStrokeColor
    stroke.Transparency = theme.stageStrokeTransparency
    stroke.Parent = frame

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
    layout.Padding = UDim.new(0, theme.sectionSpacing)
    layout.Parent = frame

    local stagesSection = createSection(theme, frame, "Verification stages", 1)
    local eventsSection = createSection(theme, frame, "Event history", 2)
    local errorsSection = createSection(theme, frame, "Alerts", 3)

    local stageRows = {}
    local stageOrder = {}
    for index, definition in ipairs(DEFAULT_STAGES) do
        local row = createStageRow(theme, stagesSection.body, definition)
        row.frame.LayoutOrder = index
        stageRows[definition.id] = row
        stageOrder[index] = definition.id
    end

    if stagesSection.layout then
        stagesSection.layout:Destroy()
    end

    local stageGrid = Instance.new("UIGridLayout")
    stageGrid.Name = "StageGrid"
    stageGrid.FillDirection = Enum.FillDirection.Horizontal
    stageGrid.HorizontalAlignment = Enum.HorizontalAlignment.Left
    stageGrid.VerticalAlignment = Enum.VerticalAlignment.Top
    stageGrid.SortOrder = Enum.SortOrder.LayoutOrder
    stageGrid.CellPadding = UDim2.new(0, theme.sectionSpacing, 0, theme.sectionSpacing)
    stageGrid.CellSize = computeGridCellSize(2, theme.sectionSpacing, 76)
    stageGrid.Parent = stagesSection.body
    stagesSection.layout = stageGrid

    local stageGridDefaults = {
        cellPadding = stageGrid.CellPadding,
        cellSize = stageGrid.CellSize,
        maxColumns = 2,
        padding = theme.sectionSpacing,
        defaultHeight = 76,
        singleHeight = 84,
    }
    local stageSingleCellSize = computeGridCellSize(1, theme.sectionSpacing, stageGridDefaults.singleHeight)

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
        _stageRows = stageRows,
        _stageOrder = stageOrder,
        _stageGrid = stageGrid,
        _stageGridDefaults = stageGridDefaults,
        _stageSingleCellSize = stageSingleCellSize,
        _events = {},
        _eventRows = {},
        _eventsList = eventList,
        _filters = {},
        _filterButtons = filterButtons,
        _filterLayout = filterLayout,
        _activeFilter = nil,
        _badges = {},
        _startClock = os.clock(),
        _connections = {},
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

    local resizeConnection = frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
        self:_updateLayout()
    end)
    table.insert(self._connections, resizeConnection)
    task.defer(function()
        self:_updateLayout()
    end)

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
end

function DiagnosticsPanel:_updateLayout(width)
    if self._destroyed then
        return
    end

    local frame = self.frame
    if not frame then
        return
    end

    width = tonumber(width) or frame.AbsoluteSize.X or 0

    local grid = self._stageGrid
    if grid and self._stageGridDefaults then
        local defaults = self._stageGridDefaults
        local padding = defaults.cellPadding or UDim2.new(0, defaults.padding or 0, 0, defaults.padding or 0)
        local paddingX = (padding and padding.X and padding.X.Offset) or defaults.padding or 0
        local defaultHeight = defaults.defaultHeight or 76
        local singleHeight = defaults.singleHeight or (defaultHeight + 6)
        if width <= 380 then
            grid.FillDirectionMaxCells = 1
            grid.CellSize = self._stageSingleCellSize or computeGridCellSize(1, paddingX, singleHeight)
        else
            grid.FillDirectionMaxCells = defaults.maxColumns or 2
            grid.CellSize = defaults.cellSize or computeGridCellSize(2, paddingX, defaultHeight)
        end
    end

    if self._filterLayout then
        if width <= 420 then
            self._filterLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        else
            self._filterLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
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
end

function DiagnosticsPanel:showError(errorInfo)
    if errorInfo == nil then
        for _, badge in pairs(self._badges) do
            badge.frame:Destroy()
        end
        self._badges = {}
        return
    end

    local id = tostring(errorInfo.id or errorInfo.kind or (#self._badges + 1))
    local badge = self._badges[id]
    if not badge then
        badge = createBadge(self._theme, self._sections.errors.body.Badges, id)
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
end

function DiagnosticsPanel:destroy()
    if self._destroyed then
        return
    end

    self._destroyed = true

    if self._connections then
        for _, connection in ipairs(self._connections) do
            if connection and connection.Disconnect then
                connection:Disconnect()
            elseif connection and connection.disconnect then
                connection:disconnect()
            end
        end
        self._connections = nil
    end

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
