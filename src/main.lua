-- mikkel32/AutoParry : src/main.lua
-- selene: allow(global_usage)
-- Bootstraps the AutoParry experience, wiring together the UI and core logic
-- and returning a friendly developer API.

local Require = rawget(_G, "ARequire")
assert(Require, "AutoParry: ARequire missing (loader.lua not executed)")

local Util = Require("src/shared/util.lua")
local LoadingOverlay = Require("src/ui/loading_overlay.lua")
local VerificationDashboard = Require("src/ui/verification_dashboard.lua")

local HttpService = game:GetService("HttpService")

local VERSION = "1.1.0"
local UI_MODULE_PATH = "src/ui/init.lua"
local PARRY_MODULE_PATH = "src/core/autoparry.lua"
local ERROR_DOCS_URL = "https://github.com/mikkel32/AutoParry#troubleshooting"
local REASON_STAGE_MAP = {
    ["local-player"] = "player",
    ["player"] = "player",
    ["waiting-player"] = "player",
    ["remotes"] = "remotes",
    ["waiting-remotes"] = "remotes",
    ["remotes-folder"] = "remotes",
    ["remote"] = "remotes",
    ["parry-remote"] = "remotes",
    ["success"] = "success",
    ["success-events"] = "success",
    ["balls"] = "balls",
    ["balls-folder"] = "balls",
}

local function formatSeconds(seconds)
    if not seconds or seconds <= 0 then
        return nil
    end
    if seconds < 1 then
        return string.format("%.2f s", seconds)
    end
    return string.format("%.1f s", seconds)
end

local function resolveStageId(value)
    if value == nil then
        return nil
    end
    local text = string.lower(tostring(value))
    return REASON_STAGE_MAP[text]
end

