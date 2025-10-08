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
local GuiService = game:GetService("GuiService")

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
    containerSize = UDim2.new(0, 960, 0, 580),
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
    errorPanel = {
        backgroundColor = Color3.fromRGB(44, 18, 32),
        backgroundTransparency = 0.12,
        strokeColor = Color3.fromRGB(255, 128, 164),
        strokeTransparency = 0.35,
        cornerRadius = UDim.new(0, 12),
        titleFont = Enum.Font.GothamBold,
        titleTextSize = 20,
        titleColor = Color3.fromRGB(255, 214, 228),
        summaryFont = Enum.Font.Gotham,
        summaryTextSize = 16,
        summaryColor = Color3.fromRGB(255, 226, 236),
        entryLabelFont = Enum.Font.GothamSemibold,
        entryLabelTextSize = 14,
        entryLabelColor = Color3.fromRGB(255, 174, 196),
        entryFont = Enum.Font.Code,
        entryTextSize = 14,
        entryTextColor = Color3.fromRGB(255, 236, 240),
        entryBackgroundColor = Color3.fromRGB(32, 16, 26),
        entryBackgroundTransparency = 0.2,
        entryCornerRadius = UDim.new(0, 8),
        sectionPadding = 10,
        sectionSpacing = 8,
        listSpacing = 8,
        tipFont = Enum.Font.Gotham,
        tipTextSize = 14,
        tipTextColor = Color3.fromRGB(255, 220, 232),
        badgeColor = Color3.fromRGB(255, 110, 150),
        badgeTransparency = 0.65,
        actionFont = Enum.Font.GothamSemibold,
        actionTextSize = 14,
        actionPrimaryColor = Color3.fromRGB(255, 128, 168),
        actionPrimaryTextColor = Color3.fromRGB(32, 16, 26),
        actionSecondaryColor = Color3.fromRGB(60, 30, 48),
        actionSecondaryTextColor = Color3.fromRGB(255, 226, 236),
        scrollBarColor = Color3.fromRGB(255, 156, 196),
        scrollBarTransparency = 0.55,
        icon = "rbxassetid://6031071051",
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
        minScale = 0.82,
        maxScale = 1.04,
    },
    backdropGradient = {
        color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(6, 12, 28)),
            ColorSequenceKeypoint.new(0.45, Color3.fromRGB(8, 18, 44)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(6, 12, 28)),
        }),
        transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.1),
            NumberSequenceKeypoint.new(0.5, 0.18),
            NumberSequenceKeypoint.new(1, 0.3),
        }),
        rotation = 65,
    },
    shadow = {
        padding = Vector2.new(120, 120),
        color = Color3.fromRGB(0, 32, 64),
        outerColor = Color3.fromRGB(0, 12, 24),
        transparency = 0.88,
        gradientInnerTransparency = 0.45,
    },
    hologramBadgeColor = Color3.fromRGB(0, 210, 255),
    hologramBadgeTransparency = 0.25,
    progressArcColor = Color3.fromRGB(0, 210, 255),
    progressArcTransparency = 0.4,
    dashboardMountSize = UDim2.new(0.94, 0, 0, 0),
    dashboardMaxWidth = 760,
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

