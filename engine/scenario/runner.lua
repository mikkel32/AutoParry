--!strict

local HttpService = game:GetService("HttpService")

local Runner = {}

local function findTestHarness(instance: Instance): Instance
    local current = instance
    while current do
        if current.Name == "TestHarness" then
            return current
        end
        current = current.Parent
    end
    error("engine.scenario.runner: failed to locate TestHarness ancestor", 0)
end

local TestHarness = findTestHarness(script)
local Context = require(TestHarness:WaitForChild("Context"))

local function ensureScenarioFolder(): Instance
    local folder = TestHarness:FindFirstChild("Scenarios")
    if not folder then
        error("engine.scenario.runner: scenario artifact folder TestHarness/Scenarios is missing", 0)
    end
    return folder
end

local function sanitiseValue(value: any, visited: {[any]: boolean}?): any
    local luaType = typeof(value)
    if luaType == "number" or luaType == "boolean" or luaType == "string" or value == nil then
        return value
    end

    if luaType == "Vector3" then
        local vector = value :: Vector3
        return { x = vector.X, y = vector.Y, z = vector.Z }
    elseif luaType == "Vector2" then
        local vector = value :: Vector2
        return { x = vector.X, y = vector.Y }
    elseif luaType == "CFrame" then
        local components = { (value :: CFrame):GetComponents() }
        return { type = "CFrame", components = components }
    elseif luaType == "EnumItem" then
        local enum = value :: EnumItem
        return string.format("%s.%s", enum.EnumType.Name, enum.Name)
    elseif luaType == "Instance" then
        local instance = value :: Instance
        return {
            name = instance.Name,
            className = instance.ClassName,
        }
    elseif luaType == "table" then
        visited = visited or {}
        if visited[value] then
            return "<cycle>"
        end
        visited[value] = true

        local isArray = true
        local count = 0
        for key in pairs(value) do
            if typeof(key) ~= "number" then
                isArray = false
                break
            end
            if key > count then
                count = key
            end
        end

        local result
        if isArray and count == #value then
            result = table.create(#value)
            for index = 1, #value do
                result[index] = sanitiseValue(value[index], visited)
            end
        else
            result = {}
            for key, child in pairs(value) do
                local serialisedKey: any = key
                local keyType = typeof(key)
                if keyType == "EnumItem" then
                    serialisedKey = string.format("%s.%s", (key :: EnumItem).EnumType.Name, (key :: EnumItem).Name)
                elseif keyType == "Instance" then
                    serialisedKey = (key :: Instance).Name
                elseif keyType ~= "string" and keyType ~= "number" then
                    serialisedKey = tostring(key)
                end
                result[serialisedKey] = sanitiseValue(child, visited)
            end
        end

        visited[value] = nil
        return result
    else
        return tostring(value)
    end
end

local function sanitiseParryLog(log: { any }): { any }
    local result = {}
    for _, entry in ipairs(log) do
        local ball = entry.ball
        local payload = {
            timestamp = entry.timestamp,
            frame = entry.frame,
        }
        if typeof(ball) == "table" or typeof(ball) == "Instance" then
            local name
            if typeof(ball) == "Instance" then
                name = (ball :: Instance).Name
            else
                name = ball.Name
            end
            payload.ball = {
                name = name,
                position = sanitiseValue(ball.Position),
                velocity = sanitiseValue(ball.AssemblyLinearVelocity),
                realBall = (typeof(ball.GetAttribute) == "function" and ball:GetAttribute("realBall")) or nil,
            }
        end
        table.insert(result, payload)
    end
    return result
end

local function sanitiseRemoteLog(log: { any }): { any }
    local result = {}
    for _, entry in ipairs(log) do
        table.insert(result, {
            timestamp = entry.timestamp,
            payload = sanitiseValue(entry.payload),
        })
    end
    return result
end

local function sanitiseVirtualInput(log: { any }): { any }
    local result = {}
    for _, entry in ipairs(log) do
        table.insert(result, {
            timestamp = entry.timestamp,
            isPressed = entry.isPressed,
            keyCode = sanitiseValue(entry.keyCode),
            isRepeat = entry.isRepeat,
        })
    end
    return result
end

local function sanitiseTelemetrySnapshot(snapshot: any): any
    return sanitiseValue(snapshot)
end

local function sanitiseEvents(events: { any }): { any }
    local result = {}
    for _, event in ipairs(events) do
        local record = {
            time = event.time,
            type = event.type,
            notes = event.notes,
        }
        if event.rule then
            record.rule = event.rule
        end
        if event.value ~= nil then
            record.value = event.value
        end
        if event.action then
            record.action = event.action
        end
        if event.payload ~= nil then
            record.payload = sanitiseValue(event.payload)
        end
        if event.details ~= nil then
            record.details = sanitiseValue(event.details)
        end
        table.insert(result, record)
    end
    return result
end

local function resolveRelativeOverrides(defaults: {[string]: any}, overrides: {[string]: any}, warnings: {string})
    local resolved: {[string]: any} = {}
    for key, value in pairs(overrides) do
        if typeof(value) == "string" then
            local text = string.lower(value)
            local base = defaults[key]
            local operator, numberText = string.match(text, "^%s*default%s*([%+%-])%s*([%d%.]+)")
            if operator and numberText then
                local delta = tonumber(numberText)
                if delta and typeof(base) == "number" then
                    if operator == "+" then
                        resolved[key] = base + delta
                    else
                        resolved[key] = base - delta
                    end
                else
                    resolved[key] = base
                    table.insert(warnings, string.format("Unable to resolve override '%s' for %s", value, tostring(key)))
                end
            elseif text == "default" then
                resolved[key] = base
            else
                resolved[key] = value
            end
        else
            resolved[key] = value
        end
    end
    return resolved
end

local function captureSnapshots(context: any, warnings: {string})
    local autoparry = context.autoparry
    local snapshots = {}

    local function capture(name: string)
        local member = autoparry and autoparry[name]
        if typeof(member) ~= "function" then
            return nil
        end
        local ok, value = pcall(member)
        if ok then
            snapshots[name] = sanitiseTelemetrySnapshot(value)
            return value
        else
            table.insert(warnings, string.format("%s failed: %s", name, tostring(value)))
            return nil
        end
    end

    capture("getConfig")
    capture("getSmartPressState")
    capture("getSmartTuningSnapshot")
    capture("getTelemetryStats")
    capture("getDiagnosticsReport")

    return snapshots
end

local function computeScenarioSummary(results: {any})
    local totalDuration = 0
    local totalParries = 0
    local totalRemote = 0
    local totalWarnings = 0

    for _, entry in ipairs(results) do
        totalDuration += entry.duration or 0
        local metrics = entry.metrics or {}
        totalParries += metrics.parries or 0
        totalRemote += metrics.remoteEvents or 0
        totalWarnings += (#(entry.warnings or {}))
    end

    return {
        generated = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        scenarios = #results,
        totalDuration = totalDuration,
        totalParries = totalParries,
        totalRemoteEvents = totalRemote,
        totalWarnings = totalWarnings,
    }
end

local function sortModules(modules: {ModuleScript})
    table.sort(modules, function(a, b)
        return string.lower(a.Name) < string.lower(b.Name)
    end)
end

function Runner.listScenarioModules(): {ModuleScript}
    local folder = ensureScenarioFolder()
    local modules: {ModuleScript} = {}
    for _, child in ipairs(folder:GetChildren()) do
        if child:IsA("ModuleScript") then
            table.insert(modules, child)
        end
    end
    sortModules(modules)
    return modules
end

local function runTimelineEvent(context: any, event: {[string]: any}, log: {any}, metrics: {[string]: number}, warnings: {string})
    local autoparry = context.autoparry
    local eventType = event.event
    if eventType == "spawn-threat" then
        metrics.threats = (metrics.threats or 0) + 1
        if context.world then
            context.world:addProjectile({
                position = event.position,
                velocity = event.velocity,
                attributes = event.attributes,
            })
        else
            context:addBall({
                position = event.position,
                velocity = event.velocity,
                attributes = event.attributes,
            })
        end
        table.insert(log, {
            time = event.time,
            type = "spawn-threat",
            details = {
                id = event.id,
                tags = event.tags,
            },
            notes = event.notes,
        })
    elseif eventType == "rule-toggle" then
        local ruleName = string.lower(tostring(event.rule or ""))
        local value = event.value
        if ruleName == "autoparry-enabled" then
            if autoparry and typeof(autoparry.setEnabled) == "function" then
                local ok, err = pcall(autoparry.setEnabled, value == true)
                if not ok then
                    table.insert(warnings, string.format("setEnabled failed: %s", tostring(err)))
                else
                    metrics.autopEnabled = (metrics.autopEnabled or 0) + 1
                end
            else
                table.insert(warnings, "AutoParry.setEnabled unavailable")
            end
        elseif ruleName == "highlight-gate" then
            if typeof(context.setHighlightEnabled) == "function" then
                context:setHighlightEnabled(value ~= false)
                metrics.highlightToggles = (metrics.highlightToggles or 0) + 1
            else
                table.insert(warnings, "Context.setHighlightEnabled unavailable")
            end
        elseif ruleName == "balls-folder-present" then
            local container = context.remotes and context.remotes.Parent
            if container and typeof(container.Add) == "function" and typeof(container.Remove) == "function" then
                if value then
                    container:Add(context.ballsFolder)
                else
                    container:Remove(context.ballsFolder.Name)
                end
            else
                table.insert(warnings, "ReplicatedStorage container does not support Add/Remove for balls folder")
            end
        else
            table.insert(warnings, string.format("Unhandled rule '%s'", tostring(event.rule)))
        end
        table.insert(log, {
            time = event.time,
            type = "rule-toggle",
            rule = event.rule,
            value = value,
            notes = event.notes,
        })
    elseif eventType == "player-action" then
        local action = tostring(event.action or "")
        local parameters = event.parameters or {}
        if action == "configure" then
            if autoparry and typeof(autoparry.getConfig) == "function" and typeof(autoparry.configure) == "function" then
                local defaults = autoparry.getConfig()
                local resolved = resolveRelativeOverrides(defaults, parameters.overrides or {}, warnings)
                local ok, err = pcall(autoparry.configure, resolved)
                if not ok then
                    table.insert(warnings, string.format("configure failed: %s", tostring(err)))
                end
            else
                table.insert(warnings, "AutoParry.configure unavailable")
            end
        elseif action == "configure-invalid" then
            if autoparry and typeof(autoparry.getConfig) == "function" and typeof(autoparry.configure) == "function" then
                local defaults = autoparry.getConfig()
                local resolved = resolveRelativeOverrides(defaults, parameters.overrides or {}, warnings)
                local ok, err = pcall(autoparry.configure, resolved)
                if ok then
                    table.insert(warnings, "configure-invalid overrides were accepted unexpectedly")
                end
            else
                table.insert(warnings, "AutoParry.configure unavailable")
            end
        elseif action == "reset-config" then
            if autoparry and typeof(autoparry.resetConfig) == "function" then
                local ok, err = pcall(autoparry.resetConfig)
                if not ok then
                    table.insert(warnings, string.format("resetConfig failed: %s", tostring(err)))
                end
            else
                table.insert(warnings, "AutoParry.resetConfig unavailable")
            end
        elseif action == "observe-telemetry" then
            local duration = tonumber(event.duration or parameters.duration or 0) or 0
            if duration > 0 then
                context:advance(duration, { step = 1 / 240 })
            end
        else
            table.insert(warnings, string.format("Unhandled player action '%s'", action))
        end
        table.insert(log, {
            time = event.time,
            type = "player-action",
            action = action,
            details = sanitiseValue(parameters),
            notes = event.notes,
        })
    elseif eventType == "network" then
        local name = tostring(event.name or "")
        local payload = event.payload
        if name == "remotes:ParryButtonPress" then
            local available = true
            if typeof(payload) == "table" and payload.available ~= nil then
                available = payload.available == true
            end
            if available then
                if typeof(context.attachParryRemote) == "function" then
                    context:attachParryRemote()
                else
                    table.insert(warnings, "Context.attachParryRemote unavailable")
                end
            else
                if typeof(context.removeParryRemote) == "function" then
                    context:removeParryRemote()
                else
                    table.insert(warnings, "Context.removeParryRemote unavailable")
                end
            end
        else
            table.insert(warnings, string.format("Unhandled network event '%s'", name))
        end
        table.insert(log, {
            time = event.time,
            type = "network",
            payload = payload,
            notes = event.notes,
        })
    end
end

function Runner.runScenario(planEntry: {module: ModuleScript, plan: {[string]: any}}): {[string]: any}
    local plan = planEntry.plan
    local metadata = plan.metadata or {}
    local warnings: {string} = {}

    local context = Context.createContext({})
    local scheduler = context.scheduler
    local autoparry = context.autoparry

    if autoparry and typeof(autoparry.resetConfig) == "function" then
        local ok, err = pcall(autoparry.resetConfig)
        if not ok then
            table.insert(warnings, string.format("resetConfig failed: %s", tostring(err)))
        end
    end

    if plan.config and plan.config.autoparry and autoparry and typeof(autoparry.configure) == "function" then
        local ok, err = pcall(autoparry.configure, plan.config.autoparry)
        if not ok then
            table.insert(warnings, string.format("configure failed: %s", tostring(err)))
        end
    end

    if plan.intelligence then
        table.insert(warnings, "Scenario intelligence configuration is not currently applied in runner")
    end

    local eventsLog: {any} = {}
    local metrics: {[string]: number} = {
        parries = 0,
        remoteEvents = 0,
    }

    local previousTime = scheduler:clock()
    for _, event in ipairs(plan.events or {}) do
        local targetTime = math.max(event.time or 0, previousTime)
        local delta = targetTime - scheduler:clock()
        if delta > 0 then
            context:advance(delta, { step = 1 / 240 })
        end
        runTimelineEvent(context, event, eventsLog, metrics, warnings)
        previousTime = targetTime
    end

    context:advance(0.25, { step = 1 / 240 })

    local parryLog = sanitiseParryLog(context.parryLog or {})
    local remoteLog = sanitiseRemoteLog(context.remoteLog or {})
    local virtualInput = sanitiseVirtualInput(context.virtualInputLog or {})

    metrics.parries = #parryLog
    metrics.remoteEvents = #remoteLog

    local telemetry
    if context.world and typeof(context.world.exportTelemetry) == "function" then
        telemetry = sanitiseTelemetrySnapshot(context.world:exportTelemetry())
    end

    local projectiles
    if context.world and typeof(context.world.getProjectileSamples) == "function" then
        projectiles = sanitiseValue(context.world:getProjectileSamples())
    end

    local snapshots = captureSnapshots(context, warnings)

    local duration = scheduler:clock()

    local result = {
        id = metadata.id or planEntry.module.Name,
        label = metadata.label or planEntry.module.Name,
        tags = metadata.tags or {},
        description = metadata.description,
        history = metadata.history or {},
        duration = duration,
        metrics = metrics,
        events = sanitiseEvents(eventsLog),
        parryLog = parryLog,
        remoteLog = remoteLog,
        virtualInput = virtualInput,
        telemetry = telemetry,
        projectiles = projectiles,
        warnings = warnings,
        snapshots = snapshots,
        module = planEntry.module.Name,
    }

    local ok, err = pcall(context.destroy, context)
    if not ok then
        table.insert(result.warnings, string.format("Context cleanup failed: %s", tostring(err)))
    end

    return result
end

function Runner.runAll(): {any}
    local modules = Runner.listScenarioModules()
    local plans = {}
    for _, module in ipairs(modules) do
        local ok, plan = pcall(require, module)
        if not ok then
            error(string.format("Failed to load scenario module %s: %s", module.Name, tostring(plan)), 0)
        end
        if typeof(plan) ~= "table" then
            error(string.format("Scenario module %s did not return a table", module.Name), 0)
        end
        plans[#plans + 1] = {
            module = module,
            plan = plan,
        }
    end

    local results = {}
    for _, entry in ipairs(plans) do
        results[#results + 1] = Runner.runScenario(entry)
    end

    return results
end

function Runner.buildSimulationPayload(results: {any}): {[string]: any}
    return {
        run = computeScenarioSummary(results),
        scenarios = results,
    }
end

function Runner.buildReplayPayload(results: {any}): {[string]: any}
    local replays = {}
    for _, entry in ipairs(results) do
        replays[#replays + 1] = {
            id = entry.id,
            label = entry.label,
            duration = entry.duration,
            remoteLog = entry.remoteLog,
            virtualInput = entry.virtualInput,
            parryLog = entry.parryLog,
            events = entry.events,
            warnings = entry.warnings,
        }
    end
    return {
        run = computeScenarioSummary(results),
        replays = replays,
    }
end

function Runner.buildMetricsPayload(results: {any}): {[string]: any}
    local summary = computeScenarioSummary(results)
    local scenarios = {}
    for _, entry in ipairs(results) do
        scenarios[#scenarios + 1] = {
            id = entry.id,
            label = entry.label,
            metrics = entry.metrics,
            warnings = entry.warnings,
        }
    end
    return {
        run = summary,
        scenarios = scenarios,
    }
end

function Runner.emitArtifact(name: string, payload: {[string]: any})
    local encoded = HttpService:JSONEncode(payload)
    print(string.format("[ARTIFACT] %s %s", name, encoded))
end

return Runner