local function buildErrorDetail(state)
    local errorState = state.error or {}
    local detail = {
        kind = "error",
        title = errorState.title or errorState.message or "AutoParry encountered an error",
        summary = errorState.message or "AutoParry failed to start.",
        message = errorState.message or "AutoParry failed to start.",
        reason = errorState.reason,
        docsLink = errorState.docsLink or ERROR_DOCS_URL,
        entries = {},
        tips = {},
        timeline = {},
        meta = {},
    }

    local copyLines = {}
    local function pushCopy(line)
        if typeof(line) == "string" and line ~= "" then
            table.insert(copyLines, line)
        end
    end

    pushCopy(detail.title)
    if detail.summary and detail.summary ~= detail.title then
        pushCopy(detail.summary)
    end

    local function addEntry(label, value, kind)
        if value == nil then
            return
        end
        if typeof(value) ~= "string" then
            value = tostring(value)
        end
        if value == "" then
            return
        end
        table.insert(detail.entries, { label = label, value = value, kind = kind })
        pushCopy(string.format("%s: %s", label, value))
    end

    local function addTips(tips)
        if tips == nil then
            return
        end
        if typeof(tips) == "table" then
            for _, tip in ipairs(tips) do
                if tip ~= nil then
                    local text = typeof(tip) == "string" and tip or tostring(tip)
                    table.insert(detail.tips, text)
                    pushCopy("Tip: " .. text)
                end
            end
        else
            local text = typeof(tips) == "string" and tips or tostring(tips)
            table.insert(detail.tips, text)
            pushCopy("Tip: " .. text)
        end
    end

    local payload = errorState.payload
    if typeof(payload) == "table" then
        if detail.reason == nil and payload.reason ~= nil then
            detail.reason = payload.reason
        end
    end

    if errorState.kind == "loader" then
        detail.title = errorState.message or "Module download failed"
        detail.summary = errorState.message or "AutoParry could not download required modules."
        detail.message = detail.summary

        local last = state.loader and state.loader.last
        local path = payload and payload.path or (last and last.path)
        addEntry("Module", path, "path")

        local errMsg = payload and (payload.error or payload.message)
        addEntry("Loader error", errMsg)

        if payload and (payload.stackTrace or payload.stack) then
            local stack = payload.stackTrace or payload.stack
            detail.logs = detail.logs or {}
            table.insert(detail.logs, { label = "Stack trace", value = stack, kind = "stack" })
            pushCopy("Stack trace:\n" .. stack)
        end

        addTips(payload and payload.remediation)

        if #detail.tips == 0 then
            addTips({
                "Check your network connection and retry the AutoParry download.",
                "Ensure your executor allows HttpGet/HttpPost for AutoParry modules.",
            })
        end

        local stage = resolveStageId("remotes") or "remotes"
        table.insert(detail.timeline, {
            id = stage,
            status = "failed",
            message = detail.summary,
            tooltip = path and string.format("Failed to fetch %s", path) or detail.summary,
        })
        detail.meta[stage] = "Download failure"
        detail.failingStage = stage
        detail.timelineStatus = "failed"
    elseif errorState.kind == "parry" then
        detail.title = errorState.message or "AutoParry verification failed"
        detail.summary = errorState.message or "AutoParry failed during verification."
        detail.message = detail.summary

        if payload and payload.stage then
            addEntry("Verification stage", payload.stage)
        end
        if payload and payload.step then
            addEntry("Step", payload.step)
        end
        if payload and payload.target then
            addEntry("Target", payload.target)
        end
        if payload and payload.remoteName then
            addEntry("Remote", payload.remoteName)
        end
        if payload and payload.remoteVariant then
            addEntry("Variant", payload.remoteVariant)
        end
        if payload and payload.remoteClass then
            addEntry("Remote class", payload.remoteClass)
        end
        if payload and payload.elapsed then
            addEntry("Elapsed", formatSeconds(payload.elapsed))
        end

        local stage = resolveStageId(detail.reason)
            or (payload and (resolveStageId(payload.step) or resolveStageId(payload.stage)))
            or "success"
        detail.failingStage = stage

        local status = "failed"
        local reasonLower = detail.reason and string.lower(tostring(detail.reason)) or nil
        if reasonLower == "balls" or reasonLower == "balls-folder" or (payload and payload.step == "balls") then
            status = "warning"
        end

        table.insert(detail.timeline, {
            id = stage,
            status = status,
            message = detail.summary,
            tooltip = detail.summary,
        })
        detail.timelineStatus = status
        detail.meta[stage] = payload and (payload.reason or payload.step or payload.stage) or detail.reason

        if payload and payload.stackTrace then
            detail.logs = detail.logs or {}
            table.insert(detail.logs, { label = "Stack trace", value = payload.stackTrace, kind = "stack" })
            pushCopy("Stack trace:\n" .. payload.stackTrace)
        end

        if payload and payload.tip then
            addTips(payload.tip)
        end

        if reasonLower == "local-player" then
            addTips("Wait for your avatar to spawn in before retrying AutoParry.")
        elseif reasonLower == "remotes-folder" or reasonLower == "parry-remote" or reasonLower == "remote" then
            addTips("Join or rejoin a Blade Ball match so the parry remotes replicate.")
        elseif reasonLower == "balls" or reasonLower == "balls-folder" then
            addTips("Ensure a match is active with balls in play before enabling AutoParry.")
        end
    end

    if detail.reason then
        addEntry("Reason", detail.reason)
    end

    if payload and typeof(payload) == "table" then
        local ok, encoded = pcall(HttpService.JSONEncode, HttpService, payload)
        if ok then
            detail.payloadText = encoded
            pushCopy("Payload: " .. encoded)
        end
    elseif payload ~= nil then
        addEntry("Payload", tostring(payload))
    end

    if #detail.tips == 0 and errorState.kind ~= "loader" then
        addTips("Retry the bootstrap from the overlay controls when the issue is resolved.")
    end

    detail.copyText = table.concat(copyLines, "\n")

    return detail
