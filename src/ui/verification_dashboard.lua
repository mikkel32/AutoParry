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
    telemetry = {
        titleFont = Enum.Font.GothamBold,
        titleTextSize = 16,
        valueFont = Enum.Font.GothamBlack,
        valueTextSize = 24,
        labelFont = Enum.Font.Gotham,
        labelTextSize = 14,
        cardColor = Color3.fromRGB(18, 24, 40),
        cardTransparency = 0.08,
        cardStrokeColor = Color3.fromRGB(0, 160, 255),
        cardStrokeTransparency = 0.45,
        accentColor = Color3.fromRGB(0, 210, 255),
    },
    controls = {
        headerFont = Enum.Font.GothamBold,
        headerTextSize = 16,
        headerColor = Color3.fromRGB(220, 234, 255),
        descriptionFont = Enum.Font.Gotham,
        descriptionTextSize = 14,
        descriptionColor = Color3.fromRGB(178, 194, 230),
        toggleOnColor = Color3.fromRGB(0, 210, 255),
        toggleOffColor = Color3.fromRGB(32, 42, 64),
        toggleOnTextColor = Color3.fromRGB(12, 16, 20),
        toggleOffTextColor = Color3.fromRGB(220, 234, 255),
        toggleCorner = UDim.new(0, 12),
        toggleStrokeColor = Color3.fromRGB(0, 210, 255),
        toggleStrokeTransparency = 0.4,
        toggleBadgeFont = Enum.Font.GothamSemibold,
        toggleBadgeSize = 13,
        toggleBadgeColor = Color3.fromRGB(170, 200, 255),
        sectionBackground = Color3.fromRGB(14, 18, 32),
        sectionTransparency = 0.08,
        sectionStrokeColor = Color3.fromRGB(0, 170, 255),
        sectionStrokeTransparency = 0.5,
        sectionGradient = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(12, 18, 30)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 120, 200)),
        }),
        sectionGradientTransparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.85),
            NumberSequenceKeypoint.new(1, 0.3),
        }),
    },
}

local DEFAULT_TELEMETRY = {
    {
        id = "latency",
        label = "Latency",
        value = "-- ms",
        hint = "Ping to Blade Ball server",
    },
    {
        id = "uptime",
        label = "Session",
        value = "00:00",
        hint = "Runtime since activation",
    },
    {
        id = "autotune",
        label = "Auto-Tune",
        value = "Calibrating",
        hint = "Adaptive neural mesh status",
    },
}

