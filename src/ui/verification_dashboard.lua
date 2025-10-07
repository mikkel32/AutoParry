-- mikkel32/AutoParry : src/ui/verification_dashboard.lua
-- Futuristic verification dashboard used by the loading overlay. Renders a
-- neon timeline that visualises the orchestrator's verification stages with
-- animated status icons, tooltips, and action hooks.

local TweenService = game:GetService("TweenService")

local Require = rawget(_G, "ARequire")
local Util = Require("src/shared/util.lua")

local VerificationDashboard = {}
VerificationDashboard.__index = VerificationDashboard

local STATUS_PRIORITY = {
    pending = 0,
    active = 1,
    ok = 2,
    warning = 3,
    failed = 4,
}

local STEP_DEFINITIONS = {
    {
        id = "player",
        title = "Player Sync",
        description = "Locking on to your avatar and character rig.",
        tooltip = "AutoParry waits for the LocalPlayer and character to spawn before continuing.",
    },
    {
        id = "remotes",
        title = "Remotes",
        description = "Scanning Blade Ball network remotes.",
        tooltip = "Detects the parry remote and required folders inside ReplicatedStorage.Remotes.",
    },
    {
        id = "success",
        title = "Success Events",
        description = "Tracking parry success broadcasts.",
        tooltip = "Watches ParrySuccess events so AutoParry can react instantly to successes.",
    },
    {
        id = "balls",
        title = "Ball Telemetry",
        description = "Locating live balls for prediction.",
        tooltip = "Ensures the configured balls folder exists so projectiles can be analysed.",
    },
}

local DEFAULT_THEME = {
    accentColor = Color3.fromRGB(0, 210, 255),
    backgroundTransparency = 1,
    cardColor = Color3.fromRGB(22, 28, 48),
    cardTransparency = 0.08,
    cardStrokeColor = Color3.fromRGB(0, 150, 255),
    cardStrokeTransparency = 0.45,
    connectorColor = Color3.fromRGB(0, 170, 255),
    connectorTransparency = 0.55,
    pendingColor = Color3.fromRGB(95, 112, 140),
    activeColor = Color3.fromRGB(0, 195, 255),
    okColor = Color3.fromRGB(0, 230, 180),
    warningColor = Color3.fromRGB(255, 196, 0),
    failedColor = Color3.fromRGB(255, 70, 95),
    tooltipBackground = Color3.fromRGB(12, 16, 32),
    tooltipTransparency = 0.05,
    tooltipTextColor = Color3.fromRGB(215, 230, 255),
    titleFont = Enum.Font.GothamBlack,
    titleTextSize = 20,
    subtitleFont = Enum.Font.Gotham,
    subtitleTextSize = 16,
    stepTitleFont = Enum.Font.GothamSemibold,
    stepTitleTextSize = 17,
    stepStatusFont = Enum.Font.Gotham,
    stepStatusTextSize = 14,
    tooltipFont = Enum.Font.Gotham,
    tooltipTextSize = 14,
    actionFont = Enum.Font.GothamBold,
    actionTextSize = 16,
    actionHeight = 36,
    actionCorner = UDim.new(0, 10),
    actionPrimaryColor = Color3.fromRGB(0, 210, 255),
    actionPrimaryTextColor = Color3.fromRGB(10, 12, 20),
    actionSecondaryColor = Color3.fromRGB(30, 40, 60),
    actionSecondaryTextColor = Color3.fromRGB(215, 230, 255),
    logo = {
        width = 230,
        text = "AutoParry",
        font = Enum.Font.GothamBlack,
        textSize = 28,
        textGradient = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(0, 210, 255)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 236, 173)),
        }),
        textGradientRotation = 15,
        textStrokeColor = Color3.fromRGB(10, 12, 24),
        textStrokeTransparency = 0.6,
        primaryColor = Color3.fromRGB(235, 245, 255),
        tagline = "Neural shield online",
        taglineFont = Enum.Font.Gotham,
        taglineTextSize = 15,
        taglineColor = Color3.fromRGB(188, 206, 255),
        taglineTransparency = 0,
        backgroundColor = Color3.fromRGB(16, 20, 36),
        backgroundTransparency = 0.08,
        strokeColor = Color3.fromRGB(0, 180, 255),
        strokeTransparency = 0.35,
        gradient = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(12, 18, 30)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 195, 255)),
        }),
        gradientTransparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.55),
            NumberSequenceKeypoint.new(0.4, 0.35),
            NumberSequenceKeypoint.new(1, 0.15),
        }),
        gradientRotation = 120,
        glyphImage = "rbxassetid://12148062841",
        glyphColor = Color3.fromRGB(0, 230, 200),
        glyphTransparency = 0.2,
    },
    iconography = {
        pending = "rbxassetid://6031071050",
        active = "rbxassetid://6031075929",
        check = "rbxassetid://6031068421",
        warning = "rbxassetid://6031071051",
        error = "rbxassetid://6031094678",
    },
}

local STATUS_STYLE = {
    pending = function(theme)
        return {
            icon = theme.iconography.pending,
            color = theme.pendingColor,
            label = "Pending",
            strokeTransparency = 0.7,
        }
    end,
    active = function(theme)
        return {
            icon = theme.iconography.active or theme.iconography.pending,
            color = theme.activeColor,
            label = "Scanning…",
            strokeTransparency = 0.35,
        }
    end,
    ok = function(theme)
        return {
            icon = theme.iconography.check,
            color = theme.okColor,
            label = "Ready",
            strokeTransparency = 0.2,
        }
    end,
    warning = function(theme)
        return {
            icon = theme.iconography.warning,
            color = theme.warningColor,
            label = "Warning",
            strokeTransparency = 0.25,
        }
    end,
    failed = function(theme)
        return {
            icon = theme.iconography.error,
            color = theme.failedColor,
            label = "Failed",
            strokeTransparency = 0.15,
        }
    end,
}

local function mergeTable(base, overrides)
    if typeof(overrides) ~= "table" then
        return base
    end

    local merged = Util.deepCopy(base)
    for key, value in pairs(overrides) do
        if typeof(value) == "table" and typeof(merged[key]) == "table" then
            merged[key] = mergeTable(merged[key], value)
        else
            merged[key] = value
        end
    end
    return merged
end

