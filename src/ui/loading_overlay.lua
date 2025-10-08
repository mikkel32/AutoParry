-- mikkel32/AutoParry : src/ui/loading_overlay.lua
-- Full-screen loading overlay with spinner, progress bar, status text, and optional tips.
--
-- API:
--   local overlay = LoadingOverlay.create({
--       parent = CoreGui, -- optional custom parent
--       name = "AutoParryLoadingOverlay", -- ScreenGui name override
--       tips = { "Tip A", "Tip B" }, -- optional table of rotating tips
--       theme = { -- override any of the keys below to theme the overlay
--           backdropColor = Color3.fromRGB(6, 7, 9),
--           backdropTransparency = 0.2,
--           accentColor = Color3.fromRGB(0, 170, 255),
--           spinnerColor = Color3.fromRGB(255, 255, 255),
--           progressBackgroundColor = Color3.fromRGB(40, 40, 40),
--           progressFillColor = Color3.fromRGB(0, 170, 255),
--           statusTextColor = Color3.fromRGB(235, 235, 235),
--           tipTextColor = Color3.fromRGB(180, 180, 180),
--           containerSize = UDim2.new(0, 360, 0, 240),
--           spinnerSize = UDim2.new(0, 72, 0, 72),
--           progressBarSize = UDim2.new(0, 280, 0, 12),
--           progressTweenSeconds = 0.35,
--           statusTweenSeconds = 0.18,
--       },
--   })
--
-- Methods on the returned overlay instance:
--   overlay:setStatus(text, options?)
--   overlay:setProgress(alpha, options?)
--   overlay:setTips(tipsTable)
--   overlay:showTip(text)
--   overlay:nextTip()
--   overlay:applyTheme(themeOverrides)
--   overlay:complete()
--   overlay:onCompleted(callback) -> connection
--   overlay:isComplete() -> bool
--   overlay:destroy()
--
-- Styling hooks are exposed through the `theme` table. Downstream experiences can
-- call `overlay:applyTheme` at runtime to adjust colors, fonts, and layout metrics.

local CoreGui = game:GetService("CoreGui")
local TweenService = game:GetService("TweenService")
local ContentProvider = game:GetService("ContentProvider")
local Workspace = game:GetService("Workspace")

local Require = rawget(_G, "ARequire")
local Util = Require("src/shared/util.lua")

local LoadingOverlay = {}
LoadingOverlay.__index = LoadingOverlay

local Module = {}

local FONT_ASSET = "rbxasset://fonts/families/GothamSSm.json"
local SPINNER_ASSET = "rbxasset://textures/ui/LoadingIndicator.png"

local DEFAULT_THEME = {
    backdropColor = Color3.fromRGB(6, 6, 6),
    backdropTransparency = 0.35,
    accentColor = Color3.fromRGB(0, 170, 255),
    spinnerColor = Color3.fromRGB(255, 255, 255),
    progressBackgroundColor = Color3.fromRGB(24, 26, 40),
    progressFillColor = Color3.fromRGB(0, 170, 255),
    statusTextColor = Color3.fromRGB(240, 240, 240),
    tipTextColor = Color3.fromRGB(185, 185, 185),
    containerSize = UDim2.new(0, 640, 0, 360),
    containerTransparency = 0.08,
    containerCornerRadius = UDim.new(0, 18),
    containerStrokeColor = Color3.fromRGB(0, 150, 255),
    containerStrokeTransparency = 0.35,
    containerStrokeThickness = 2,
    spinnerSize = UDim2.new(0, 96, 0, 96),
    spinnerPosition = UDim2.new(0.5, 0, 0.22, 0),
    progressBarSize = UDim2.new(0.85, 0, 0, 14),
    progressBarPosition = UDim2.new(0.5, 0, 0.52, 0),
    statusPosition = UDim2.new(0.5, 0, 0.7, 0),
    tipPosition = UDim2.new(0.5, 0, 0.85, 0),
    progressTweenSeconds = 0.35,
    statusTweenSeconds = 0.18,
    actionsPadding = UDim.new(0, 12),
    actionsPosition = UDim2.new(0.5, 0, 1, -24),
    actionsSize = UDim2.new(0.9, 0, 0, 44),
    actionButtonHeight = 40,
    actionButtonMinWidth = 140,
    actionButtonCorner = UDim.new(0, 10),
    actionButtonFont = Enum.Font.GothamBold,
    actionButtonTextSize = 18,
    actionPrimaryColor = Color3.fromRGB(0, 170, 255),
    actionPrimaryTextColor = Color3.fromRGB(15, 15, 15),
    actionSecondaryColor = Color3.fromRGB(40, 45, 65),
    actionSecondaryTextColor = Color3.fromRGB(240, 240, 240),
    glow = {
        color = Color3.fromRGB(0, 255, 255),
        transparency = 0.55,
        size = Vector2.new(120, 160),
    },
    gradient = {
        enabled = true,
        rotation = 115,
        color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(12, 16, 36)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 170, 255)),
        }),
        transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.25),
            NumberSequenceKeypoint.new(0.55, 0.45),
            NumberSequenceKeypoint.new(1, 0.2),
        }),
    },
    hero = {
        titleFont = Enum.Font.GothamBlack,
        titleTextSize = 28,
        titleColor = Color3.fromRGB(235, 245, 255),
        subtitleFont = Enum.Font.Gotham,
        subtitleTextSize = 18,
        subtitleColor = Color3.fromRGB(188, 210, 255),
        pillFont = Enum.Font.GothamSemibold,
        pillTextSize = 14,
        pillTextColor = Color3.fromRGB(205, 225, 255),
        pillBackgroundColor = Color3.fromRGB(16, 24, 40),
        pillTransparency = 0.1,
        pillAccentColor = Color3.fromRGB(0, 210, 255),
        pillStrokeTransparency = 0.55,
        gridPadding = 12,
    },
    dashboardPanel = {
        backgroundColor = Color3.fromRGB(12, 18, 32),
        backgroundTransparency = 0.05,
        strokeColor = Color3.fromRGB(0, 170, 255),
        strokeTransparency = 0.45,
        cornerRadius = UDim.new(0, 16),
        gradient = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(10, 16, 28)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 110, 180)),
        }),
        gradientTransparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.8),
            NumberSequenceKeypoint.new(1, 0.3),
        }),
    },
    iconography = {
        spinner = SPINNER_ASSET,
        check = "rbxassetid://6031068421",
        warning = "rbxassetid://6031071051",
        error = "rbxassetid://6031094678",
        pending = "rbxassetid://6031071050",
        hologram = "rbxassetid://12148062841",
        progressArc = "rbxassetid://10957012643",
    },
    typography = {
        statusFont = Enum.Font.GothamMedium,
        statusTextSize = 20,
        tipFont = Enum.Font.Gotham,
        tipTextSize = 16,
        badgeFont = Enum.Font.GothamBold,
        badgeTextSize = 16,
        timelineHeadingFont = Enum.Font.GothamBlack,
        timelineHeadingSize = 20,
        timelineStepFont = Enum.Font.GothamSemibold,
        timelineStepSize = 18,
        timelineTooltipFont = Enum.Font.Gotham,
        timelineTooltipSize = 14,
    },
    responsive = {
        minWidth = 360,
        mediumWidth = 540,
        largeWidth = 720,
        maxWidth = 820,
        columnSpacing = 32,
    },
    hologramBadgeColor = Color3.fromRGB(0, 210, 255),
    hologramBadgeTransparency = 0.25,
    progressArcColor = Color3.fromRGB(0, 210, 255),
    progressArcTransparency = 0.4,
    dashboardMountSize = UDim2.new(1, -12, 1, -12),
}

local activeOverlay

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