local CONTROL_DEFINITIONS = {
    {
        id = "adaptive",
        title = "Adaptive Reaction",
        description = "Auto-learns opponent speed to retime parries in real-time.",
        default = true,
        badge = "AI",
    },
    {
        id = "failsafe",
        title = "Failsafe Recall",
        description = "Instantly revert to manual control if anomalies are detected.",
        default = true,
        badge = "SAFE",
    },
    {
        id = "edge",
        title = "Edge Prediction",
        description = "Predict ricochet vectors and pre-aim at the next ball handoff.",
        default = false,
    },
    {
        id = "audible",
        title = "Audible Cues",
        description = "Emit positional pings for high-priority parry windows.",
        default = true,
    },
    {
        id = "ghost",
        title = "Ghost Anticipation",
        description = "Simulate incoming trajectories to pre-charge counter windows.",
        default = false,
    },
    {
        id = "autosync",
        title = "Autosync Party",
        description = "Synchronise teammates with shared parry telemetry.",
        default = true,
        badge = "TEAM",
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
    frame.Size = UDim2.new(1, 0, 0, 72)
    frame.BackgroundColor3 = theme.cardColor
    frame.BackgroundTransparency = theme.cardTransparency
    frame.BorderSizePixel = 0
    frame.Parent = parent
    frame.ClipsDescendants = true
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
    icon.Size = UDim2.new(0, 36, 0, 36)
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

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.AnchorPoint = Vector2.new(0, 0)
    title.Position = UDim2.new(0, 66, 0, 10)
    title.Size = UDim2.new(1, -90, 0, 24)
    title.BackgroundTransparency = 1
    title.Font = theme.stepTitleFont
    title.TextSize = theme.stepTitleTextSize
    title.TextColor3 = Color3.fromRGB(235, 240, 255)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = definition.title
    title.Parent = frame

    local status = Instance.new("TextLabel")
    status.Name = "Status"
    status.AnchorPoint = Vector2.new(0, 0)
    status.Position = UDim2.new(0, 66, 0, 34)
    status.Size = UDim2.new(1, -90, 0, 24)
    status.BackgroundTransparency = 1
    status.Font = theme.stepStatusFont
    status.TextSize = theme.stepStatusTextSize
    status.TextColor3 = Color3.fromRGB(180, 194, 235)
    status.TextXAlignment = Enum.TextXAlignment.Left
    status.Text = definition.description
    status.Parent = frame

    local connector = Instance.new("Frame")
    connector.Name = "Connector"
    connector.AnchorPoint = Vector2.new(0.5, 0)
    connector.Position = UDim2.new(0, 34, 1, -4)
    connector.Size = UDim2.new(0, 4, 0, 24)
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

local function createTelemetryCard(parent, theme, definition)
    local telemetryTheme = theme.telemetry or DEFAULT_THEME.telemetry

    local card = Instance.new("Frame")
    card.Name = string.format("Telemetry_%s", definition.id)
    card.BackgroundColor3 = telemetryTheme.cardColor
    card.BackgroundTransparency = telemetryTheme.cardTransparency
    card.BorderSizePixel = 0
    card.Size = UDim2.new(0, 0, 0, 96)
    card.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 12)
    corner.Parent = card

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1.1
    stroke.Transparency = telemetryTheme.cardStrokeTransparency
    stroke.Color = telemetryTheme.cardStrokeColor
    stroke.Parent = card

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 10)
    padding.PaddingBottom = UDim.new(0, 12)
    padding.PaddingLeft = UDim.new(0, 12)
    padding.PaddingRight = UDim.new(0, 12)
    padding.Parent = card

    local label = Instance.new("TextLabel")
    label.Name = "Label"
    label.BackgroundTransparency = 1
    label.Size = UDim2.new(1, 0, 0, 18)
    label.Font = telemetryTheme.labelFont
    label.TextSize = telemetryTheme.labelTextSize
    label.TextColor3 = (telemetryTheme.accentColor or theme.accentColor):Lerp(Color3.new(1, 1, 1), 0.35)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = definition.label or definition.id
    label.Parent = card

    local value = Instance.new("TextLabel")
    value.Name = "Value"
    value.BackgroundTransparency = 1
    value.Size = UDim2.new(1, 0, 0, 32)
    value.Position = UDim2.new(0, 0, 0, 20)
    value.Font = telemetryTheme.valueFont
    value.TextSize = telemetryTheme.valueTextSize
    value.TextXAlignment = Enum.TextXAlignment.Left
    value.TextColor3 = Color3.fromRGB(235, 245, 255)
    value.Text = tostring(definition.value or "--")
    value.Parent = card

    local hint = Instance.new("TextLabel")
    hint.Name = "Hint"
    hint.BackgroundTransparency = 1
    hint.Size = UDim2.new(1, 0, 0, 22)
    hint.Position = UDim2.new(0, 0, 0, 54)
    hint.Font = telemetryTheme.labelFont
    hint.TextSize = telemetryTheme.labelTextSize - 1
    hint.TextColor3 = Color3.fromRGB(176, 196, 230)
    hint.TextXAlignment = Enum.TextXAlignment.Left
    hint.TextTransparency = 0.15
    hint.TextWrapped = true
    hint.Text = definition.hint or ""
    hint.Parent = card

    return {
        frame = card,
        stroke = stroke,
        label = label,
        value = value,
        hint = hint,
        definition = definition,
    }
end

