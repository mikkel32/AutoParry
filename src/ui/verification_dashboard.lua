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
        title = "Player Readiness",
        description = "Waiting for your avatar and character rig.",
        tooltip = "Ensures the LocalPlayer and character are available before continuing.",
    },
    {
        id = "remotes",
        title = "Game Remotes",
        description = "Connecting to Blade Ball remote events.",
        tooltip = "Verifies that the required remote folders exist within ReplicatedStorage.Remotes.",
    },
    {
        id = "success",
        title = "Success Feedback",
        description = "Listening for parry confirmation events.",
        tooltip = "Subscribes to ParrySuccess events so AutoParry can track every confirmation.",
    },
    {
        id = "balls",
        title = "Ball Tracking",
        description = "Tracking live balls for prediction.",
        tooltip = "Validates the balls folder to keep projectile telemetry up to date.",
    },
}

local DEFAULT_THEME = {
    accentColor = Color3.fromRGB(112, 198, 255),
    backgroundTransparency = 1,
    cardColor = Color3.fromRGB(20, 24, 32),
    cardTransparency = 0.02,
    cardStrokeColor = Color3.fromRGB(76, 118, 190),
    cardStrokeTransparency = 0.32,
    connectorColor = Color3.fromRGB(112, 198, 255),
    connectorTransparency = 0.35,
    pendingColor = Color3.fromRGB(142, 152, 188),
    activeColor = Color3.fromRGB(112, 198, 255),
    okColor = Color3.fromRGB(118, 228, 182),
    warningColor = Color3.fromRGB(255, 198, 110),
    failedColor = Color3.fromRGB(248, 110, 128),
    tooltipBackground = Color3.fromRGB(18, 22, 30),
    tooltipTransparency = 0.12,
    tooltipTextColor = Color3.fromRGB(220, 232, 252),
    titleFont = Enum.Font.GothamSemibold,
    titleTextSize = 24,
    subtitleFont = Enum.Font.Gotham,
    subtitleTextSize = 16,
    stepTitleFont = Enum.Font.GothamSemibold,
    stepTitleTextSize = 17,
    stepStatusFont = Enum.Font.Gotham,
    stepStatusTextSize = 14,
    tooltipFont = Enum.Font.Gotham,
    tooltipTextSize = 14,
    actionFont = Enum.Font.GothamSemibold,
    actionTextSize = 16,
    actionHeight = 40,
    actionCorner = UDim.new(0, 10),
    actionPrimaryColor = Color3.fromRGB(112, 198, 255),
    actionPrimaryTextColor = Color3.fromRGB(12, 16, 26),
    actionSecondaryColor = Color3.fromRGB(40, 46, 62),
    actionSecondaryTextColor = Color3.fromRGB(226, 236, 252),
    insights = {
        backgroundColor = Color3.fromRGB(14, 18, 26),
        backgroundTransparency = 0.07,
        strokeColor = Color3.fromRGB(66, 102, 172),
        strokeTransparency = 0.38,
        gradient = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(24, 30, 44)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(12, 16, 26))
        }),
        gradientTransparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.8),
            NumberSequenceKeypoint.new(1, 0.25),
        }),
        gradientRotation = 120,
        paddingTop = 18,
        paddingBottom = 18,
        paddingHorizontal = 20,
        paddingBetween = 16,
    },
    logo = {
        width = 240,
        text = "AutoParry",
        font = Enum.Font.GothamBlack,
        textSize = 28,
        textGradient = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(82, 156, 255)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(88, 206, 157)),
        }),
        textGradientRotation = 18,
        textStrokeColor = Color3.fromRGB(10, 14, 26),
        textStrokeTransparency = 0.65,
        primaryColor = Color3.fromRGB(235, 240, 248),
        tagline = "Precision parry automation",
        taglineFont = Enum.Font.Gotham,
        taglineTextSize = 15,
        taglineColor = Color3.fromRGB(188, 202, 230),
        taglineTransparency = 0.05,
        backgroundColor = Color3.fromRGB(24, 28, 36),
        backgroundTransparency = 0.1,
        strokeColor = Color3.fromRGB(94, 148, 214),
        strokeTransparency = 0.45,
        gradient = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(30, 36, 48)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(82, 156, 255)),
        }),
        gradientTransparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.6),
            NumberSequenceKeypoint.new(0.5, 0.3),
            NumberSequenceKeypoint.new(1, 0.18),
        }),
        gradientRotation = 115,
        glyphImage = "rbxassetid://12148062841",
        glyphColor = Color3.fromRGB(82, 156, 255),
        glyphTransparency = 0.15,
    },
    iconography = {
        pending = "rbxassetid://6031071050",
        active = "rbxassetid://6031075929",
        check = "rbxassetid://6031068421",
        warning = "rbxassetid://6031071051",
        error = "rbxassetid://6031094678",
    },
    telemetry = {
        titleFont = Enum.Font.GothamSemibold,
        titleTextSize = 16,
        valueFont = Enum.Font.GothamBold,
        valueTextSize = 26,
        labelFont = Enum.Font.Gotham,
        labelTextSize = 13,
        cardColor = Color3.fromRGB(26, 30, 40),
        cardTransparency = 0.05,
        cardStrokeColor = Color3.fromRGB(94, 148, 214),
        cardStrokeTransparency = 0.45,
        accentColor = Color3.fromRGB(82, 156, 255),
        valueColor = Color3.fromRGB(235, 245, 255),
        hintColor = Color3.fromRGB(170, 192, 230),
        sparkColor = Color3.fromRGB(112, 198, 255),
        sparkTransparency = 0.25,
        cellSize = UDim2.new(0.5, -12, 0, 104),
        cellPadding = UDim2.new(0, 12, 0, 12),
        maxColumns = 2,
    },
    controls = {
        headerFont = Enum.Font.GothamSemibold,
        headerTextSize = 16,
        headerColor = Color3.fromRGB(226, 232, 244),
        descriptionFont = Enum.Font.Gotham,
        descriptionTextSize = 14,
        descriptionColor = Color3.fromRGB(178, 190, 214),
        toggleOnColor = Color3.fromRGB(82, 156, 255),
        toggleOffColor = Color3.fromRGB(40, 46, 62),
        toggleOnTextColor = Color3.fromRGB(12, 16, 26),
        toggleOffTextColor = Color3.fromRGB(226, 232, 244),
        toggleCorner = UDim.new(0, 12),
        toggleStrokeColor = Color3.fromRGB(82, 156, 255),
        toggleStrokeTransparency = 0.55,
        toggleBadgeFont = Enum.Font.GothamSemibold,
        toggleBadgeSize = 13,
        toggleBadgeColor = Color3.fromRGB(188, 202, 230),
        sectionBackground = Color3.fromRGB(24, 28, 36),
        sectionTransparency = 0.05,
        sectionStrokeColor = Color3.fromRGB(82, 156, 255),
        sectionStrokeTransparency = 0.5,
        sectionGradient = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(20, 24, 32)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(82, 156, 255)),
        }),
        sectionGradientTransparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.9),
            NumberSequenceKeypoint.new(1, 0.35),
        }),
        iconBackground = Color3.fromRGB(34, 40, 54),
        iconTransparency = 0.15,
        iconGradient = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(46, 58, 82)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(24, 32, 52)),
        }),
        iconSize = UDim2.new(0, 34, 0, 34),
        iconColor = Color3.fromRGB(210, 224, 255),
        iconAccentColor = Color3.fromRGB(112, 198, 255),
    },
    summary = {
        chipBackground = Color3.fromRGB(30, 36, 48),
        chipTransparency = 0.06,
        chipStrokeColor = Color3.fromRGB(94, 148, 214),
        chipStrokeTransparency = 0.5,
        labelFont = Enum.Font.Gotham,
        labelTextSize = 12,
        labelColor = Color3.fromRGB(168, 182, 210),
        valueFont = Enum.Font.GothamSemibold,
        valueTextSize = 17,
        valueColor = Color3.fromRGB(236, 244, 255),
    },
}