local function createScreenGui(options)
    local gui = Instance.new("ScreenGui")
    gui.Name = options.name or "AutoParryLoadingOverlay"
    gui.DisplayOrder = 10_000
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.IgnoreGuiInset = true
    gui.Parent = options.parent or CoreGui
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
    backdrop.ClipsDescendants = false
    backdrop.Parent = gui

    local backdropGradientConfig = theme.backdropGradient or DEFAULT_THEME.backdropGradient
    local backdropGradient
    if backdropGradientConfig then
        backdropGradient = Instance.new("UIGradient")
        backdropGradient.Name = "BackdropGradient"
        backdropGradient.Color = backdropGradientConfig.color or DEFAULT_THEME.backdropGradient.color
        backdropGradient.Transparency = backdropGradientConfig.transparency or DEFAULT_THEME.backdropGradient.transparency
        backdropGradient.Rotation = backdropGradientConfig.rotation or DEFAULT_THEME.backdropGradient.rotation or 0
        backdropGradient.Parent = backdrop
    end

    local container = Instance.new("Frame")
    container.Name = "Container"
    container.AnchorPoint = Vector2.new(0.5, 0.5)
    container.Position = UDim2.new(0.5, 0, 0.5, 0)
    container.Size = theme.containerSize or DEFAULT_THEME.containerSize
    container.BackgroundColor3 = theme.containerBackgroundColor or Color3.fromRGB(10, 14, 28)
    container.BackgroundTransparency = theme.containerTransparency or DEFAULT_THEME.containerTransparency or 0
    container.BorderSizePixel = 0
    container.ClipsDescendants = false
    container.ZIndex = 2
    container.Parent = backdrop

    local containerScale = Instance.new("UIScale")
    containerScale.Name = "AdaptiveScale"
    containerScale.Scale = 1
    containerScale.Parent = container

    local shadowTheme = theme.shadow or DEFAULT_THEME.shadow
    local containerShadow
    local containerShadowGradient
    if shadowTheme then
        local paddingValue = shadowTheme.padding or DEFAULT_THEME.shadow.padding
        local paddingX, paddingY
        if typeof(paddingValue) == "Vector2" then
            paddingX = paddingValue.X
            paddingY = paddingValue.Y
        elseif typeof(paddingValue) == "number" then
            paddingX = paddingValue
            paddingY = paddingValue
        else
            paddingX = DEFAULT_THEME.shadow.padding.X
            paddingY = DEFAULT_THEME.shadow.padding.Y
        end

        containerShadow = Instance.new("Frame")
        containerShadow.Name = "Shadow"
        containerShadow.AnchorPoint = Vector2.new(0.5, 0.5)
        containerShadow.Position = UDim2.new(0.5, 0, 0.5, 0)
        containerShadow.Size = UDim2.new(
            1,
            paddingX,
            1,
            paddingY
        )
        containerShadow.BackgroundColor3 = shadowTheme.color or DEFAULT_THEME.shadow.color
        containerShadow.BackgroundTransparency = shadowTheme.transparency or DEFAULT_THEME.shadow.transparency
        containerShadow.BorderSizePixel = 0
        containerShadow.ZIndex = 0
        containerShadow.Parent = container

        local shadowCorner = Instance.new("UICorner")
        shadowCorner.CornerRadius = theme.containerCornerRadius or DEFAULT_THEME.containerCornerRadius
        shadowCorner.Parent = containerShadow

        local shadowGradient = Instance.new("UIGradient")
        shadowGradient.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, shadowTheme.color or DEFAULT_THEME.shadow.color),
            ColorSequenceKeypoint.new(1, shadowTheme.outerColor or DEFAULT_THEME.shadow.outerColor or DEFAULT_THEME.shadow.color),
        })
        shadowGradient.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, shadowTheme.gradientInnerTransparency or DEFAULT_THEME.shadow.gradientInnerTransparency or 0.5),
            NumberSequenceKeypoint.new(1, 1),
        })
        shadowGradient.Parent = containerShadow
        containerShadowGradient = shadowGradient
    end

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

    local errorPanel = Instance.new("Frame")
    errorPanel.Name = "ErrorPanel"
    errorPanel.BackgroundTransparency = (theme.errorPanel and theme.errorPanel.backgroundTransparency)
        or DEFAULT_THEME.errorPanel.backgroundTransparency
    errorPanel.BackgroundColor3 = (theme.errorPanel and theme.errorPanel.backgroundColor)
        or DEFAULT_THEME.errorPanel.backgroundColor
    errorPanel.BorderSizePixel = 0
    errorPanel.Visible = false
    errorPanel.AutomaticSize = Enum.AutomaticSize.Y
    errorPanel.Size = UDim2.new(1, 0, 0, 0)
    errorPanel.LayoutOrder = 4
    errorPanel.Parent = infoColumn

    local errorCorner = Instance.new("UICorner")
    errorCorner.CornerRadius = (theme.errorPanel and theme.errorPanel.cornerRadius)
        or DEFAULT_THEME.errorPanel.cornerRadius
    errorCorner.Parent = errorPanel

    local errorStroke = Instance.new("UIStroke")
    errorStroke.Thickness = 1.25
    errorStroke.Color = (theme.errorPanel and theme.errorPanel.strokeColor) or DEFAULT_THEME.errorPanel.strokeColor
    errorStroke.Transparency = (theme.errorPanel and theme.errorPanel.strokeTransparency)
        or DEFAULT_THEME.errorPanel.strokeTransparency
    errorStroke.Parent = errorPanel

    local errorPaddingValue = (theme.errorPanel and theme.errorPanel.sectionPadding)
        or DEFAULT_THEME.errorPanel.sectionPadding
        or 10
    local errorPadding = Instance.new("UIPadding")
    errorPadding.PaddingTop = UDim.new(0, errorPaddingValue)
    errorPadding.PaddingBottom = UDim.new(0, errorPaddingValue)
    errorPadding.PaddingLeft = UDim.new(0, errorPaddingValue)
    errorPadding.PaddingRight = UDim.new(0, errorPaddingValue)
    errorPadding.Parent = errorPanel

    local errorLayout = Instance.new("UIListLayout")
    errorLayout.FillDirection = Enum.FillDirection.Vertical
    errorLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    errorLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    errorLayout.SortOrder = Enum.SortOrder.LayoutOrder
    errorLayout.Padding = UDim.new(0, (theme.errorPanel and theme.errorPanel.sectionSpacing)
        or DEFAULT_THEME.errorPanel.sectionSpacing
        or 8)
    errorLayout.Parent = errorPanel

    local errorTitle = Instance.new("TextLabel")
    errorTitle.Name = "Title"
    errorTitle.BackgroundTransparency = 1
    errorTitle.AutomaticSize = Enum.AutomaticSize.Y
    errorTitle.Size = UDim2.new(1, 0, 0, 0)
    errorTitle.TextWrapped = true
    errorTitle.TextXAlignment = Enum.TextXAlignment.Left
    errorTitle.TextYAlignment = Enum.TextYAlignment.Top
    errorTitle.Font = (theme.errorPanel and theme.errorPanel.titleFont) or DEFAULT_THEME.errorPanel.titleFont
    errorTitle.TextSize = (theme.errorPanel and theme.errorPanel.titleTextSize) or DEFAULT_THEME.errorPanel.titleTextSize
    errorTitle.TextColor3 = (theme.errorPanel and theme.errorPanel.titleColor) or DEFAULT_THEME.errorPanel.titleColor
    errorTitle.Text = ""
    errorTitle.Visible = false
    errorTitle.LayoutOrder = 1
    errorTitle.Parent = errorPanel

    local errorSummary = Instance.new("TextLabel")
    errorSummary.Name = "Summary"
    errorSummary.BackgroundTransparency = 1
    errorSummary.AutomaticSize = Enum.AutomaticSize.Y
    errorSummary.Size = UDim2.new(1, 0, 0, 0)
    errorSummary.TextWrapped = true
    errorSummary.TextXAlignment = Enum.TextXAlignment.Left
    errorSummary.TextYAlignment = Enum.TextYAlignment.Top
    errorSummary.Font = (theme.errorPanel and theme.errorPanel.summaryFont) or DEFAULT_THEME.errorPanel.summaryFont
    errorSummary.TextSize = (theme.errorPanel and theme.errorPanel.summaryTextSize) or DEFAULT_THEME.errorPanel.summaryTextSize
    errorSummary.TextColor3 = (theme.errorPanel and theme.errorPanel.summaryColor) or DEFAULT_THEME.errorPanel.summaryColor
    errorSummary.Text = ""
    errorSummary.Visible = false
    errorSummary.LayoutOrder = 2
    errorSummary.Parent = errorPanel

    local errorLogScroll = Instance.new("ScrollingFrame")
    errorLogScroll.Name = "Details"
    errorLogScroll.BackgroundTransparency = 1
    errorLogScroll.BorderSizePixel = 0
    errorLogScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    errorLogScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    errorLogScroll.Size = UDim2.new(1, 0, 0, 140)
    errorLogScroll.Visible = false
    errorLogScroll.ScrollingDirection = Enum.ScrollingDirection.Y
    errorLogScroll.ScrollBarThickness = 6
    errorLogScroll.VerticalScrollBarInset = Enum.ScrollBarInset.Always
    errorLogScroll.ScrollBarImageColor3 = (theme.errorPanel and theme.errorPanel.scrollBarColor)
        or DEFAULT_THEME.errorPanel.scrollBarColor
    errorLogScroll.ScrollBarImageTransparency = (theme.errorPanel and theme.errorPanel.scrollBarTransparency)
        or DEFAULT_THEME.errorPanel.scrollBarTransparency
    errorLogScroll.LayoutOrder = 3
    errorLogScroll.Parent = errorPanel

    local errorLogPadding = Instance.new("UIPadding")
    errorLogPadding.PaddingLeft = UDim.new(0, 4)
    errorLogPadding.PaddingRight = UDim.new(0, 4)
    errorLogPadding.PaddingTop = UDim.new(0, 4)
    errorLogPadding.PaddingBottom = UDim.new(0, 4)
    errorLogPadding.Parent = errorLogScroll

    local errorLogList = Instance.new("Frame")
    errorLogList.Name = "List"
    errorLogList.BackgroundTransparency = 1
    errorLogList.AutomaticSize = Enum.AutomaticSize.Y
    errorLogList.Size = UDim2.new(1, -4, 0, 0)
    errorLogList.Parent = errorLogScroll

    local errorLogLayout = Instance.new("UIListLayout")
    errorLogLayout.FillDirection = Enum.FillDirection.Vertical
    errorLogLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    errorLogLayout.SortOrder = Enum.SortOrder.LayoutOrder
    errorLogLayout.Padding = UDim.new(0, (theme.errorPanel and theme.errorPanel.listSpacing)
        or DEFAULT_THEME.errorPanel.listSpacing
        or 8)
    errorLogLayout.Parent = errorLogList

    local errorActions = Instance.new("Frame")
    errorActions.Name = "ErrorActions"
    errorActions.BackgroundTransparency = 1
    errorActions.AutomaticSize = Enum.AutomaticSize.Y
    errorActions.Size = UDim2.new(1, 0, 0, 0)
    errorActions.Visible = false
    errorActions.LayoutOrder = 4
    errorActions.Parent = errorPanel

    local errorActionsLayout = Instance.new("UIListLayout")
    errorActionsLayout.FillDirection = Enum.FillDirection.Horizontal
    errorActionsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
    errorActionsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    errorActionsLayout.SortOrder = Enum.SortOrder.LayoutOrder
    errorActionsLayout.Padding = UDim.new(0, (theme.errorPanel and theme.errorPanel.sectionSpacing)
        or DEFAULT_THEME.errorPanel.sectionSpacing
        or 8)
    errorActionsLayout.Parent = errorActions

    local copyButton = Instance.new("TextButton")
    copyButton.Name = "CopyButton"
    copyButton.Text = "Copy error"
    copyButton.Font = (theme.errorPanel and theme.errorPanel.actionFont) or DEFAULT_THEME.errorPanel.actionFont
    copyButton.TextSize = (theme.errorPanel and theme.errorPanel.actionTextSize) or DEFAULT_THEME.errorPanel.actionTextSize
    copyButton.TextColor3 = (theme.errorPanel and theme.errorPanel.actionPrimaryTextColor)
        or DEFAULT_THEME.errorPanel.actionPrimaryTextColor
    copyButton.BackgroundColor3 = (theme.errorPanel and theme.errorPanel.actionPrimaryColor)
        or DEFAULT_THEME.errorPanel.actionPrimaryColor
    copyButton.AutoButtonColor = true
    copyButton.BackgroundTransparency = 0
    copyButton.Visible = false
    copyButton.Size = UDim2.new(0, 156, 0, 34)
    copyButton.LayoutOrder = 1
    copyButton.Parent = errorActions

    local copyCorner = Instance.new("UICorner")
    copyCorner.CornerRadius = (theme.errorPanel and theme.errorPanel.entryCornerRadius)
        or DEFAULT_THEME.errorPanel.entryCornerRadius
        or UDim.new(0, 8)
    copyCorner.Parent = copyButton

    local docsButton = Instance.new("TextButton")
    docsButton.Name = "DocsButton"
    docsButton.Text = "Open docs"
    docsButton.Font = (theme.errorPanel and theme.errorPanel.actionFont) or DEFAULT_THEME.errorPanel.actionFont
    docsButton.TextSize = (theme.errorPanel and theme.errorPanel.actionTextSize) or DEFAULT_THEME.errorPanel.actionTextSize
    docsButton.TextColor3 = (theme.errorPanel and theme.errorPanel.actionSecondaryTextColor)
        or DEFAULT_THEME.errorPanel.actionSecondaryTextColor
    docsButton.BackgroundColor3 = (theme.errorPanel and theme.errorPanel.actionSecondaryColor)
        or DEFAULT_THEME.errorPanel.actionSecondaryColor
    docsButton.AutoButtonColor = true
    docsButton.BackgroundTransparency = 0
    docsButton.Visible = false
    docsButton.Size = UDim2.new(0, 156, 0, 34)
    docsButton.LayoutOrder = 2
    docsButton.Parent = errorActions

    local docsCorner = Instance.new("UICorner")
    docsCorner.CornerRadius = (theme.errorPanel and theme.errorPanel.entryCornerRadius)
        or DEFAULT_THEME.errorPanel.entryCornerRadius
        or UDim.new(0, 8)
    docsCorner.Parent = docsButton

    local tipLabel = createTipLabel(infoColumn, theme)
    tipLabel.LayoutOrder = 5

    local actionsRow, actionsLayout = createActionsRow(infoColumn, theme)
    actionsRow.AnchorPoint = Vector2.new(0.5, 0)
    actionsRow.Position = UDim2.new(0.5, 0, 0, 0)
    actionsRow.LayoutOrder = 6

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
    dashboardSurface.ClipsDescendants = true
    dashboardSurface.ZIndex = 3
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
    dashboardMount.AutomaticSize = Enum.AutomaticSize.Y
    dashboardMount.Size = theme.dashboardMountSize or DEFAULT_THEME.dashboardMountSize
    dashboardMount.Position = UDim2.new(0.5, 0, 0.5, 0)
    dashboardMount.AnchorPoint = Vector2.new(0.5, 0.5)
    dashboardMount.ZIndex = 4
    dashboardMount.LayoutOrder = 1
    dashboardMount.Parent = dashboardSurface

    local dashboardMountPadding = Instance.new("UIPadding")
    dashboardMountPadding.PaddingTop = UDim.new(0, 12)
    dashboardMountPadding.PaddingBottom = UDim.new(0, 12)
    dashboardMountPadding.PaddingLeft = UDim.new(0, 18)
    dashboardMountPadding.PaddingRight = UDim.new(0, 18)
    dashboardMountPadding.Parent = dashboardMount

    local dashboardLayout = Instance.new("UIListLayout")
    dashboardLayout.FillDirection = Enum.FillDirection.Vertical
    dashboardLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    dashboardLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    dashboardLayout.SortOrder = Enum.SortOrder.LayoutOrder
    dashboardLayout.Padding = UDim.new(0, 18)
    dashboardLayout.Parent = dashboardMount

    local dashboardMountConstraint = Instance.new("UISizeConstraint")
    local dashboardMinWidth = 360
    local configuredDashboardMaxWidth = theme.dashboardMaxWidth or DEFAULT_THEME.dashboardMaxWidth or 760
    -- Roblox errors when MaxSize < MinSize; clamp to keep constraints sane even
    -- if a custom theme requests an unusually small dashboard width.
    local dashboardMaxWidth = math.max(configuredDashboardMaxWidth, dashboardMinWidth)
    dashboardMountConstraint.MaxSize = Vector2.new(dashboardMaxWidth, math.huge)
    dashboardMountConstraint.MinSize = Vector2.new(dashboardMinWidth, 0)
    dashboardMountConstraint.Parent = dashboardMount

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
        _backdropGradient = backdropGradient,
        _container = container,
        _containerScale = containerScale,
        _containerShadow = containerShadow,
        _containerShadowGradient = containerShadowGradient,
        _spinner = spinner,
        _progressBar = progressBar,
        _progressFill = progressFill,
        _statusLabel = statusLabel,
        _tipLabel = tipLabel,
        _errorPanel = errorPanel,
        _errorPanelCorner = errorCorner,
        _errorPanelStroke = errorStroke,
        _errorTitle = errorTitle,
        _errorSummary = errorSummary,
        _errorLogScroll = errorLogScroll,
        _errorLogList = errorLogList,
        _errorLogLayout = errorLogLayout,
        _errorLogPadding = errorLogPadding,
        _errorActionsFrame = errorActions,
        _errorActionsLayout = errorActionsLayout,
        _errorCopyButton = copyButton,
        _errorDocsButton = docsButton,
        _errorCopyCorner = copyCorner,
        _errorDocsCorner = docsCorner,
        _errorEntryInstances = {},
        _errorActionConnections = {},
        _currentErrorDetails = nil,
        _errorCopyText = nil,
        _errorDocsLink = nil,
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
        _dashboardLayout = dashboardLayout,
        _containerGlow = glow,
        _containerGradient = containerGradient,
        _containerPadding = containerPadding,
        _containerLayout = containerLayout,
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
        _defaultContainerHeight = (container.Size.Y.Scale == 0 and container.Size.Y.Offset) or nil,
        _defaultContentSize = contentFrame.Size,
        _defaultHeroHeight = (heroFrame.Size.Y.Scale == 0 and heroFrame.Size.Y.Offset) or nil,
        _defaultInfoSize = infoColumn.Size,
        _defaultDashboardSize = dashboardColumn.Size,
        _layoutState = nil,
    }, LoadingOverlay)

    local function updateErrorCanvas()
        self:_updateErrorCanvasSize()
    end

    if self._errorLogLayout then
        local errorLayoutConnection = self._errorLogLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateErrorCanvas)
        table.insert(self._connections, errorLayoutConnection)
        updateErrorCanvas()
    end

    self:_restyleErrorButtons()

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
    local viewportHeight = viewportSize and viewportSize.Y or ((theme.containerSize and theme.containerSize.Y.Offset) or 360) + 260

    local minWidth = responsive.minWidth or 420
    local maxWidth = responsive.maxWidth or math.max(minWidth, math.floor(viewportWidth * 0.92))
    local columnSpacing = responsive.columnSpacing or 32
    local mediumWidth = responsive.mediumWidth or 600
    local largeWidth = responsive.largeWidth or 840

    local contentLayout = self._contentLayout
    local contentFrame = self._contentFrame
    local infoColumn = self._infoColumn
    local dashboardColumn = self._dashboardColumn
    local heroFrame = self._heroFrame

    if not infoColumn or not dashboardColumn or not contentFrame or not contentLayout then
        return
    end

    local containerPadding = self._containerPadding
    local paddingTop = (containerPadding and containerPadding.PaddingTop.Offset) or 0
    local paddingBottom = (containerPadding and containerPadding.PaddingBottom.Offset) or 0
    local paddingLeft = (containerPadding and containerPadding.PaddingLeft.Offset) or 0
    local paddingRight = (containerPadding and containerPadding.PaddingRight.Offset) or 0
    local containerLayout = self._containerLayout
    local sectionGap = (containerLayout and containerLayout.Padding.Offset) or 0

    local defaultHeight = self._defaultContainerHeight
        or (theme.containerSize and theme.containerSize.Y.Offset)
        or (DEFAULT_THEME.containerSize and DEFAULT_THEME.containerSize.Y.Offset)
        or 360
    local defaultHeroHeight = self._defaultHeroHeight or 160

    local horizontalMargin = math.max(48, math.floor(viewportWidth * 0.08))
    local usableWidth = viewportWidth - horizontalMargin
    local desiredWidth = math.floor(math.clamp(usableWidth, minWidth, maxWidth))
    if viewportWidth < minWidth then
        desiredWidth = math.max(320, viewportWidth - 24)
    end

    local verticalMargin = math.max(96, math.floor(viewportHeight * 0.14))
    local heightCap = viewportHeight - verticalMargin
    heightCap = math.max(defaultHeight, heightCap)

    local aspectRatio = viewportHeight > 0 and viewportWidth / viewportHeight or 1.6

    local mode
    if desiredWidth <= mediumWidth or aspectRatio < 1.1 then
        mode = "stacked"
    elseif desiredWidth <= largeWidth or aspectRatio < 1.35 then
        mode = "hybrid"
    else
        mode = "wide"
    end

    local heroHeight
    if mode == "stacked" then
        heroHeight = math.clamp(math.floor(desiredWidth * 0.26), 132, defaultHeroHeight + 48)
    elseif mode == "hybrid" then
        heroHeight = math.clamp(math.floor(desiredWidth * 0.22), 126, defaultHeroHeight + 24)
    else
        heroHeight = math.clamp(math.floor(desiredWidth * 0.2), 120, defaultHeroHeight)
    end

    heroHeight = math.max(120, heroHeight)

    local availableContentHeight = heightCap - paddingTop - paddingBottom - sectionGap - heroHeight
    availableContentHeight = math.max(220, availableContentHeight)

    local contentHeight
    local infoHeight
    local dashboardHeight
    local fillDirection
    local horizontalAlignment
    local verticalAlignment
    local padding
    local infoSize
    local dashboardSize

    local contentWidthPixels = math.max(0, desiredWidth - paddingLeft - paddingRight)

    if mode == "stacked" then
        local stackedGap = math.max(20, math.floor(columnSpacing * 0.75))
        local infoMin = 220
        local dashMin = 260

        infoHeight = math.max(infoMin, math.floor(availableContentHeight * 0.44))
        dashboardHeight = math.max(dashMin, availableContentHeight - infoHeight - stackedGap)

        if dashboardHeight < dashMin then
            local deficit = dashMin - dashboardHeight
            dashboardHeight = dashMin
            infoHeight = math.max(infoMin, infoHeight - deficit)
        end

        contentHeight = infoHeight + dashboardHeight + stackedGap

        local containerHeight = paddingTop + heroHeight + sectionGap + contentHeight + paddingBottom
        if containerHeight > heightCap then
            local overflow = containerHeight - heightCap
            local dashReduction = math.min(overflow * 0.6, math.max(0, dashboardHeight - dashMin))
            dashboardHeight -= dashReduction
            overflow -= dashReduction

            local infoReduction = math.min(overflow, math.max(0, infoHeight - infoMin))
            infoHeight -= infoReduction
            overflow -= infoReduction

            if overflow > 0 then
                heroHeight = math.max(120, heroHeight - overflow)
            end

            contentHeight = infoHeight + dashboardHeight + stackedGap
        end

        fillDirection = Enum.FillDirection.Vertical
        horizontalAlignment = Enum.HorizontalAlignment.Center
        verticalAlignment = Enum.VerticalAlignment.Top
        padding = stackedGap
        infoSize = UDim2.new(1, -math.max(24, math.floor(columnSpacing * 0.8)), 0, math.floor(infoHeight + 0.5))
        dashboardSize = UDim2.new(1, -math.max(24, math.floor(columnSpacing * 0.8)), 0, math.floor(dashboardHeight + 0.5))
    elseif mode == "hybrid" then
        local hybridPadding = math.max(18, math.floor(columnSpacing * 0.65))
        local targetColumnHeight = math.max(240, math.min(availableContentHeight, math.floor(availableContentHeight)))

        contentHeight = targetColumnHeight
        infoHeight = targetColumnHeight
        dashboardHeight = targetColumnHeight

        fillDirection = Enum.FillDirection.Horizontal
        horizontalAlignment = Enum.HorizontalAlignment.Center
        verticalAlignment = Enum.VerticalAlignment.Top
        padding = hybridPadding
        infoSize = UDim2.new(0.5, -hybridPadding, 0, math.floor(infoHeight + 0.5))
        dashboardSize = UDim2.new(0.5, -hybridPadding, 0, math.floor(dashboardHeight + 0.5))
    else
        local wideHeight = math.max(280, math.min(availableContentHeight, math.floor(availableContentHeight)))

        contentHeight = wideHeight
        infoHeight = wideHeight
        dashboardHeight = wideHeight

        fillDirection = Enum.FillDirection.Horizontal
        horizontalAlignment = Enum.HorizontalAlignment.Center
        verticalAlignment = Enum.VerticalAlignment.Top
        padding = columnSpacing
        infoSize = UDim2.new(0.45, -columnSpacing, 0, math.floor(infoHeight + 0.5))
        dashboardSize = UDim2.new(0.55, 0, 0, math.floor(dashboardHeight + 0.5))
    end

    local containerHeight = paddingTop + heroHeight + sectionGap + contentHeight + paddingBottom
    containerHeight = math.max(defaultHeight, math.min(containerHeight, heightCap))

    local target = {
        mode = mode,
        breakpoint = mode,
        width = math.floor(desiredWidth + 0.5),
        height = math.floor(containerHeight + 0.5),
        heroHeight = math.floor(heroHeight + 0.5),
        contentHeight = math.floor(contentHeight + 0.5),
        infoHeight = math.floor(infoHeight + 0.5),
        dashboardHeight = math.floor(dashboardHeight + 0.5),
        fillDirection = fillDirection,
        horizontalAlignment = horizontalAlignment,
        verticalAlignment = verticalAlignment,
        padding = padding,
        contentSize = UDim2.new(1, 0, 0, math.floor(contentHeight + 0.5)),
        infoSize = infoSize,
        dashboardSize = dashboardSize,
        viewportWidth = math.floor(viewportWidth + 0.5),
        viewportHeight = math.floor(viewportHeight + 0.5),
    }

    if contentLayout then
        contentLayout.FillDirection = target.fillDirection
        contentLayout.HorizontalAlignment = target.horizontalAlignment
        contentLayout.VerticalAlignment = target.verticalAlignment
        contentLayout.Padding = UDim.new(0, target.padding)
    end

    if contentFrame then
        contentFrame.Size = target.contentSize
    end

    if infoColumn then
        infoColumn.Size = target.infoSize
    end

    if dashboardColumn then
        dashboardColumn.Size = target.dashboardSize
    end

    if heroFrame then
        heroFrame.Size = UDim2.new(1, 0, 0, target.heroHeight)
    end

    container.Size = UDim2.new(0, target.width, 0, target.height)

    local dashboardWidth
    if target.fillDirection == Enum.FillDirection.Vertical then
        dashboardWidth = math.max(0, contentWidthPixels + (target.dashboardSize and target.dashboardSize.X.Offset or 0))
    else
        local scale = target.dashboardSize and target.dashboardSize.X.Scale or 0
        local offset = target.dashboardSize and target.dashboardSize.X.Offset or 0
        dashboardWidth = math.max(0, math.floor(contentWidthPixels * scale + offset + 0.5))
    end

    target.contentWidth = contentWidthPixels
    target.dashboardWidth = dashboardWidth

    local scale = 1
    if viewportWidth and viewportWidth > 0 then
        local widthAllowance = viewportWidth - horizontalMargin * 0.5
        if widthAllowance > 0 then
            scale = math.min(scale, widthAllowance / target.width)
        end
    end
    if viewportHeight and viewportHeight > 0 then
        local heightAllowance = viewportHeight - verticalMargin * 0.5
        if heightAllowance > 0 then
            scale = math.min(scale, heightAllowance / target.height)
        end
    end

    local minScale = responsive.minScale or DEFAULT_THEME.responsive.minScale or 0.82
    local maxScale = responsive.maxScale or DEFAULT_THEME.responsive.maxScale or 1
    scale = math.clamp(scale, minScale, maxScale)

    if self._containerScale then
        self._containerScale.Scale = scale
    end

    local scaledWidth = math.floor(target.width * scale + 0.5)
    local scaledHeight = math.floor(target.height * scale + 0.5)
    local scaledDashboardWidth = math.floor(dashboardWidth * scale + 0.5)
    local scaledDashboardHeight = math.floor(target.dashboardHeight * scale + 0.5)
    local scaledContentWidth = math.floor(contentWidthPixels * scale + 0.5)

    local layoutBounds = {
        mode = target.mode,
        breakpoint = target.mode,
        containerWidth = scaledWidth,
        containerHeight = scaledHeight,
        width = scaledWidth,
        height = scaledHeight,
        dashboardWidth = scaledDashboardWidth,
        dashboardHeight = scaledDashboardHeight,
        contentWidth = scaledContentWidth,
        heroHeight = math.floor(target.heroHeight * scale + 0.5),
        infoHeight = math.floor(target.infoHeight * scale + 0.5),
        contentHeight = math.floor(target.contentHeight * scale + 0.5),
        viewportWidth = viewportWidth and math.floor(viewportWidth + 0.5) or scaledWidth,
        viewportHeight = viewportSize and math.floor(viewportHeight + 0.5) or scaledHeight,
        scale = scale,
        raw = target,
        rawWidth = target.width,
        rawHeight = target.height,
    }

    if self._dashboard and self._dashboard.updateLayout then
        self._dashboard:updateLayout(layoutBounds)
    end

    self._layoutState = layoutBounds
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
        if dashboard.updateLayout and self._layoutState then
            dashboard:updateLayout(self._layoutState)
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