local function createControlToggle(parent, theme, definition)
    local controlsTheme = theme.controls or DEFAULT_THEME.controls

    local button = Instance.new("TextButton")
    button.Name = definition.id or "Control"
    button.AutoButtonColor = false
    button.BackgroundColor3 = controlsTheme.toggleOffColor
    button.BorderSizePixel = 0
    button.Size = UDim2.new(0, 240, 0, 96)
    button.Text = ""
    button.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = controlsTheme.toggleCorner or DEFAULT_THEME.controls.toggleCorner
    corner.Parent = button

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1.25
    stroke.Color = controlsTheme.toggleStrokeColor or DEFAULT_THEME.controls.toggleStrokeColor
    stroke.Transparency = controlsTheme.toggleStrokeTransparency or DEFAULT_THEME.controls.toggleStrokeTransparency
    stroke.Parent = button

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 14)
    padding.PaddingBottom = UDim.new(0, 14)
    padding.PaddingLeft = UDim.new(0, 16)
    padding.PaddingRight = UDim.new(0, 16)
    padding.Parent = button

    local indicator = Instance.new("Frame")
    indicator.Name = "Indicator"
    indicator.BackgroundColor3 = controlsTheme.toggleOnColor or DEFAULT_THEME.controls.toggleOnColor
    indicator.BackgroundTransparency = 0.35
    indicator.BorderSizePixel = 0
    indicator.Size = UDim2.new(0, 4, 1, -28)
    indicator.Position = UDim2.new(0, -2, 0, 14)
    indicator.Visible = false
    indicator.Parent = button

    local indicatorCorner = Instance.new("UICorner")
    indicatorCorner.CornerRadius = UDim.new(1, 0)
    indicatorCorner.Parent = indicator

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.BackgroundTransparency = 1
    title.Size = UDim2.new(1, -8, 0, 24)
    title.Position = UDim2.new(0, 0, 0, 0)
    title.Font = controlsTheme.headerFont or DEFAULT_THEME.controls.headerFont
    title.TextSize = controlsTheme.headerTextSize or DEFAULT_THEME.controls.headerTextSize
    title.TextColor3 = controlsTheme.headerColor or DEFAULT_THEME.controls.headerColor
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = definition.title or definition.id
    title.Parent = button

    local badge
    if definition.badge then
        badge = Instance.new("TextLabel")
        badge.Name = "Badge"
        badge.AnchorPoint = Vector2.new(1, 0)
        badge.Position = UDim2.new(1, 0, 0, 0)
        badge.Size = UDim2.new(0, 52, 0, 22)
        badge.BackgroundTransparency = 0.2
        badge.BackgroundColor3 = (controlsTheme.toggleStrokeColor or DEFAULT_THEME.controls.toggleStrokeColor):Lerp(Color3.new(1, 1, 1), 0.3)
        badge.Font = controlsTheme.toggleBadgeFont or DEFAULT_THEME.controls.toggleBadgeFont
        badge.TextSize = controlsTheme.toggleBadgeSize or DEFAULT_THEME.controls.toggleBadgeSize
        badge.TextColor3 = controlsTheme.toggleBadgeColor or DEFAULT_THEME.controls.toggleBadgeColor
        badge.TextXAlignment = Enum.TextXAlignment.Center
        badge.Text = tostring(definition.badge)
        badge.Parent = button

        local badgeCorner = Instance.new("UICorner")
        badgeCorner.CornerRadius = UDim.new(0, 10)
        badgeCorner.Parent = badge
    end

    local description = Instance.new("TextLabel")
    description.Name = "Description"
    description.BackgroundTransparency = 1
    description.Position = UDim2.new(0, 0, 0, 30)
    description.Size = UDim2.new(1, -8, 0, 38)
    description.TextWrapped = true
    description.TextXAlignment = Enum.TextXAlignment.Left
    description.Font = controlsTheme.descriptionFont or DEFAULT_THEME.controls.descriptionFont
    description.TextSize = controlsTheme.descriptionTextSize or DEFAULT_THEME.controls.descriptionTextSize
    description.TextColor3 = controlsTheme.descriptionColor or DEFAULT_THEME.controls.descriptionColor
    description.Text = definition.description or ""
    description.Parent = button

    local status = Instance.new("TextLabel")
    status.Name = "Status"
    status.AnchorPoint = Vector2.new(1, 1)
    status.Position = UDim2.new(1, 0, 1, -2)
    status.Size = UDim2.new(0, 70, 0, 18)
    status.BackgroundTransparency = 1
    status.Font = controlsTheme.descriptionFont or DEFAULT_THEME.controls.descriptionFont
    status.TextSize = (controlsTheme.descriptionTextSize or DEFAULT_THEME.controls.descriptionTextSize) - 1
    status.TextColor3 = controlsTheme.descriptionColor or DEFAULT_THEME.controls.descriptionColor
    status.TextXAlignment = Enum.TextXAlignment.Right
    status.Text = "OFF"
    status.Parent = button

    return {
        button = button,
        indicator = indicator,
        title = title,
        description = description,
        badge = badge,
        status = status,
        stroke = stroke,
        definition = definition,
        enabled = false,
    }
end

local function styleControlToggle(toggle, theme, enabled)
    local controlsTheme = theme.controls or DEFAULT_THEME.controls
    local onColor = controlsTheme.toggleOnColor or DEFAULT_THEME.controls.toggleOnColor
    local offColor = controlsTheme.toggleOffColor or DEFAULT_THEME.controls.toggleOffColor
    local onTextColor = controlsTheme.toggleOnTextColor or DEFAULT_THEME.controls.toggleOnTextColor
    local offTextColor = controlsTheme.toggleOffTextColor or controlsTheme.headerColor or DEFAULT_THEME.controls.headerColor
    local descriptionColor = controlsTheme.descriptionColor or DEFAULT_THEME.controls.descriptionColor

    if toggle.button then
        toggle.button.BackgroundColor3 = enabled and onColor:Lerp(Color3.new(1, 1, 1), 0.08) or offColor
    end
    if toggle.stroke then
        toggle.stroke.Color = controlsTheme.toggleStrokeColor or DEFAULT_THEME.controls.toggleStrokeColor
        toggle.stroke.Transparency = enabled and 0.18 or (controlsTheme.toggleStrokeTransparency or DEFAULT_THEME.controls.toggleStrokeTransparency)
    end
    if toggle.indicator then
        toggle.indicator.Visible = enabled
        toggle.indicator.BackgroundColor3 = onColor
    end
    if toggle.title then
        toggle.title.TextColor3 = enabled and onTextColor or offTextColor
    end
    if toggle.description then
        toggle.description.TextColor3 = enabled and descriptionColor or descriptionColor:Lerp(Color3.new(0.6, 0.66, 0.8), 0.35)
    end
    if toggle.status then
        toggle.status.Text = enabled and "ON" or "OFF"
        toggle.status.TextColor3 = enabled and onTextColor or descriptionColor
    end
    if toggle.badge then
        toggle.badge.TextColor3 = controlsTheme.toggleBadgeColor or DEFAULT_THEME.controls.toggleBadgeColor
        toggle.badge.BackgroundTransparency = enabled and 0.1 or 0.35
    end

    toggle.enabled = enabled