local function createLogoBadge(parent, theme)
    local config = mergeTable(DEFAULT_THEME.logo, theme.logo or {})

    local badge = Instance.new("Frame")
    badge.Name = "LogoBadge"
    badge.AnchorPoint = Vector2.new(0, 0.5)
    badge.Position = UDim2.new(0, 0, 0.5, 0)
    badge.Size = UDim2.new(1, 0, 1, -8)
    badge.BackgroundColor3 = config.backgroundColor or theme.cardColor
    badge.BackgroundTransparency = config.backgroundTransparency or 0.1
    badge.BorderSizePixel = 0
    badge.ClipsDescendants = true
    badge.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 14)
    corner.Parent = badge

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1.6
    stroke.Transparency = config.strokeTransparency or 0.35
    stroke.Color = config.strokeColor or theme.accentColor
    stroke.Parent = badge

    local gradient = Instance.new("UIGradient")
    gradient.Color = config.gradient or DEFAULT_THEME.logo.gradient
    gradient.Transparency = config.gradientTransparency or DEFAULT_THEME.logo.gradientTransparency
    gradient.Rotation = config.gradientRotation or DEFAULT_THEME.logo.gradientRotation or 120
    gradient.Parent = badge

    local glyph = Instance.new("ImageLabel")
    glyph.Name = "Glyph"
    glyph.AnchorPoint = Vector2.new(0, 0.5)
    glyph.Position = UDim2.new(0, 14, 0.5, 0)
    glyph.Size = UDim2.new(0, 34, 0, 34)
    glyph.BackgroundTransparency = 1
    glyph.Image = config.glyphImage or (theme.iconography and theme.iconography.hologram) or ""
    glyph.ImageColor3 = config.glyphColor or theme.accentColor
    glyph.ImageTransparency = config.glyphTransparency or 0.2
    glyph.Parent = badge

    local wordmark = Instance.new("TextLabel")
    wordmark.Name = "Wordmark"
    wordmark.AnchorPoint = Vector2.new(0, 0.5)
    wordmark.Position = UDim2.new(0, 58, 0.5, -10)
    wordmark.Size = UDim2.new(1, -70, 0, 30)
    wordmark.BackgroundTransparency = 1
    wordmark.Font = config.font or DEFAULT_THEME.logo.font
    wordmark.TextSize = config.textSize or DEFAULT_THEME.logo.textSize
    wordmark.Text = string.upper(config.text or DEFAULT_THEME.logo.text)
    wordmark.TextColor3 = config.primaryColor or Color3.fromRGB(235, 245, 255)
    wordmark.TextXAlignment = Enum.TextXAlignment.Left
    wordmark.TextStrokeColor3 = config.textStrokeColor or Color3.fromRGB(10, 12, 24)
    wordmark.TextStrokeTransparency = config.textStrokeTransparency or 0.6
    wordmark.Parent = badge

    local wordmarkGradient = Instance.new("UIGradient")
    wordmarkGradient.Name = "WordmarkGradient"
    wordmarkGradient.Color = config.textGradient or DEFAULT_THEME.logo.textGradient
    wordmarkGradient.Rotation = config.textGradientRotation or DEFAULT_THEME.logo.textGradientRotation or 0
    wordmarkGradient.Parent = wordmark

    local tagline = Instance.new("TextLabel")
    tagline.Name = "Tagline"
    tagline.AnchorPoint = Vector2.new(0, 0.5)
    tagline.Position = UDim2.new(0, 58, 0.5, 16)
    tagline.Size = UDim2.new(1, -70, 0, 22)
    tagline.BackgroundTransparency = 1
    tagline.Font = config.taglineFont or DEFAULT_THEME.logo.taglineFont
    tagline.TextSize = config.taglineTextSize or DEFAULT_THEME.logo.taglineTextSize
    tagline.TextColor3 = config.taglineColor or DEFAULT_THEME.logo.taglineColor
    tagline.Text = config.tagline or DEFAULT_THEME.logo.tagline
    tagline.TextTransparency = config.taglineTransparency or 0
    tagline.TextXAlignment = Enum.TextXAlignment.Left
    tagline.Parent = badge

    return {
        frame = badge,
        stroke = stroke,
        gradient = gradient,
        glyph = glyph,
        wordmark = wordmark,
        wordmarkGradient = wordmarkGradient,
        tagline = tagline,
    }
end

local function createTooltip(parent, theme, text)
    local tooltip = Instance.new("TextLabel")
    tooltip.Name = "Tooltip"
    tooltip.AnchorPoint = Vector2.new(0.5, 1)
    tooltip.Position = UDim2.new(0.5, 0, 0, -6)
    tooltip.BackgroundColor3 = theme.tooltipBackground
    tooltip.BackgroundTransparency = theme.tooltipTransparency
    tooltip.TextColor3 = theme.tooltipTextColor
    tooltip.Text = text or ""
    tooltip.TextWrapped = true
    tooltip.Visible = false
    tooltip.Size = UDim2.new(0.9, 0, 0, 48)
    tooltip.Font = theme.tooltipFont
    tooltip.TextSize = theme.tooltipTextSize
    tooltip.ZIndex = 4
    tooltip.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = tooltip

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1
    stroke.Transparency = 0.4
    stroke.Color = theme.accentColor
    stroke.Parent = tooltip

    return tooltip
end