function LoadingOverlay:_updateErrorCanvasSize()
    if not self._errorLogLayout or not self._errorLogScroll then
        return
    end

    local paddingBottom = 0
    if self._errorLogPadding and self._errorLogPadding.PaddingBottom then
        paddingBottom = self._errorLogPadding.PaddingBottom.Offset
    end

    self._errorLogScroll.CanvasSize = UDim2.new(0, 0, 0, self._errorLogLayout.AbsoluteContentSize.Y + paddingBottom)
end

function LoadingOverlay:_restyleErrorButtons()
    local copyButton = self._errorCopyButton
    local docsButton = self._errorDocsButton
    if not copyButton and not docsButton then
        return
    end

    local theme = self._theme or DEFAULT_THEME
    local errorTheme = theme.errorPanel or DEFAULT_THEME.errorPanel
    local cornerRadius = errorTheme.entryCornerRadius or DEFAULT_THEME.errorPanel.entryCornerRadius or UDim.new(0, 8)

    local function applyStyle(button, corner, variant)
        if not button then
            return
        end
        button.Font = errorTheme.actionFont or DEFAULT_THEME.errorPanel.actionFont
        button.TextSize = errorTheme.actionTextSize or DEFAULT_THEME.errorPanel.actionTextSize
        if variant == "secondary" then
            button.BackgroundColor3 = errorTheme.actionSecondaryColor or DEFAULT_THEME.errorPanel.actionSecondaryColor
            button.TextColor3 = errorTheme.actionSecondaryTextColor or DEFAULT_THEME.errorPanel.actionSecondaryTextColor
        else
            button.BackgroundColor3 = errorTheme.actionPrimaryColor or DEFAULT_THEME.errorPanel.actionPrimaryColor
            button.TextColor3 = errorTheme.actionPrimaryTextColor or DEFAULT_THEME.errorPanel.actionPrimaryTextColor
        end
        if corner then
            corner.CornerRadius = cornerRadius
        end
    end

    applyStyle(copyButton, self._errorCopyCorner, "primary")
    applyStyle(docsButton, self._errorDocsCorner, "secondary")

    if self._errorActionsLayout then
        self._errorActionsLayout.Padding = UDim.new(0, errorTheme.sectionSpacing or DEFAULT_THEME.errorPanel.sectionSpacing or 8)
    end