local DEFAULT_TELEMETRY = {
    {
        id = "latency",
        label = "Round Trip",
        value = "-- ms",
        hint = "Rolling network latency sample used for Δ.",
    },
    {
        id = "delta",
        label = "Lead Δ",
        value = "-- ms",
        hint = "Forecasted pre-fire lead from ping and activation lag.",
    },
    {
        id = "inequality",
        label = "μ + zσ",
        value = "--",
        hint = "Current PERFECT-PARRY margin; negative means ready to fire.",
    },
    {
        id = "confidence",
        label = "Confidence",
        value = "z = 2.20",
        hint = "Safety index applied to the μ + zσ trigger.",
    },
}

local CONTROL_DEFINITIONS = {
    {
        id = "adaptive",
        title = "Adaptive Timing",
        description = "Learns activation latency and tunes μ forecasts in real time.",
        default = true,
        badge = "SMART",
        icon = "rbxassetid://6031280882",
    },
    {
        id = "failsafe",
        title = "Safety Net",
        description = "Hands control back if μ + zσ behaviour looks unsafe.",
        default = true,
        badge = "SAFE",
        icon = "rbxassetid://6031280887",
    },
    {
        id = "edge",
        title = "Edge Solver",
        description = "Extends forecasts to curve/ricochet chains for team handoffs.",
        default = false,
        icon = "rbxassetid://6031229327",
    },
    {
        id = "audible",
        title = "Audio Alerts",
        description = "Play positional cues when μ + zσ crosses zero.",
        default = true,
        icon = "rbxassetid://6031280883",
    },
    {
        id = "ghost",
        title = "Trajectory Ghosts",
        description = "Pre-simulate probable ball paths to rehearse parries early.",
        default = false,
        icon = "rbxassetid://6031075931",
    },
    {
        id = "autosync",
        title = "Team Sync",
        description = "Broadcast timing cues and σ inflation notices to your squad.",
        default = true,
        badge = "TEAM",
        icon = "rbxassetid://6035202002",
    },
}

local DEFAULT_HEADER_SUMMARY = {
    {
        id = "status",
        label = "System",
        value = "Online",
    },
    {
        id = "delta",
        label = "Δ Lead",
        value = "-- ms",
    },
    {
        id = "confidence",
        label = "Confidence",
        value = "z = 2.20",
    },
}

local STATUS_STYLE = {
    pending = function(theme)
        return {
            icon = theme.iconography.pending,
            color = theme.pendingColor,
            label = "Waiting",
            strokeTransparency = 0.65,
        }
    end,
    active = function(theme)
        return {
            icon = theme.iconography.active or theme.iconography.pending,
            color = theme.activeColor,
            label = "In progress",
            strokeTransparency = 0.35,
        }
    end,
    ok = function(theme)
        return {
            icon = theme.iconography.check,
            color = theme.okColor,
            label = "Ready",
            strokeTransparency = 0.25,
        }
    end,
    warning = function(theme)
        return {
            icon = theme.iconography.warning,
            color = theme.warningColor,
            label = "Check",
            strokeTransparency = 0.3,
        }
    end,
    failed = function(theme)
        return {
            icon = theme.iconography.error,
            color = theme.failedColor,
            label = "Failed",
            strokeTransparency = 0.22,
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

local function createSummaryChip(parent, theme, definition, index)
    local summaryTheme = mergeTable(DEFAULT_THEME.summary, theme.summary or {})
    local identifier = definition.id or definition.Id or definition.key or definition.Key or definition.label or definition.title or tostring(index)

    local chip = Instance.new("Frame")
    chip.Name = string.format("%sChip", tostring(identifier):gsub("%s+", ""))
    chip.AutomaticSize = Enum.AutomaticSize.XY
    chip.Size = UDim2.new(0, 132, 0, 34)
    chip.BackgroundColor3 = summaryTheme.chipBackground or DEFAULT_THEME.summary.chipBackground
    chip.BackgroundTransparency = summaryTheme.chipTransparency or DEFAULT_THEME.summary.chipTransparency
    chip.BorderSizePixel = 0
    chip.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = chip

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1
    stroke.Color = summaryTheme.chipStrokeColor or DEFAULT_THEME.summary.chipStrokeColor
    stroke.Transparency = summaryTheme.chipStrokeTransparency or DEFAULT_THEME.summary.chipStrokeTransparency or 0.6
    stroke.Parent = chip

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 6)
    padding.PaddingBottom = UDim.new(0, 6)
    padding.PaddingLeft = UDim.new(0, 10)
    padding.PaddingRight = UDim.new(0, 10)
    padding.Parent = chip

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    layout.VerticalAlignment = Enum.VerticalAlignment.Top
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 2)
    layout.Parent = chip

    local defaultLabel = definition.label or definition.title or definition.name or definition.id or ""
    local defaultValue = definition.value
    if defaultValue == nil then
        defaultValue = definition.text or definition.display or definition.default or ""
    end

    local label = Instance.new("TextLabel")
    label.Name = "Label"
    label.BackgroundTransparency = 1
    label.Font = summaryTheme.labelFont or DEFAULT_THEME.summary.labelFont
    label.TextSize = summaryTheme.labelTextSize or DEFAULT_THEME.summary.labelTextSize
    label.TextColor3 = summaryTheme.labelColor or DEFAULT_THEME.summary.labelColor
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = string.upper(tostring(defaultLabel))
    label.Size = UDim2.new(1, 0, 0, (summaryTheme.labelTextSize or DEFAULT_THEME.summary.labelTextSize) + 2)
    label.LayoutOrder = 1
    label.Parent = chip

    local value = Instance.new("TextLabel")
    value.Name = "Value"
    value.BackgroundTransparency = 1
    value.Font = summaryTheme.valueFont or DEFAULT_THEME.summary.valueFont
    value.TextSize = summaryTheme.valueTextSize or DEFAULT_THEME.summary.valueTextSize
    value.TextColor3 = summaryTheme.valueColor or DEFAULT_THEME.summary.valueColor
    value.TextXAlignment = Enum.TextXAlignment.Left
    value.Text = tostring(defaultValue)
    value.Size = UDim2.new(1, 0, 0, (summaryTheme.valueTextSize or DEFAULT_THEME.summary.valueTextSize) + 4)
    value.LayoutOrder = 2
    value.Parent = chip

    return {
        frame = chip,
        stroke = stroke,
        label = label,
        value = value,
        definition = definition,
        id = identifier,
        defaultLabel = defaultLabel,
        defaultValue = defaultValue,
    }
end

local function createSummaryRow(parent, theme, summary)
    local container = Instance.new("Frame")
    container.Name = "Summary"
    container.BackgroundTransparency = 1
    container.AutomaticSize = Enum.AutomaticSize.Y
    container.Size = UDim2.new(1, 0, 0, 0)
    container.Parent = parent

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 2)
    padding.PaddingBottom = UDim.new(0, 2)
    padding.Parent = container

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Horizontal
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    layout.VerticalAlignment = Enum.VerticalAlignment.Center
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 12)
    layout.Parent = container

    local chips = {}
    for index, definition in ipairs(summary) do
        local chip = createSummaryChip(container, theme, definition, index)
        chip.frame.LayoutOrder = index
        chips[chip.id or definition.id or tostring(index)] = chip
    end

    return {
        frame = container,
        layout = layout,
        chips = chips,
    }
end