local function createStep(parent, definition, theme)
    local frame = Instance.new("Frame")
    frame.Name = definition.id
    frame.Size = UDim2.new(1, 0, 0, 0)
    frame.AutomaticSize = Enum.AutomaticSize.Y
    frame.BackgroundColor3 = theme.cardColor
    frame.BackgroundTransparency = theme.cardTransparency
    frame.BorderSizePixel = 0
    frame.Parent = parent
    frame.ClipsDescendants = false
    frame.ZIndex = 2

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 12)
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1.5
    stroke.Color = theme.cardStrokeColor
    stroke.Transparency = theme.cardStrokeTransparency
    stroke.Parent = frame

    local gradient = Instance.new("UIGradient")
    gradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, theme.cardColor),
        ColorSequenceKeypoint.new(1, theme.cardColor:Lerp(theme.accentColor, 0.08)),
    })
    gradient.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, theme.cardTransparency + 0.05),
        NumberSequenceKeypoint.new(1, theme.cardTransparency + 0.15),
    })
    gradient.Rotation = 120
    gradient.Parent = frame

    local icon = Instance.new("ImageLabel")
    icon.Name = "StatusIcon"
    icon.AnchorPoint = Vector2.new(0.5, 0.5)
    icon.Position = UDim2.new(0, 34, 0.5, 0)
    icon.Size = UDim2.new(0, 38, 0, 38)
    icon.BackgroundTransparency = 1
    icon.Image = theme.iconography.pending
    icon.ImageTransparency = 0.25
    icon.ImageColor3 = theme.pendingColor
    icon.ZIndex = 3
    icon.Parent = frame

    local iconGlow = Instance.new("UIStroke")
    iconGlow.Thickness = 2
    iconGlow.Transparency = 0.4
    iconGlow.Color = theme.pendingColor
    iconGlow.Parent = icon

    local statePill = Instance.new("Frame")
    statePill.Name = "StatePill"
    statePill.AnchorPoint = Vector2.new(1, 0)
    statePill.Position = UDim2.new(1, -18, 0, 16)
    statePill.Size = UDim2.new(0, 116, 0, 26)
    statePill.BackgroundColor3 = theme.cardColor:Lerp(theme.accentColor, 0.28)
    statePill.BackgroundTransparency = 0.25
    statePill.BorderSizePixel = 0
    statePill.Parent = frame

    local pillCorner = Instance.new("UICorner")
    pillCorner.CornerRadius = UDim.new(0, 12)
    pillCorner.Parent = statePill

    local pillLabel = Instance.new("TextLabel")
    pillLabel.Name = "StateLabel"
    pillLabel.BackgroundTransparency = 1
    pillLabel.Size = UDim2.new(1, -16, 1, 0)
    pillLabel.Position = UDim2.new(0, 8, 0, 0)
    pillLabel.Font = theme.stepStatusFont
    pillLabel.TextSize = theme.stepStatusTextSize
    pillLabel.TextColor3 = Color3.fromRGB(220, 234, 255)
    pillLabel.TextXAlignment = Enum.TextXAlignment.Left
    pillLabel.Text = "Pending"
    pillLabel.Parent = statePill

    local content = Instance.new("Frame")
    content.Name = "Content"
    content.BackgroundTransparency = 1
    content.Position = UDim2.new(0, 78, 0, 12)
    content.Size = UDim2.new(1, -140, 0, 0)
    content.AutomaticSize = Enum.AutomaticSize.Y
    content.Parent = frame

    local contentLayout = Instance.new("UIListLayout")
    contentLayout.FillDirection = Enum.FillDirection.Vertical
    contentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    contentLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
    contentLayout.Padding = UDim.new(0, 6)
    contentLayout.Parent = content

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.BackgroundTransparency = 1
    title.Size = UDim2.new(1, 0, 0, 0)
    title.AutomaticSize = Enum.AutomaticSize.Y
    title.Font = theme.stepTitleFont
    title.TextSize = theme.stepTitleTextSize
    title.TextColor3 = Color3.fromRGB(235, 240, 255)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextWrapped = true
    title.Text = definition.title
    title.Parent = content

    local status = Instance.new("TextLabel")
    status.Name = "Status"
    status.BackgroundTransparency = 1
    status.Size = UDim2.new(1, 0, 0, 0)
    status.AutomaticSize = Enum.AutomaticSize.Y
    status.Font = theme.stepStatusFont
    status.TextSize = theme.stepStatusTextSize
    status.TextColor3 = Color3.fromRGB(180, 194, 235)
    status.TextXAlignment = Enum.TextXAlignment.Left
    status.TextWrapped = true
    status.Text = definition.description
    status.Parent = content

    local connector = Instance.new("Frame")
    connector.Name = "Connector"
    connector.AnchorPoint = Vector2.new(0.5, 0)
    connector.Position = UDim2.new(0, 34, 1, -8)
    connector.Size = UDim2.new(0, 4, 0, 32)
    connector.BackgroundColor3 = theme.connectorColor
    connector.BackgroundTransparency = theme.connectorTransparency
    connector.BorderSizePixel = 0
    connector.ZIndex = 1
    connector.Parent = frame

    local tooltip = createTooltip(frame, theme, definition.tooltip)

    local hoverArea = Instance.new("TextButton")
    hoverArea.Name = "Hover"
    hoverArea.BackgroundTransparency = 1
    hoverArea.Text = ""
    hoverArea.Size = UDim2.new(1, 0, 1, 0)
    hoverArea.AutoButtonColor = false
    hoverArea.ZIndex = 5
    hoverArea.Parent = frame

    local step = {
        id = definition.id,
        frame = frame,
        icon = icon,
        iconGlow = iconGlow,
        statePill = statePill,
        stateLabel = pillLabel,
        title = title,
        status = status,
        connector = connector,
        tooltip = tooltip,
        hoverArea = hoverArea,
        state = "pending",
        priority = STATUS_PRIORITY.pending,
        iconTween = nil,
    }

    hoverArea.MouseEnter:Connect(function()
        tooltip.Visible = true
        tooltip.TextTransparency = 1
        TweenService:Create(
            tooltip,
            TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
            { TextTransparency = 0.05, BackgroundTransparency = theme.tooltipTransparency }
        ):Play()
    end)

    local function hideTooltip()
        if tooltip.Visible then
            TweenService:Create(
                tooltip,
                TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
                { TextTransparency = 1, BackgroundTransparency = 1 }
            ):Play()
            task.delay(0.22, function()
                tooltip.Visible = false
            end)
        end
    end

    hoverArea.MouseLeave:Connect(hideTooltip)
    hoverArea.MouseButton1Down:Connect(hideTooltip)

    return step
end

local function styleActionButton(button, theme, action)
    local isSecondary = action.variant == "secondary" or action.kind == "cancel"
    button.AutoButtonColor = false
    button.BackgroundColor3 = isSecondary and theme.actionSecondaryColor or theme.actionPrimaryColor
    button.TextColor3 = isSecondary and theme.actionSecondaryTextColor or theme.actionPrimaryTextColor
    button.Font = theme.actionFont
    button.TextSize = theme.actionTextSize
    button.TextXAlignment = Enum.TextXAlignment.Center
    button.TextYAlignment = Enum.TextYAlignment.Center
    button.TextWrapped = true

    local minWidth = theme.actionButtonMinWidth or 140
    local targetWidth = action.width or minWidth
    if theme.actionButtonMinWidth then
        targetWidth = math.max(targetWidth, theme.actionButtonMinWidth)
    end
    button.Size = UDim2.new(0, targetWidth, 0, theme.actionHeight)

    local corner = Instance.new("UICorner")
    corner.CornerRadius = theme.actionCorner
    corner.Parent = button

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1.5
    stroke.Transparency = 0.35
    stroke.Color = theme.accentColor
    stroke.Parent = button

    local gradient = Instance.new("UIGradient")
    gradient.Rotation = 120
    if isSecondary then
        gradient.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, theme.actionSecondaryColor:Lerp(Color3.fromRGB(255, 255, 255), 0.06)),
            ColorSequenceKeypoint.new(1, theme.actionSecondaryColor:Lerp(Color3.fromRGB(10, 12, 20), 0.2)),
        })
    else
        gradient.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, theme.actionPrimaryColor:Lerp(Color3.fromRGB(255, 255, 255), 0.2)),
            ColorSequenceKeypoint.new(1, theme.actionPrimaryColor:Lerp(Color3.fromRGB(10, 12, 20), 0.25)),
        })
    end
    gradient.Parent = button
end