end

function LoadingOverlay:_clearErrorDetails()
    disconnectConnections(self._errorActionConnections)
    self._errorActionConnections = {}

    if self._errorEntryInstances then
        for _, item in ipairs(self._errorEntryInstances) do
            if item and item.Destroy then
                item:Destroy()
            end
        end
    end
    self._errorEntryInstances = {}

    if self._errorLogList then
        for _, child in ipairs(self._errorLogList:GetChildren()) do
            if child:IsA("GuiObject") then
                child:Destroy()
            end
        end
    end

    if self._errorTitle then
        self._errorTitle.Text = ""
        self._errorTitle.Visible = false
    end

    if self._errorSummary then
        self._errorSummary.Text = ""
        self._errorSummary.Visible = false
    end

    if self._errorLogScroll then
        self._errorLogScroll.Visible = false
    end

    if self._errorActionsFrame then
        self._errorActionsFrame.Visible = false
    end

    if self._errorPanel then
        self._errorPanel.Visible = false
    end

    self._errorCopyText = nil
    self._errorDocsLink = nil

    self:_updateErrorCanvasSize()
end

function LoadingOverlay:_updateErrorActions(detail)
    if not self._errorActionsFrame then
        return
    end

    disconnectConnections(self._errorActionConnections)
    self._errorActionConnections = {}

    local copyButton = self._errorCopyButton
    local docsButton = self._errorDocsButton

    local hasCopy = detail and typeof(detail.copyText) == "string" and detail.copyText ~= ""
    local copyAllowed = hasCopy and typeof(setclipboard) == "function"
    self._errorCopyText = hasCopy and detail.copyText or nil

    if copyButton then
        copyButton.Visible = hasCopy
        copyButton.Active = copyAllowed
        copyButton.AutoButtonColor = copyAllowed
        copyButton.TextTransparency = (hasCopy and not copyAllowed) and 0.35 or 0
        local copyLabel = detail and detail.copyLabel or "Copy error"
        if not copyLabel or copyLabel == "" then
            copyLabel = "Copy error"
        end
        copyButton.Text = copyLabel

        if hasCopy and copyAllowed then
            local connection = copyButton.MouseButton1Click:Connect(function()
                if self._destroyed or not self._errorCopyText then
                    return
                end

                local ok, err = pcall(setclipboard, self._errorCopyText)
                if not ok then
                    warn("AutoParry: failed to copy error payload", err)
                    return
                end

                local successLabel = (detail and detail.copySuccessLabel) or "Copied!"
                copyButton.Text = successLabel

                task.delay(2.5, function()
                    if self._destroyed or self._errorCopyButton ~= copyButton or not copyButton.Visible then
                        return
                    end
                    local resetLabel = (detail and detail.copyLabel) or "Copy error"
                    if not resetLabel or resetLabel == "" then
                        resetLabel = "Copy error"
                    end
                    copyButton.Text = resetLabel
                end)
            end)
            table.insert(self._errorActionConnections, connection)
        end
    end

    local hasDocs = detail and typeof(detail.docsLink) == "string" and detail.docsLink ~= ""
    self._errorDocsLink = hasDocs and detail.docsLink or nil

    if docsButton then
        docsButton.Visible = hasDocs
        docsButton.Active = hasDocs
        docsButton.AutoButtonColor = hasDocs
        docsButton.TextTransparency = hasDocs and 0 or 0.35
        local docsLabel = detail and detail.docsLabel or "Open docs"
        if not docsLabel or docsLabel == "" then
            docsLabel = "Open docs"
        end
        docsButton.Text = docsLabel

        if hasDocs then
            local connection = docsButton.MouseButton1Click:Connect(function()
                if self._destroyed or not self._errorDocsLink then
                    return
                end

                local ok, err = pcall(function()
                    if GuiService and GuiService.OpenBrowserWindow then
                        GuiService:OpenBrowserWindow(self._errorDocsLink)
                    else
                        warn("AutoParry: GuiService.OpenBrowserWindow unavailable")
                    end
                end)
                if not ok then
                    warn("AutoParry: failed to open documentation link", err)
                end
            end)
            table.insert(self._errorActionConnections, connection)
        end
    end

    local hasActions = false
    if copyButton and copyButton.Visible then
        hasActions = true
    end
    if docsButton and docsButton.Visible then
        hasActions = true
    end

    self._errorActionsFrame.Visible = hasActions

    self:_restyleErrorButtons()