local function normalizeSummaryInput(summary)
    if typeof(summary) ~= "table" then
        return nil
    end

    local result = {}

    if #summary == 0 then
        local list = {}
        for key, payload in pairs(summary) do
            if typeof(payload) == "table" then
                local entry = Util.deepCopy(payload)
                entry.id = entry.id or entry.Id or entry.key or entry.Key or key
                entry.label = entry.label or entry.title or entry.name or key
                entry.value = entry.value or entry.text or entry.display or entry[1]
                table.insert(list, entry)
            elseif payload ~= nil then
                table.insert(list, {
                    id = key,
                    label = key,
                    value = payload,
                })
            end
        end
        summary = list
    end

    for _, entry in ipairs(summary) do
        if typeof(entry) == "table" then
            local id = entry.id or entry.Id or entry.key or entry.Key or entry.label or entry.title
            if id then
                result[string.lower(tostring(id))] = {
                    id = id,
                    label = entry.label or entry.title or entry.name or id,
                    value = entry.value or entry.text or entry.display or entry[1],
                }
            end
        end
    end

    if next(result) == nil then
        return nil
    end

    return result
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

local function createStep(parent, definition, theme, order, totalSteps)
    local frame = Instance.new("Frame")
    frame.Name = definition.id
    frame.Size = UDim2.new(1, 0, 0, 76)
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
    iconGlow.Transparency = 0.55
    iconGlow.Color = theme.pendingColor
    iconGlow.Parent = icon

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.AnchorPoint = Vector2.new(0, 0)
    title.Position = UDim2.new(0, 66, 0, 10)
    title.Size = UDim2.new(1, -150, 0, 24)
    title.BackgroundTransparency = 1
    title.Font = theme.stepTitleFont
    title.TextSize = theme.stepTitleTextSize
    title.TextColor3 = Color3.fromRGB(232, 238, 248)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = definition.title
    title.Parent = frame

    local metaLabel
    if order then
        metaLabel = Instance.new("TextLabel")
        metaLabel.Name = "Meta"
        metaLabel.AnchorPoint = Vector2.new(1, 0)
        metaLabel.Position = UDim2.new(1, -18, 0, 12)
        metaLabel.Size = UDim2.new(0, 86, 0, 20)
        metaLabel.BackgroundTransparency = 1
        metaLabel.Font = theme.stepStatusFont
        metaLabel.TextSize = math.max(theme.stepStatusTextSize - 1, 12)
        metaLabel.TextColor3 = Color3.fromRGB(168, 182, 210)
        if totalSteps and totalSteps > 0 then
            metaLabel.Text = string.format("Step %d/%d", order, totalSteps)
        else
            metaLabel.Text = string.format("Step %d", order)
        end
        metaLabel.TextXAlignment = Enum.TextXAlignment.Right
        metaLabel.Parent = frame
    end

    local status = Instance.new("TextLabel")
    status.Name = "Status"
    status.AnchorPoint = Vector2.new(0, 0)
    status.Position = UDim2.new(0, 66, 0, 34)
    status.Size = UDim2.new(1, -150, 0, 26)
    status.BackgroundTransparency = 1
    status.Font = theme.stepStatusFont
    status.TextSize = theme.stepStatusTextSize
    status.TextColor3 = Color3.fromRGB(184, 198, 224)
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
        meta = metaLabel,
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
    card.AutomaticSize = Enum.AutomaticSize.Y
    card.Size = UDim2.new(0, 0, 0, 104)
    card.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 12)
    corner.Parent = card

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1.1
    stroke.Transparency = telemetryTheme.cardStrokeTransparency
    stroke.Color = telemetryTheme.cardStrokeColor
    stroke.Parent = card

    local spark = Instance.new("Frame")
    spark.Name = "Spark"
    spark.AnchorPoint = Vector2.new(0, 0.5)
    spark.Position = UDim2.new(0, -3, 0.5, 0)
    spark.Size = UDim2.new(0, 6, 1, -24)
    spark.BackgroundColor3 = telemetryTheme.sparkColor or (theme.accentColor and theme.accentColor:Lerp(Color3.new(1, 1, 1), 0.2)) or theme.accentColor
    spark.BackgroundTransparency = telemetryTheme.sparkTransparency or 0.2
    spark.BorderSizePixel = 0
    spark.Parent = card

    local sparkCorner = Instance.new("UICorner")
    sparkCorner.CornerRadius = UDim.new(1, 0)
    sparkCorner.Parent = spark

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 12)
    padding.PaddingBottom = UDim.new(0, 14)
    padding.PaddingLeft = UDim.new(0, 16)
    padding.PaddingRight = UDim.new(0, 14)
    padding.Parent = card

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    layout.VerticalAlignment = Enum.VerticalAlignment.Top
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 6)
    layout.Parent = card

    local label = Instance.new("TextLabel")
    label.Name = "Label"
    label.BackgroundTransparency = 1
    label.Size = UDim2.new(1, 0, 0, 18)
    label.Font = telemetryTheme.labelFont
    label.TextSize = telemetryTheme.labelTextSize
    label.TextColor3 = (telemetryTheme.accentColor or theme.accentColor):Lerp(Color3.new(1, 1, 1), 0.35)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = string.upper(definition.label or definition.id or "Telemetry")
    label.LayoutOrder = 1
    label.Parent = card

    local value = Instance.new("TextLabel")
    value.Name = "Value"
    value.BackgroundTransparency = 1
    value.Size = UDim2.new(1, 0, 0, 32)
    value.Font = telemetryTheme.valueFont
    value.TextSize = telemetryTheme.valueTextSize
    value.TextXAlignment = Enum.TextXAlignment.Left
    value.TextColor3 = Color3.fromRGB(235, 245, 255)
    value.Text = tostring(definition.value or "--")
    value.LayoutOrder = 2
    value.Parent = card

    local hint = Instance.new("TextLabel")
    hint.Name = "Hint"
    hint.BackgroundTransparency = 1
    hint.Size = UDim2.new(1, 0, 0, 22)
    hint.Font = telemetryTheme.labelFont
    hint.TextSize = math.max((telemetryTheme.labelTextSize or 13) - 1, 10)
    hint.TextColor3 = telemetryTheme.hintColor or Color3.fromRGB(176, 196, 230)
    hint.TextTransparency = 0.18
    hint.TextWrapped = true
    hint.TextXAlignment = Enum.TextXAlignment.Left
    hint.Text = definition.hint or ""
    hint.LayoutOrder = 3
    hint.Parent = card

    return {
        frame = card,
        stroke = stroke,
        label = label,
        value = value,
        hint = hint,
        spark = spark,
        defaultValueColor = value.TextColor3,
        defaultHintColor = hint.TextColor3,
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
    button.Size = UDim2.new(0, 260, 0, 112)
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
    padding.PaddingLeft = UDim.new(0, 18)
    padding.PaddingRight = UDim.new(0, 18)
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

    local iconFrame
    local iconImage
    local iconOffset = 0
    local iconSize = controlsTheme.iconSize or DEFAULT_THEME.controls.iconSize or UDim2.new(0, 34, 0, 34)
    if typeof(definition.icon) == "string" and definition.icon ~= "" then
        iconFrame = Instance.new("Frame")
        iconFrame.Name = "Icon"
        iconFrame.BackgroundColor3 = controlsTheme.iconBackground or DEFAULT_THEME.controls.iconBackground
        iconFrame.BackgroundTransparency = controlsTheme.iconTransparency or DEFAULT_THEME.controls.iconTransparency or 0.15
        iconFrame.BorderSizePixel = 0
        iconFrame.Size = iconSize
        iconFrame.Position = UDim2.new(0, 0, 0, math.max(6, math.floor((button.Size.Y.Offset - iconSize.Y.Offset) * 0.5)))
        iconFrame.ZIndex = 2
        iconFrame.Parent = button

        local iconCorner = Instance.new("UICorner")
        iconCorner.CornerRadius = UDim.new(0, 12)
        iconCorner.Parent = iconFrame

        local iconGradient = Instance.new("UIGradient")
        iconGradient.Color = controlsTheme.iconGradient or DEFAULT_THEME.controls.iconGradient
        iconGradient.Rotation = 120
        iconGradient.Parent = iconFrame

        iconImage = Instance.new("ImageLabel")
        iconImage.Name = "Glyph"
        iconImage.AnchorPoint = Vector2.new(0.5, 0.5)
        iconImage.Position = UDim2.new(0.5, 0, 0.5, 0)
        iconImage.Size = UDim2.new(0, math.max(iconSize.X.Offset - 12, 20), 0, math.max(iconSize.Y.Offset - 12, 20))
        iconImage.BackgroundTransparency = 1
        iconImage.Image = definition.icon
        iconImage.ImageColor3 = controlsTheme.iconColor or DEFAULT_THEME.controls.iconColor
        iconImage.Parent = iconFrame

        iconOffset = iconSize.X.Offset + 18
    end

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.BackgroundTransparency = 1
    title.Size = UDim2.new(1, -iconOffset - 8, 0, 26)
    title.Position = UDim2.new(0, iconOffset, 0, 0)
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
        badge.Position = UDim2.new(1, -4, 0, 2)
        badge.Size = UDim2.new(0, 58, 0, 22)
        badge.BackgroundTransparency = 0.25
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
    description.Position = UDim2.new(0, iconOffset, 0, 32)
    description.Size = UDim2.new(1, -iconOffset - 8, 0, 46)
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
    status.Position = UDim2.new(1, -6, 1, -6)
    status.Size = UDim2.new(0, 74, 0, 20)
    status.BackgroundTransparency = 1
    status.Font = controlsTheme.descriptionFont or DEFAULT_THEME.controls.descriptionFont
    status.TextSize = math.max((controlsTheme.descriptionTextSize or DEFAULT_THEME.controls.descriptionTextSize) - 1, 11)
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
        icon = iconImage,
        iconFrame = iconFrame,
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
        toggle.badge.BackgroundTransparency = enabled and 0.12 or 0.4
    end
    if toggle.icon then
        toggle.icon.ImageColor3 = enabled and (controlsTheme.iconAccentColor or onColor) or (controlsTheme.iconColor or DEFAULT_THEME.controls.iconColor)
    end
    if toggle.iconFrame then
        toggle.iconFrame.BackgroundTransparency = enabled and 0.08 or (controlsTheme.iconTransparency or DEFAULT_THEME.controls.iconTransparency or 0.15)
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
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    layout.VerticalAlignment = Enum.VerticalAlignment.Top
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 18)
    layout.Parent = root

    local header = Instance.new("Frame")
    header.Name = "Header"
    header.BackgroundTransparency = 1
    header.Size = UDim2.new(1, 0, 0, 118)
    header.LayoutOrder = 1
    header.Parent = root

    local headerLayout = Instance.new("UIListLayout")
    headerLayout.FillDirection = Enum.FillDirection.Horizontal
    headerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    headerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    headerLayout.SortOrder = Enum.SortOrder.LayoutOrder
    headerLayout.Padding = UDim.new(0, 18)
    headerLayout.Parent = header

    local initialLogoWidth = (theme.logo and theme.logo.width) or DEFAULT_THEME.logo.width or 230

    local logoContainer = Instance.new("Frame")
    logoContainer.Name = "LogoContainer"
    logoContainer.BackgroundTransparency = 1
    logoContainer.Size = UDim2.new(0, initialLogoWidth, 1, 0)
    logoContainer.Parent = header

    local logoElements = createLogoBadge(logoContainer, theme)

    local textContainer = Instance.new("Frame")
    textContainer.Name = "HeaderText"
    textContainer.BackgroundTransparency = 1
    textContainer.Size = UDim2.new(1, -initialLogoWidth, 1, 0)
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
    title.Text = "PERFECT-PARRY Orchestrator"
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
    subtitle.Text = "Calibrating μ + zσ forecast pipeline…"
    subtitle.LayoutOrder = 2
    subtitle.Parent = textContainer

    local summaryDefinitions
    local shouldSortSummary = false
    if typeof(options.summary) == "table" then
        if #options.summary > 0 then
            summaryDefinitions = options.summary
        else
            summaryDefinitions = {}
            for key, payload in pairs(options.summary) do
                if typeof(payload) == "table" then
                    local entry = Util.deepCopy(payload)
                    entry.id = entry.id or entry.Id or entry.key or entry.Key or key
                    entry.label = entry.label or entry.title or entry.name or key
                    entry.value = entry.value or entry.text or entry.display or entry[1]
                    table.insert(summaryDefinitions, entry)
                elseif payload ~= nil then
                    table.insert(summaryDefinitions, {
                        id = key,
                        label = key,
                        value = payload,
                    })
                end
            end
            shouldSortSummary = true
        end
    end

    summaryDefinitions = summaryDefinitions or DEFAULT_HEADER_SUMMARY

    if shouldSortSummary then
        table.sort(summaryDefinitions, function(a, b)
            local orderA = tonumber(a.order or a.Order)
            local orderB = tonumber(b.order or b.Order)
            if orderA and orderB then
                if orderA == orderB then
                    return tostring(a.label or a.id or "") < tostring(b.label or b.id or "")
                end
                return orderA < orderB
            elseif orderA then
                return true
            elseif orderB then
                return false
            end
            return tostring(a.label or a.id or "") < tostring(b.label or b.id or "")
        end)
    end

    local insightsTheme = mergeTable(DEFAULT_THEME.insights or {}, theme.insights or {})

    local insightsCard = Instance.new("Frame")
    insightsCard.Name = "InsightsCard"
    insightsCard.BackgroundColor3 = insightsTheme.backgroundColor or theme.cardColor
    insightsCard.BackgroundTransparency = insightsTheme.backgroundTransparency or theme.cardTransparency
    insightsCard.BorderSizePixel = 0
    insightsCard.LayoutOrder = 2
    insightsCard.AutomaticSize = Enum.AutomaticSize.Y
    insightsCard.Size = UDim2.new(1, 0, 0, 0)
    insightsCard.Parent = root

    local insightsCorner = Instance.new("UICorner")
    insightsCorner.CornerRadius = UDim.new(0, 16)
    insightsCorner.Parent = insightsCard

    local insightsStroke = Instance.new("UIStroke")
    insightsStroke.Thickness = 1.15
    insightsStroke.Color = insightsTheme.strokeColor or theme.cardStrokeColor
    insightsStroke.Transparency = insightsTheme.strokeTransparency or theme.cardStrokeTransparency
    insightsStroke.Parent = insightsCard

    local insightsGradient
    if insightsTheme.gradient then
        insightsGradient = Instance.new("UIGradient")
        insightsGradient.Color = insightsTheme.gradient
        insightsGradient.Transparency = insightsTheme.gradientTransparency or DEFAULT_THEME.insights.gradientTransparency
        insightsGradient.Rotation = insightsTheme.gradientRotation or 120
        insightsGradient.Parent = insightsCard
    end

    local insightsPadding = Instance.new("UIPadding")
    insightsPadding.PaddingTop = UDim.new(0, insightsTheme.paddingTop or 18)
    insightsPadding.PaddingBottom = UDim.new(0, insightsTheme.paddingBottom or 18)
    insightsPadding.PaddingLeft = UDim.new(0, insightsTheme.paddingHorizontal or 20)
    insightsPadding.PaddingRight = UDim.new(0, insightsTheme.paddingHorizontal or 20)
    insightsPadding.Parent = insightsCard

    local insightsLayout = Instance.new("UIListLayout")
    insightsLayout.FillDirection = Enum.FillDirection.Vertical
    insightsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    insightsLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    insightsLayout.SortOrder = Enum.SortOrder.LayoutOrder
    insightsLayout.Padding = UDim.new(0, insightsTheme.paddingBetween or 16)
    insightsLayout.Parent = insightsCard

    local summaryRow
    if #summaryDefinitions > 0 then
        summaryRow = createSummaryRow(insightsCard, theme, summaryDefinitions)
        summaryRow.frame.LayoutOrder = 1
    end

    local telemetryFrame = Instance.new("Frame")
    telemetryFrame.Name = "Telemetry"
    telemetryFrame.BackgroundTransparency = 1
    telemetryFrame.AutomaticSize = Enum.AutomaticSize.Y
    telemetryFrame.Size = UDim2.new(1, 0, 0, 0)
    telemetryFrame.LayoutOrder = summaryRow and 2 or 1
    telemetryFrame.Parent = insightsCard

    local telemetryGrid = Instance.new("UIGridLayout")
    telemetryGrid.FillDirection = Enum.FillDirection.Horizontal
    telemetryGrid.HorizontalAlignment = Enum.HorizontalAlignment.Left
    telemetryGrid.VerticalAlignment = Enum.VerticalAlignment.Top
    telemetryGrid.SortOrder = Enum.SortOrder.LayoutOrder
    telemetryGrid.CellPadding = (theme.telemetry and theme.telemetry.cellPadding) or DEFAULT_THEME.telemetry.cellPadding
    telemetryGrid.CellSize = (theme.telemetry and theme.telemetry.cellSize) or DEFAULT_THEME.telemetry.cellSize
    telemetryGrid.FillDirectionMaxCells = (theme.telemetry and theme.telemetry.maxColumns) or DEFAULT_THEME.telemetry.maxColumns or 2
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
    controlPanel.AutomaticSize = Enum.AutomaticSize.Y
    controlPanel.Size = UDim2.new(1, 0, 0, 0)
    controlPanel.LayoutOrder = telemetryFrame.LayoutOrder + 1
    controlPanel.Parent = insightsCard

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
    controlHeader.Text = "System toggles"
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
    controlGrid.CellSize = UDim2.new(0.5, -12, 0, 112)
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
    timelineCard.LayoutOrder = 3
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
    progressTrack.BackgroundColor3 = theme.cardColor:Lerp(theme.accentColor, 0.08)
    progressTrack.BackgroundTransparency = math.clamp((theme.cardTransparency or 0) + 0.12, 0, 1)
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
        local step = createStep(listFrame, definition, theme, index, #STEP_DEFINITIONS)
        step.frame.LayoutOrder = index
        if index == #STEP_DEFINITIONS then
            step.connector.Visible = false
        end
        steps[definition.id] = step
    end

    local actionsFrame = Instance.new("Frame")
    actionsFrame.Name = "Actions"
    actionsFrame.BackgroundTransparency = 1
    actionsFrame.LayoutOrder = 4
    actionsFrame.Size = UDim2.new(1, 0, 0, theme.actionHeight + 12)
    actionsFrame.Visible = false
    actionsFrame.Parent = root

    local actionsLayout = Instance.new("UIListLayout")
    actionsLayout.FillDirection = Enum.FillDirection.Horizontal
    actionsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    actionsLayout.SortOrder = Enum.SortOrder.LayoutOrder
    actionsLayout.Padding = UDim.new(0, 12)
    actionsLayout.Parent = actionsFrame

    local headerDefaults = {
        fillDirection = headerLayout.FillDirection,
        horizontalAlignment = headerLayout.HorizontalAlignment,
        verticalAlignment = headerLayout.VerticalAlignment,
        padding = headerLayout.Padding,
    }
    local textDefaults = {
        horizontalAlignment = textLayout.HorizontalAlignment,
        verticalAlignment = textLayout.VerticalAlignment,
    }
    local titleDefaults = {
        alignment = title.TextXAlignment,
        wrapped = title.TextWrapped,
    }
    local subtitleDefaults = {
        alignment = subtitle.TextXAlignment,
    }
    local summaryDefaults = summaryRow and {
        fillDirection = summaryRow.layout.FillDirection,
        horizontalAlignment = summaryRow.layout.HorizontalAlignment,
    } or nil
    local telemetryDefaults = {
        cellSize = telemetryGrid.CellSize,
        maxColumns = telemetryGrid.FillDirectionMaxCells,
    }
    local controlGridDefaults = {
        maxColumns = controlGrid.FillDirectionMaxCells,
    }
    local actionsDefaults = {
        fillDirection = actionsLayout.FillDirection,
        horizontalAlignment = actionsLayout.HorizontalAlignment,
        padding = actionsLayout.Padding,
    }
    local actionsFrameDefaults = {
        size = actionsFrame.Size,
        automaticSize = actionsFrame.AutomaticSize,
    }
    local logoDefaults
    if logoElements then
        logoDefaults = {
            containerSize = logoContainer.Size,
            frameAnchor = logoElements.frame.AnchorPoint,
            framePosition = logoElements.frame.Position,
            frameSize = logoElements.frame.Size,
            glyphAnchor = logoElements.glyph.AnchorPoint,
            glyphPosition = logoElements.glyph.Position,
            glyphSize = logoElements.glyph.Size,
            wordmarkAnchor = logoElements.wordmark.AnchorPoint,
            wordmarkPosition = logoElements.wordmark.Position,
            wordmarkSize = logoElements.wordmark.Size,
            wordmarkAlignment = logoElements.wordmark.TextXAlignment,
            taglineAnchor = logoElements.tagline.AnchorPoint,
            taglinePosition = logoElements.tagline.Position,
            taglineAlignment = logoElements.tagline.TextXAlignment,
        }
    end

    local headerTextDefaults = textContainer.Size

    local self = setmetatable({
        _theme = theme,
        _root = root,
        _layout = layout,
        _header = header,
        _headerLayout = headerLayout,
        _title = title,
        _subtitle = subtitle,
        _insightsCard = insightsCard,
        _insightsStroke = insightsStroke,
        _insightsGradient = insightsGradient,
        _insightsLayout = insightsLayout,
        _insightsPadding = insightsPadding,
        _summaryFrame = summaryRow and summaryRow.frame or nil,
        _summaryLayout = summaryRow and summaryRow.layout or nil,
        _summaryChips = summaryRow and summaryRow.chips or nil,
        _summaryDefinitions = Util.deepCopy(summaryDefinitions),
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
        _progressTrack = progressTrack,
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
        _headerLayoutDefaults = headerDefaults,
        _textLayout = textLayout,
        _textLayoutDefaults = textDefaults,
        _headerText = textContainer,
        _headerTextDefaults = headerTextDefaults,
        _logoContainer = logoContainer,
        _logoFrame = logoElements and logoElements.frame,
        _logoStroke = logoElements and logoElements.stroke,
        _logoGradient = logoElements and logoElements.gradient,
        _logoGlyph = logoElements and logoElements.glyph,
        _logoWordmark = logoElements and logoElements.wordmark,
        _logoWordmarkGradient = logoElements and logoElements.wordmarkGradient,
        _logoTagline = logoElements and logoElements.tagline,
        _logoDefaults = logoDefaults,
        _initialLogoWidth = initialLogoWidth,
        _titleDefaults = titleDefaults,
        _subtitleDefaults = subtitleDefaults,
        _summaryDefaults = summaryDefaults,
        _telemetryDefaults = telemetryDefaults,
        _controlGridDefaults = controlGridDefaults,
        _actionsDefaults = actionsDefaults,
        _actionsFrameDefaults = actionsFrameDefaults,
        _logoShimmerTween = nil,
        _connections = {},
        _responsiveState = {},
        _lastLayoutBounds = nil,
        _destroyed = false,
    }, VerificationDashboard)

    for _, definition in ipairs(STEP_DEFINITIONS) do
        self._stepStates[definition.id] = { status = "pending", priority = STATUS_PRIORITY.pending }
    end

    self:_applyLogoTheme()
    self:_applyInsightsTheme()
    self:_applySummaryTheme()
    self:_startLogoShimmer()
    self:setHeaderSummary(summaryDefinitions)
    self:setControls(options.controls)
    self:setTelemetry(options.telemetry)
    self:setProgress(0)

    self:_installResponsiveHandlers()
    self:updateLayout()

    return self
end

function VerificationDashboard:_installResponsiveHandlers()
    if not self._root then
        return
    end

    local connection = self._root:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
        if self._destroyed then
            return
        end
        self:updateLayout(self._lastLayoutBounds)
    end)
    table.insert(self._connections, connection)

    task.defer(function()
        if self._destroyed then
            return
        end
        self:updateLayout(self._lastLayoutBounds)
    end)