function VerificationDashboard.new(options)
    options = options or {}
    local theme = mergeTable(DEFAULT_THEME, options.theme or {})

    local parent = options.parent
    assert(parent, "VerificationDashboard.new requires a parent frame")

    local root = Instance.new("Frame")
    root.Name = options.name or "VerificationDashboard"
    root.BackgroundTransparency = theme.backgroundTransparency
    root.BackgroundColor3 = Color3.new(0, 0, 0)
    root.Size = UDim2.new(1, 0, 1, 0)
    root.BorderSizePixel = 0
    root.ClipsDescendants = false
    root.Parent = parent

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 16)
    padding.PaddingBottom = UDim.new(0, 16)
    padding.PaddingLeft = UDim.new(0, 16)
    padding.PaddingRight = UDim.new(0, 16)
    padding.Parent = root

    local surface = Instance.new("Frame")
    surface.Name = "Surface"
    surface.BackgroundColor3 = theme.cardColor:Lerp(theme.accentColor, 0.06)
    surface.BackgroundTransparency = math.clamp((theme.cardTransparency or 0.08) + 0.12, 0, 1)
    surface.Size = UDim2.new(1, 0, 1, 0)
    surface.BorderSizePixel = 0
    surface.ClipsDescendants = false
    surface.Parent = root

    local surfaceCorner = Instance.new("UICorner")
    surfaceCorner.CornerRadius = UDim.new(0, 18)
    surfaceCorner.Parent = surface

    local surfaceStroke = Instance.new("UIStroke")
    surfaceStroke.Thickness = 1.6
    surfaceStroke.Transparency = math.clamp((theme.cardStrokeTransparency or 0.45) + 0.1, 0, 1)
    surfaceStroke.Color = theme.cardStrokeColor:Lerp(theme.accentColor, 0.35)
    surfaceStroke.Parent = surface

    local surfaceGradient = Instance.new("UIGradient")
    surfaceGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, theme.cardColor:Lerp(theme.accentColor, 0.2)),
        ColorSequenceKeypoint.new(1, theme.cardColor),
    })
    surfaceGradient.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, math.clamp((theme.cardTransparency or 0.08) + 0.05, 0, 1)),
        NumberSequenceKeypoint.new(0.45, math.clamp((theme.cardTransparency or 0.08) + 0.12, 0, 1)),
        NumberSequenceKeypoint.new(1, math.clamp((theme.cardTransparency or 0.08) + 0.2, 0, 1)),
    })
    surfaceGradient.Rotation = 115
    surfaceGradient.Parent = surface

    local surfacePadding = Instance.new("UIPadding")
    surfacePadding.PaddingTop = UDim.new(0, 22)
    surfacePadding.PaddingBottom = UDim.new(0, 22)
    surfacePadding.PaddingLeft = UDim.new(0, 24)
    surfacePadding.PaddingRight = UDim.new(0, 24)
    surfacePadding.Parent = surface

    local surfaceLayout = Instance.new("UIListLayout")
    surfaceLayout.FillDirection = Enum.FillDirection.Vertical
    surfaceLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    surfaceLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    surfaceLayout.SortOrder = Enum.SortOrder.LayoutOrder
    surfaceLayout.Padding = UDim.new(0, 18)
    surfaceLayout.Parent = surface

    local header = Instance.new("Frame")
    header.Name = "Header"
    header.BackgroundTransparency = 1
    header.Size = UDim2.new(1, 0, 0, 0)
    header.AutomaticSize = Enum.AutomaticSize.Y
    header.LayoutOrder = 1
    header.Parent = surface

    local headerLayout = Instance.new("UIListLayout")
    headerLayout.FillDirection = Enum.FillDirection.Horizontal
    headerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    headerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    headerLayout.SortOrder = Enum.SortOrder.LayoutOrder
    headerLayout.Padding = UDim.new(0, 22)
    headerLayout.Parent = header

    local logoContainer = Instance.new("Frame")
    logoContainer.Name = "LogoContainer"
    logoContainer.BackgroundTransparency = 1
    logoContainer.Size = UDim2.new(0, 230, 0, 86)
    logoContainer.AutomaticSize = Enum.AutomaticSize.Y
    logoContainer.Parent = header

    local logoElements = createLogoBadge(logoContainer, theme)

    local textContainer = Instance.new("Frame")
    textContainer.Name = "HeaderText"
    textContainer.BackgroundTransparency = 1
    textContainer.Size = UDim2.new(1, -230, 0, 0)
    textContainer.AutomaticSize = Enum.AutomaticSize.Y
    textContainer.Parent = header

    local textLayout = Instance.new("UIListLayout")
    textLayout.FillDirection = Enum.FillDirection.Vertical
    textLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    textLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    textLayout.SortOrder = Enum.SortOrder.LayoutOrder
    textLayout.Padding = UDim.new(0, 6)
    textLayout.Parent = textContainer

    local title = Instance.new("TextLabel")
    title.Name = "Heading"
    title.BackgroundTransparency = 1
    title.Size = UDim2.new(1, 0, 0, 0)
    title.AutomaticSize = Enum.AutomaticSize.Y
    title.Font = theme.titleFont
    title.TextSize = theme.titleTextSize
    title.TextColor3 = Color3.fromRGB(235, 245, 255)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextWrapped = true
    title.Text = "Verification Timeline"
    title.LayoutOrder = 1
    title.Parent = textContainer

    local subtitlePill = Instance.new("Frame")
    subtitlePill.Name = "StatusPill"
    subtitlePill.BackgroundColor3 = theme.accentColor:Lerp(theme.cardColor, 0.7)
    subtitlePill.BackgroundTransparency = 0.35
    subtitlePill.Size = UDim2.new(0, 0, 0, 0)
    subtitlePill.AutomaticSize = Enum.AutomaticSize.XY
    subtitlePill.LayoutOrder = 2
    subtitlePill.Parent = textContainer

    local subtitleCorner = Instance.new("UICorner")
    subtitleCorner.CornerRadius = UDim.new(0, 12)
    subtitleCorner.Parent = subtitlePill

    local subtitlePadding = Instance.new("UIPadding")
    subtitlePadding.PaddingTop = UDim.new(0, 6)
    subtitlePadding.PaddingBottom = UDim.new(0, 6)
    subtitlePadding.PaddingLeft = UDim.new(0, 12)
    subtitlePadding.PaddingRight = UDim.new(0, 12)
    subtitlePadding.Parent = subtitlePill

    local subtitle = Instance.new("TextLabel")
    subtitle.Name = "Subtitle"
    subtitle.BackgroundTransparency = 1
    subtitle.Size = UDim2.new(1, 0, 0, 0)
    subtitle.AutomaticSize = Enum.AutomaticSize.Y
    subtitle.Font = theme.subtitleFont
    subtitle.TextSize = theme.subtitleTextSize
    subtitle.TextColor3 = Color3.fromRGB(188, 206, 255)
    subtitle.TextXAlignment = Enum.TextXAlignment.Left
    subtitle.TextWrapped = true
    subtitle.Text = "Preparing AutoParry systems…"
    subtitle.Parent = subtitlePill

    local progressWrapper = Instance.new("Frame")
    progressWrapper.Name = "ProgressWrapper"
    progressWrapper.BackgroundTransparency = 1
    progressWrapper.Size = UDim2.new(1, 0, 0, 0)
    progressWrapper.AutomaticSize = Enum.AutomaticSize.Y
    progressWrapper.LayoutOrder = 2
    progressWrapper.Parent = surface

    local progressLabel = Instance.new("TextLabel")
    progressLabel.Name = "ProgressLabel"
    progressLabel.BackgroundTransparency = 1
    progressLabel.Size = UDim2.new(1, 0, 0, 0)
    progressLabel.AutomaticSize = Enum.AutomaticSize.Y
    progressLabel.Font = theme.stepStatusFont
    progressLabel.TextSize = theme.stepStatusTextSize
    progressLabel.TextColor3 = Color3.fromRGB(170, 186, 220)
    progressLabel.Text = "Verification progress"
    progressLabel.TextXAlignment = Enum.TextXAlignment.Left
    progressLabel.Parent = progressWrapper

    local progressTrack = Instance.new("Frame")
    progressTrack.Name = "ProgressTrack"
    progressTrack.Size = UDim2.new(1, 0, 0, 8)
    progressTrack.BackgroundColor3 = Color3.fromRGB(26, 32, 52)
    progressTrack.BackgroundTransparency = 0.1
    progressTrack.BorderSizePixel = 0
    progressTrack.Parent = progressWrapper

    local trackCorner = Instance.new("UICorner")
    trackCorner.CornerRadius = UDim.new(0, 6)
    trackCorner.Parent = progressTrack

    local progressFill = Instance.new("Frame")
    progressFill.Name = "Fill"
    progressFill.Size = UDim2.new(0, 0, 1, 0)
    progressFill.BackgroundColor3 = theme.accentColor
    progressFill.BorderSizePixel = 0
    progressFill.Parent = progressTrack

    local progressCorner = Instance.new("UICorner")
    progressCorner.CornerRadius = UDim.new(0, 6)
    progressCorner.Parent = progressFill

    local glow = Instance.new("UIGradient")
    glow.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, theme.accentColor),
        ColorSequenceKeypoint.new(1, theme.accentColor:lerp(Color3.new(1, 1, 1), 0.3)),
    })
    glow.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.08),
        NumberSequenceKeypoint.new(1, 0.5),
    })
    glow.Parent = progressFill

    local listFrame = Instance.new("Frame")
    listFrame.Name = "Steps"
    listFrame.Size = UDim2.new(1, 0, 0, 0)
    listFrame.AutomaticSize = Enum.AutomaticSize.Y
    listFrame.BackgroundTransparency = 1
    listFrame.ClipsDescendants = false
    listFrame.LayoutOrder = 3
    listFrame.Parent = surface

    local listLayout = Instance.new("UIListLayout")
    listLayout.FillDirection = Enum.FillDirection.Vertical
    listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    listLayout.Padding = UDim.new(0, 14)
    listLayout.Parent = listFrame

    local spine = Instance.new("Frame")
    spine.Name = "TimelineSpine"
    spine.AnchorPoint = Vector2.new(0, 0)
    spine.Position = UDim2.new(0, 34, 0, 8)
    spine.Size = UDim2.new(0, 2, 0, 0)
    spine.BackgroundColor3 = theme.connectorColor
    spine.BackgroundTransparency = math.clamp((theme.connectorTransparency or 0.55) + 0.1, 0, 1)
    spine.BorderSizePixel = 0
    spine.ZIndex = 0
    spine.Parent = listFrame

    local spineGradient = Instance.new("UIGradient")
    spineGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, theme.connectorColor),
        ColorSequenceKeypoint.new(1, theme.accentColor),
    })
    spineGradient.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.45),
        NumberSequenceKeypoint.new(1, 0.05),
    })
    spineGradient.Rotation = 90
    spineGradient.Parent = spine

    local steps = {}
    for index, definition in ipairs(STEP_DEFINITIONS) do
        local step = createStep(listFrame, definition, theme)
        step.frame.LayoutOrder = index
        if index == #STEP_DEFINITIONS and step.connector then
            step.connector.Visible = false
        end
        steps[definition.id] = step
    end

    local actionsDivider = Instance.new("Frame")
    actionsDivider.Name = "Divider"
    actionsDivider.BackgroundColor3 = theme.cardStrokeColor
    actionsDivider.BackgroundTransparency = 0.65
    actionsDivider.BorderSizePixel = 0
    actionsDivider.Size = UDim2.new(1, 0, 0, 1)
    actionsDivider.LayoutOrder = 4
    actionsDivider.Parent = surface

    actionsDivider.Visible = false

    local actionsFrame = Instance.new("Frame")
    actionsFrame.Name = "Actions"
    actionsFrame.BackgroundTransparency = 1
    actionsFrame.Size = UDim2.new(1, 0, 0, 0)
    actionsFrame.AutomaticSize = Enum.AutomaticSize.Y
    actionsFrame.Visible = false
    actionsFrame.LayoutOrder = 5
    actionsFrame.Parent = surface

    local actionsPadding = Instance.new("UIPadding")
    actionsPadding.PaddingTop = UDim.new(0, 10)
    actionsPadding.PaddingBottom = UDim.new(0, 4)
    actionsPadding.Parent = actionsFrame

    local actionsLayout = Instance.new("UIListLayout")
    actionsLayout.FillDirection = Enum.FillDirection.Horizontal
    actionsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
    actionsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    actionsLayout.SortOrder = Enum.SortOrder.LayoutOrder
    actionsLayout.Padding = UDim.new(0, 12)
    actionsLayout.Parent = actionsFrame

    local self = setmetatable({
        _theme = theme,
        _root = root,
        _header = header,
        _title = title,
        _subtitle = subtitle,
        _subtitlePill = subtitlePill,
        _surface = surface,
        _surfaceStroke = surfaceStroke,
        _surfaceGradient = surfaceGradient,
        _progressFill = progressFill,
        _progressTrack = progressTrack,
        _progressLabel = progressLabel,
        _progressWrapper = progressWrapper,
        _progressTween = nil,
        _stepsFrame = listFrame,
        _stepsLayout = listLayout,
        _timelineSpine = spine,
        _timelineSpineGradient = spineGradient,
        _timelineSizeConnection = nil,
        _steps = steps,
        _stepStates = {},
        _actionsFrame = actionsFrame,
        _actionsLayout = actionsLayout,
        _actionsDivider = actionsDivider,
        _actionButtons = {},
        _actionConnections = {},
        _actions = nil,
        _headerText = textContainer,
        _logoContainer = logoContainer,
        _logoFrame = logoElements and logoElements.frame,
        _logoStroke = logoElements and logoElements.stroke,
        _logoGradient = logoElements and logoElements.gradient,
        _logoGlyph = logoElements and logoElements.glyph,
        _logoWordmark = logoElements and logoElements.wordmark,
        _logoWordmarkGradient = logoElements and logoElements.wordmarkGradient,
        _logoTagline = logoElements and logoElements.tagline,
        _logoShimmerTween = nil,
        _destroyed = false,
    }, VerificationDashboard)

    for _, definition in ipairs(STEP_DEFINITIONS) do
        self._stepStates[definition.id] = {
            status = "pending",
            priority = STATUS_PRIORITY.pending,
            message = definition.description,
            tooltip = definition.tooltip,
        }
    end

    self:_updateTimelineSpine()
    if listLayout then
        self._timelineSizeConnection = listLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
            self:_updateTimelineSpine()
        end)
    end

    self:_applyLogoTheme()
    self:_startLogoShimmer()
    self:setProgress(0)

    return self
