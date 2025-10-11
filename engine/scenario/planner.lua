--!strict

local Schema = require(script.Parent.schema)

export type Diagnostic = Schema.Diagnostic
export type ValidationResult = Schema.ValidationResult
export type TimelineEntry = Schema.TimelineEntry

export type PlannerOptions = {
    vectorFactory: ((number, number, number) -> any)?,
}

export type PlannedEvent = {
    time: number,
    event: string,
    notes: string?,
    [string]: any,
}

export type PlannedScenario = {
    version: number,
    metadata: ValidationResult["metadata"],
    config: { [string]: any }?,
    events: { PlannedEvent },
}

local Planner = {}

local function pushDiagnostic(diagnostics: { Diagnostic }, path: string, message: string, severity: string?)
    diagnostics[#diagnostics + 1] = {
        path = path,
        message = message,
        severity = severity or "error",
    }
end

local function toVector3Like(vector: Schema.Vector3Like, options: PlannerOptions?): any
    local x = vector.x
    local y = vector.y
    local z = vector.z

    if options and options.vectorFactory then
        return options.vectorFactory(x, y, z)
    end

    local ok, result = pcall(function()
        -- selene: allow(undefined_variable)
        return Vector3.new(x, y, z)
    end)

    if ok then
        return result
    end

    return { x = x, y = y, z = z }
end

local MacroLibrary: { [string]: (TimelineEntry, PlannerOptions?, { Diagnostic }) -> { PlannedEvent } } = {}

local function registerMacro(names: { string }, handler: (TimelineEntry, PlannerOptions?, { Diagnostic }) -> { PlannedEvent })
    for _, name in ipairs(names) do
        local normalised = name:lower():gsub("[_%s]+", "-")
        MacroLibrary[normalised] = handler
    end
end

registerMacro({ "oscillation storm", "oscillation-storm", "oscillation_storm" }, function(entry, _options, diagnostics)
    local context = entry.options or {}
    local duration = tonumber(context.duration) or 0
    local frequency = tonumber(context.frequencyHz) or 0
    local ruleName = (context.rule and tostring(context.rule)) or "highlight"
    local values = context.values

    if duration <= 0 then
        pushDiagnostic(
            diagnostics,
            entry.path .. ".options.duration",
            "oscillation storm requires a positive duration",
            "warning"
        )
        duration = 0.2
    end

    if frequency <= 0 then
        pushDiagnostic(
            diagnostics,
            entry.path .. ".options.frequencyHz",
            "oscillation storm requires a positive frequency",
            "warning"
        )
        frequency = 18
    end

    local toggleValues: { any }
    if type(values) == "table" and #values > 0 then
        toggleValues = {}
        for index = 1, #values do
            toggleValues[index] = values[index]
        end
    else
        toggleValues = { true, false }
    end

    local halfPeriod = 0.5 / frequency
    local steps = math.max(math.floor(duration / halfPeriod + 0.5), 1)
    local currentTime = entry.time
    local toggleIndex = 1

    local events: { PlannedEvent } = {}
    for step = 1, steps do
        events[#events + 1] = {
            time = currentTime,
            event = "rule-toggle",
            rule = ruleName,
            value = toggleValues[toggleIndex],
            notes = entry.notes or string.format("oscillation storm toggle %d", step),
            macro = "oscillation-storm",
        }

        currentTime = currentTime + halfPeriod
        toggleIndex = toggleIndex + 1
        if toggleIndex > #toggleValues then
            toggleIndex = 1
        end
    end

    return events
end)

registerMacro({ "hitch gauntlet", "hitch-gauntlet", "hitch_gauntlet" }, function(entry, _options, diagnostics)
    local context = entry.options or {}
    local count = math.max(tonumber(context.count) or 0, 0)
    local interval = tonumber(context.interval) or 0
    local magnitude = tonumber(context.magnitude) or 0

    if count == 0 then
        pushDiagnostic(diagnostics, entry.path .. ".options.count", "hitch gauntlet requires a positive count", "warning")
        count = 1
    end

    if interval <= 0 then
        pushDiagnostic(
            diagnostics,
            entry.path .. ".options.interval",
            "hitch gauntlet interval must be positive",
            "warning"
        )
        interval = 0.25
    end

    if magnitude <= 0 then
        pushDiagnostic(
            diagnostics,
            entry.path .. ".options.magnitude",
            "hitch gauntlet magnitude must be positive",
            "warning"
        )
        magnitude = 0.18
    end

    local events: { PlannedEvent } = {}
    local timeCursor = entry.time

    for index = 1, count do
        events[#events + 1] = {
            time = timeCursor,
            event = "player-action",
            action = "inject-hitch",
            duration = magnitude,
            notes = entry.notes or string.format("hitch gauntlet hitch %d", index),
            macro = "hitch-gauntlet",
        }
        timeCursor = timeCursor + interval
    end

    return events
end)