end

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
        local detail = buildErrorDetail(state)
        if typeof(state.error) == "table" then
            state.error.detail = detail
        end
        return {
            text = detail.summary or detail.message or "AutoParry failed to start.",
            detail = detail,
        }
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
                return {
                    text = ("Downloading %s (%d/%d)"):format(lastPath, finished + failed, total),
                }
            else
                return {
                    text = ("Downloading %s…"):format(lastPath),
                }
            end
        end

        if total > 0 then
            return {
                text = ("Downloading AutoParry modules (%d/%d)"):format(finished + failed, total),
            }
        end

        return { text = "Preparing AutoParry download…" }
    end

    local parry = state.parry or {}
    local stage = parry.stage

    if stage == "ready" then
        return { text = "AutoParry ready!" }
    elseif stage == "waiting-remotes" then
        if parry.target == "remote" then
            return { text = "Waiting for parry remote…" }
        end
        return { text = "Waiting for Blade Ball remotes…" }
    elseif stage == "waiting-player" then
        return { text = "Waiting for your player…" }
    elseif stage == "timeout" then
        return { text = "AutoParry initialization timed out." }
    end

    return { text = "Preparing AutoParry…" }
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
    local dashboard = nil
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

        local mount = overlay and overlay:getDashboardMount()
        if mount then
            local okDashboard, dashboardResult = pcall(function()
                return VerificationDashboard.new({
                    parent = mount,
                    theme = overlay:getTheme(),
                })
            end)
            if okDashboard then
                dashboard = dashboardResult
                overlay:attachDashboard(dashboard)
                dashboard:update(overlayState, { progress = dashboardProgressAlpha })
                overlay:onCompleted(function()
                    dashboard = nil
                end)
            else
                warn("AutoParry dashboard initialization failed:", dashboardResult)
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

    local dashboardProgressAlpha = 0

    local DIAGNOSTIC_STAGE_ORDER = { "player", "remotes", "success", "balls" }
    local MAX_DIAGNOSTIC_EVENTS = 120
    local DIAGNOSTIC_STAGE_INFO = {
        player = {
            id = "player",
            title = "Player readiness",
            description = "Ensure your avatar is loaded.",
        },
        remotes = {
            id = "remotes",
            title = "Game remotes",
            description = "Connect to Blade Ball remotes.",
        },
        success = {
            id = "success",
            title = "Success feedback",
            description = "Listen for parry success events.",
        },
        balls = {
            id = "balls",
            title = "Ball telemetry",
            description = "Track balls for prediction.",
        },
    }

    local diagnosticsState = {
        stages = {},
        events = {},
        errors = {},
        eventSequence = 0,
        startClock = os.clock(),
        lastParrySignature = nil,
        panelSynced = false,
    }

    local controller = nil

    local function diagnosticsDeepCopy(value)
        if Util and Util.deepCopy then
            return Util.deepCopy(value)
        end
        if typeof(value) ~= "table" then
            return value
        end
        local copy = {}
        for key, item in pairs(value) do
            copy[key] = diagnosticsDeepCopy(item)
        end
        return copy
    end

    local function resetDiagnosticsState()
        diagnosticsState.stages = {}
        for _, id in ipairs(DIAGNOSTIC_STAGE_ORDER) do
            local info = DIAGNOSTIC_STAGE_INFO[id]
            diagnosticsState.stages[id] = {
                id = id,
                title = info.title,
                description = info.description,
                status = "pending",
                message = info.description,
                detail = nil,
            }
        end
        diagnosticsState.events = {}
        diagnosticsState.errors = {}
        diagnosticsState.eventSequence = 0
        diagnosticsState.startClock = os.clock()
        diagnosticsState.lastParrySignature = nil
        diagnosticsState.panelSynced = false
    end

    resetDiagnosticsState()

    local function diagnosticsStagesToArray()
        local list = {}
        for _, id in ipairs(DIAGNOSTIC_STAGE_ORDER) do
            local stage = diagnosticsState.stages[id]
            if stage then
                table.insert(list, {
                    id = stage.id or id,
                    title = stage.title or (DIAGNOSTIC_STAGE_INFO[id] and DIAGNOSTIC_STAGE_INFO[id].title) or id,
                    description = stage.description or (DIAGNOSTIC_STAGE_INFO[id] and DIAGNOSTIC_STAGE_INFO[id].description) or "",
                    status = stage.status or "pending",
                    message = stage.message or stage.description or "",
                    detail = stage.detail,
                })
            end
        end
        return list
    end

    local function broadcastDiagnosticsStages()
        if controller and controller.setDiagnosticsStages then
            controller:setDiagnosticsStages(diagnosticsStagesToArray())
        end
    end

    local function updateDiagnosticsStage(id, props)
        props = props or {}
        local info = DIAGNOSTIC_STAGE_INFO[id]
        local stage = diagnosticsState.stages[id]
        if not stage then
            stage = {
                id = id,
                title = info and info.title or id,
                description = info and info.description or "",
                status = "pending",
                message = info and info.description or "",
                detail = nil,
            }
            diagnosticsState.stages[id] = stage
        end

        local changed = false

        if props.status and stage.status ~= props.status then
            stage.status = props.status
            changed = true
        end

        if props.message ~= nil then
            local message = props.message
            if message == false then
                message = stage.description
            end
            if stage.message ~= message then
                stage.message = message
                changed = true
            end
        end

        if props.detail ~= nil or props.clearDetail then
            local detail = props.detail
            if props.clearDetail or detail == false or detail == "" then
                detail = nil
            end
            if stage.detail ~= detail then
                stage.detail = detail
                changed = true
            end
        end

        return changed
    end

    local function formatInitElapsed(seconds)
        if typeof(seconds) ~= "number" then
            return nil
        end
        if seconds < 0 then
            seconds = 0
        end
        if seconds >= 120 then
            return string.format("%d s", math.floor(seconds + 0.5))
        elseif seconds >= 10 then
            return string.format("%.1f s", seconds)
        end
        return string.format("%.2f s", seconds)
    end

    local function applyParrySnapshotToDiagnostics(snapshot)
        if typeof(snapshot) ~= "table" then
            return
        end

        local stage = snapshot.stage
        local status = snapshot.status
        local target = snapshot.target or snapshot.step
        local changed = false

        local function mark(id, state, message, detail, clearDetail)
            if not id then
                return
            end
            local props = { status = state }
            if message ~= nil then
                props.message = message
            end
            if detail ~= nil then
                props.detail = detail
            end
            if clearDetail then
                props.clearDetail = true
            end
            if updateDiagnosticsStage(id, props) then
                changed = true
            end
        end

        if stage == "ready" then
            mark("player", "ok", "Player locked", nil, true)
            local remoteMessage = string.format("%s (%s)", snapshot.remoteName or "Parry remote", snapshot.remoteVariant or "detected")
            mark("remotes", "ok", remoteMessage, nil, true)
            if snapshot.successEvents then
                mark("success", "ok", "Success listeners wired", nil, true)
            else
                mark("success", "ok", "Success listeners active", nil, true)
            end
            if snapshot.successEvents and snapshot.successEvents.Balls then
                mark("balls", "ok", "Ball telemetry streaming", nil, true)
            else
                mark("balls", "ok", "Ready for match", nil, true)
            end
        elseif stage == "timeout" then
            local reason = snapshot.reason or target
            if reason == "local-player" or target == "local-player" then
                mark("player", "failed", "Timed out waiting for player", nil, true)
            elseif reason == "remotes-folder" or target == "folder" then
                mark("remotes", "failed", "Remotes folder missing", nil, true)
            elseif reason == "parry-remote" or target == "remote" then
                mark("remotes", "failed", "Parry remote unavailable", nil, true)
            elseif reason == "balls-folder" then
                mark("balls", "warning", "Balls folder not found", "AutoParry will continue without ball telemetry if the folder is missing.")
            else
                mark("success", "warning", snapshot.message or "Verification timeout", snapshot.message)
            end
        elseif stage == "error" then
            if target == "remote" then
                mark("remotes", "failed", snapshot.message or "Unsupported parry remote", nil, true)
            elseif target == "folder" then
                mark("remotes", "failed", snapshot.message or "Remotes folder removed", nil, true)
            else
                mark("success", "warning", snapshot.message or "Verification error", snapshot.message)
            end
        elseif stage == "waiting-player" or stage == "waiting-character" then
            if status == "ok" then
                local elapsed = formatInitElapsed(snapshot.elapsed)
                local message = elapsed and string.format("Player ready (%s)", elapsed) or "Player ready"
                mark("player", "ok", message, nil, true)
            elseif status == "waiting" or status == "pending" then
                mark("player", "active", "Waiting for player…", nil, true)
            end
        elseif stage == "waiting-remotes" then
            if target == "folder" then
                if status == "ok" then
                    mark("remotes", "active", "Remotes folder located", nil, true)
                else
                    mark("remotes", "active", "Searching for Remotes folder…", nil, true)
                end
            elseif target == "remote" then
                if status == "ok" then
                    local name = snapshot.remoteName or "Parry remote"
                    local variant = snapshot.remoteVariant or "detected"
                    mark("remotes", "ok", string.format("%s (%s)", name, variant), nil, true)
                else
                    mark("remotes", "active", "Scanning for parry remote…", nil, true)
                end
            end
        elseif stage == "verifying-success-remotes" then
            if snapshot.remotes or status == "ok" then
                mark("success", "ok", "Success listeners bound", nil, true)
            else
                mark("success", "active", "Hooking success events…", nil, true)
            end
        elseif stage == "verifying-balls" then
            if status == "ok" then
                mark("balls", "ok", "Ball telemetry online", nil, true)
            elseif status == "warning" then
                mark("balls", "warning", "Ball folder timeout", "AutoParry will continue without ball telemetry if the folder is missing.")
            elseif status == "waiting" or status == "pending" then
                mark("balls", "active", "Searching for balls…", nil, true)
            end
        elseif stage == "restarting" then
            local reason = snapshot.reason or target
            local detail = reason and string.format("Reason: %s", reason) or nil
            mark("remotes", "active", "Reinitialising verification…", detail, reason == nil)
        end

        if changed then
            broadcastDiagnosticsStages()
        end
    end

    local function describeParryProgress(progress)
        local stage = progress.stage
        local status = progress.status
        local target = progress.target or progress.step
        local reason = progress.reason
        local message
        local severity = "info"
        local detail = progress.message

        if stage == "ready" then
            severity = "success"
            message = "Verification complete"
        elseif stage == "waiting-player" or stage == "waiting-character" then
            if status == "ok" then
                severity = "success"
                local elapsed = formatInitElapsed(progress.elapsed)
                message = elapsed and string.format("Player ready (%s)", elapsed) or "Player ready"
            else
                message = "Waiting for player"
            end
        elseif stage == "waiting-remotes" then
            if target == "folder" then
                if status == "ok" then
                    severity = "success"
                    message = "Remotes folder located"
                else
                    message = "Searching for remotes folder"
                end
            else
                if status == "ok" then
                    severity = "success"
                    message = string.format("Parry remote detected (%s)", progress.remoteVariant or "detected")
                else
                    message = "Scanning for parry remote"
                end
            end
        elseif stage == "verifying-success-remotes" then
            if progress.remotes or status == "ok" then
                severity = "success"
                message = "Success listeners bound"
            else
                message = "Hooking success events"
            end
        elseif stage == "verifying-balls" then
            if status == "ok" then
                severity = "success"
                message = "Ball telemetry verified"
            elseif status == "warning" then
                severity = "warning"
                message = "Ball folder timeout"
                detail = "AutoParry will continue without ball telemetry if the folder is missing."
            else
                message = "Searching for balls"
            end
        elseif stage == "timeout" then
            severity = "error"
            local reasonText = reason or target
            if reasonText == "local-player" then
                message = "Timed out waiting for player"
            elseif reasonText == "remotes-folder" then
                message = "Timed out waiting for remotes folder"
            elseif reasonText == "parry-remote" or reasonText == "remote" then
                message = "Timed out waiting for parry remote"
            elseif reasonText == "balls-folder" then
                message = "Ball folder timed out"
            else
                message = progress.message or "AutoParry initialization timed out"
            end
        elseif stage == "error" then
            severity = "error"
            message = progress.message or "Verification error"
        elseif stage == "restarting" then
            severity = "warning"
            if reason then
                message = string.format("Restarting verification (%s)", reason)
            else
                message = "Restarting verification"
            end
            detail = progress.message or detail
        end

        if not message then
            message = stage or "Verification update"
        end

        return message, severity, detail
    end

    local function recordDiagnosticEvent(event)
        if typeof(event) ~= "table" then
            return
        end

        local copy = diagnosticsDeepCopy(event)
        diagnosticsState.eventSequence += 1
        copy.sequence = diagnosticsState.eventSequence
        copy.timestamp = copy.timestamp or os.clock()

        if #diagnosticsState.events >= MAX_DIAGNOSTIC_EVENTS then
            table.remove(diagnosticsState.events, 1)
        end
        table.insert(diagnosticsState.events, copy)

        if controller and controller.pushDiagnosticsEvent then
            controller:pushDiagnosticsEvent(copy)
        end
    end

    local function recordLoaderEvent(kind, payload)
        local path = payload and payload.path
        local message
        local severity = "info"
        local detail

        if kind == "started" then
            message = path and ("Downloading %s"):format(path) or "Downloading AutoParry modules"
        elseif kind == "completed" then
            severity = "success"
            message = path and ("Downloaded %s"):format(path) or "Module downloaded"
        elseif kind == "failed" then
            severity = "error"
            message = path and ("Failed to download %s"):format(path) or "Module download failed"
            if payload and payload.error then
                detail = tostring(payload.error)
            end
        elseif kind == "all-complete" then
            severity = "success"
            message = "AutoParry download complete"
        else
            message = kind
        end

        recordDiagnosticEvent({
            kind = "loader",
            action = kind,
            severity = severity,
            message = message,
            detail = detail,
            payload = payload and diagnosticsDeepCopy(payload) or nil,
            timestamp = os.clock(),
        })
    end

    local function recordParrySnapshot(progress)
        if typeof(progress) ~= "table" then
            return
        end

        local stage = progress.stage or "unknown"
        local status = progress.status or ""
        local target = progress.target or progress.step or ""
        local reason = progress.reason or ""
        local signature = string.format("%s|%s|%s|%s", stage, status, target, progress.message or reason or "")

        if diagnosticsState.lastParrySignature == signature then
            return
        end

        diagnosticsState.lastParrySignature = signature

        local message, severity, detail = describeParryProgress(progress)

        recordDiagnosticEvent({
            kind = "parry",
            stage = stage,
            status = progress.status,
            target = target,
            severity = severity or "info",
            message = message or stage,
            detail = detail or progress.message,
            payload = diagnosticsDeepCopy(progress),
            timestamp = os.clock(),
        })
    end

    local function upsertDiagnosticsError(entry)
        if typeof(entry) ~= "table" then
            return
        end

        local id = entry.id or entry.kind or "error"
        local stored = diagnosticsState.errors[id]
        if not stored then
            stored = {
                id = id,
                kind = entry.kind,
                severity = entry.severity or "error",
                message = entry.message or "AutoParry error",
                payload = entry.payload and diagnosticsDeepCopy(entry.payload) or nil,
                active = entry.active ~= false,
            }
            diagnosticsState.errors[id] = stored
        else
            stored.kind = entry.kind or stored.kind
            stored.severity = entry.severity or stored.severity or "error"
            if entry.message ~= nil then
                stored.message = entry.message
            end
            if entry.payload ~= nil then
                stored.payload = entry.payload and diagnosticsDeepCopy(entry.payload) or nil
            end
            if entry.active ~= nil then
                stored.active = entry.active ~= false
            end
        end

        if controller and controller.showDiagnosticsError then
            controller:showDiagnosticsError(diagnosticsDeepCopy(stored))
        end
    end

    local function resolveDiagnosticsError(kind, message)
        if not kind then
            return
        end

        local stored = diagnosticsState.errors[kind]
        if not stored then
            return
        end

        if message then
            stored.message = message
        end

        if stored.active then
            stored.active = false
        end

        if controller and controller.showDiagnosticsError then
            controller:showDiagnosticsError(diagnosticsDeepCopy(stored))
        end
    end

    local function applyDiagnosticsError(errorState)
        if not errorState then
            return
        end

        local id = errorState.id or errorState.kind or "error"
        upsertDiagnosticsError({
            id = id,
            kind = errorState.kind,
            severity = errorState.severity or "error",
            message = errorState.message or "AutoParry error",
            payload = errorState.payload,
            active = errorState.active ~= false,
        })
    end

    local function syncDiagnosticsToController()
        if not controller then
            return
        end

        controller:resetDiagnostics()
        controller:setDiagnosticsStages(diagnosticsStagesToArray())
        for _, event in ipairs(diagnosticsState.events) do
            controller:pushDiagnosticsEvent(event)
        end
        for _, errorEntry in pairs(diagnosticsState.errors) do
            controller:showDiagnosticsError(diagnosticsDeepCopy(errorEntry))
        end
        diagnosticsState.panelSynced = true
    end

    local loaderComplete = not overlayEnabled
    local parryReady = not overlayEnabled
    local bootstrapCancelled = false
    local finalizeTriggered = false
    local retryInFlight = false

    local loaderConnections = {}
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

        local okStatus, statusResult = pcall(statusFormatter, overlayState, overlayOpts, opts)
        if okStatus then
            local statusPayload
            if typeof(statusResult) == "table" then
                statusPayload = statusResult
            elseif typeof(statusResult) == "string" then
                statusPayload = { text = statusResult }
            elseif statusResult ~= nil then
                statusPayload = { text = tostring(statusResult) }
            else
                statusPayload = { text = "" }
            end

            overlay:setStatus(statusPayload, { force = overlayState.error ~= nil })
            if overlay.setErrorDetails then
                overlay:setErrorDetails(statusPayload.detail)
            end
            if overlayState.error and statusPayload.detail then
                overlayState.error.detail = statusPayload.detail
                applyDiagnosticsError(overlayState.error)
            end
        else
            warn("AutoParry loading overlay status formatter error:", statusResult)
        end

        local okProgress, progressValue = pcall(progressFormatter, overlayState, overlayOpts, opts)
        if okProgress and typeof(progressValue) == "number" then
            local clamped = math.clamp(progressValue, 0, 1)
            overlay:setProgress(clamped, { force = overlayState.error ~= nil })
            dashboardProgressAlpha = clamped
        elseif not okProgress then
            warn("AutoParry loading overlay progress formatter error:", progressValue)
        end

        if applyActions then
            applyActions()
        end

        if dashboard then
            dashboard:update(overlayState, { progress = dashboardProgressAlpha })
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

        if dashboard then
            dashboard:setActions(nil)
            dashboard:setStatusText("Verification cancelled")
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
        dashboardProgressAlpha = 0

        resetDiagnosticsState()
        if controller then
            syncDiagnosticsToController()
        end

        if overlay then
            overlay:setActions(nil)
            overlay:setStatus("Retrying AutoParry download…", { force = true })
            overlay:setProgress(0, { force = true })
        end

        if dashboard then
            dashboard:reset()
            dashboard:setStatusText("Reinitialising verification…")
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
            recordLoaderEvent("started", payload)
            updateOverlay()
        end)
        table.insert(loaderConnections, startedConn)

        local completedConn = loaderSignals.onFetchCompleted:Connect(function(payload)
            overlayState.loader.last = payload
            refreshLoaderCounters()
            refreshLoaderCompletion()
            recordLoaderEvent("completed", payload)
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
            recordLoaderEvent("failed", payload)
            refreshLoaderCompletion()
            updateOverlay()
            applyDiagnosticsError(overlayState.error)
        end)
        table.insert(loaderConnections, failedConn)

        local completeConn = loaderSignals.onAllComplete:Connect(function()
            refreshLoaderCounters()
            refreshLoaderCompletion()
            recordLoaderEvent("all-complete")
            resolveDiagnosticsError("loader")
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
        applyParrySnapshotToDiagnostics(overlayState.parry)
        recordParrySnapshot(progress or overlayState.parry)
        local stage = progress and progress.stage

        if stage == "ready" then
            parryReady = true
            if overlayState.error and overlayState.error.kind == "parry" then
                overlayState.error = nil
            end
            resolveDiagnosticsError("parry", "AutoParry ready")
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
            resolveDiagnosticsError("parry")
        end

        if overlayState.error then
            applyDiagnosticsError(overlayState.error)
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
                syncDiagnosticsToController()
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

        dashboard = nil
    end

    return api
end