end

function VerificationDashboard:_stopLogoShimmer()
    if self._logoShimmerTween then
        self._logoShimmerTween:Cancel()
        self._logoShimmerTween = nil
    end
end

function VerificationDashboard:_startLogoShimmer()
    if self._destroyed then
        return
    end

    if not self._logoGradient then
        return
    end

    self:_stopLogoShimmer()

    local tween = TweenService:Create(
        self._logoGradient,
        TweenInfo.new(4.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
        { Offset = Vector2.new(0.35, 0) }
    )
    self._logoGradient.Offset = Vector2.new(-0.35, 0)
    tween:Play()
    self._logoShimmerTween = tween
end

function VerificationDashboard:_applyLogoTheme()
    if self._destroyed then
        return
    end

    local theme = self._theme or DEFAULT_THEME
    local config = mergeTable(DEFAULT_THEME.logo, theme.logo or {})
    local logoWidth = config.width or DEFAULT_THEME.logo.width or 230

    if self._logoContainer then
        self._logoContainer.Size = UDim2.new(0, logoWidth, 1, 0)
    end

    if self._headerText then
        self._headerText.Size = UDim2.new(1, -logoWidth, 1, 0)
    end

    if self._logoFrame then
        self._logoFrame.BackgroundColor3 = config.backgroundColor or theme.cardColor
        self._logoFrame.BackgroundTransparency = config.backgroundTransparency or 0.1
    end

    if self._logoStroke then
        self._logoStroke.Color = config.strokeColor or theme.accentColor
        self._logoStroke.Transparency = config.strokeTransparency or 0.35
    end

    if self._logoGradient then
        self._logoGradient.Color = config.gradient or DEFAULT_THEME.logo.gradient
        self._logoGradient.Transparency = config.gradientTransparency or DEFAULT_THEME.logo.gradientTransparency
        self._logoGradient.Rotation = config.gradientRotation or DEFAULT_THEME.logo.gradientRotation or 120
    end

    if self._logoGlyph then
        self._logoGlyph.Image = config.glyphImage or (theme.iconography and theme.iconography.hologram) or ""
        self._logoGlyph.ImageColor3 = config.glyphColor or theme.accentColor
        self._logoGlyph.ImageTransparency = config.glyphTransparency or 0.2
    end

    if self._logoWordmark then
        self._logoWordmark.Font = config.font or DEFAULT_THEME.logo.font
        self._logoWordmark.TextSize = config.textSize or DEFAULT_THEME.logo.textSize
        self._logoWordmark.Text = string.upper(config.text or DEFAULT_THEME.logo.text)
        self._logoWordmark.TextColor3 = config.primaryColor or Color3.fromRGB(235, 245, 255)
        self._logoWordmark.TextStrokeColor3 = config.textStrokeColor or Color3.fromRGB(10, 12, 24)
        self._logoWordmark.TextStrokeTransparency = config.textStrokeTransparency or 0.6
    end

    if self._logoWordmarkGradient then
        self._logoWordmarkGradient.Color = config.textGradient or DEFAULT_THEME.logo.textGradient
        self._logoWordmarkGradient.Rotation = config.textGradientRotation or DEFAULT_THEME.logo.textGradientRotation or 0
    end

    if self._logoTagline then
        self._logoTagline.Font = config.taglineFont or DEFAULT_THEME.logo.taglineFont
        self._logoTagline.TextSize = config.taglineTextSize or DEFAULT_THEME.logo.taglineTextSize
        self._logoTagline.TextColor3 = config.taglineColor or DEFAULT_THEME.logo.taglineColor
        self._logoTagline.TextTransparency = config.taglineTransparency or DEFAULT_THEME.logo.taglineTransparency or 0
        self._logoTagline.Text = config.tagline or DEFAULT_THEME.logo.tagline
    end
end

function VerificationDashboard:_updateTimelineSpine()
    if self._destroyed then
        return
    end

    local spine = self._timelineSpine
    local layout = self._stepsLayout
    if not spine or not layout then
        return
    end

    local contentHeight = layout.AbsoluteContentSize.Y
    spine.Size = UDim2.new(0, 2, 0, math.max(contentHeight - 10, 0))
end

function VerificationDashboard:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true

    self:_stopLogoShimmer()

    for _, connection in ipairs(self._actionConnections) do
        if connection then
            if connection.Disconnect then
                connection:Disconnect()
            elseif connection.disconnect then
                connection:disconnect()
            end
        end
    end

    for _, button in ipairs(self._actionButtons) do
        if button and button.Destroy then
            button:Destroy()
        end
    end

    if self._timelineSizeConnection then
        if self._timelineSizeConnection.Disconnect then
            self._timelineSizeConnection:Disconnect()
        elseif self._timelineSizeConnection.disconnect then
            self._timelineSizeConnection:disconnect()
        end
        self._timelineSizeConnection = nil
    end

    if self._root then
        self._root:Destroy()
        self._root = nil
    end
end

function VerificationDashboard:getRoot()
    return self._root
end

function VerificationDashboard:getTheme()
    return self._theme
end

function VerificationDashboard:applyTheme(theme)
    if self._destroyed then
        return
    end

    if theme then
        self._theme = mergeTable(DEFAULT_THEME, theme)
    end

    local currentTheme = self._theme

    self:_stopLogoShimmer()
    self:_applyLogoTheme()

    local accent = currentTheme.accentColor or DEFAULT_THEME.accentColor
    local cardColor = currentTheme.cardColor or DEFAULT_THEME.cardColor
    local cardTransparency = currentTheme.cardTransparency or DEFAULT_THEME.cardTransparency
    local cardStrokeTransparency = currentTheme.cardStrokeTransparency or DEFAULT_THEME.cardStrokeTransparency
    local connectorTransparency = currentTheme.connectorTransparency or DEFAULT_THEME.connectorTransparency

    if self._title then
        self._title.Font = currentTheme.titleFont
        self._title.TextSize = currentTheme.titleTextSize
    end
    if self._subtitle then
        self._subtitle.Font = currentTheme.subtitleFont
        self._subtitle.TextSize = currentTheme.subtitleTextSize
        self._subtitle.TextColor3 = Color3.fromRGB(188, 206, 255)
    end
    if self._subtitlePill then
        self._subtitlePill.BackgroundColor3 = accent:Lerp(cardColor, 0.7)
        self._subtitlePill.BackgroundTransparency = 0.35
    end
    if self._surface then
        self._surface.BackgroundColor3 = cardColor:Lerp(accent, 0.06)
        self._surface.BackgroundTransparency = math.clamp(cardTransparency + 0.12, 0, 1)
    end
    if self._surfaceStroke then
        self._surfaceStroke.Color = (currentTheme.cardStrokeColor or DEFAULT_THEME.cardStrokeColor):Lerp(accent, 0.35)
        self._surfaceStroke.Transparency = math.clamp(cardStrokeTransparency + 0.1, 0, 1)
    end
    if self._surfaceGradient then
        self._surfaceGradient.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, cardColor:Lerp(accent, 0.2)),
            ColorSequenceKeypoint.new(1, cardColor),
        })
        self._surfaceGradient.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, math.clamp(cardTransparency + 0.05, 0, 1)),
            NumberSequenceKeypoint.new(0.45, math.clamp(cardTransparency + 0.12, 0, 1)),
            NumberSequenceKeypoint.new(1, math.clamp(cardTransparency + 0.2, 0, 1)),
        })
    end
    if self._progressLabel then
        self._progressLabel.Font = currentTheme.stepStatusFont
        self._progressLabel.TextSize = currentTheme.stepStatusTextSize
        self._progressLabel.TextColor3 = Color3.fromRGB(170, 186, 220)
    end
    if self._progressTrack then
        self._progressTrack.BackgroundColor3 = Color3.fromRGB(26, 32, 52)
        self._progressTrack.BackgroundTransparency = 0.1
    end
    if self._progressFill then
        self._progressFill.BackgroundColor3 = accent
    end
    if self._timelineSpine then
        self._timelineSpine.BackgroundColor3 = currentTheme.connectorColor or DEFAULT_THEME.connectorColor
        self._timelineSpine.BackgroundTransparency = math.clamp(connectorTransparency + 0.1, 0, 1)
    end
    if self._timelineSpineGradient then
        self._timelineSpineGradient.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, currentTheme.connectorColor or DEFAULT_THEME.connectorColor),
            ColorSequenceKeypoint.new(1, accent),
        })
        self._timelineSpineGradient.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.45),
            NumberSequenceKeypoint.new(1, 0.05),
        })
    end
    if self._actionsDivider then
        self._actionsDivider.BackgroundColor3 = currentTheme.cardStrokeColor or DEFAULT_THEME.cardStrokeColor
    end

    for _, definition in ipairs(STEP_DEFINITIONS) do
        local step = self._steps[definition.id]
        if step then
            step.frame.BackgroundColor3 = cardColor
            step.frame.BackgroundTransparency = currentTheme.cardTransparency
            if step.frame:FindFirstChildOfClass("UIStroke") then
                local stroke = step.frame:FindFirstChildOfClass("UIStroke")
                stroke.Color = currentTheme.cardStrokeColor
                stroke.Transparency = currentTheme.cardStrokeTransparency
            end
            step.title.Font = currentTheme.stepTitleFont
            step.title.TextSize = currentTheme.stepTitleTextSize
            step.status.Font = currentTheme.stepStatusFont
            step.status.TextSize = currentTheme.stepStatusTextSize
            step.status.TextColor3 = Color3.fromRGB(180, 194, 235)
            if step.stateLabel then
                step.stateLabel.Font = currentTheme.stepStatusFont
                step.stateLabel.TextSize = currentTheme.stepStatusTextSize
            end
            if step.statePill then
                step.statePill.BackgroundColor3 = cardColor:Lerp(accent, 0.28)
                step.statePill.BackgroundTransparency = 0.25
            end
            if step.tooltip then
                step.tooltip.Font = currentTheme.tooltipFont
                step.tooltip.TextSize = currentTheme.tooltipTextSize
                step.tooltip.BackgroundColor3 = currentTheme.tooltipBackground
                step.tooltip.BackgroundTransparency = currentTheme.tooltipTransparency
                step.tooltip.TextColor3 = currentTheme.tooltipTextColor
            end
        end
    end

    self:_updateTimelineSpine()

    for _, connection in ipairs(self._actionConnections) do
        if connection then
            if connection.Disconnect then
                connection:Disconnect()
            elseif connection.disconnect then
                connection:disconnect()
            end
        end
    end
    self._actionConnections = {}

    for _, button in ipairs(self._actionButtons) do
        if button and button.Destroy then
            button:Destroy()
        end
    end
    self._actionButtons = {}

    if self._actions then
        self:setActions(self._actions)
    end

    for id, info in pairs(self._stepStates) do
        if info and info.status then
            self:_applyStepState(id, info.status, info.message, info.tooltip)
        end
    end

    self:_startLogoShimmer()