end

function VerificationDashboard:_applyResponsiveLayout(width, bounds)
    if self._destroyed then
        return
    end

    width = math.floor(tonumber(width) or 0)
    if width <= 0 then
        return
    end

    local headerLayout = self._headerLayout
    if not headerLayout then
        return
    end

    local headerDefaults = self._headerLayoutDefaults
    if headerDefaults then
        headerLayout.FillDirection = headerDefaults.fillDirection
        headerLayout.HorizontalAlignment = headerDefaults.horizontalAlignment
        headerLayout.VerticalAlignment = headerDefaults.verticalAlignment
        headerLayout.Padding = headerDefaults.padding or headerLayout.Padding
    end

    if self._textLayout and self._textLayoutDefaults then
        self._textLayout.HorizontalAlignment = self._textLayoutDefaults.horizontalAlignment
        self._textLayout.VerticalAlignment = self._textLayoutDefaults.verticalAlignment
    end

    if self._headerText and self._headerTextDefaults then
        self._headerText.Size = self._headerTextDefaults
    end

    if self._title and self._titleDefaults then
        self._title.TextXAlignment = self._titleDefaults.alignment
        self._title.TextWrapped = self._titleDefaults.wrapped
    end

    if self._subtitle and self._subtitleDefaults then
        self._subtitle.TextXAlignment = self._subtitleDefaults.alignment
    end

    if self._summaryLayout and self._summaryDefaults then
        self._summaryLayout.FillDirection = self._summaryDefaults.fillDirection
        self._summaryLayout.HorizontalAlignment = self._summaryDefaults.horizontalAlignment
    end

    if self._telemetryGrid and self._telemetryDefaults then
        self._telemetryGrid.FillDirectionMaxCells = self._telemetryDefaults.maxColumns or self._telemetryGrid.FillDirectionMaxCells
        self._telemetryGrid.CellSize = self._telemetryDefaults.cellSize or self._telemetryGrid.CellSize
    end

    if self._controlGrid and self._controlGridDefaults then
        self._controlGrid.FillDirectionMaxCells = self._controlGridDefaults.maxColumns or self._controlGrid.FillDirectionMaxCells
    end

    if self._actionsLayout and self._actionsDefaults then
        self._actionsLayout.FillDirection = self._actionsDefaults.fillDirection
        self._actionsLayout.HorizontalAlignment = self._actionsDefaults.horizontalAlignment
        self._actionsLayout.Padding = self._actionsDefaults.padding or self._actionsLayout.Padding
    end

    if self._actionsFrame and self._actionsFrameDefaults then
        self._actionsFrame.AutomaticSize = self._actionsFrameDefaults.automaticSize or Enum.AutomaticSize.None
        self._actionsFrame.Size = self._actionsFrameDefaults.size or self._actionsFrame.Size
    end

    local logoDefaults = self._logoDefaults
    if logoDefaults then
        if self._logoContainer then
            self._logoContainer.Size = logoDefaults.containerSize
        end
        if self._logoFrame then
            self._logoFrame.AnchorPoint = logoDefaults.frameAnchor
            self._logoFrame.Position = logoDefaults.framePosition
            self._logoFrame.Size = logoDefaults.frameSize
        end
        if self._logoGlyph then
            self._logoGlyph.AnchorPoint = logoDefaults.glyphAnchor
            self._logoGlyph.Position = logoDefaults.glyphPosition
            self._logoGlyph.Size = logoDefaults.glyphSize
        end
        if self._logoWordmark then
            self._logoWordmark.AnchorPoint = logoDefaults.wordmarkAnchor
            self._logoWordmark.Position = logoDefaults.wordmarkPosition
            self._logoWordmark.Size = logoDefaults.wordmarkSize
            self._logoWordmark.TextXAlignment = logoDefaults.wordmarkAlignment
        end
        if self._logoTagline then
            self._logoTagline.AnchorPoint = logoDefaults.taglineAnchor
            self._logoTagline.Position = logoDefaults.taglinePosition
            self._logoTagline.TextXAlignment = logoDefaults.taglineAlignment
        end
    end

    local breakpoint
    if bounds and bounds.mode == "stacked" then
        breakpoint = "small"
    elseif bounds and bounds.mode == "hybrid" then
        breakpoint = "medium"
    else
        if width <= 540 then
            breakpoint = "small"
        elseif width <= 820 then
            breakpoint = "medium"
        else
            breakpoint = "large"
        end
    end

    local state = self._responsiveState or {}
    state.breakpoint = breakpoint
    state.width = width
    state.mode = bounds and bounds.mode or breakpoint
    self._responsiveState = state

    local dashboardWidth = (bounds and bounds.dashboardWidth) or width
    local logoMaxWidth = self._initialLogoWidth or ((logoDefaults and logoDefaults.containerSize and logoDefaults.containerSize.X.Offset) or 240)

    if breakpoint == "small" then
        if headerLayout then
            headerLayout.FillDirection = Enum.FillDirection.Vertical
            headerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
            headerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
            headerLayout.Padding = UDim.new(0, 12)
        end
        if self._logoContainer then
            self._logoContainer.Size = UDim2.new(1, 0, 0, 112)
        end
        if self._headerText then
            self._headerText.Size = UDim2.new(1, 0, 0, 96)
        end
        if self._logoFrame then
            self._logoFrame.AnchorPoint = Vector2.new(0.5, 0.5)
            self._logoFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
            self._logoFrame.Size = UDim2.new(1, -16, 0, 102)
        end
        if self._logoGlyph then
            self._logoGlyph.AnchorPoint = Vector2.new(0.5, 0.5)
            self._logoGlyph.Position = UDim2.new(0.5, 0, 0.5, -20)
        end
        if self._logoWordmark then
            self._logoWordmark.AnchorPoint = Vector2.new(0.5, 0.5)
            self._logoWordmark.Position = UDim2.new(0.5, 0, 0.5, 8)
            self._logoWordmark.Size = UDim2.new(1, -40, 0, self._logoWordmark.Size.Y.Offset)
            self._logoWordmark.TextXAlignment = Enum.TextXAlignment.Center
        end
        if self._logoTagline then
            self._logoTagline.AnchorPoint = Vector2.new(0.5, 0.5)
            self._logoTagline.Position = UDim2.new(0.5, 0, 0.5, 34)
            self._logoTagline.Size = UDim2.new(1, -48, 0, self._logoTagline.Size.Y.Offset)
            self._logoTagline.TextXAlignment = Enum.TextXAlignment.Center
        end
        if self._textLayout then
            self._textLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        end
        if self._title then
            self._title.TextWrapped = true
            self._title.TextXAlignment = Enum.TextXAlignment.Center
        end
        if self._subtitle then
            self._subtitle.TextXAlignment = Enum.TextXAlignment.Center
        end
        if self._summaryLayout then
            self._summaryLayout.FillDirection = Enum.FillDirection.Vertical
            self._summaryLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        end
        if self._telemetryGrid then
            self._telemetryGrid.FillDirectionMaxCells = 1
            self._telemetryGrid.CellSize = UDim2.new(1, -12, 0, 112)
        end
        if self._controlGrid then
            self._controlGrid.FillDirectionMaxCells = 1
        end
        if self._actionsLayout then
            self._actionsLayout.FillDirection = Enum.FillDirection.Vertical
            self._actionsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
            self._actionsLayout.Padding = UDim.new(0, 10)
        end
        if self._actionsFrame then
            self._actionsFrame.AutomaticSize = Enum.AutomaticSize.Y
            self._actionsFrame.Size = UDim2.new(1, 0, 0, 0)
        end
    elseif breakpoint == "medium" then
        local logoWidth = math.clamp(math.floor(dashboardWidth * 0.38), 170, logoMaxWidth)
        if self._logoContainer then
            self._logoContainer.Size = UDim2.new(0, logoWidth, 1, 0)
        end
        if self._headerText then
            self._headerText.Size = UDim2.new(1, -logoWidth, 1, 0)
        end
        if headerLayout then
            headerLayout.FillDirection = Enum.FillDirection.Horizontal
            headerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
            headerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
        end
        if self._textLayout then
            self._textLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
        end
        if self._title then
            self._title.TextWrapped = width <= 680
        end
        if self._summaryLayout then
            self._summaryLayout.FillDirection = Enum.FillDirection.Horizontal
            self._summaryLayout.HorizontalAlignment = width <= 700 and Enum.HorizontalAlignment.Center
                or Enum.HorizontalAlignment.Left
        end
        if self._telemetryGrid then
            if width <= 700 then
                self._telemetryGrid.FillDirectionMaxCells = 1
                self._telemetryGrid.CellSize = UDim2.new(1, -12, 0, 112)
            else
                self._telemetryGrid.FillDirectionMaxCells = math.min(2, self._telemetryDefaults.maxColumns or 2)
                self._telemetryGrid.CellSize = self._telemetryDefaults.cellSize or self._telemetryGrid.CellSize
            end
        end
        if self._controlGrid then
            self._controlGrid.FillDirectionMaxCells = width <= 700 and 1 or (self._controlGridDefaults.maxColumns or 2)
        end
        if self._actionsLayout then
            self._actionsLayout.FillDirection = Enum.FillDirection.Horizontal
            if width <= 700 then
                self._actionsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
                self._actionsLayout.Padding = UDim.new(0, 10)
                if self._actionsFrame then
                    self._actionsFrame.AutomaticSize = Enum.AutomaticSize.Y
                    self._actionsFrame.Size = UDim2.new(1, 0, 0, 0)
                end
            else
                self._actionsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
            end
        end
    else
        local logoWidth = math.clamp(math.floor(dashboardWidth * 0.32), 200, logoMaxWidth)
        if self._logoContainer then
            self._logoContainer.Size = UDim2.new(0, logoWidth, 1, 0)
        end
        if self._headerText then
            self._headerText.Size = UDim2.new(1, -logoWidth, 1, 0)
        end
        if self._summaryLayout then
            self._summaryLayout.FillDirection = Enum.FillDirection.Horizontal
            self._summaryLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
        end
        if self._telemetryGrid then
            self._telemetryGrid.FillDirectionMaxCells = self._telemetryDefaults.maxColumns or 2
            self._telemetryGrid.CellSize = self._telemetryDefaults.cellSize or self._telemetryGrid.CellSize
        end
        if self._controlGrid and self._controlGridDefaults then
            self._controlGrid.FillDirectionMaxCells = self._controlGridDefaults.maxColumns or self._controlGrid.FillDirectionMaxCells
        end
    end