local function expandEntry(entry: TimelineEntry, options: PlannerOptions?, diagnostics: { Diagnostic }): { PlannedEvent }
    if entry.kind == "macro" then
        local handler = MacroLibrary[entry.macro]
        if not handler then
            pushDiagnostic(diagnostics, entry.path .. ".macro", string.format("unknown macro '%s'", entry.macro))
            return {}
        end

        local ok, result = pcall(handler, entry, options, diagnostics)
        if not ok then
            pushDiagnostic(diagnostics, entry.path .. ".macro", string.format("failed to expand macro: %s", tostring(result)))
            return {}
        end

        return result
    elseif entry.kind == "threat" then
        local threat = entry.threat
        local spawn = threat.spawn

        local planned: PlannedEvent = {
            time = entry.time,
            event = "spawn-threat",
            id = threat.id,
            tags = threat.tags,
            metadata = threat.metadata,
            notes = entry.notes,
        }

        planned.position = toVector3Like(spawn.position, options)

        if spawn.velocity then
            planned.velocity = toVector3Like(spawn.velocity, options)
        end

        if spawn.cframe ~= nil then
            planned.cframe = spawn.cframe
        end

        if spawn.attributes ~= nil then
            planned.attributes = spawn.attributes
        end

        return { planned }
    elseif entry.kind == "player" then
        local player = entry.player
        return { {
            time = entry.time,
            event = "player-action",
            action = player.action,
            value = player.value,
            duration = player.duration,
            parameters = player.parameters,
            notes = entry.notes,
        } }
    elseif entry.kind == "network" then
        local network = entry.network
        return { {
            time = entry.time,
            event = "network",
            name = network.event,
            channel = network.channel,
            direction = network.direction,
            payload = network.payload,
            notes = entry.notes,
        } }
    elseif entry.kind == "rule" then
        local rule = entry.rule
        return { {
            time = entry.time,
            event = "rule-toggle",
            rule = rule.rule,
            value = rule.value,
            transition = rule.transition,
            duration = rule.duration,
            notes = entry.notes,
        } }
    end

    return {}
end

function Planner.plan(manifest: any, options: PlannerOptions?): (boolean, PlannedScenario?, { Diagnostic })
    local valid, normalised, schemaDiagnostics = Schema.validate(manifest)
    if not valid or not normalised then
        return false, nil, schemaDiagnostics
    end

    local diagnostics: { Diagnostic } = {}
    local events: { PlannedEvent } = {}
    local order = 0

    for _, entry in ipairs(normalised.timeline) do
        local expanded = expandEntry(entry, options, diagnostics)
        for _, event in ipairs(expanded) do
            order = order + 1
            event._order = order
            events[#events + 1] = event
        end
    end

    table.sort(events, function(a, b)
        if a.time == b.time then
            return (a._order or 0) < (b._order or 0)
        end
        return a.time < b.time
    end)

    for _, event in ipairs(events) do
        event._order = nil
    end

    local plan: PlannedScenario = {
        version = normalised.version,
        metadata = normalised.metadata,
        config = normalised.config,
        events = events,
    }

    local combinedDiagnostics: { Diagnostic } = {}
    local hasErrors = false

    local function appendDiagnostics(source: { Diagnostic })
        for _, diagnostic in ipairs(source) do
            if diagnostic.severity == nil or diagnostic.severity == "error" then
                hasErrors = true
            end
            combinedDiagnostics[#combinedDiagnostics + 1] = diagnostic
        end
    end

    appendDiagnostics(schemaDiagnostics)
    appendDiagnostics(diagnostics)

    return not hasErrors, plan, combinedDiagnostics
end

return Planner