end

function VerificationDashboard:setStatusText(text)
    if self._destroyed then
        return
    end
    if self._subtitle then
        self._subtitle.Text = text or ""
    end
end

function VerificationDashboard:setProgress(alpha)
    if self._destroyed then
        return
    end

    alpha = math.clamp(alpha or 0, 0, 1)

    if self._progressTween then
        self._progressTween:Cancel()
        self._progressTween = nil
    end

    if self._progressLabel then
        self._progressLabel.Text = string.format("Verification progress • %d%%", math.floor(alpha * 100 + 0.5))
    end

    if not self._progressFill then
        return
    end

    local tween = TweenService:Create(self._progressFill, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Size = UDim2.new(alpha, 0, 1, 0),
    })
    self._progressTween = tween
    tween:Play()
end

function VerificationDashboard:reset()
    if self._destroyed then
        return
    end

    for _, definition in ipairs(STEP_DEFINITIONS) do
        local step = self._steps[definition.id]
        if step then
            step.state = "pending"
            step.priority = STATUS_PRIORITY.pending
            step.status.Text = definition.description
            if step.iconTween then
                step.iconTween:Cancel()
                step.iconTween = nil
            end
            step.icon.Image = self._theme.iconography.pending
            step.icon.ImageColor3 = self._theme.pendingColor
            if step.iconGlow then
                step.iconGlow.Color = self._theme.pendingColor
            end
            step.connector.BackgroundTransparency = self._theme.connectorTransparency
            step.connector.BackgroundColor3 = self._theme.connectorColor
            if step.stateLabel then
                step.stateLabel.Text = "Pending"
                step.stateLabel.TextColor3 = Color3.fromRGB(220, 234, 255)
                step.stateLabel.Font = self._theme.stepStatusFont
                step.stateLabel.TextSize = self._theme.stepStatusTextSize
            end
            if step.statePill then
                step.statePill.BackgroundColor3 = (self._theme.cardColor or DEFAULT_THEME.cardColor):Lerp(self._theme.accentColor or DEFAULT_THEME.accentColor, 0.28)
                step.statePill.BackgroundTransparency = 0.25
            end
            if step.tooltip then
                step.tooltip.Text = definition.tooltip
            end
        end
        self._stepStates[definition.id] = {
            status = "pending",
            priority = STATUS_PRIORITY.pending,
            message = definition.description,
            tooltip = definition.tooltip,
        }
    end

    self:setProgress(0)
    self:setStatusText("Preparing AutoParry systems…")
    self:_updateTimelineSpine()