local function mergeTheme(overrides)
    local theme = Util.deepCopy(DEFAULT_THEME)
    if typeof(overrides) == "table" then
        theme = mergeTable(theme, overrides)
        if overrides.accentColor then
            if overrides.progressFillColor == nil then
                theme.progressFillColor = overrides.accentColor
            end
            if overrides.spinnerColor == nil then
                theme.spinnerColor = overrides.accentColor
            end
        end
    end
    return theme
end

local function resolveScreenGuiParent(requestedParent)
    if requestedParent == nil then
        return CoreGui
    end

    if typeof(requestedParent) ~= "Instance" then
        return CoreGui
    end

    if requestedParent:IsA("LayerCollector")
        or requestedParent:IsA("BasePlayerGui")
        or requestedParent:IsA("CoreGui")
    then
        return requestedParent
    end

    local ancestorCollector = requestedParent:FindFirstAncestorWhichIsA("LayerCollector")
    if ancestorCollector then
        return ancestorCollector
    end

    local ancestorPlayerGui = requestedParent:FindFirstAncestorWhichIsA("BasePlayerGui")
    if ancestorPlayerGui then
        return ancestorPlayerGui
    end

    local ancestorCoreGui = requestedParent:FindFirstAncestorWhichIsA("CoreGui")
    if ancestorCoreGui then
        return ancestorCoreGui
    end

    return CoreGui
end

local function createScreenGui(options)
    local parent = resolveScreenGuiParent(options.parent)

    local gui = Instance.new("ScreenGui")
    gui.Name = options.name or "AutoParryLoadingOverlay"
    gui.DisplayOrder = 10_000
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.IgnoreGuiInset = true
    gui.Parent = parent
    return gui
end

local function createSpinner(parent, theme)
    local spinner = Instance.new("ImageLabel")
    spinner.Name = "Spinner"
    spinner.AnchorPoint = Vector2.new(0.5, 0.5)
    spinner.Size = theme.spinnerSize or DEFAULT_THEME.spinnerSize
    spinner.Position = theme.spinnerPosition or DEFAULT_THEME.spinnerPosition
    spinner.BackgroundTransparency = 1
    spinner.Image = (theme.iconography and theme.iconography.spinner)
        or theme.spinnerAsset
        or SPINNER_ASSET
    spinner.ImageColor3 = theme.spinnerColor or DEFAULT_THEME.spinnerColor
    spinner.Parent = parent
    return spinner
end

local function createProgressBar(parent, theme)
    local bar = Instance.new("Frame")
    bar.Name = "Progress"
    bar.AnchorPoint = Vector2.new(0.5, 0)
    bar.Size = theme.progressBarSize or DEFAULT_THEME.progressBarSize
    bar.Position = theme.progressBarPosition or DEFAULT_THEME.progressBarPosition
    bar.BackgroundColor3 = theme.progressBackgroundColor or DEFAULT_THEME.progressBackgroundColor
    bar.BackgroundTransparency = 0.25
    bar.BorderSizePixel = 0
    bar.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = bar

    local fill = Instance.new("Frame")
    fill.Name = "Fill"
    fill.AnchorPoint = Vector2.new(0, 0.5)
    fill.Position = UDim2.new(0, 0, 0.5, 0)
    fill.Size = UDim2.new(0, 0, 1, 0)
    fill.BackgroundColor3 = theme.progressFillColor or DEFAULT_THEME.progressFillColor
    fill.BackgroundTransparency = 0
    fill.BorderSizePixel = 0
    fill.Parent = bar

    local fillCorner = Instance.new("UICorner")
    fillCorner.CornerRadius = UDim.new(0, 6)
    fillCorner.Parent = fill

    return bar, fill
end

local function createStatusLabel(parent, theme)
    local label = Instance.new("TextLabel")
    label.Name = "Status"
    label.AnchorPoint = Vector2.new(0.5, 0)
    label.Position = theme.statusPosition or DEFAULT_THEME.statusPosition
    label.Size = UDim2.new(0.8, 0, 0, 32)
    label.BackgroundTransparency = 1
    label.Font = (theme.typography and theme.typography.statusFont)
        or DEFAULT_THEME.typography.statusFont
    label.TextSize = (theme.typography and theme.typography.statusTextSize)
        or DEFAULT_THEME.typography.statusTextSize
    label.TextColor3 = theme.statusTextColor or DEFAULT_THEME.statusTextColor
    label.Text = ""
    label.TextWrapped = true
    label.Parent = parent
    return label
end

local function createTipLabel(parent, theme)
    local label = Instance.new("TextLabel")
    label.Name = "Tip"
    label.AnchorPoint = Vector2.new(0.5, 0)
    label.Position = theme.tipPosition or DEFAULT_THEME.tipPosition
    label.Size = UDim2.new(0.9, 0, 0, 28)
    label.BackgroundTransparency = 1
    label.Font = (theme.typography and theme.typography.tipFont)
        or DEFAULT_THEME.typography.tipFont
    label.TextSize = (theme.typography and theme.typography.tipTextSize)
        or DEFAULT_THEME.typography.tipTextSize
    label.TextColor3 = theme.tipTextColor or DEFAULT_THEME.tipTextColor
    label.TextTransparency = 0.15
    label.TextWrapped = true
    label.Text = ""
    label.Visible = false
    label.Parent = parent
    return label
end

local function createHeroPill(parent, theme, text)
    local heroTheme = theme.hero or DEFAULT_THEME.hero or {}

    local pill = Instance.new("Frame")
    pill.Name = "HeroPill"
    pill.BackgroundTransparency = heroTheme.pillTransparency or 0.1
    pill.BackgroundColor3 = heroTheme.pillBackgroundColor or Color3.fromRGB(16, 24, 40)
    pill.BorderSizePixel = 0
    pill.Size = UDim2.new(0, 180, 0, 34)
    pill.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 14)
    corner.Parent = pill

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1
    stroke.Transparency = heroTheme.pillStrokeTransparency or 0.55
    stroke.Color = theme.accentColor or DEFAULT_THEME.accentColor
    stroke.Parent = pill

    local accent = Instance.new("Frame")
    accent.Name = "Accent"
    accent.AnchorPoint = Vector2.new(0, 0.5)
    accent.Position = UDim2.new(0, 10, 0.5, 0)
    accent.Size = UDim2.new(0, 10, 0, 10)
    accent.BackgroundColor3 = heroTheme.pillAccentColor or theme.accentColor or DEFAULT_THEME.accentColor
    accent.BorderSizePixel = 0
    accent.Parent = pill

    local accentCorner = Instance.new("UICorner")
    accentCorner.CornerRadius = UDim.new(1, 0)
    accentCorner.Parent = accent

    local label = Instance.new("TextLabel")
    label.Name = "Label"
    label.BackgroundTransparency = 1
    label.Size = UDim2.new(1, -36, 1, 0)
    label.Position = UDim2.new(0, 28, 0, 0)
    label.Font = heroTheme.pillFont or Enum.Font.GothamSemibold
    label.TextSize = heroTheme.pillTextSize or 14
    label.TextColor3 = heroTheme.pillTextColor or Color3.fromRGB(205, 225, 255)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = text or ""
    label.Parent = pill

    return {
        frame = pill,
        label = label,
        accent = accent,
        stroke = stroke,
    }
end

local function createActionsRow(parent, theme)
    local frame = Instance.new("Frame")
    frame.Name = "Actions"
    frame.AnchorPoint = Vector2.new(0.5, 1)
    frame.Position = theme.actionsPosition or DEFAULT_THEME.actionsPosition
    frame.Size = theme.actionsSize or DEFAULT_THEME.actionsSize
    frame.BackgroundTransparency = 1
    frame.Visible = false
    frame.Parent = parent

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Horizontal
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    layout.VerticalAlignment = Enum.VerticalAlignment.Center
    layout.Padding = theme.actionsPadding or DEFAULT_THEME.actionsPadding
    layout.Parent = frame

    return frame, layout