end

function VerificationDashboard:updateLayout(bounds)
    if self._destroyed then
        return
    end

    if bounds then
        self._lastLayoutBounds = {
            mode = bounds.mode,
            containerWidth = bounds.containerWidth,
            containerHeight = bounds.containerHeight,
            dashboardWidth = bounds.dashboardWidth,
            dashboardHeight = bounds.dashboardHeight,
            contentWidth = bounds.contentWidth,
        }
    end

    local reference = bounds or self._lastLayoutBounds
    local width = reference and reference.dashboardWidth or (self._root and self._root.AbsoluteSize.X) or 0
    if width <= 0 and self._root then
        width = self._root.AbsoluteSize.X
    end
    if width <= 0 then
        return
    end

    self:_applyResponsiveLayout(width, reference)
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

function VerificationDashboard:_applyInsightsTheme()
    if self._destroyed then
        return
    end

    local theme = self._theme or DEFAULT_THEME
    local insightsTheme = mergeTable(DEFAULT_THEME.insights or {}, theme.insights or {})

    if self._insightsCard then
        self._insightsCard.BackgroundColor3 = insightsTheme.backgroundColor or theme.cardColor
        self._insightsCard.BackgroundTransparency = insightsTheme.backgroundTransparency or theme.cardTransparency
    end

    if self._insightsStroke then
        self._insightsStroke.Color = insightsTheme.strokeColor or theme.cardStrokeColor
        self._insightsStroke.Transparency = insightsTheme.strokeTransparency or theme.cardStrokeTransparency
    end

    if self._insightsGradient then
        self._insightsGradient.Color = insightsTheme.gradient or DEFAULT_THEME.insights.gradient
        self._insightsGradient.Transparency = insightsTheme.gradientTransparency or DEFAULT_THEME.insights.gradientTransparency
        self._insightsGradient.Rotation = insightsTheme.gradientRotation or 120
    end

    if self._insightsPadding then
        self._insightsPadding.PaddingTop = UDim.new(0, insightsTheme.paddingTop or DEFAULT_THEME.insights.paddingTop or 16)
        self._insightsPadding.PaddingBottom = UDim.new(0, insightsTheme.paddingBottom or DEFAULT_THEME.insights.paddingBottom or 16)
        self._insightsPadding.PaddingLeft = UDim.new(0, insightsTheme.paddingHorizontal or DEFAULT_THEME.insights.paddingHorizontal or 18)
        self._insightsPadding.PaddingRight = UDim.new(0, insightsTheme.paddingHorizontal or DEFAULT_THEME.insights.paddingHorizontal or 18)
    end

    if self._insightsLayout then
        self._insightsLayout.Padding = UDim.new(0, insightsTheme.paddingBetween or DEFAULT_THEME.insights.paddingBetween or 16)
    end