end

local function styleActionButton(button, theme, action)
    local isSecondary = action.variant == "secondary" or action.kind == "cancel"
    button.AutoButtonColor = true
    button.BackgroundColor3 = isSecondary and theme.actionSecondaryColor or theme.actionPrimaryColor
    button.TextColor3 = isSecondary and theme.actionSecondaryTextColor or theme.actionPrimaryTextColor
    button.Font = theme.actionFont
    button.TextSize = theme.actionTextSize
    button.Size = UDim2.new(0, action.width or 140, 0, theme.actionHeight)

    local corner = Instance.new("UICorner")
    corner.CornerRadius = theme.actionCorner
    corner.Parent = button

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1.5
    stroke.Transparency = 0.35
    stroke.Color = theme.accentColor
    stroke.Parent = button
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
    root.Parent = parent

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 12)
    padding.PaddingBottom = UDim.new(0, 12)
    padding.PaddingLeft = UDim.new(0, 12)
    padding.PaddingRight = UDim.new(0, 12)
    padding.Parent = root

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Stretch
    layout.VerticalAlignment = Enum.VerticalAlignment.Top
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 18)
    layout.Parent = root

    local header = Instance.new("Frame")
    header.Name = "Header"
    header.BackgroundTransparency = 1
    header.Size = UDim2.new(1, 0, 0, 96)
    header.LayoutOrder = 1
    header.Parent = root

    local headerLayout = Instance.new("UIListLayout")
    headerLayout.FillDirection = Enum.FillDirection.Horizontal
    headerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    headerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    headerLayout.SortOrder = Enum.SortOrder.LayoutOrder
    headerLayout.Padding = UDim.new(0, 18)
    headerLayout.Parent = header

    local logoContainer = Instance.new("Frame")
    logoContainer.Name = "LogoContainer"
    logoContainer.BackgroundTransparency = 1
    logoContainer.Size = UDim2.new(0, 230, 1, 0)
    logoContainer.Parent = header

    local logoElements = createLogoBadge(logoContainer, theme)

    local textContainer = Instance.new("Frame")
    textContainer.Name = "HeaderText"
    textContainer.BackgroundTransparency = 1
    textContainer.Size = UDim2.new(1, -230, 1, 0)
    textContainer.Parent = header

    local textLayout = Instance.new("UIListLayout")
    textLayout.FillDirection = Enum.FillDirection.Vertical
    textLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    textLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    textLayout.SortOrder = Enum.SortOrder.LayoutOrder
    textLayout.Padding = UDim.new(0, 4)
    textLayout.Parent = textContainer

    local title = Instance.new("TextLabel")
    title.Name = "Heading"
    title.BackgroundTransparency = 1
    title.Size = UDim2.new(1, 0, 0, 30)
    title.Font = theme.titleFont
    title.TextSize = theme.titleTextSize
    title.TextColor3 = Color3.fromRGB(235, 245, 255)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "Verification Timeline"
    title.LayoutOrder = 1
    title.Parent = textContainer

    local subtitle = Instance.new("TextLabel")
    subtitle.Name = "Subtitle"
    subtitle.BackgroundTransparency = 1
    subtitle.Size = UDim2.new(1, 0, 0, 24)
    subtitle.Font = theme.subtitleFont
    subtitle.TextSize = theme.subtitleTextSize
    subtitle.TextColor3 = Color3.fromRGB(170, 184, 220)
    subtitle.TextXAlignment = Enum.TextXAlignment.Left
    subtitle.Text = "Preparing AutoParry systems…"
    subtitle.LayoutOrder = 2
    subtitle.Parent = textContainer

    local telemetryFrame = Instance.new("Frame")
    telemetryFrame.Name = "Telemetry"
    telemetryFrame.BackgroundTransparency = 1
    telemetryFrame.Size = UDim2.new(1, 0, 0, 110)
    telemetryFrame.LayoutOrder = 2
    telemetryFrame.Parent = root

    local telemetryGrid = Instance.new("UIGridLayout")
    telemetryGrid.FillDirection = Enum.FillDirection.Horizontal
    telemetryGrid.HorizontalAlignment = Enum.HorizontalAlignment.Left
    telemetryGrid.VerticalAlignment = Enum.VerticalAlignment.Top
    telemetryGrid.SortOrder = Enum.SortOrder.LayoutOrder
    telemetryGrid.CellPadding = UDim2.new(0, 12, 0, 12)
    telemetryGrid.CellSize = UDim2.new(0.333, -12, 0, 96)
    telemetryGrid.Parent = telemetryFrame

    local telemetryCards = {}
    for index, definition in ipairs(DEFAULT_TELEMETRY) do
        local card = createTelemetryCard(telemetryFrame, theme, definition)
        card.frame.LayoutOrder = index
        telemetryCards[definition.id] = card
    end

    local controlPanel = Instance.new("Frame")
    controlPanel.Name = "ControlPanel"
    controlPanel.BackgroundColor3 = theme.controls.sectionBackground or DEFAULT_THEME.controls.sectionBackground
    controlPanel.BackgroundTransparency = theme.controls.sectionTransparency or DEFAULT_THEME.controls.sectionTransparency
    controlPanel.BorderSizePixel = 0
    controlPanel.LayoutOrder = 3
    controlPanel.AutomaticSize = Enum.AutomaticSize.Y
    controlPanel.Size = UDim2.new(1, 0, 0, 200)
    controlPanel.Parent = root

    local controlCorner = Instance.new("UICorner")
    controlCorner.CornerRadius = DEFAULT_THEME.controls.toggleCorner
    controlCorner.Parent = controlPanel

    local controlStroke = Instance.new("UIStroke")
    controlStroke.Thickness = 1.2
    controlStroke.Color = theme.controls.sectionStrokeColor or DEFAULT_THEME.controls.sectionStrokeColor
    controlStroke.Transparency = theme.controls.sectionStrokeTransparency or DEFAULT_THEME.controls.sectionStrokeTransparency
    controlStroke.Parent = controlPanel

    local controlGradient = Instance.new("UIGradient")
    controlGradient.Color = theme.controls.sectionGradient or DEFAULT_THEME.controls.sectionGradient
    controlGradient.Transparency = theme.controls.sectionGradientTransparency or DEFAULT_THEME.controls.sectionGradientTransparency
    controlGradient.Rotation = 115
    controlGradient.Parent = controlPanel

    local controlPadding = Instance.new("UIPadding")
    controlPadding.PaddingTop = UDim.new(0, 18)
    controlPadding.PaddingBottom = UDim.new(0, 18)
    controlPadding.PaddingLeft = UDim.new(0, 18)
    controlPadding.PaddingRight = UDim.new(0, 18)
    controlPadding.Parent = controlPanel

    local controlStack = Instance.new("Frame")
    controlStack.Name = "ControlStack"
    controlStack.BackgroundTransparency = 1
    controlStack.AutomaticSize = Enum.AutomaticSize.Y
    controlStack.Size = UDim2.new(1, 0, 0, 0)
    controlStack.Parent = controlPanel

    local controlLayout = Instance.new("UIListLayout")
    controlLayout.FillDirection = Enum.FillDirection.Vertical
    controlLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    controlLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    controlLayout.SortOrder = Enum.SortOrder.LayoutOrder
    controlLayout.Padding = UDim.new(0, 12)
    controlLayout.Parent = controlStack

    local controlHeader = Instance.new("TextLabel")
    controlHeader.Name = "ControlHeader"
    controlHeader.BackgroundTransparency = 1
    controlHeader.Size = UDim2.new(1, 0, 0, 26)
    controlHeader.Font = theme.controls.headerFont or DEFAULT_THEME.controls.headerFont
    controlHeader.TextSize = theme.controls.headerTextSize or DEFAULT_THEME.controls.headerTextSize
    controlHeader.TextColor3 = theme.controls.headerColor or DEFAULT_THEME.controls.headerColor
    controlHeader.TextXAlignment = Enum.TextXAlignment.Left
    controlHeader.Text = "Command matrix"
    controlHeader.LayoutOrder = 1
    controlHeader.Parent = controlStack

    local controlGridContainer = Instance.new("Frame")
    controlGridContainer.Name = "ControlGrid"
    controlGridContainer.BackgroundTransparency = 1
    controlGridContainer.AutomaticSize = Enum.AutomaticSize.Y
    controlGridContainer.Size = UDim2.new(1, 0, 0, 0)
    controlGridContainer.LayoutOrder = 2
    controlGridContainer.Parent = controlStack

    local controlGrid = Instance.new("UIGridLayout")
    controlGrid.FillDirection = Enum.FillDirection.Horizontal
    controlGrid.HorizontalAlignment = Enum.HorizontalAlignment.Left
    controlGrid.VerticalAlignment = Enum.VerticalAlignment.Top
    controlGrid.SortOrder = Enum.SortOrder.LayoutOrder
    controlGrid.CellPadding = UDim2.new(0, 12, 0, 12)
    controlGrid.CellSize = UDim2.new(0.5, -12, 0, 96)
    controlGrid.FillDirectionMaxCells = 2
    controlGrid.Parent = controlGridContainer

    local controlButtons = {}

    local timelineCard = Instance.new("Frame")
    timelineCard.Name = "TimelineCard"
    timelineCard.BackgroundColor3 = theme.cardColor
    timelineCard.BackgroundTransparency = theme.cardTransparency
    timelineCard.BorderSizePixel = 0
    timelineCard.AutomaticSize = Enum.AutomaticSize.Y
    timelineCard.Size = UDim2.new(1, 0, 0, 200)
    timelineCard.LayoutOrder = 4
    timelineCard.Parent = root

    local timelineCorner = Instance.new("UICorner")
    timelineCorner.CornerRadius = UDim.new(0, 14)
    timelineCorner.Parent = timelineCard

    local timelineStroke = Instance.new("UIStroke")
    timelineStroke.Thickness = 1.4
    timelineStroke.Color = theme.cardStrokeColor
    timelineStroke.Transparency = theme.cardStrokeTransparency
    timelineStroke.Parent = timelineCard

    local timelinePadding = Instance.new("UIPadding")
    timelinePadding.PaddingTop = UDim.new(0, 18)
    timelinePadding.PaddingBottom = UDim.new(0, 18)
    timelinePadding.PaddingLeft = UDim.new(0, 18)
    timelinePadding.PaddingRight = UDim.new(0, 18)
    timelinePadding.Parent = timelineCard

    local timelineLayout = Instance.new("UIListLayout")
    timelineLayout.FillDirection = Enum.FillDirection.Vertical
    timelineLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    timelineLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    timelineLayout.SortOrder = Enum.SortOrder.LayoutOrder
    timelineLayout.Padding = UDim.new(0, 14)
    timelineLayout.Parent = timelineCard

    local progressTrack = Instance.new("Frame")
    progressTrack.Name = "ProgressTrack"
    progressTrack.Size = UDim2.new(1, 0, 0, 8)
    progressTrack.BackgroundColor3 = Color3.fromRGB(26, 32, 52)
    progressTrack.BackgroundTransparency = 0.2
    progressTrack.BorderSizePixel = 0
    progressTrack.LayoutOrder = 1
    progressTrack.Parent = timelineCard

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
        ColorSequenceKeypoint.new(1, theme.accentColor:lerp(Color3.new(1, 1, 1), 0.25)),
    })
    glow.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.1),
        NumberSequenceKeypoint.new(1, 0.4),
    })
    glow.Parent = progressFill

    local listFrame = Instance.new("Frame")
    listFrame.Name = "Steps"
    listFrame.BackgroundTransparency = 1
    listFrame.AutomaticSize = Enum.AutomaticSize.Y
    listFrame.Size = UDim2.new(1, 0, 0, 0)
    listFrame.LayoutOrder = 2
    listFrame.Parent = timelineCard

    local listLayout = Instance.new("UIListLayout")
    listLayout.FillDirection = Enum.FillDirection.Vertical
    listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    listLayout.Padding = UDim.new(0, 10)
    listLayout.Parent = listFrame

    local steps = {}
    for index, definition in ipairs(STEP_DEFINITIONS) do
        local step = createStep(listFrame, definition, theme)
        step.frame.LayoutOrder = index
        if index == #STEP_DEFINITIONS then
            step.connector.Visible = false
        end
        steps[definition.id] = step
    end

    local actionsFrame = Instance.new("Frame")
    actionsFrame.Name = "Actions"
    actionsFrame.BackgroundTransparency = 1
    actionsFrame.LayoutOrder = 5
    actionsFrame.Size = UDim2.new(1, 0, 0, theme.actionHeight + 12)
    actionsFrame.Visible = false
    actionsFrame.Parent = root

    local actionsLayout = Instance.new("UIListLayout")
    actionsLayout.FillDirection = Enum.FillDirection.Horizontal
    actionsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    actionsLayout.SortOrder = Enum.SortOrder.LayoutOrder
    actionsLayout.Padding = UDim.new(0, 12)
    actionsLayout.Parent = actionsFrame

    local self = setmetatable({
        _theme = theme,
        _root = root,
        _layout = layout,
        _header = header,
        _title = title,
        _subtitle = subtitle,
        _telemetryFrame = telemetryFrame,
        _telemetryGrid = telemetryGrid,
        _telemetryCards = telemetryCards,
        _controlPanel = controlPanel,
        _controlStroke = controlStroke,
        _controlGradient = controlGradient,
        _controlHeader = controlHeader,
        _controlGrid = controlGrid,
        _controlButtons = controlButtons,
        _controlConnections = {},
        _controlState = {},
        _controlDefinitions = CONTROL_DEFINITIONS,
        _onControlChanged = options and options.onControlToggle or nil,
        _timelineCard = timelineCard,
        _timelineStroke = timelineStroke,
        _progressFill = progressFill,
        _progressTween = nil,
        _stepsFrame = listFrame,
        _steps = steps,
        _stepStates = {},
        _actionsFrame = actionsFrame,
        _actionsLayout = actionsLayout,
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
        self._stepStates[definition.id] = { status = "pending", priority = STATUS_PRIORITY.pending }
    end

    self:_applyLogoTheme()
    self:_startLogoShimmer()
    self:setControls(options.controls)
    self:setTelemetry(options.telemetry)
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

    for _, connection in ipairs(self._controlConnections) do
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

    if self._controlButtons then
        for _, toggle in pairs(self._controlButtons) do
            if toggle and toggle.button and toggle.button.Destroy then
                toggle.button:Destroy()
            end
        end
        self._controlButtons = {}
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

    if self._title then
        self._title.Font = currentTheme.titleFont
        self._title.TextSize = currentTheme.titleTextSize
    end
    if self._subtitle then
        self._subtitle.Font = currentTheme.subtitleFont
        self._subtitle.TextSize = currentTheme.subtitleTextSize
    end

    if self._actionsFrame then
        self._actionsFrame.Size = UDim2.new(1, 0, 0, currentTheme.actionHeight + 12)
    end

    if self._progressFill then
        self._progressFill.BackgroundColor3 = currentTheme.accentColor
    end

    if self._telemetryCards then
        local telemetryTheme = currentTheme.telemetry or DEFAULT_THEME.telemetry
        for _, card in pairs(self._telemetryCards) do
            if card.frame then
                card.frame.BackgroundColor3 = telemetryTheme.cardColor
                card.frame.BackgroundTransparency = telemetryTheme.cardTransparency
            end
            if card.stroke then
                card.stroke.Color = telemetryTheme.cardStrokeColor
                card.stroke.Transparency = telemetryTheme.cardStrokeTransparency
            end
            if card.label then
                card.label.Font = telemetryTheme.labelFont
                card.label.TextSize = telemetryTheme.labelTextSize
                card.label.TextColor3 = (telemetryTheme.accentColor or currentTheme.accentColor):Lerp(Color3.new(1, 1, 1), 0.35)
            end
            if card.value then
                card.value.Font = telemetryTheme.valueFont
                card.value.TextSize = telemetryTheme.valueTextSize
                card.value.TextColor3 = Color3.fromRGB(235, 245, 255)
            end
            if card.hint then
                card.hint.Font = telemetryTheme.labelFont
                card.hint.TextSize = math.max((telemetryTheme.labelTextSize or DEFAULT_THEME.telemetry.labelTextSize) - 1, 10)
                card.hint.TextColor3 = Color3.fromRGB(176, 196, 230)
            end
        end
    end

    if self._controlPanel then
        local controlsTheme = currentTheme.controls or DEFAULT_THEME.controls
        self._controlPanel.BackgroundColor3 = controlsTheme.sectionBackground or DEFAULT_THEME.controls.sectionBackground
        self._controlPanel.BackgroundTransparency = controlsTheme.sectionTransparency or DEFAULT_THEME.controls.sectionTransparency
        if self._controlStroke then
            self._controlStroke.Color = controlsTheme.sectionStrokeColor or DEFAULT_THEME.controls.sectionStrokeColor
            self._controlStroke.Transparency = controlsTheme.sectionStrokeTransparency or DEFAULT_THEME.controls.sectionStrokeTransparency
        end
        if self._controlGradient then
            self._controlGradient.Color = controlsTheme.sectionGradient or DEFAULT_THEME.controls.sectionGradient
            self._controlGradient.Transparency = controlsTheme.sectionGradientTransparency or DEFAULT_THEME.controls.sectionGradientTransparency
        end
        if self._controlHeader then
            self._controlHeader.Font = controlsTheme.headerFont or DEFAULT_THEME.controls.headerFont
            self._controlHeader.TextSize = controlsTheme.headerTextSize or DEFAULT_THEME.controls.headerTextSize
            self._controlHeader.TextColor3 = controlsTheme.headerColor or DEFAULT_THEME.controls.headerColor
        end
        if self._controlButtons then
            for id, toggle in pairs(self._controlButtons) do
                local state = self._controlState and self._controlState[id]
                if state == nil then
                    state = toggle.enabled
                end
                styleControlToggle(toggle, currentTheme, not not state)
            end
        end
    end

    if self._timelineCard then
        self._timelineCard.BackgroundColor3 = currentTheme.cardColor
        self._timelineCard.BackgroundTransparency = currentTheme.cardTransparency
    end
    if self._timelineStroke then
        self._timelineStroke.Color = currentTheme.cardStrokeColor
        self._timelineStroke.Transparency = currentTheme.cardStrokeTransparency
    end

    for _, definition in ipairs(STEP_DEFINITIONS) do
        local step = self._steps[definition.id]
        if step then
            step.frame.BackgroundColor3 = currentTheme.cardColor
            step.frame.BackgroundTransparency = currentTheme.cardTransparency
            if step.frame:FindFirstChildOfClass("UIStroke") then
                local stroke = step.frame:FindFirstChildOfClass("UIStroke")
                stroke.Color = currentTheme.cardStrokeColor
                stroke.Transparency = currentTheme.cardStrokeTransparency
            end
            step.icon.ImageColor3 = currentTheme.pendingColor
            step.icon.Image = currentTheme.iconography.pending
            if step.iconGlow then
                step.iconGlow.Color = currentTheme.pendingColor
            end
            step.title.Font = currentTheme.stepTitleFont
            step.title.TextSize = currentTheme.stepTitleTextSize
            step.status.Font = currentTheme.stepStatusFont
            step.status.TextSize = currentTheme.stepStatusTextSize
            step.connector.BackgroundColor3 = currentTheme.connectorColor
            step.connector.BackgroundTransparency = currentTheme.connectorTransparency
            if step.tooltip then
                step.tooltip.Font = currentTheme.tooltipFont
                step.tooltip.TextSize = currentTheme.tooltipTextSize
                step.tooltip.BackgroundColor3 = currentTheme.tooltipBackground
                step.tooltip.BackgroundTransparency = currentTheme.tooltipTransparency
                step.tooltip.TextColor3 = currentTheme.tooltipTextColor
            end
        end
    end

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

function VerificationDashboard:setTelemetry(telemetry)
    if self._destroyed then
        return
    end

    telemetry = telemetry or {}

    if not self._telemetryCards then
        return
    end

    for id, card in pairs(self._telemetryCards) do
        local payload = telemetry[id]
        if payload == nil and typeof(telemetry) == "table" then
            payload = telemetry[string.upper(id or "")] or telemetry[string.lower(id or "")]
        end

        local valueText = payload
        local hintText

        if typeof(payload) == "table" then
            valueText = payload.value or payload.text or payload.display or payload[1]
            hintText = payload.hint or payload.description or payload.label
        end

        if valueText ~= nil and card.value then
            card.value.Text = tostring(valueText)
        elseif card.definition and card.definition.value and card.value then
            card.value.Text = tostring(card.definition.value)
        end

        if card.hint then
            if hintText ~= nil then
                card.hint.Text = tostring(hintText)
            elseif card.definition then
                card.hint.Text = card.definition.hint or ""
            end
        end
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
            if step.tooltip then
                step.tooltip.Text = definition.tooltip
            end
        end
        self._stepStates[definition.id] = { status = "pending", priority = STATUS_PRIORITY.pending }
    end

    self:setProgress(0)
    self:setStatusText("Preparing AutoParry systems…")
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

    self._stepStates[id] = { status = status, priority = newPriority }

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

    step.state = status
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

    for index, action in ipairs(actions) do
        local button = Instance.new("TextButton")
        button.Name = action.id or action.name or string.format("Action%d", index)
        button.Text = action.text or action.label or "Action"
        button.BackgroundTransparency = 0
        button.ZIndex = 5
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

function VerificationDashboard:setControls(controls)
    if self._destroyed then
        return
    end

    controls = controls or self._controlDefinitions or CONTROL_DEFINITIONS

    if typeof(controls) ~= "table" then
        controls = CONTROL_DEFINITIONS
    end

    self._controlDefinitions = controls

    for _, connection in ipairs(self._controlConnections) do
        if connection then
            if connection.Disconnect then
                connection:Disconnect()
            elseif connection.disconnect then
                connection:disconnect()
            end
        end
    end
    self._controlConnections = {}

    if self._controlButtons then
        for _, toggle in pairs(self._controlButtons) do
            if toggle and toggle.button and toggle.button.Destroy then
                toggle.button:Destroy()
            end
        end
    end

    self._controlButtons = {}
    self._controlState = {}

    local grid = self._controlGrid
    if not grid then
        return
    end

    local container = grid.Parent
    if not container then
        return
    end

    for index, definition in ipairs(controls) do
        local id = definition.id or string.format("Control%d", index)
        local toggle = createControlToggle(container, self._theme, definition)
        toggle.button.LayoutOrder = index
        toggle.definition = definition
        self._controlButtons[id] = toggle

        local enabled = definition.enabled
        if enabled == nil then
            enabled = definition.default
        end
        if enabled == nil then
            enabled = true
        end
        enabled = not not enabled
        self._controlState[id] = enabled
        styleControlToggle(toggle, self._theme, enabled)

        local connection = toggle.button.MouseButton1Click:Connect(function()
            self:toggleControl(id)
        end)
        table.insert(self._controlConnections, connection)
    end
end

function VerificationDashboard:setControlState(id, enabled)
    if self._destroyed then
        return
    end

    if id == nil then
        return
    end

    id = tostring(id)
    enabled = not not enabled

    if not self._controlState then
        self._controlState = {}
    end

    self._controlState[id] = enabled

    local toggle = self._controlButtons and self._controlButtons[id]
    if toggle then
        styleControlToggle(toggle, self._theme, enabled)
        if toggle.definition and typeof(toggle.definition.callback) == "function" then
            toggle.definition.callback(self, enabled, toggle)
        end
    end

    if self._onControlChanged then
        self._onControlChanged(id, enabled, toggle and toggle.definition or nil)
    end
end

function VerificationDashboard:toggleControl(id)
    if self._destroyed or id == nil then
        return
    end

    id = tostring(id)
    local current = self._controlState and self._controlState[id]
    if current == nil then
        return
    end
    self:setControlState(id, not current)
end

function VerificationDashboard:getControlState(id)
    if not self._controlState then
        return nil
    end
    return self._controlState[id]
end

return VerificationDashboard