end

local function preloadAssets(instances)
    task.spawn(function()
        local payload = {}
        for _, item in ipairs(instances) do
            if item ~= nil then
                table.insert(payload, item)
            end
        end

        if #payload == 0 then
            return
        end

        local ok, err = pcall(function()
            ContentProvider:PreloadAsync(payload)
        end)
        if not ok then
            warn("AutoParry loading overlay preload failed:", err)
        end
    end)
end

function LoadingOverlay.new(options)
    options = options or {}
    local theme = mergeTheme(options.theme)

    local gui = createScreenGui(options)

    local backdrop = Instance.new("Frame")
    backdrop.Name = "Backdrop"
    backdrop.Size = UDim2.new(1, 0, 1, 0)
    backdrop.BackgroundColor3 = theme.backdropColor or DEFAULT_THEME.backdropColor
    backdrop.BackgroundTransparency = theme.backdropTransparency or DEFAULT_THEME.backdropTransparency
    backdrop.BorderSizePixel = 0
    backdrop.Parent = gui

    local container = Instance.new("Frame")
    container.Name = "Container"
    container.AnchorPoint = Vector2.new(0.5, 0.5)
    container.Position = UDim2.new(0.5, 0, 0.5, 0)
    container.Size = theme.containerSize or DEFAULT_THEME.containerSize
    container.BackgroundColor3 = theme.containerBackgroundColor or Color3.fromRGB(10, 14, 28)
    container.BackgroundTransparency = theme.containerTransparency or DEFAULT_THEME.containerTransparency or 0
    container.BorderSizePixel = 0
    container.ClipsDescendants = false
    container.Parent = backdrop

    local containerCorner = Instance.new("UICorner")
    containerCorner.CornerRadius = theme.containerCornerRadius or DEFAULT_THEME.containerCornerRadius
    containerCorner.Parent = container

    local containerStroke = Instance.new("UIStroke")
    containerStroke.Thickness = theme.containerStrokeThickness or DEFAULT_THEME.containerStrokeThickness or 2
    containerStroke.Color = theme.containerStrokeColor or theme.accentColor or DEFAULT_THEME.containerStrokeColor
    containerStroke.Transparency = theme.containerStrokeTransparency or DEFAULT_THEME.containerStrokeTransparency or 0.4
    containerStroke.Parent = container

    local containerGradient
    if theme.gradient and theme.gradient.enabled ~= false then
        containerGradient = Instance.new("UIGradient")
        containerGradient.Name = "ContainerGradient"
        containerGradient.Color = theme.gradient.color or DEFAULT_THEME.gradient.color
        containerGradient.Transparency = theme.gradient.transparency or DEFAULT_THEME.gradient.transparency
        containerGradient.Rotation = theme.gradient.rotation or DEFAULT_THEME.gradient.rotation or 0
        containerGradient.Parent = container
    end

    local glow
    if theme.glow then
        glow = Instance.new("ImageLabel")
        glow.Name = "Glow"
        glow.AnchorPoint = Vector2.new(0.5, 0.5)
        glow.Position = UDim2.new(0.5, 0, 0.5, 0)
        glow.Size = UDim2.new(0, (theme.glow.size and theme.glow.size.X) or 240, 0, (theme.glow.size and theme.glow.size.Y) or 320)
        glow.BackgroundTransparency = 1
        glow.Image = theme.iconography and theme.iconography.hologram or "rbxassetid://12148062841"
        glow.ImageTransparency = theme.glow.transparency or 0.55
        glow.ImageColor3 = theme.glow.color or theme.accentColor or DEFAULT_THEME.accentColor
        glow.ZIndex = 0
        glow.Parent = container
    end

    local containerPadding = Instance.new("UIPadding")
    containerPadding.PaddingTop = UDim.new(0, 28)
    containerPadding.PaddingBottom = UDim.new(0, 28)
    containerPadding.PaddingLeft = UDim.new(0, 28)
    containerPadding.PaddingRight = UDim.new(0, 28)
    containerPadding.Parent = container

    local containerLayout = Instance.new("UIListLayout")
    containerLayout.FillDirection = Enum.FillDirection.Vertical
    containerLayout.SortOrder = Enum.SortOrder.LayoutOrder
    containerLayout.Padding = UDim.new(0, 18)
    containerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    containerLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    containerLayout.Parent = container

    local heroFrame = Instance.new("Frame")
    heroFrame.Name = "Hero"
    heroFrame.BackgroundTransparency = 1
    heroFrame.Size = UDim2.new(1, 0, 0, 150)
    heroFrame.LayoutOrder = 1
    heroFrame.Parent = container

    local heroLayout = Instance.new("UIListLayout")
    heroLayout.FillDirection = Enum.FillDirection.Vertical
    heroLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    heroLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    heroLayout.SortOrder = Enum.SortOrder.LayoutOrder
    heroLayout.Padding = UDim.new(0, 8)
    heroLayout.Parent = heroFrame

    local badge = Instance.new("TextLabel")
    badge.Name = "Badge"
    badge.AnchorPoint = Vector2.new(0.5, 0)
    badge.BackgroundColor3 = theme.hologramBadgeColor or DEFAULT_THEME.hologramBadgeColor
    badge.BackgroundTransparency = theme.hologramBadgeTransparency or DEFAULT_THEME.hologramBadgeTransparency
    badge.Size = UDim2.new(0, 320, 0, 30)
    badge.Font = (theme.typography and theme.typography.badgeFont) or DEFAULT_THEME.typography.badgeFont
    badge.TextSize = (theme.typography and theme.typography.badgeTextSize) or DEFAULT_THEME.typography.badgeTextSize
    badge.TextColor3 = Color3.fromRGB(255, 255, 255)
    badge.Text = "Initializing AutoParry"
    badge.TextXAlignment = Enum.TextXAlignment.Center
    badge.LayoutOrder = 1
    badge.Parent = heroFrame

    local badgeCorner = Instance.new("UICorner")
    badgeCorner.CornerRadius = UDim.new(0, 10)
    badgeCorner.Parent = badge

    local badgeStroke = Instance.new("UIStroke")
    badgeStroke.Thickness = 1.5
    badgeStroke.Transparency = 0.35
    badgeStroke.Color = (theme.accentColor or DEFAULT_THEME.accentColor)
    badgeStroke.Parent = badge

    local heroTitle = Instance.new("TextLabel")
    heroTitle.Name = "HeroTitle"
    heroTitle.BackgroundTransparency = 1
    heroTitle.Size = UDim2.new(1, -32, 0, 34)
    heroTitle.Font = (theme.hero and theme.hero.titleFont) or DEFAULT_THEME.hero.titleFont
    heroTitle.TextSize = (theme.hero and theme.hero.titleTextSize) or DEFAULT_THEME.hero.titleTextSize
    heroTitle.TextColor3 = (theme.hero and theme.hero.titleColor) or DEFAULT_THEME.hero.titleColor
    heroTitle.Text = "Command Center Online"
    heroTitle.TextXAlignment = Enum.TextXAlignment.Center
    heroTitle.LayoutOrder = 2
    heroTitle.Parent = heroFrame

    local heroSubtitle = Instance.new("TextLabel")
    heroSubtitle.Name = "HeroSubtitle"
    heroSubtitle.BackgroundTransparency = 1
    heroSubtitle.Size = UDim2.new(0.9, 0, 0, 28)
    heroSubtitle.Font = (theme.hero and theme.hero.subtitleFont) or DEFAULT_THEME.hero.subtitleFont
    heroSubtitle.TextSize = (theme.hero and theme.hero.subtitleTextSize) or DEFAULT_THEME.hero.subtitleTextSize
    heroSubtitle.TextColor3 = (theme.hero and theme.hero.subtitleColor) or DEFAULT_THEME.hero.subtitleColor
    heroSubtitle.Text = "AutoParry calibrating advanced parry heuristics"
    heroSubtitle.TextWrapped = true
    heroSubtitle.TextXAlignment = Enum.TextXAlignment.Center
    heroSubtitle.LayoutOrder = 3
    heroSubtitle.Parent = heroFrame

    local heroHighlights = Instance.new("Frame")
    heroHighlights.Name = "HeroHighlights"
    heroHighlights.BackgroundTransparency = 1
    heroHighlights.Size = UDim2.new(1, -40, 0, 40)
    heroHighlights.LayoutOrder = 4
    heroHighlights.Parent = heroFrame

    local heroHighlightsLayout = Instance.new("UIListLayout")
    heroHighlightsLayout.FillDirection = Enum.FillDirection.Horizontal
    heroHighlightsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    heroHighlightsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    heroHighlightsLayout.SortOrder = Enum.SortOrder.LayoutOrder
    heroHighlightsLayout.Padding = UDim.new(0, (theme.hero and theme.hero.gridPadding) or DEFAULT_THEME.hero.gridPadding)
    heroHighlightsLayout.Parent = heroHighlights

    local heroPills = {}
    for _, labelText in ipairs({
        "Adaptive timing engine",
        "Lag-safe prediction",
        "Quantum ball tracing",
    }) do
        local pill = createHeroPill(heroHighlights, theme, labelText)
        table.insert(heroPills, pill)
    end

    local contentFrame = Instance.new("Frame")
    contentFrame.Name = "Content"
    contentFrame.BackgroundTransparency = 1
    contentFrame.Size = UDim2.new(1, 0, 1, -160)
    contentFrame.LayoutOrder = 2
    contentFrame.Parent = container

    local contentLayout = Instance.new("UIListLayout")
    contentLayout.FillDirection = Enum.FillDirection.Horizontal
    contentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    contentLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
    contentLayout.Padding = UDim.new(0, (theme.responsive and theme.responsive.columnSpacing) or DEFAULT_THEME.responsive.columnSpacing or 32)
    contentLayout.Parent = contentFrame

    local infoColumn = Instance.new("Frame")
    infoColumn.Name = "InfoColumn"
    infoColumn.Size = UDim2.new(0.46, -12, 1, -12)
    infoColumn.BackgroundTransparency = 1
    infoColumn.LayoutOrder = 1
    infoColumn.Parent = contentFrame

    local infoLayout = Instance.new("UIListLayout")
    infoLayout.FillDirection = Enum.FillDirection.Vertical
    infoLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    infoLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    infoLayout.SortOrder = Enum.SortOrder.LayoutOrder
    infoLayout.Padding = UDim.new(0, 12)
    infoLayout.Parent = infoColumn

    local visualStack = Instance.new("Frame")
    visualStack.Name = "VisualStack"
    visualStack.BackgroundTransparency = 1
    visualStack.Size = UDim2.new(1, 0, 0, 150)
    visualStack.LayoutOrder = 1
    visualStack.Parent = infoColumn

    local spinner = createSpinner(visualStack, theme)
    spinner.AnchorPoint = Vector2.new(0.5, 0.5)
    spinner.Position = UDim2.new(0.5, 0, 0.5, 0)

    local progressArc = Instance.new("ImageLabel")
    progressArc.Name = "ProgressArc"
    progressArc.AnchorPoint = Vector2.new(0.5, 0.5)
    progressArc.Position = UDim2.new(0.5, 0, 0.5, 0)
    progressArc.Size = UDim2.new(0, math.max((spinner.Size.X.Offset or 0) + 56, 136), 0, math.max((spinner.Size.Y.Offset or 0) + 56, 136))
    progressArc.BackgroundTransparency = 1
    progressArc.Image = theme.iconography and theme.iconography.progressArc or "rbxassetid://10957012643"
    progressArc.ImageColor3 = theme.progressArcColor or DEFAULT_THEME.progressArcColor
    progressArc.ImageTransparency = theme.progressArcTransparency or DEFAULT_THEME.progressArcTransparency
    progressArc.ZIndex = spinner.ZIndex - 1
    progressArc.Parent = visualStack

    local arcGradient = Instance.new("UIGradient")
    arcGradient.Name = "ProgressGradient"
    arcGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, theme.progressArcColor or DEFAULT_THEME.progressArcColor),
        ColorSequenceKeypoint.new(1, theme.progressArcColor or DEFAULT_THEME.progressArcColor),
    })
    arcGradient.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0),
        NumberSequenceKeypoint.new(0.5, 0.35),
        NumberSequenceKeypoint.new(1, 1),
    })
    arcGradient.Rotation = 0
    arcGradient.Offset = Vector2.new(-1, 0)
    arcGradient.Parent = progressArc

    local progressBar, progressFill = createProgressBar(infoColumn, theme)
    progressBar.LayoutOrder = 2

    local statusLabel = createStatusLabel(infoColumn, theme)
    statusLabel.LayoutOrder = 3

    local tipLabel = createTipLabel(infoColumn, theme)
    tipLabel.LayoutOrder = 4

    local actionsRow, actionsLayout = createActionsRow(infoColumn, theme)
    actionsRow.AnchorPoint = Vector2.new(0.5, 0)
    actionsRow.Position = UDim2.new(0.5, 0, 0, 0)
    actionsRow.LayoutOrder = 5

    local dashboardColumn = Instance.new("Frame")
    dashboardColumn.Name = "DashboardColumn"
    dashboardColumn.Size = UDim2.new(0.54, 0, 1, 0)
    dashboardColumn.BackgroundTransparency = 1
    dashboardColumn.LayoutOrder = 2
    dashboardColumn.Parent = contentFrame

    local dashboardSurface = Instance.new("Frame")
    dashboardSurface.Name = "DashboardSurface"
    dashboardSurface.AnchorPoint = Vector2.new(0.5, 0.5)
    dashboardSurface.Position = UDim2.new(0.5, 0, 0.5, 0)
    dashboardSurface.Size = UDim2.new(1, -4, 1, -4)
    dashboardSurface.BackgroundColor3 = (theme.dashboardPanel and theme.dashboardPanel.backgroundColor) or DEFAULT_THEME.dashboardPanel.backgroundColor
    dashboardSurface.BackgroundTransparency = (theme.dashboardPanel and theme.dashboardPanel.backgroundTransparency) or DEFAULT_THEME.dashboardPanel.backgroundTransparency
    dashboardSurface.BorderSizePixel = 0
    dashboardSurface.Parent = dashboardColumn

    local dashboardCorner = Instance.new("UICorner")
    dashboardCorner.CornerRadius = (theme.dashboardPanel and theme.dashboardPanel.cornerRadius) or DEFAULT_THEME.dashboardPanel.cornerRadius
    dashboardCorner.Parent = dashboardSurface

    local dashboardStroke = Instance.new("UIStroke")
    dashboardStroke.Thickness = 1.6
    dashboardStroke.Color = (theme.dashboardPanel and theme.dashboardPanel.strokeColor) or DEFAULT_THEME.dashboardPanel.strokeColor
    dashboardStroke.Transparency = (theme.dashboardPanel and theme.dashboardPanel.strokeTransparency) or DEFAULT_THEME.dashboardPanel.strokeTransparency
    dashboardStroke.Parent = dashboardSurface

    local dashboardGradient = Instance.new("UIGradient")
    dashboardGradient.Color = (theme.dashboardPanel and theme.dashboardPanel.gradient) or DEFAULT_THEME.dashboardPanel.gradient
    dashboardGradient.Transparency = (theme.dashboardPanel and theme.dashboardPanel.gradientTransparency) or DEFAULT_THEME.dashboardPanel.gradientTransparency
    dashboardGradient.Rotation = 120
    dashboardGradient.Parent = dashboardSurface

    local dashboardMount = Instance.new("Frame")
    dashboardMount.Name = "DashboardMount"
    dashboardMount.BackgroundTransparency = 1
    dashboardMount.Size = theme.dashboardMountSize or DEFAULT_THEME.dashboardMountSize
    dashboardMount.Position = UDim2.new(0.5, 0, 0.5, 0)
    dashboardMount.AnchorPoint = Vector2.new(0.5, 0.5)
    dashboardMount.Parent = dashboardSurface

    preloadAssets({
        spinner,
        progressBar,
        FONT_ASSET,
        SPINNER_ASSET,
        progressArc,
        badge,
        (theme.iconography and theme.iconography.check) or nil,
        (theme.iconography and theme.iconography.warning) or nil,
        (theme.iconography and theme.iconography.error) or nil,
        (theme.iconography and theme.iconography.pending) or nil,
    })

    local self = setmetatable({
        _gui = gui,
        _backdrop = backdrop,
        _container = container,
        _spinner = spinner,
        _progressBar = progressBar,
        _progressFill = progressFill,
        _statusLabel = statusLabel,
        _tipLabel = tipLabel,
        _actionsRow = actionsRow,
        _actionsLayout = actionsLayout,
        _dashboardMount = dashboardMount,
        _progressArc = progressArc,
        _progressArcGradient = arcGradient,
        _badge = badge,
        _heroFrame = heroFrame,
        _heroTitle = heroTitle,
        _heroSubtitle = heroSubtitle,
        _heroHighlightsFrame = heroHighlights,
        _heroPills = heroPills,
        _heroTitleText = heroTitle.Text,
        _heroSubtitleText = heroSubtitle.Text,
        _heroHighlightTexts = {
            heroPills[1] and heroPills[1].label and heroPills[1].label.Text or "Adaptive timing engine",
            heroPills[2] and heroPills[2].label and heroPills[2].label.Text or "Lag-safe prediction",
            heroPills[3] and heroPills[3].label and heroPills[3].label.Text or "Quantum ball tracing",
        },
        _contentFrame = contentFrame,
        _contentLayout = contentLayout,
        _infoColumn = infoColumn,
        _infoLayout = infoLayout,
        _visualStack = visualStack,
        _dashboardColumn = dashboardColumn,
        _dashboardSurface = dashboardSurface,
        _dashboardStroke = dashboardStroke,
        _dashboardGradient = dashboardGradient,
        _containerGlow = glow,
        _containerGradient = containerGradient,
        _viewportConnection = nil,
        _badgeStatus = "Initializing AutoParry",
        _badgeProgress = 0,
        _dashboard = nil,
        _progress = 0,
        _completed = false,
        _destroyed = false,
        _theme = theme,
        _tips = nil,
        _tipIndex = 0,
        _connections = {},
        _completedSignal = Util.Signal.new(),
        _actionButtons = {},
        _actionConnections = {},
        _actions = nil,
    }, LoadingOverlay)

    local spinnerTween = TweenService:Create(spinner, TweenInfo.new(1.2, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1), {
        Rotation = 360,
    })
    spinnerTween:Play()
    self._spinnerTween = spinnerTween

    self:_connectResponsiveLayout()

    if typeof(options.tips) == "table" then
        self:setTips(options.tips)
    end

    if typeof(options.heroTitle) == "string" then
        self:setHeroTitle(options.heroTitle)
    end
    if typeof(options.heroSubtitle) == "string" then
        self:setHeroSubtitle(options.heroSubtitle)
    end
    if typeof(options.heroHighlights) == "table" then
        self:setHeroHighlights(options.heroHighlights)
    end

    self:_refreshBadge()

    return self