end

function VerificationDashboard:_applySummaryTheme()
    if self._destroyed or not self._summaryChips then
        return
    end

    local theme = self._theme or DEFAULT_THEME
    local summaryTheme = mergeTable(DEFAULT_THEME.summary, theme.summary or {})

    if self._summaryFrame then
        self._summaryFrame.Visible = next(self._summaryChips) ~= nil
    end

    for _, chip in pairs(self._summaryChips) do
        if chip.frame then
            chip.frame.BackgroundColor3 = summaryTheme.chipBackground or DEFAULT_THEME.summary.chipBackground
            chip.frame.BackgroundTransparency = summaryTheme.chipTransparency or DEFAULT_THEME.summary.chipTransparency
        end
        if chip.stroke then
            chip.stroke.Color = summaryTheme.chipStrokeColor or DEFAULT_THEME.summary.chipStrokeColor
            chip.stroke.Transparency = summaryTheme.chipStrokeTransparency or DEFAULT_THEME.summary.chipStrokeTransparency or 0.6
        end
        if chip.label then
            chip.label.Font = summaryTheme.labelFont or DEFAULT_THEME.summary.labelFont
            chip.label.TextSize = summaryTheme.labelTextSize or DEFAULT_THEME.summary.labelTextSize
            chip.label.TextColor3 = summaryTheme.labelColor or DEFAULT_THEME.summary.labelColor
        end
        if chip.value then
            chip.value.Font = summaryTheme.valueFont or DEFAULT_THEME.summary.valueFont
            chip.value.TextSize = summaryTheme.valueTextSize or DEFAULT_THEME.summary.valueTextSize
            chip.value.TextColor3 = summaryTheme.valueColor or DEFAULT_THEME.summary.valueColor
        end
    end