end

local function resolveStyle(theme, status)
    local resolver = STATUS_STYLE[status]
    if resolver then
        return resolver(theme)
    end
    return STATUS_STYLE.pending(theme)
end

function VerificationDashboard:_applyStepState(id, status, message, tooltip)
    if self._destroyed then
        return
    end

    local step = self._steps[id]
    if not step then
        return
    end

    local current = self._stepStates[id]
    current = current or { status = "pending", priority = STATUS_PRIORITY.pending }
    local newPriority = STATUS_PRIORITY[status] or STATUS_PRIORITY.pending
    if current.priority and current.priority > newPriority then
        return
    end

    self._stepStates[id] = {
        status = status,
        priority = newPriority,
        message = label,
        tooltip = tooltip or (step.tooltip and step.tooltip.Text) or nil,
    }

    local style = resolveStyle(self._theme, status)

    local label = message or style.label
    if label and label ~= "" then
        step.status.Text = label
    end

    if tooltip and step.tooltip then
        step.tooltip.Text = tooltip
    end

    if step.iconTween then
        step.iconTween:Cancel()
        step.iconTween = nil
    end

    if style.icon then
        step.icon.Image = style.icon
    end

    local tween = TweenService:Create(step.icon, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        ImageColor3 = style.color,
        ImageTransparency = 0,
    })
    step.iconTween = tween
    tween:Play()

    if step.iconGlow then
        step.iconGlow.Color = style.color
        step.iconGlow.Transparency = 0.35
    end

    if step.connector then
        step.connector.BackgroundColor3 = style.color
        step.connector.BackgroundTransparency = status == "pending" and self._theme.connectorTransparency or 0.15
    end

    if step.stateLabel then
        if style.label then
            step.stateLabel.Text = style.label
        end
        if style.color then
            step.stateLabel.TextColor3 = style.color:Lerp(Color3.fromRGB(240, 242, 255), 0.35)
        end
    end

    if step.statePill then
        local pillBase = self._theme.cardColor or DEFAULT_THEME.cardColor
        local pillColor = style.color or (self._theme.accentColor or DEFAULT_THEME.accentColor)
        local blend = status == "pending" and 0.28 or 0.5
        step.statePill.BackgroundColor3 = pillBase:Lerp(pillColor, blend)
        step.statePill.BackgroundTransparency = status == "pending" and 0.35 or 0.18
    end

    step.state = status

    task.defer(function()
        if not self._destroyed then
            self:_updateTimelineSpine()
        end
    end)