end

function LoadingOverlay:_applyResponsiveLayout(viewportSize)
    if self._destroyed then
        return
    end

    local container = self._container
    if not container then
        return
    end

    local theme = self._theme or DEFAULT_THEME
    local responsive = theme.responsive or DEFAULT_THEME.responsive or {}
    local viewportWidth = viewportSize and viewportSize.X or (theme.containerSize and theme.containerSize.X.Offset) or 640
    local minWidth = responsive.minWidth or 360
    local maxWidth = responsive.maxWidth or viewportWidth
    local desiredWidth = math.clamp(math.floor(viewportWidth * 0.7), minWidth, maxWidth)
    local defaultHeight = (theme.containerSize and theme.containerSize.Y.Offset)
        or (DEFAULT_THEME.containerSize and DEFAULT_THEME.containerSize.Y.Offset)
        or 360

    container.Size = UDim2.new(0, desiredWidth, 0, defaultHeight)

    local contentLayout = self._contentLayout
    local infoColumn = self._infoColumn
    local dashboardColumn = self._dashboardColumn
    local heroFrame = self._heroFrame
    if not infoColumn or not dashboardColumn then
        return
    end

    local columnSpacing = responsive.columnSpacing or 32
    if contentLayout then
        contentLayout.Padding = UDim.new(0, columnSpacing)
    end

    if viewportWidth <= (responsive.mediumWidth or 540) then
        if contentLayout then
            contentLayout.FillDirection = Enum.FillDirection.Vertical
            contentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        end

        infoColumn.Size = UDim2.new(1, -32, 0, 260)
        dashboardColumn.Size = UDim2.new(1, -32, 0, 320)

        if heroFrame then
            heroFrame.Size = UDim2.new(1, 0, 0, 190)
        end
    elseif viewportWidth <= (responsive.largeWidth or 720) then
        if contentLayout then
            contentLayout.FillDirection = Enum.FillDirection.Vertical
            contentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        end

        infoColumn.Size = UDim2.new(1, -32, 0, 300)
        dashboardColumn.Size = UDim2.new(1, -32, 0, 340)

        if heroFrame then
            heroFrame.Size = UDim2.new(1, 0, 0, 180)
        end
    else
        if contentLayout then
            contentLayout.FillDirection = Enum.FillDirection.Horizontal
            contentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        end

        infoColumn.Size = UDim2.new(0.46, -columnSpacing, 1, -12)
        dashboardColumn.Size = UDim2.new(0.54, 0, 1, -12)

        if heroFrame then
            heroFrame.Size = UDim2.new(1, 0, 0, 150)
        end
    end