end

function VerificationDashboard:setHeaderSummary(summary)
    if self._destroyed or not self._summaryChips then
        return
    end

    if summary ~= nil and typeof(summary) == "table" then
        self._summaryDefinitions = Util.deepCopy(summary)
    end

    local source = summary
    if typeof(source) ~= "table" then
        source = self._summaryDefinitions or DEFAULT_HEADER_SUMMARY
    end

    local normalised = normalizeSummaryInput(source)
    if not normalised then
        normalised = normalizeSummaryInput(DEFAULT_HEADER_SUMMARY) or {}
    end

    for key, chip in pairs(self._summaryChips) do
        local identifier = chip.id or key
        local lookupKey = identifier and string.lower(tostring(identifier)) or nil
        local payload = lookupKey and normalised[lookupKey] or nil

        local labelText = chip.defaultLabel or identifier
        local valueText = chip.defaultValue
        if valueText == nil then
            valueText = ""
        end

        if payload then
            if payload.label ~= nil then
                labelText = payload.label
            end
            if payload.value ~= nil then
                valueText = payload.value
            end
        end

        if chip.label then
            chip.label.Text = string.upper(tostring(labelText))
        end
        if chip.value then
            chip.value.Text = tostring(valueText)
        end
    end

    self:_applySummaryTheme()
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

    if self._connections then
        for _, connection in ipairs(self._connections) do
            if connection then
                if connection.Disconnect then
                    connection:Disconnect()
                elseif connection.disconnect then
                    connection:disconnect()
                end
            end
        end
        self._connections = nil
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
    self:_applyInsightsTheme()
    self:_applySummaryTheme()

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

    if self._progressTrack then
        self._progressTrack.BackgroundColor3 = currentTheme.cardColor:Lerp(currentTheme.accentColor, 0.08)
        self._progressTrack.BackgroundTransparency = math.clamp((currentTheme.cardTransparency or 0) + 0.12, 0, 1)
    end

    if self._progressFill then
        self._progressFill.BackgroundColor3 = currentTheme.accentColor
    end

    if self._telemetryGrid or self._telemetryCards then
        local telemetryTheme = currentTheme.telemetry or DEFAULT_THEME.telemetry
        if self._telemetryGrid then
            self._telemetryGrid.CellPadding = telemetryTheme.cellPadding or DEFAULT_THEME.telemetry.cellPadding
            self._telemetryGrid.CellSize = telemetryTheme.cellSize or DEFAULT_THEME.telemetry.cellSize
            self._telemetryGrid.FillDirectionMaxCells = telemetryTheme.maxColumns or DEFAULT_THEME.telemetry.maxColumns or 2
        end

        if self._telemetryCards then
            for _, card in pairs(self._telemetryCards) do
                if card.frame then
                    card.frame.BackgroundColor3 = telemetryTheme.cardColor
                    card.frame.BackgroundTransparency = telemetryTheme.cardTransparency
                end
                if card.stroke then
                    card.stroke.Color = telemetryTheme.cardStrokeColor
                    card.stroke.Transparency = telemetryTheme.cardStrokeTransparency
                end
                if card.spark then
                    card.spark.BackgroundColor3 = telemetryTheme.sparkColor or currentTheme.accentColor
                    card.spark.BackgroundTransparency = telemetryTheme.sparkTransparency or 0.2
                end
                if card.label then
                    card.label.Font = telemetryTheme.labelFont
                    card.label.TextSize = telemetryTheme.labelTextSize
                    card.label.TextColor3 = (telemetryTheme.accentColor or currentTheme.accentColor):Lerp(Color3.new(1, 1, 1), 0.35)
                end
                if card.value then
                    local valueColor = telemetryTheme.valueColor or Color3.fromRGB(235, 245, 255)
                    card.value.Font = telemetryTheme.valueFont
                    card.value.TextSize = telemetryTheme.valueTextSize
                    card.value.TextColor3 = valueColor
                    card.defaultValueColor = valueColor
                end
                if card.hint then
                    local hintColor = telemetryTheme.hintColor or Color3.fromRGB(176, 196, 230)
                    card.hint.Font = telemetryTheme.labelFont
                    card.hint.TextSize = math.max((telemetryTheme.labelTextSize or DEFAULT_THEME.telemetry.labelTextSize) - 1, 10)
                    card.hint.TextColor3 = hintColor
                    card.defaultHintColor = hintColor
                end
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
            if step.meta then
                step.meta.Font = currentTheme.stepStatusFont
                step.meta.TextSize = math.max(currentTheme.stepStatusTextSize - 1, 12)
                step.meta.TextColor3 = Color3.fromRGB(168, 182, 210)
            end
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

    self:updateLayout(self._lastLayoutBounds)
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
        local valueColor
        local hintColor
        local sparkColor
        local sparkTransparency

        if typeof(payload) == "table" then
            valueText = payload.value or payload.text or payload.display or payload[1]
            hintText = payload.hint or payload.description or payload.label
            if payload.color and typeof(payload.color) == "Color3" then
                valueColor = payload.color
                sparkColor = payload.color
            elseif payload.state then
                local statusColor = self:_resolveStatusColor(payload.state)
                if statusColor then
                    valueColor = statusColor
                    sparkColor = statusColor
                end
            end
            if payload.hintColor and typeof(payload.hintColor) == "Color3" then
                hintColor = payload.hintColor
            end
            if payload.sparkColor and typeof(payload.sparkColor) == "Color3" then
                sparkColor = payload.sparkColor
            end
            if payload.sparkTransparency ~= nil then
                sparkTransparency = payload.sparkTransparency
            end
        end

        if valueText ~= nil and card.value then
            card.value.Text = tostring(valueText)
        elseif card.definition and card.definition.value and card.value then
            card.value.Text = tostring(card.definition.value)
        end

        if card.value then
            card.value.TextColor3 = valueColor or card.defaultValueColor or card.value.TextColor3
        end

        if card.hint then
            if hintText ~= nil then
                card.hint.Text = tostring(hintText)
            elseif card.definition then
                card.hint.Text = card.definition.hint or ""
            end

            card.hint.TextColor3 = hintColor or card.defaultHintColor or card.hint.TextColor3
        end

        if card.spark then
            local theme = self._theme or DEFAULT_THEME
            local telemetryTheme = theme.telemetry or DEFAULT_THEME.telemetry
            card.spark.BackgroundColor3 = sparkColor or telemetryTheme.sparkColor or theme.accentColor
            if sparkTransparency ~= nil then
                card.spark.BackgroundTransparency = sparkTransparency
            else
                card.spark.BackgroundTransparency = telemetryTheme.sparkTransparency or 0.2
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
                step.iconGlow.Transparency = 0.55
            end
            step.connector.BackgroundTransparency = self._theme.connectorTransparency
            step.connector.BackgroundColor3 = self._theme.connectorColor
            if step.meta then
                step.meta.TextColor3 = Color3.fromRGB(168, 182, 210)
            end
            if step.tooltip then
                step.tooltip.Text = definition.tooltip
            end
        end
        self._stepStates[definition.id] = { status = "pending", priority = STATUS_PRIORITY.pending }
    end

    self:setProgress(0)
    self:setHeaderSummary(nil)
    self:setStatusText("Initialising AutoParry suite…")
end

local function resolveStyle(theme, status)
    local resolver = STATUS_STYLE[status]
    if resolver then
        return resolver(theme)
    end
    return STATUS_STYLE.pending(theme)
end

function VerificationDashboard:_resolveStatusColor(status)
    if not status then
        return nil
    end

    local theme = self._theme or DEFAULT_THEME
    local styleResolver = STATUS_STYLE[status]
    if styleResolver then
        local style = styleResolver(theme)
        return style and style.color or nil
    end

    return nil
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
        step.iconGlow.Transparency = style.strokeTransparency or 0.35
    end

    if step.connector then
        step.connector.BackgroundColor3 = style.color
        step.connector.BackgroundTransparency = status == "pending" and self._theme.connectorTransparency or 0.15
    end

    if step.meta then
        if status == "pending" then
            step.meta.TextColor3 = Color3.fromRGB(168, 182, 210)
        else
            local accentBase = style.color or self._theme.accentColor
            step.meta.TextColor3 = accentBase:Lerp(Color3.fromRGB(230, 236, 248), 0.45)
        end
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
        self:updateLayout(self._lastLayoutBounds)
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

    self:updateLayout(self._lastLayoutBounds)
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

    self:updateLayout(self._lastLayoutBounds)
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
