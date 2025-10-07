-- mikkel32/AutoParry : src/main.lua
-- selene: allow(global_usage)
-- Bootstraps the AutoParry experience, wiring together the UI and core logic
-- and returning a friendly developer API.

local Require = rawget(_G, "ARequire")
assert(Require, "AutoParry: ARequire missing (loader.lua not executed)")

local Util = Require("src/shared/util.lua")
local LoadingOverlay = Require("src/ui/loading_overlay.lua")

local VERSION = "1.1.0"
local UI_MODULE_PATH = "src/ui/init.lua"
local PARRY_MODULE_PATH = "src/core/autoparry.lua"

local function disconnect(connection)
    if not connection then
        return
    end
    if connection.Disconnect then
        connection:Disconnect()
    elseif connection.disconnect then
        connection:disconnect()
    end
end

local function defaultStatusFormatter(state)
    if state.error then
        return state.error.message or "AutoParry failed to start."
    end

    local loader = state.loader or {}
    if loader.completed ~= true then
        local started = loader.started or 0
        local finished = loader.finished or 0
        local failed = loader.failed or 0
        local lastPath = loader.last and loader.last.path
        local total = math.max(started, finished + failed)

        if lastPath then
            if total > 0 then
                return ("Downloading %s (%d/%d)"):format(lastPath, finished + failed, total)
            else
                return ("Downloading %s…"):format(lastPath)
            end
        end

        if total > 0 then
            return ("Downloading AutoParry modules (%d/%d)"):format(finished + failed, total)
        end

        return "Preparing AutoParry download…"
    end

    local parry = state.parry or {}
    local stage = parry.stage

    if stage == "ready" then
        return "AutoParry ready!"
    elseif stage == "waiting-remotes" then
        if parry.target == "remote" then
            return "Waiting for parry remote…"
        end
        return "Waiting for Blade Ball remotes…"
    elseif stage == "waiting-player" then
        return "Waiting for your player…"
    elseif stage == "timeout" then
        return "AutoParry initialization timed out."
    end

    return "Preparing AutoParry…"
end

local function defaultProgressFormatter(state)
    local loader = state.loader or {}
    local parry = state.parry or {}

    local loaderStarted = loader.started or 0
    local loaderFinished = loader.finished or 0
    local loaderFailed = loader.failed or 0
    local loaderTotal = math.max(loaderStarted, loaderFinished + loaderFailed)
    local loaderAlpha = 0
    if loaderTotal > 0 then
        loaderAlpha = math.clamp((loaderFinished + loaderFailed) / loaderTotal, 0, 1)
    end

    if state.error then
        return loaderAlpha
    end

    local parryStage = parry.stage
    local parryAlpha = 0
    if parryStage == "ready" then
        parryAlpha = 1
    elseif parryStage == "waiting-remotes" then
        parryAlpha = 0.7
    elseif parryStage == "waiting-player" then
        parryAlpha = 0.4
    elseif parryStage == "timeout" then
        parryAlpha = 0
    end

    if loader.completed == true then
        return parryAlpha
    end

    return math.clamp(loaderAlpha * 0.7 + parryAlpha * 0.3, 0, 1)
end

local function normalizeLoadingOverlayOptions(option)
    local defaults = {
        enabled = true,
        parent = nil,
        name = nil,
        tips = nil,
        theme = nil,
        statusFormatter = nil,
        progressFormatter = nil,
        formatStatus = nil,
        formatProgress = nil,
        actions = nil,
        retryLabel = "Retry",
        cancelLabel = "Cancel",
        onRetry = nil,
        onCancel = nil,
        onOverlayCreated = nil,
        customizeOverlay = nil,
        fadeDuration = nil,
        progressDuration = nil,
    }

    if option == nil then
        return defaults
    end

    if option == false then
        defaults.enabled = false
        return defaults
    end

    if option == true then
        return defaults
    end

    if typeof(option) == "table" then
        if option.enabled ~= nil then
            defaults.enabled = option.enabled ~= false
        end

        for key, value in pairs(option) do
            if key ~= "enabled" then
                defaults[key] = value
            end
        end

        if defaults.statusFormatter == nil and typeof(defaults.formatStatus) == "function" then
            defaults.statusFormatter = defaults.formatStatus
        end
        if defaults.progressFormatter == nil and typeof(defaults.formatProgress) == "function" then
            defaults.progressFormatter = defaults.formatProgress
        end

        defaults.formatStatus = nil
        defaults.formatProgress = nil

        return defaults
    end

    return defaults