end

function LoadingOverlay:_connectResponsiveLayout()
    local function applyFromCamera(camera)
        if not camera then
            self:_applyResponsiveLayout(nil)
            return
        end
        self:_applyResponsiveLayout(camera.ViewportSize)
    end

    local function connectViewport(camera)
        if self._viewportConnection then
            self._viewportConnection:Disconnect()
            self._viewportConnection = nil
        end
        if not camera then
            return
        end
        applyFromCamera(camera)
        local connection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
            applyFromCamera(camera)
        end)
        table.insert(self._connections, connection)
        self._viewportConnection = connection
    end

    connectViewport(Workspace.CurrentCamera)

    local cameraChanged = Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
        connectViewport(Workspace.CurrentCamera)
    end)
    table.insert(self._connections, cameraChanged)
end

local function truncateBadgeText(text)
    if typeof(text) ~= "string" then
        return ""
    end

    local sanitized = text:gsub("%s+", " ")
    if #sanitized > 40 then
        sanitized = sanitized:sub(1, 40) .. "…"
    end
    return sanitized
end

function LoadingOverlay:_refreshBadge()
    if not self._badge then
        return
    end

    local status = truncateBadgeText(self._badgeStatus or "Initializing AutoParry")
    local progress = self._badgeProgress
    if typeof(progress) == "number" then
        self._badge.Text = string.format("%s  •  %d%%", status, math.floor(math.clamp(progress, 0, 1) * 100 + 0.5))
    else
        self._badge.Text = status
    end