end

local function ensureArray(value)
    if typeof(value) ~= "table" then
        return {}
    end
    local result = {}
    for index, item in ipairs(value) do
        result[index] = item
    end
    return result
end

local function coerceEntry(value)
    if value == nil then
        return nil
    end
    if typeof(value) ~= "table" then
        return { value = value }
    end
    return value
end

function LoadingOverlay:_renderErrorDetails(detail)
    if not self._errorPanel then
        return
    end

    local visible = detail.visible ~= false
    if detail.kind and detail.kind ~= "error" and detail.force ~= true then
        visible = false
    end

    if not visible then
        self:_clearErrorDetails()
        return
    end

    self._errorPanel.Visible = true

    if self._errorTitle then
        local title = detail.title or detail.name or detail.message or "AutoParry error"
        self._errorTitle.Text = title
        self._errorTitle.Visible = title ~= nil and title ~= ""
    end

    if self._errorSummary then
        local summary = detail.summary or detail.description or detail.message or ""
        self._errorSummary.Text = summary
        self._errorSummary.Visible = summary ~= nil and summary ~= ""
    end

    if not self._errorLogList or not self._errorLogScroll then
        self:_updateErrorActions(detail)
        return
    end

    for _, child in ipairs(self._errorLogList:GetChildren()) do
        if child:IsA("GuiObject") then
            child:Destroy()
        end
    end

    self._errorEntryInstances = {}

    local aggregated = {}

    for _, entry in ipairs(ensureArray(detail.entries)) do
        table.insert(aggregated, coerceEntry(entry))
    end

    if typeof(detail.logs) == "table" then
        for _, entry in ipairs(detail.logs) do
            if typeof(entry) == "table" then
                table.insert(aggregated, coerceEntry(entry))
            elseif entry ~= nil then
                table.insert(aggregated, { label = "Log", value = entry })
            end
        end
    elseif detail.log ~= nil then
        if typeof(detail.log) == "table" then
            table.insert(aggregated, coerceEntry(detail.log))
        else
            table.insert(aggregated, { label = "Log", value = detail.log })
        end
    end

    if typeof(detail.tips) == "table" then
        for _, tip in ipairs(detail.tips) do
            table.insert(aggregated, { label = "Tip", value = tip, kind = "tip" })
        end
    elseif detail.tip ~= nil then
        table.insert(aggregated, { label = "Tip", value = detail.tip, kind = "tip" })
    end

    if detail.stack or detail.stackTrace then
        table.insert(aggregated, { label = "Stack trace", value = detail.stackTrace or detail.stack, kind = "stack" })
    end

    if detail.reason and detail.includeReason ~= false then
        table.insert(aggregated, { label = "Reason", value = detail.reason })
    end

    if detail.payloadText then
        table.insert(aggregated, { label = "Payload", value = detail.payloadText, kind = "stack" })
    end

    local theme = self._theme or DEFAULT_THEME
    local errorTheme = theme.errorPanel or DEFAULT_THEME.errorPanel

    local visibleEntries = 0

    for index, entry in ipairs(aggregated) do
        entry = coerceEntry(entry)
        if entry then
            local value = entry.value or entry.text or entry.message or entry[1]
            if value ~= nil then
                if typeof(value) ~= "string" then
                    value = tostring(value)
                end
                value = value:gsub("%s+$", "")
                if value ~= "" then
                    local frame = Instance.new("Frame")
                    frame.Name = string.format("Entry%d", index)
                    frame.BackgroundTransparency = errorTheme.entryBackgroundTransparency or DEFAULT_THEME.errorPanel.entryBackgroundTransparency
                    frame.BackgroundColor3 = errorTheme.entryBackgroundColor or DEFAULT_THEME.errorPanel.entryBackgroundColor
                    frame.BorderSizePixel = 0
                    frame.AutomaticSize = Enum.AutomaticSize.Y
                    frame.Size = UDim2.new(1, 0, 0, 0)
                    frame.LayoutOrder = index
                    frame.Parent = self._errorLogList

                    local corner = Instance.new("UICorner")
                    corner.CornerRadius = errorTheme.entryCornerRadius or DEFAULT_THEME.errorPanel.entryCornerRadius or UDim.new(0, 8)
                    corner.Parent = frame

                    local padding = Instance.new("UIPadding")
                    padding.PaddingTop = UDim.new(0, 8)
                    padding.PaddingBottom = UDim.new(0, 8)
                    padding.PaddingLeft = UDim.new(0, 10)
                    padding.PaddingRight = UDim.new(0, 10)
                    padding.Parent = frame

                    local layout = Instance.new("UIListLayout")
                    layout.FillDirection = Enum.FillDirection.Vertical
                    layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
                    layout.SortOrder = Enum.SortOrder.LayoutOrder
                    layout.Padding = UDim.new(0, entry.label and entry.label ~= "" and 4 or 0)
                    layout.Parent = frame

                    if entry.label and entry.label ~= "" then
                        local labelText = Instance.new("TextLabel")
                        labelText.Name = "Label"
                        labelText.BackgroundTransparency = 1
                        labelText.AutomaticSize = Enum.AutomaticSize.Y
                        labelText.Size = UDim2.new(1, 0, 0, 0)
                        labelText.Font = errorTheme.entryLabelFont or DEFAULT_THEME.errorPanel.entryLabelFont
                        labelText.TextSize = errorTheme.entryLabelTextSize or DEFAULT_THEME.errorPanel.entryLabelTextSize
                        labelText.TextColor3 = errorTheme.entryLabelColor or DEFAULT_THEME.errorPanel.entryLabelColor
                        labelText.TextXAlignment = Enum.TextXAlignment.Left
                        labelText.TextYAlignment = Enum.TextYAlignment.Top
                        labelText.TextWrapped = true
                        labelText.Text = string.upper(entry.label)
                        labelText.LayoutOrder = 1
                        labelText.Parent = frame
                    end

                    local body = Instance.new("TextLabel")
                    body.Name = "Body"
                    body.BackgroundTransparency = 1
                    body.AutomaticSize = Enum.AutomaticSize.Y
                    body.Size = UDim2.new(1, 0, 0, 0)
                    body.Font = (entry.kind == "stack" and Enum.Font.Code)
                        or errorTheme.entryFont
                        or DEFAULT_THEME.errorPanel.entryFont
                    body.TextSize = errorTheme.entryTextSize or DEFAULT_THEME.errorPanel.entryTextSize
                    body.TextColor3 = errorTheme.entryTextColor or DEFAULT_THEME.errorPanel.entryTextColor
                    body.TextXAlignment = Enum.TextXAlignment.Left
                    body.TextYAlignment = Enum.TextYAlignment.Top
                    body.TextWrapped = true
                    body.RichText = entry.richText == true
                    body.Text = value
                    body.LayoutOrder = 2
                    body.Parent = frame

                    table.insert(self._errorEntryInstances, frame)
                    visibleEntries += 1
                end
            end
        end
    end

    self._errorLogScroll.Visible = visibleEntries > 0

    self:_updateErrorActions(detail)
    self:_updateErrorCanvasSize()

    local camera = Workspace.CurrentCamera
    if camera then
        self:_applyResponsiveLayout(camera.ViewportSize)
    else
        self:_applyResponsiveLayout(nil)
    end