end

local function normalizeOptions(options)
    options = options or {}
    local defaults = {
        title = "AutoParry",
        autoStart = false,
        defaultEnabled = false,
        hotkey = nil,
        tooltip = nil,
        parry = nil,
        loadingOverlay = true,
    }

    local merged = Util.merge(Util.deepCopy(defaults), options)
    merged.loadingOverlay = normalizeLoadingOverlayOptions(merged.loadingOverlay)
    return merged
end

return function(options, loaderContext)
    local opts = normalizeOptions(options)
    local overlayOpts = opts.loadingOverlay
    local overlayEnabled = overlayOpts.enabled ~= false

    local overlay = nil
    if overlayEnabled then
        overlay = LoadingOverlay.create({
            parent = overlayOpts.parent,
            name = overlayOpts.name,
            tips = overlayOpts.tips,
            theme = overlayOpts.theme,
        })

        local customize = overlayOpts.onOverlayCreated or overlayOpts.customizeOverlay
        if typeof(customize) == "function" then
            local ok, err = pcall(customize, overlay, overlayOpts, opts)
            if not ok then
                warn("AutoParry loading overlay customization failed:", err)
            end
        end
    end

    local loaderState = rawget(_G, "AutoParryLoader")
    local activeContext = loaderContext or (loaderState and loaderState.context)
    local loaderSignals = activeContext and activeContext.signals or (loaderState and loaderState.signals)
    local loaderProgress = activeContext and activeContext.progress or (loaderState and loaderState.progress) or {
        started = 0,
        finished = 0,
        failed = 0,
    }

    local overlayState = {
        loader = {
            started = loaderProgress.started or 0,
            finished = loaderProgress.finished or 0,
            failed = loaderProgress.failed or 0,
            completed = false,
            last = nil,
        },
        parry = {},
        error = nil,
    }

    local loaderComplete = not overlayEnabled
    local parryReady = not overlayEnabled
    local bootstrapCancelled = false
    local finalizeTriggered = false
    local retryInFlight = false

    local loaderConnections = {}
    local controller = nil
    local parryConn = nil
    local initConn = nil

    local statusFormatter = overlayOpts.statusFormatter
        or overlayOpts.formatStatus
        or defaultStatusFormatter
    local progressFormatter = overlayOpts.progressFormatter
        or overlayOpts.formatProgress
        or defaultProgressFormatter

    if typeof(statusFormatter) ~= "function" then
        statusFormatter = defaultStatusFormatter
    end
    if typeof(progressFormatter) ~= "function" then
        progressFormatter = defaultProgressFormatter
    end

    local function refreshLoaderCounters()
        if loaderProgress then
            overlayState.loader.started = loaderProgress.started or overlayState.loader.started
            overlayState.loader.finished = loaderProgress.finished or overlayState.loader.finished
            overlayState.loader.failed = loaderProgress.failed or overlayState.loader.failed
        end
    end

    local function refreshLoaderCompletion()
        local started = overlayState.loader.started or 0
        local finished = overlayState.loader.finished or 0
        local failed = overlayState.loader.failed or 0
        if started > 0 and finished + failed >= started then
            overlayState.loader.completed = true
            loaderComplete = true
        end
    end

    local finalize -- forward declaration

    local applyActions -- forward declaration

    local function updateOverlay()
        if not overlay then
            return
        end

        local okStatus, statusText = pcall(statusFormatter, overlayState, overlayOpts, opts)
        if okStatus and typeof(statusText) == "string" then
            overlay:setStatus(statusText, { force = overlayState.error ~= nil })
        elseif not okStatus then
            warn("AutoParry loading overlay status formatter error:", statusText)
        end

        local okProgress, progressValue = pcall(progressFormatter, overlayState, overlayOpts, opts)
        if okProgress and typeof(progressValue) == "number" then
            overlay:setProgress(math.clamp(progressValue, 0, 1), { force = overlayState.error ~= nil })
        elseif not okProgress then
            warn("AutoParry loading overlay progress formatter error:", progressValue)
        end

        if applyActions then
            applyActions()
        end
    end

    local function handleCancel()
        if bootstrapCancelled then
            return
        end
        bootstrapCancelled = true

        if overlay then
            overlay:setActions(nil)
        end

        if typeof(overlayOpts.onCancel) == "function" then
            local ok, err = pcall(overlayOpts.onCancel, {
                overlay = overlay,
                options = opts,
                state = overlayState,
                context = activeContext,
            })
            if not ok then
                warn("AutoParry loading overlay cancel handler failed:", err)
            end
        end
    end

    local function handleRetry()
        if retryInFlight then
            return
        end
        retryInFlight = true

        if typeof(overlayOpts.onRetry) == "function" then
            local ok, err = pcall(overlayOpts.onRetry, {
                overlay = overlay,
                options = opts,
                state = overlayState,
                context = activeContext,
            })
            if not ok then
                warn("AutoParry loading overlay retry handler failed:", err)
            end
            retryInFlight = false
            return
        end

        local retryContext = activeContext or (loaderState and loaderState.context)
        if not retryContext or typeof(retryContext.require) ~= "function" then
            warn("AutoParry: loader context unavailable, cannot retry bootstrap")
            retryInFlight = false
            return
        end

        bootstrapCancelled = true

        retryContext.refresh = true
        retryContext.cache = {}
        if loaderState and loaderState.progress then
            loaderState.progress.started = 0
            loaderState.progress.finished = 0
            loaderState.progress.failed = 0
        end

        overlayState.error = nil
        overlayState.loader.completed = false
        loaderComplete = not overlayEnabled
        parryReady = not overlayEnabled

        if overlay then
            overlay:setActions(nil)
            overlay:setStatus("Retrying AutoParry download…", { force = true })
            overlay:setProgress(0, { force = true })
        end

        task.spawn(function()
            local okModule, moduleOrError = pcall(retryContext.require, retryContext.entrypoint)
            if not okModule then
                warn("AutoParry: loader retry failed", moduleOrError)
                overlayState.error = {
                    kind = "loader",
                    message = tostring(moduleOrError),
                    payload = { error = moduleOrError },
                }
                updateOverlay()
                retryInFlight = false
                return
            end

            if typeof(moduleOrError) == "function" then
                local okExecute, execErr = pcall(moduleOrError, opts, retryContext)
                if not okExecute then
                    warn("AutoParry: loader retry execution failed", execErr)
                end
            end

            retryInFlight = false
        end)
    end

    applyActions = function()
        if not overlay then
            return
        end

        if overlayState.error then
            local actions = nil
            if typeof(overlayOpts.actions) == "function" then
                local ok, result = pcall(overlayOpts.actions, overlayState, overlayOpts, opts)
                if ok and typeof(result) == "table" then
                    actions = result
                elseif not ok then
                    warn("AutoParry loading overlay custom actions error:", result)
                end
            elseif typeof(overlayOpts.actions) == "table" then
                actions = overlayOpts.actions
            end

            if not actions then
                actions = {
                    {
                        id = "retry",
                        text = overlayOpts.retryLabel or "Retry",
                        callback = handleRetry,
                    },
                    {
                        id = "cancel",
                        text = overlayOpts.cancelLabel or "Cancel",
                        variant = "secondary",
                        callback = handleCancel,
                    },
                }
            end

            overlay:setActions(actions)
        else
            if typeof(overlayOpts.actions) == "table" and #overlayOpts.actions > 0 then
                overlay:setActions(overlayOpts.actions)
            else
                overlay:setActions(nil)
            end
        end
    end

    local function checkReady()
        if finalizeTriggered or bootstrapCancelled then
            return
        end

        if overlayState.error then
            return
        end

        if (not overlayEnabled or loaderComplete) and parryReady and finalize then
            finalizeTriggered = true
            finalize()
        end
    end

    if loaderSignals then
        local startedConn = loaderSignals.onFetchStarted:Connect(function(payload)
            overlayState.loader.last = payload
            refreshLoaderCounters()
            updateOverlay()
        end)
        table.insert(loaderConnections, startedConn)

        local completedConn = loaderSignals.onFetchCompleted:Connect(function(payload)
            overlayState.loader.last = payload
            refreshLoaderCounters()
            refreshLoaderCompletion()
            updateOverlay()
            checkReady()
        end)
        table.insert(loaderConnections, completedConn)

        local failedConn = loaderSignals.onFetchFailed:Connect(function(payload)
            overlayState.loader.last = payload
            refreshLoaderCounters()
            overlayState.error = {
                kind = "loader",
                message = (payload and payload.error) or (payload and payload.path and ("Failed to load %s"):format(payload.path)) or "Failed to download AutoParry modules.",
                payload = payload,
            }
            refreshLoaderCompletion()
            updateOverlay()
        end)
        table.insert(loaderConnections, failedConn)

        local completeConn = loaderSignals.onAllComplete:Connect(function()
            refreshLoaderCounters()
            refreshLoaderCompletion()
            updateOverlay()
            checkReady()
        end)
        table.insert(loaderConnections, completeConn)
    end

    refreshLoaderCounters()
    refreshLoaderCompletion()
    updateOverlay()

    local UI = Require(UI_MODULE_PATH)
    local Parry = Require(PARRY_MODULE_PATH)

    if typeof(opts.parry) == "table" then
        Parry.configure(opts.parry)
    end

    parryConn = Parry.onStateChanged(function(enabled)
        if controller then
            controller:setEnabled(enabled, { silent = true, source = "parry" })
        end
    end)

    initConn = Parry.onInitStatus(function(progress)
        overlayState.parry = Util.deepCopy(progress or {})
        local stage = progress and progress.stage

        if stage == "ready" then
            parryReady = true
            if overlayState.error and overlayState.error.kind == "parry" then
                overlayState.error = nil
            end
        elseif stage == "timeout" then
            parryReady = false
            local reason = progress and progress.reason
            local stageName = progress and progress.stage
            local message
            if reason then
                message = ("Timed out waiting for %s."):format(reason)
            elseif stageName then
                message = ("Timed out during %s."):format(stageName)
            else
                message = "AutoParry initialization timed out."
            end
            overlayState.error = {
                kind = "parry",
                message = message,
                payload = Util.deepCopy(progress or {}),
            }
        else
            if overlayState.error and overlayState.error.kind == "parry" then
                overlayState.error = nil
            end
        end

        updateOverlay()
        checkReady()
    end)

        finalize = function()
            if bootstrapCancelled then
                return
            end

            controller = UI.mount({
                title = opts.title,
                initialState = opts.autoStart or opts.defaultEnabled or Parry.isEnabled(),
                hotkey = opts.hotkey,
                tooltip = opts.tooltip,
                onToggle = function(enabled)
                    Parry.setEnabled(enabled)
                end,
            })

            if controller then
                controller:setEnabled(Parry.isEnabled(), { silent = true })
            end

            if opts.autoStart or opts.defaultEnabled then
                Parry.enable()
            else
                if controller then
                    controller:setEnabled(Parry.isEnabled(), { silent = true })
                end
            end

            if overlay then
                overlay:setActions(nil)
            overlay:complete({
                fadeDuration = overlayOpts.fadeDuration,
                progressDuration = overlayOpts.progressDuration,
            })
        end
    end

    updateOverlay()
    checkReady()

    local api = {}

    function api.getVersion()
        return VERSION
    end

    function api.isEnabled()
        return Parry.isEnabled()
    end

    function api.setEnabled(enabled)
        if controller then
            controller:setEnabled(enabled)
        else
            Parry.setEnabled(enabled)
        end
        return Parry.isEnabled()
    end

    function api.toggle()
        if controller then
            controller:toggle()
        else
            Parry.toggle()
        end
        return Parry.isEnabled()
    end

    function api.configure(config)
        Parry.configure(config)
        return Parry.getConfig()
    end

    function api.getConfig()
        return Parry.getConfig()
    end

    function api.resetConfig()
        return Parry.resetConfig()
    end

    function api.setLogger(fn)
        Parry.setLogger(fn)
    end

    function api.getLastParryTime()
        return Parry.getLastParryTime()
    end

    function api.onStateChanged(callback)
        return Parry.onStateChanged(callback)
    end

    function api.onParry(callback)
        return Parry.onParry(callback)
    end

    function api.getUiController()
        return controller
    end

    function api.destroy()
        Parry.destroy()

        disconnect(parryConn)
        parryConn = nil

        disconnect(initConn)
        initConn = nil

        for _, connection in ipairs(loaderConnections) do
            disconnect(connection)
        end
        if table.clear then
            table.clear(loaderConnections)
        else
            for index = #loaderConnections, 1, -1 do
                loaderConnections[index] = nil
            end
        end

        if controller then
            controller:destroy()
            controller = nil
        end

        if overlay and not overlay:isComplete() then
            overlay:destroy()
            overlay = nil
        end
    end

    return api
end