end

function LoadingOverlay:_setBadgeStatus(text)
    self._badgeStatus = text or self._badgeStatus
    self:_refreshBadge()
end

function LoadingOverlay:_setBadgeProgress(alpha)
    self._badgeProgress = alpha
    self:_refreshBadge()
end

function LoadingOverlay:_updateProgressVisual(alpha, tweenDuration)
    if self._progressArcGradient then
        if self._progressArcTween then
            self._progressArcTween:Cancel()
        end
        local targetOffset = Vector2.new(math.clamp(alpha * 2 - 1, -1, 1), 0)
        local tween = TweenService:Create(self._progressArcGradient, TweenInfo.new(tweenDuration or self._theme.progressTweenSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            Offset = targetOffset,
            Rotation = 360 * math.clamp(alpha, 0, 1),
        })
        self._progressArcTween = tween
        tween:Play()
    end

    self:_setBadgeProgress(alpha)
end

function LoadingOverlay:_applyTipVisibility()
    if not self._tipLabel then
        return
    end
    local visible = self._tipLabel.Text ~= nil and self._tipLabel.Text ~= ""
    self._tipLabel.Visible = visible
end

function LoadingOverlay:setHeroTitle(text)
    if self._destroyed then
        return
    end

    if typeof(text) ~= "string" then
        return
    end

    self._heroTitleText = text
    if self._heroTitle then
        self._heroTitle.Text = text
    end
end

function LoadingOverlay:setHeroSubtitle(text)
    if self._destroyed then
        return
    end

    if typeof(text) ~= "string" then
        return
    end

    self._heroSubtitleText = text
    if self._heroSubtitle then
        self._heroSubtitle.Text = text
    end
end

function LoadingOverlay:setHeroHighlights(highlights)
    if self._destroyed then
        return
    end

    if typeof(highlights) ~= "table" then
        return
    end

    self._heroHighlightTexts = {}

    if not self._heroPills then
        return
    end

    for index, pill in ipairs(self._heroPills) do
        local value = highlights[index]
        if typeof(value) ~= "string" then
            value = pill.label and pill.label.Text or ""
        end
        self._heroHighlightTexts[index] = value
        if pill.label then
            pill.label.Text = value
        end
    end
end

function LoadingOverlay:getTheme()
    return self._theme
end

function LoadingOverlay:getDashboardMount()
    return self._dashboardMount
end

function LoadingOverlay:attachDashboard(dashboard)
    if self._destroyed then
        if dashboard and dashboard.destroy then
            dashboard:destroy()
        end
        return
    end

    if self._dashboard and self._dashboard ~= dashboard and self._dashboard.destroy then
        self._dashboard:destroy()
    end

    self._dashboard = dashboard

    if dashboard then
        if dashboard.applyTheme then
            dashboard:applyTheme(self._theme)
        end
        if dashboard.setProgress then
            dashboard:setProgress(self._progress)
        end
        if dashboard.setStatusText and self._statusLabel then
            dashboard:setStatusText(self._statusLabel.Text)
        end
    end
end

function LoadingOverlay:updateDashboardTelemetry(telemetry)
    if self._destroyed then
        return
    end

    if self._dashboard and self._dashboard.setTelemetry then
        self._dashboard:setTelemetry(telemetry)
    end
end

function LoadingOverlay:setDashboardControls(controls)
    if self._destroyed then
        return
    end

    if self._dashboard and self._dashboard.setControls then
        self._dashboard:setControls(controls)
    end
end

function LoadingOverlay:setTips(tips)
    if self._destroyed then
        return
    end
    if typeof(tips) == "table" and #tips > 0 then
        self._tips = tips
        self._tipIndex = 0
        self:nextTip()
    else
        self._tips = nil
        self._tipIndex = 0
        self:showTip(nil)
    end
end

local function styleActionButton(button, theme, action)
    local isSecondary = action.variant == "secondary" or action.kind == "cancel"
    button.AutoButtonColor = true
    button.BorderSizePixel = 0
    button.BackgroundColor3 = action.backgroundColor
        or (isSecondary and (theme.actionSecondaryColor or DEFAULT_THEME.actionSecondaryColor)
            or (theme.actionPrimaryColor or DEFAULT_THEME.actionPrimaryColor))
    button.TextColor3 = action.textColor
        or (isSecondary and (theme.actionSecondaryTextColor or DEFAULT_THEME.actionSecondaryTextColor)
            or (theme.actionPrimaryTextColor or DEFAULT_THEME.actionPrimaryTextColor))
    button.Font = action.font or theme.actionButtonFont or DEFAULT_THEME.actionButtonFont
    button.TextSize = action.textSize or theme.actionButtonTextSize or DEFAULT_THEME.actionButtonTextSize
end

local function destroyButtons(buttons)
    if not buttons then
        return
    end
    for _, button in ipairs(buttons) do
        if button and button.Destroy then
            button:Destroy()
        end
    end
end

local function disconnectConnections(connections)
    if not connections then
        return
    end
    for _, connection in ipairs(connections) do
        if connection then
            if connection.Disconnect then
                connection:Disconnect()
            elseif connection.disconnect then
                connection:disconnect()
            end
        end
    end
end

function LoadingOverlay:setActions(actions)
    if self._destroyed then
        return
    end

    self._actions = actions

    if not self._actionsRow then
        local row, layout = createActionsRow(self._container, self._theme)
        self._actionsRow = row
        self._actionsLayout = layout
    end

    disconnectConnections(self._actionConnections)
    destroyButtons(self._actionButtons)

    self._actionConnections = {}
    self._actionButtons = {}

    if typeof(actions) ~= "table" or #actions == 0 then
        if self._actionsRow then
            self._actionsRow.Visible = false
        end
        if self._dashboard and self._dashboard.setActions then
            self._dashboard:setActions(nil)
        end
        return
    end

    local theme = self._theme or DEFAULT_THEME
    self._actionsRow.Visible = true
    self._actionsRow.Position = theme.actionsPosition or DEFAULT_THEME.actionsPosition
    self._actionsRow.Size = theme.actionsSize or DEFAULT_THEME.actionsSize
    if self._actionsLayout then
        self._actionsLayout.Padding = theme.actionsPadding or DEFAULT_THEME.actionsPadding
    end

    for index, action in ipairs(actions) do
        local button = Instance.new("TextButton")
        button.Name = action.name or action.id or string.format("Action%d", index)
        button.Size = UDim2.new(0, action.width or theme.actionButtonMinWidth or DEFAULT_THEME.actionButtonMinWidth, 0, action.height or theme.actionButtonHeight or DEFAULT_THEME.actionButtonHeight)
        button.Text = action.text or action.label or "Action"
        styleActionButton(button, theme, action)
        button.Parent = self._actionsRow

        local corner = Instance.new("UICorner")
        corner.CornerRadius = theme.actionButtonCorner or DEFAULT_THEME.actionButtonCorner
        corner.Parent = button

        local connection
        if typeof(action.callback) == "function" then
            connection = button.MouseButton1Click:Connect(function()
                if self._destroyed then
                    return
                end
                action.callback(self, action)
            end)
        end

        table.insert(self._actionButtons, button)
        table.insert(self._actionConnections, connection)
    end

    if self._dashboard and self._dashboard.setActions then
        self._dashboard:setActions(actions)
    end
end

function LoadingOverlay:nextTip()
    if self._destroyed then
        return
    end
    if not self._tips or #self._tips == 0 then
        self:showTip(nil)
        return
    end
    self._tipIndex = self._tipIndex % #self._tips + 1
    self:showTip(self._tips[self._tipIndex])
end

function LoadingOverlay:showTip(text)
    if self._destroyed then
        return
    end
    self._tipLabel.Text = text or ""
    self:_applyTipVisibility()