end

function LoadingOverlay:setErrorDetails(detail)
    if self._destroyed then
        return
    end

    if detail == nil then
        self._currentErrorDetails = nil
        self:_clearErrorDetails()
        local camera = Workspace.CurrentCamera
        if camera or self._layoutState then
            self:_applyResponsiveLayout(camera and camera.ViewportSize or nil)
        end
        return
    end

    if typeof(detail) ~= "table" then
        self._currentErrorDetails = nil
        self:_clearErrorDetails()
        return
    end

    self._currentErrorDetails = Util.deepCopy(detail)
    self:_renderErrorDetails(detail)
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

function LoadingOverlay:setStatus(status, options)
    if self._destroyed then
        return
    end
    options = options or {}

    local detail = options.detail
    local text = status
    local dashboardPayload

    if typeof(status) == "table" then
        detail = detail or status.detail or status.details
        text = status.text or status.message or ""
        if options.force == nil and status.force ~= nil then
            options.force = status.force
        end
        dashboardPayload = Util.deepCopy(status)
        dashboardPayload.text = dashboardPayload.text or text
        dashboardPayload.detail = dashboardPayload.detail or detail
    else
        text = text or ""
        dashboardPayload = { text = text, detail = detail }
    end

    local label = self._statusLabel
    local detailChanged = detail ~= nil or (self._currentErrorDetails ~= nil and detail == nil)
    if label.Text == text and not options.force and not detailChanged then
        if self._dashboard and self._dashboard.setStatusText then
            self._dashboard:setStatusText(dashboardPayload)
        end
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
        self._dashboard:setStatusText(dashboardPayload)
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
    if self._backdropGradient then
        local backdropTheme = theme.backdropGradient or DEFAULT_THEME.backdropGradient
        if backdropTheme then
            self._backdropGradient.Color = backdropTheme.color or DEFAULT_THEME.backdropGradient.color
            self._backdropGradient.Transparency = backdropTheme.transparency or DEFAULT_THEME.backdropGradient.transparency
            self._backdropGradient.Rotation = backdropTheme.rotation or DEFAULT_THEME.backdropGradient.rotation or 0
        end
    end
    if self._container then
        self._container.Size = theme.containerSize or DEFAULT_THEME.containerSize
        self._container.BackgroundColor3 = theme.containerBackgroundColor or Color3.fromRGB(10, 14, 28)
        self._container.BackgroundTransparency = theme.containerTransparency or DEFAULT_THEME.containerTransparency or 0
    end
    if self._containerShadow then
        local shadow = theme.shadow or DEFAULT_THEME.shadow
        local paddingValue = shadow and shadow.padding or DEFAULT_THEME.shadow.padding
        local paddingX, paddingY
        if typeof(paddingValue) == "Vector2" then
            paddingX, paddingY = paddingValue.X, paddingValue.Y
        elseif typeof(paddingValue) == "number" then
            paddingX, paddingY = paddingValue, paddingValue
        else
            paddingX, paddingY = DEFAULT_THEME.shadow.padding.X, DEFAULT_THEME.shadow.padding.Y
        end
        self._containerShadow.Size = UDim2.new(1, paddingX, 1, paddingY)
        self._containerShadow.BackgroundColor3 = (shadow and shadow.color) or DEFAULT_THEME.shadow.color
        self._containerShadow.BackgroundTransparency = (shadow and shadow.transparency) or DEFAULT_THEME.shadow.transparency
        if self._containerShadowGradient then
            self._containerShadowGradient.Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0, (shadow and shadow.color) or DEFAULT_THEME.shadow.color),
                ColorSequenceKeypoint.new(1, (shadow and shadow.outerColor) or DEFAULT_THEME.shadow.outerColor or DEFAULT_THEME.shadow.color),
            })
            self._containerShadowGradient.Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, (shadow and shadow.gradientInnerTransparency) or DEFAULT_THEME.shadow.gradientInnerTransparency or 0.5),
                NumberSequenceKeypoint.new(1, 1),
            })
        end
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
    local errorTheme = theme.errorPanel or DEFAULT_THEME.errorPanel
    if self._errorPanel then
        self._errorPanel.BackgroundColor3 = errorTheme.backgroundColor or DEFAULT_THEME.errorPanel.backgroundColor
        self._errorPanel.BackgroundTransparency = errorTheme.backgroundTransparency or DEFAULT_THEME.errorPanel.backgroundTransparency
    end
    if self._errorPanelCorner then
        self._errorPanelCorner.CornerRadius = errorTheme.cornerRadius or DEFAULT_THEME.errorPanel.cornerRadius
    end
    if self._errorPanelStroke then
        self._errorPanelStroke.Color = errorTheme.strokeColor or DEFAULT_THEME.errorPanel.strokeColor
        self._errorPanelStroke.Transparency = errorTheme.strokeTransparency or DEFAULT_THEME.errorPanel.strokeTransparency
    end
    if self._errorTitle then
        self._errorTitle.Font = errorTheme.titleFont or DEFAULT_THEME.errorPanel.titleFont
        self._errorTitle.TextSize = errorTheme.titleTextSize or DEFAULT_THEME.errorPanel.titleTextSize
        self._errorTitle.TextColor3 = errorTheme.titleColor or DEFAULT_THEME.errorPanel.titleColor
        if self._currentErrorDetails and self._currentErrorDetails.title then
            self._errorTitle.Text = self._currentErrorDetails.title
        end
    end
    if self._errorSummary then
        self._errorSummary.Font = errorTheme.summaryFont or DEFAULT_THEME.errorPanel.summaryFont
        self._errorSummary.TextSize = errorTheme.summaryTextSize or DEFAULT_THEME.errorPanel.summaryTextSize
        self._errorSummary.TextColor3 = errorTheme.summaryColor or DEFAULT_THEME.errorPanel.summaryColor
    end
    if self._errorLogScroll then
        self._errorLogScroll.ScrollBarImageColor3 = errorTheme.scrollBarColor or DEFAULT_THEME.errorPanel.scrollBarColor
        self._errorLogScroll.ScrollBarImageTransparency = errorTheme.scrollBarTransparency or DEFAULT_THEME.errorPanel.scrollBarTransparency
    end
    if self._errorLogLayout then
        self._errorLogLayout.Padding = UDim.new(0, errorTheme.listSpacing or DEFAULT_THEME.errorPanel.listSpacing or 8)
    end
    if self._errorLogPadding then
        local pad = errorTheme.sectionPadding or DEFAULT_THEME.errorPanel.sectionPadding or 10
        self._errorLogPadding.PaddingTop = UDim.new(0, pad)
        self._errorLogPadding.PaddingBottom = UDim.new(0, pad)
        self._errorLogPadding.PaddingLeft = UDim.new(0, pad)
        self._errorLogPadding.PaddingRight = UDim.new(0, pad)
    end
    self:_restyleErrorButtons()
    if self._currentErrorDetails then
        self:_renderErrorDetails(Util.deepCopy(self._currentErrorDetails))
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

    disconnectConnections(self._errorActionConnections)
    self._errorActionConnections = nil
    if self._errorEntryInstances then
        for _, item in ipairs(self._errorEntryInstances) do
            if item and item.Destroy then
                item:Destroy()
            end
        end
    end
    self._errorEntryInstances = nil
    self._currentErrorDetails = nil
    self._errorCopyText = nil
    self._errorDocsLink = nil

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