end

local function formatElapsed(seconds)
    if not seconds or seconds <= 0 then
        return nil
    end
    if seconds < 1 then
        return string.format("%.2f s", seconds)
    end
    return string.format("%.1f s", seconds)
end

function VerificationDashboard:_applyParrySnapshot(snapshot)
    if typeof(snapshot) ~= "table" then
        return
    end

    local stage = snapshot.stage
    local status = snapshot.status
    local target = snapshot.target or snapshot.step

    if stage == "ready" then
        self:_applyStepState("player", "ok", "Player locked")
        self:_applyStepState("remotes", "ok", string.format("%s (%s)", snapshot.remoteName or "Parry remote", snapshot.remoteVariant or "detected"))
        if snapshot.successEvents then
            self:_applyStepState("success", "ok", "Success listeners wired")
        else
            self:_applyStepState("success", "ok", "Success listeners active")
        end
        if snapshot.successEvents and snapshot.successEvents.Balls then
            self:_applyStepState("balls", "ok", "Ball telemetry streaming")
        else
            self:_applyStepState("balls", "ok", "Ready for match")
        end
        return
    end

    if stage == "timeout" then
        local reason = snapshot.reason or target
        if reason == "local-player" or target == "local-player" then
            self:_applyStepState("player", "failed", "Timed out waiting for player")
        elseif reason == "remotes-folder" or target == "folder" then
            self:_applyStepState("remotes", "failed", "Remotes folder missing")
        elseif reason == "parry-remote" or target == "remote" then
            self:_applyStepState("remotes", "failed", "Parry remote unavailable")
        elseif reason == "balls-folder" then
            self:_applyStepState("balls", "warning", "Balls folder not found")
        end
        return
    end

    if stage == "error" then
        if target == "remote" then
            self:_applyStepState("remotes", "failed", snapshot.message or "Unsupported parry remote")
        elseif target == "folder" then
            self:_applyStepState("remotes", "failed", snapshot.message or "Remotes folder removed")
        else
            self:_applyStepState("success", "warning", snapshot.message or "Verification error")
        end
        return
    end

    if stage == "waiting-player" then
        if status == "ok" then
            local elapsed = formatElapsed(snapshot.elapsed)
            self:_applyStepState("player", "ok", elapsed and ("Player ready (" .. elapsed .. ")") or "Player ready")
        elseif status == "waiting" or status == "pending" then
            self:_applyStepState("player", "active", "Waiting for player…")
        end
        return
    end

    if stage == "waiting-remotes" then
        if target == "folder" then
            if status == "ok" then
                self:_applyStepState("remotes", "active", "Remotes folder located")
            elseif status == "waiting" or status == "pending" then
                self:_applyStepState("remotes", "active", "Searching for Remotes folder…")
            end
        elseif target == "remote" then
            if status == "ok" then
                local name = snapshot.remoteName or "Parry remote"
                local variant = snapshot.remoteVariant or "detected"
                self:_applyStepState("remotes", "ok", string.format("%s (%s)", name, variant))
            elseif status == "waiting" or status == "pending" then
                self:_applyStepState("remotes", "active", "Scanning for parry remote…")
            end
        end
        return
    end

    if stage == "verifying-success-remotes" then
        self:_applyStepState("success", "active", "Hooking success events…")
        if snapshot.remotes then
            self:_applyStepState("success", "ok", "Success listeners bound")
        end
        return
    end

    if stage == "verifying-balls" then
        if status == "ok" then
            self:_applyStepState("balls", "ok", "Ball telemetry online")
        elseif status == "waiting" then
            self:_applyStepState("balls", "active", "Searching for balls…")
        elseif status == "warning" then
            self:_applyStepState("balls", "warning", "Ball folder timeout", "AutoParry will continue without ball telemetry if the folder is missing.")
        end
        return
    end
end

local function extractErrorReason(errorState)
    if typeof(errorState) ~= "table" then
        return nil, nil
    end

    local payload = errorState.payload
    local reason = errorState.reason
    if payload and typeof(payload) == "table" then
        reason = payload.reason or payload.target or payload.step or reason
    end

    return reason, payload
end

function VerificationDashboard:_applyError(errorState)
    if not errorState then
        return
    end

    local reason, payload = extractErrorReason(errorState)
    local message = errorState.message or "Verification error"

    if reason == "local-player" then
        self:_applyStepState("player", "failed", message)
    elseif reason == "remotes-folder" or reason == "parry-remote" or reason == "remote" then
        self:_applyStepState("remotes", "failed", message)
    elseif reason == "balls-folder" or reason == "balls" then
        self:_applyStepState("balls", "warning", message)
    else
        self:_applyStepState("success", "warning", message)
    end

    if payload and payload.elapsed then
        self:setStatusText(string.format("Failed after %s", formatElapsed(payload.elapsed) or "0 s"))
    else
        self:setStatusText(message)
    end
end

function VerificationDashboard:update(state, context)
    if self._destroyed then
        return
    end

    state = state or {}

    if state.parry then
        self:_applyParrySnapshot(state.parry)
    elseif state.stage then
        self:_applyParrySnapshot(state)
    end

    if state.error then
        self:_applyError(state.error)
    end

    if context and context.progress then
        self:setProgress(context.progress)
    end
end

function VerificationDashboard:setActions(actions)
    if self._destroyed then
        return
    end

    self._actions = actions

    for _, connection in ipairs(self._actionConnections) do
        if connection then
            if connection.Disconnect then
                connection:Disconnect()
            elseif connection.disconnect then
                connection:disconnect()
            end
        end
    end
    self._actionConnections = {}

    for _, button in ipairs(self._actionButtons) do
        if button and button.Destroy then
            button:Destroy()
        end
    end
    self._actionButtons = {}

    if self._actionsDivider then
        self._actionsDivider.Visible = false
    end

    if typeof(actions) ~= "table" or #actions == 0 then
        if self._actionsFrame then
            self._actionsFrame.Visible = false
        end
        return
    end

    if not self._actionsFrame then
        return
    end

    self._actionsFrame.Visible = true
    if self._actionsDivider then
        self._actionsDivider.Visible = true
    end

    for index, action in ipairs(actions) do
        local button = Instance.new("TextButton")
        button.Name = action.id or action.name or string.format("Action%d", index)
        button.Text = action.text or action.label or "Action"
        button.BackgroundTransparency = 0
        button.ZIndex = 5
        button.LayoutOrder = action.order or index
        button.Parent = self._actionsFrame

        styleActionButton(button, self._theme, action)

        local connection
        if typeof(action.callback) == "function" then
            connection = button.MouseButton1Click:Connect(function()
                action.callback(self, action)
            end)
        end

        table.insert(self._actionButtons, button)
        table.insert(self._actionConnections, connection)
    end
end

return VerificationDashboard