end

function LoadingOverlay:setStatus(text, options)
    if self._destroyed then
        return
    end
    options = options or {}
    text = text or ""

    local label = self._statusLabel
    if label.Text == text and not options.force then
        return
    end

    label.TextTransparency = 1
    label.Text = text
    label.Visible = text ~= ""

    self:_setBadgeStatus(text)

    if self._statusTween then
        self._statusTween:Cancel()
    end

    local tween = TweenService:Create(label, TweenInfo.new(options.duration or self._theme.statusTweenSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        TextTransparency = 0,
    })
    self._statusTween = tween
    tween:Play()

    if self._dashboard and self._dashboard.setStatusText then
        self._dashboard:setStatusText(text)
    end
end

function LoadingOverlay:setProgress(alpha, options)
    if self._destroyed then
        return
    end

    alpha = math.clamp(tonumber(alpha) or 0, 0, 1)
    options = options or {}

    if self._progress == alpha and not options.force then
        return
    end

    self._progress = alpha

    if self._progressTween then
        self._progressTween:Cancel()
        self._progressTween = nil
    end
    if self._progressTweenConnection then
        self._progressTweenConnection:Disconnect()
        self._progressTweenConnection = nil
    end

    local tween = TweenService:Create(self._progressFill, TweenInfo.new(options.duration or self._theme.progressTweenSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Size = UDim2.new(alpha, 0, 1, 0),
    })
    self._progressTween = tween
    self._progressTweenConnection = tween.Completed:Connect(function()
        if self._progressTween == tween then
            self._progressTween = nil
        end
        if self._progressTweenConnection then
            self._progressTweenConnection:Disconnect()
            self._progressTweenConnection = nil
        end
    end)
    tween:Play()

    self:_updateProgressVisual(alpha, options.duration)

    if self._dashboard and self._dashboard.setProgress then
        self._dashboard:setProgress(alpha)
    end
end

function LoadingOverlay:applyTheme(themeOverrides)
    if self._destroyed then
        return
    end

    self._theme = mergeTheme(themeOverrides)

    local theme = self._theme

    if self._backdrop then
        self._backdrop.BackgroundColor3 = theme.backdropColor or DEFAULT_THEME.backdropColor
        self._backdrop.BackgroundTransparency = theme.backdropTransparency or DEFAULT_THEME.backdropTransparency
    end
    if self._container then
        self._container.Size = theme.containerSize or DEFAULT_THEME.containerSize
        self._container.BackgroundColor3 = theme.containerBackgroundColor or Color3.fromRGB(10, 14, 28)
        self._container.BackgroundTransparency = theme.containerTransparency or DEFAULT_THEME.containerTransparency or 0
    end
    if self._containerGradient then
        self._containerGradient.Color = theme.gradient and theme.gradient.color or DEFAULT_THEME.gradient.color
        self._containerGradient.Transparency = theme.gradient and theme.gradient.transparency or DEFAULT_THEME.gradient.transparency
        self._containerGradient.Rotation = theme.gradient and theme.gradient.rotation or DEFAULT_THEME.gradient.rotation or 0
    end
    if self._containerGlow then
        local glowTheme = theme.glow or DEFAULT_THEME.glow or {}
        self._containerGlow.ImageColor3 = glowTheme.color or theme.accentColor or DEFAULT_THEME.accentColor
        self._containerGlow.ImageTransparency = glowTheme.transparency or 0.55
        if glowTheme.size then
            self._containerGlow.Size = UDim2.new(0, glowTheme.size.X, 0, glowTheme.size.Y)
        end
    end
    if self._spinner then
        self._spinner.ImageColor3 = theme.spinnerColor or DEFAULT_THEME.spinnerColor
        self._spinner.Size = theme.spinnerSize or DEFAULT_THEME.spinnerSize
        self._spinner.Position = UDim2.new(0.5, 0, 0.5, 0)
        local spinnerImage = (theme.iconography and theme.iconography.spinner)
            or theme.spinnerAsset
            or SPINNER_ASSET
        if spinnerImage then
            self._spinner.Image = spinnerImage
        end
    end
    if self._progressBar then
        self._progressBar.Size = theme.progressBarSize or DEFAULT_THEME.progressBarSize
        self._progressBar.BackgroundColor3 = theme.progressBackgroundColor or DEFAULT_THEME.progressBackgroundColor
    end
    if self._progressFill then
        self._progressFill.BackgroundColor3 = theme.progressFillColor or DEFAULT_THEME.progressFillColor
        self._progressFill.Size = UDim2.new(self._progress, 0, 1, 0)
    end
    if self._progressArc then
        self._progressArc.Image = theme.iconography and theme.iconography.progressArc or self._progressArc.Image
        self._progressArc.ImageColor3 = theme.progressArcColor or DEFAULT_THEME.progressArcColor
        self._progressArc.ImageTransparency = theme.progressArcTransparency or DEFAULT_THEME.progressArcTransparency
        local spinnerSize = self._spinner and self._spinner.Size
        local width = spinnerSize and spinnerSize.X.Offset or 96
        local height = spinnerSize and spinnerSize.Y.Offset or 96
        self._progressArc.Size = UDim2.new(0, math.max(width + 40, 120), 0, math.max(height + 40, 120))
    end
    if self._progressArcGradient then
        local arcColor = theme.progressArcColor or DEFAULT_THEME.progressArcColor
        self._progressArcGradient.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, arcColor),
            ColorSequenceKeypoint.new(1, arcColor),
        })
    end
    if self._statusLabel then
        self._statusLabel.TextColor3 = theme.statusTextColor or DEFAULT_THEME.statusTextColor
        self._statusLabel.Font = (theme.typography and theme.typography.statusFont) or DEFAULT_THEME.typography.statusFont
        self._statusLabel.TextSize = (theme.typography and theme.typography.statusTextSize) or DEFAULT_THEME.typography.statusTextSize
    end
    if self._tipLabel then
        self._tipLabel.TextColor3 = theme.tipTextColor or DEFAULT_THEME.tipTextColor
        self._tipLabel.Font = (theme.typography and theme.typography.tipFont) or DEFAULT_THEME.typography.tipFont
        self._tipLabel.TextSize = (theme.typography and theme.typography.tipTextSize) or DEFAULT_THEME.typography.tipTextSize
    end
    if self._badge then
        self._badge.BackgroundColor3 = theme.hologramBadgeColor or DEFAULT_THEME.hologramBadgeColor
        self._badge.BackgroundTransparency = theme.hologramBadgeTransparency or DEFAULT_THEME.hologramBadgeTransparency
        self._badge.Font = (theme.typography and theme.typography.badgeFont) or DEFAULT_THEME.typography.badgeFont
        self._badge.TextSize = (theme.typography and theme.typography.badgeTextSize) or DEFAULT_THEME.typography.badgeTextSize
    end
    if self._actionsRow then
        self._actionsRow.AnchorPoint = Vector2.new(0.5, 0)
        self._actionsRow.Position = UDim2.new(0.5, 0, 0, 0)
        self._actionsRow.Size = theme.actionsSize or DEFAULT_THEME.actionsSize
    end
    if self._actionsLayout then
        self._actionsLayout.Padding = theme.actionsPadding or DEFAULT_THEME.actionsPadding
    end
    local heroTheme = theme.hero or DEFAULT_THEME.hero
    if self._heroTitle then
        self._heroTitle.Font = heroTheme.titleFont or DEFAULT_THEME.hero.titleFont
        self._heroTitle.TextSize = heroTheme.titleTextSize or DEFAULT_THEME.hero.titleTextSize
        self._heroTitle.TextColor3 = heroTheme.titleColor or DEFAULT_THEME.hero.titleColor
        if self._heroTitleText then
            self._heroTitle.Text = self._heroTitleText
        end
    end
    if self._heroSubtitle then
        self._heroSubtitle.Font = heroTheme.subtitleFont or DEFAULT_THEME.hero.subtitleFont
        self._heroSubtitle.TextSize = heroTheme.subtitleTextSize or DEFAULT_THEME.hero.subtitleTextSize
        self._heroSubtitle.TextColor3 = heroTheme.subtitleColor or DEFAULT_THEME.hero.subtitleColor
        if self._heroSubtitleText then
            self._heroSubtitle.Text = self._heroSubtitleText
        end
    end
    if self._heroHighlightsFrame then
        local layout = self._heroHighlightsFrame:FindFirstChildOfClass("UIListLayout")
        if layout then
            layout.Padding = UDim.new(0, heroTheme.gridPadding or DEFAULT_THEME.hero.gridPadding)
        end
    end
    if self._heroPills then
        for index, pill in ipairs(self._heroPills) do
            if pill.frame then
                pill.frame.BackgroundColor3 = heroTheme.pillBackgroundColor or DEFAULT_THEME.hero.pillBackgroundColor
                pill.frame.BackgroundTransparency = heroTheme.pillTransparency or DEFAULT_THEME.hero.pillTransparency
            end
            if pill.stroke then
                pill.stroke.Color = theme.accentColor or DEFAULT_THEME.accentColor
                pill.stroke.Transparency = heroTheme.pillStrokeTransparency or DEFAULT_THEME.hero.pillStrokeTransparency
            end
            if pill.accent then
                pill.accent.BackgroundColor3 = heroTheme.pillAccentColor or theme.accentColor or DEFAULT_THEME.accentColor
            end
            if pill.label then
                pill.label.Font = heroTheme.pillFont or DEFAULT_THEME.hero.pillFont
                pill.label.TextSize = heroTheme.pillTextSize or DEFAULT_THEME.hero.pillTextSize
                pill.label.TextColor3 = heroTheme.pillTextColor or DEFAULT_THEME.hero.pillTextColor
                if self._heroHighlightTexts and typeof(self._heroHighlightTexts[index]) == "string" then
                    pill.label.Text = self._heroHighlightTexts[index]
                end
            end
        end
    end
    if self._contentLayout then
        self._contentLayout.Padding = UDim.new(0, (theme.responsive and theme.responsive.columnSpacing) or DEFAULT_THEME.responsive.columnSpacing or 32)
    end
    local panelTheme = theme.dashboardPanel or DEFAULT_THEME.dashboardPanel
    if self._dashboardSurface then
        self._dashboardSurface.BackgroundColor3 = panelTheme.backgroundColor or DEFAULT_THEME.dashboardPanel.backgroundColor
        self._dashboardSurface.BackgroundTransparency = panelTheme.backgroundTransparency or DEFAULT_THEME.dashboardPanel.backgroundTransparency
    end
    if self._dashboardStroke then
        self._dashboardStroke.Color = panelTheme.strokeColor or DEFAULT_THEME.dashboardPanel.strokeColor
        self._dashboardStroke.Transparency = panelTheme.strokeTransparency or DEFAULT_THEME.dashboardPanel.strokeTransparency
    end
    if self._dashboardGradient then
        self._dashboardGradient.Color = panelTheme.gradient or DEFAULT_THEME.dashboardPanel.gradient
        self._dashboardGradient.Transparency = panelTheme.gradientTransparency or DEFAULT_THEME.dashboardPanel.gradientTransparency
    end
    if self._actions then
        self:setActions(self._actions)
    end

    self:_refreshBadge()
    self:_updateProgressVisual(self._progress, 0.1)
    self:_applyResponsiveLayout(Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize or nil)

    if self._dashboard and self._dashboard.applyTheme then
        self._dashboard:applyTheme(theme)
    end
end

function LoadingOverlay:isComplete()
    return self._completed
end

function LoadingOverlay:onCompleted(callback)
    assert(typeof(callback) == "function", "LoadingOverlay:onCompleted expects a function")
    if self._completed then
        task.spawn(callback, self)
        return { Disconnect = function() end, disconnect = function() end }
    end
    return self._completedSignal:connect(callback)
end

function LoadingOverlay:complete(options)
    if self._destroyed or self._completed then
        return
    end

    options = options or {}

    self:setProgress(1, { duration = options.progressDuration or 0.25, force = true })

    self._completed = true

    self:_setBadgeStatus("Verification Complete")

    if self._spinnerTween then
        self._spinnerTween:Cancel()
        self._spinnerTween = nil
    end

    local fadeTween = TweenService:Create(self._backdrop, TweenInfo.new(options.fadeDuration or 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        BackgroundTransparency = 1,
    })

    local containerFade = TweenService:Create(self._container, TweenInfo.new(options.fadeDuration or 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        BackgroundTransparency = 1,
    })

    local statusFade
    if self._statusLabel then
        statusFade = TweenService:Create(self._statusLabel, TweenInfo.new(options.fadeDuration or 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            TextTransparency = 1,
        })
    end
    local tipFade
    if self._tipLabel then
        tipFade = TweenService:Create(self._tipLabel, TweenInfo.new(options.fadeDuration or 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            TextTransparency = 1,
        })
    end
    local actionsFade
    if self._actionsRow and #self._actionButtons > 0 then
        actionsFade = TweenService:Create(self._actionsRow, TweenInfo.new(options.fadeDuration or 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            BackgroundTransparency = 1,
        })
        for _, button in ipairs(self._actionButtons) do
            local buttonFade = TweenService:Create(button, TweenInfo.new(options.fadeDuration or 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                BackgroundTransparency = 1,
                TextTransparency = 1,
            })
            buttonFade:Play()
        end
    end
    local spinnerFade
    if self._spinner then
        spinnerFade = TweenService:Create(self._spinner, TweenInfo.new(options.fadeDuration or 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            ImageTransparency = 1,
        })
    end

    fadeTween.Completed:Connect(function()
        if self._completedSignal then
            self._completedSignal:fire(self)
        end
        self:destroy()
    end)

    fadeTween:Play()
    containerFade:Play()
    if statusFade then
        statusFade:Play()
    end
    if tipFade then
        tipFade:Play()
    end
    if actionsFade then
        actionsFade:Play()
    end
    if spinnerFade then
        spinnerFade:Play()
    end
end

function LoadingOverlay:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true

    if self._spinnerTween then
        self._spinnerTween:Cancel()
        self._spinnerTween = nil
    end
    if self._progressTween then
        self._progressTween:Cancel()
        self._progressTween = nil
    end
    if self._progressTweenConnection then
        self._progressTweenConnection:Disconnect()
        self._progressTweenConnection = nil
    end
    if self._statusTween then
        self._statusTween:Cancel()
        self._statusTween = nil
    end
    if self._progressArcTween then
        self._progressArcTween:Cancel()
        self._progressArcTween = nil
    end

    if self._completedSignal then
        self._completedSignal:destroy()
        self._completedSignal = nil
    end

    disconnectConnections(self._actionConnections)
    self._actionConnections = nil
    destroyButtons(self._actionButtons)
    self._actionButtons = nil

    disconnectConnections(self._connections)
    self._connections = nil
    self._viewportConnection = nil

    if self._dashboard and self._dashboard.destroy then
        self._dashboard:destroy()
    end
    self._dashboard = nil

    if self._gui then
        self._gui:Destroy()
        self._gui = nil
    end

    if activeOverlay == self then
        activeOverlay = nil
    end
end

function Module.create(options)
    if activeOverlay then
        activeOverlay:destroy()
    end

    local overlay = LoadingOverlay.new(options)
    activeOverlay = overlay
    return overlay
end

function Module.getActive()
    return activeOverlay
end

return Module
