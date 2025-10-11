--!strict

local ScenarioSchema = {}

export type Diagnostic = {
    path: string,
    message: string,
    severity: string?,
}

export type Vector3Like = {
    x: number,
    y: number,
    z: number,
}

export type ThreatSpawn = {
    position: Vector3Like,
    velocity: Vector3Like?,
    cframe: any?,
    attributes: { [string]: any }?,
}

export type ThreatDefinition = {
    id: string?,
    spawn: ThreatSpawn,
    tags: { string }?,
    metadata: { [string]: any }?,
}

export type PlayerEvent = {
    action: string,
    value: any?,
    duration: number?,
    parameters: { [string]: any }?,
}

export type NetworkEvent = {
    event: string,
    channel: string?,
    direction: string?,
    payload: { [string]: any }?,
}

export type RuleEvent = {
    rule: string,
    value: any,
    transition: string?,
    duration: number?,
}

export type TimelineEntry =
    | { kind: "threat", time: number, path: string, threat: ThreatDefinition, notes: string? }
    | { kind: "player", time: number, path: string, player: PlayerEvent, notes: string? }
    | { kind: "network", time: number, path: string, network: NetworkEvent, notes: string? }
    | { kind: "rule", time: number, path: string, rule: RuleEvent, notes: string? }
    | { kind: "macro", time: number, path: string, macro: string, options: { [string]: any }?, notes: string? }

export type Manifest = {
    version: number?,
    metadata: {
        id: string,
        label: string,
        description: string?,
        tags: { string }?,
        history: { string }?,
    },
    config: { [string]: any }?,
    timeline: { any },
}

export type ValidationResult = {
    version: number,
    metadata: Manifest["metadata"],
    config: { [string]: any }?,
    timeline: { TimelineEntry },
}

local DEFAULT_VERSION = 1

local function typeofSafe(value: any): string?
    local ok, result = pcall(function()
        -- selene: allow(undefined_variable)
        return typeof(value)
    end)

    if ok then
        return result
    end

    return nil
end

local function pushDiagnostic(diagnostics: { Diagnostic }, path: string, message: string, severity: string?)
    diagnostics[#diagnostics + 1] = {
        path = path,
        message = message,
        severity = severity or "error",
    }
end

local function deepCopy(value: any): any
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, child in pairs(value) do
        copy[key] = deepCopy(child)
    end
    return copy
end

local function normaliseMacroName(name: string): string
    local lowered = name:lower()
    lowered = lowered:gsub("[_%s]+", "-")
    lowered = lowered:gsub("[^%w%-]", "")
    return lowered
end

local function normaliseVector(path: string, value: any, diagnostics: { Diagnostic }): Vector3Like?
    if value == nil then
        pushDiagnostic(diagnostics, path, "expected vector components to be provided")
        return nil
    end

    local kind = type(value)
    if kind == "table" then
        local x = value.x or value.X or value[1]
        local y = value.y or value.Y or value[2]
        local z = value.z or value.Z or value[3]

        if type(x) == "number" and type(y) == "number" and type(z) == "number" then
            return { x = x, y = y, z = z }
        end

        pushDiagnostic(diagnostics, path, "vector tables must expose x, y, and z numbers")
        return nil
    end

    local luauType = typeofSafe(value)
    if luauType == "Vector3" then
        -- selene: allow(undefined_variable)
        local vector = value :: Vector3
        return { x = vector.X, y = vector.Y, z = vector.Z }
    end

    pushDiagnostic(diagnostics, path, string.format("expected vector table, received %s", luauType or type(value)))
    return nil
end

local function normaliseStringArray(path: string, value: any, diagnostics: { Diagnostic }): { string }?
    if value == nil then
        return nil
    end

    if type(value) ~= "table" then
        pushDiagnostic(diagnostics, path, string.format("expected array of strings, received %s", type(value)))
        return nil
    end

    local result = {}
    for index, entry in ipairs(value) do
        if type(entry) ~= "string" then
            pushDiagnostic(diagnostics, string.format("%s[%d]", path, index), string.format("expected string but received %s", type(entry)))
        elseif entry == "" then
            pushDiagnostic(diagnostics, string.format("%s[%d]", path, index), "string entries must not be empty")
        else
            result[#result + 1] = entry
        end
    end

    return result
end

local function normaliseThreat(path: string, value: any, diagnostics: { Diagnostic }): ThreatDefinition?
    if type(value) ~= "table" then
        pushDiagnostic(diagnostics, path, string.format("expected table describing threat, received %s", type(value)))
        return nil
    end

    local threatId: string? = nil
    if value.id ~= nil then
        if type(value.id) == "string" and value.id ~= "" then
            threatId = value.id
        else
            pushDiagnostic(diagnostics, path .. ".id", "threat id must be a non-empty string when provided")
        end
    end

    local spawnSource = value.spawn or value
    if type(spawnSource) ~= "table" then
        pushDiagnostic(diagnostics, path .. ".spawn", "threat requires spawn information")
        return nil
    end

    local position = normaliseVector(path .. ".spawn.position", spawnSource.position, diagnostics)
    if not position then
        return nil
    end

    local spawn: ThreatSpawn = { position = position }

    if spawnSource.velocity ~= nil then
        local velocity = normaliseVector(path .. ".spawn.velocity", spawnSource.velocity, diagnostics)
        if velocity then
            spawn.velocity = velocity
        end
    end

    if spawnSource.cframe ~= nil then
        spawn.cframe = spawnSource.cframe
    end

    if spawnSource.attributes ~= nil then
        if type(spawnSource.attributes) == "table" then
            spawn.attributes = deepCopy(spawnSource.attributes)
        else
            pushDiagnostic(diagnostics, path .. ".spawn.attributes", "attributes must be a table when provided")
        end
    end

    local threat: ThreatDefinition = {
        id = threatId,
        spawn = spawn,
        tags = nil,
        metadata = nil,
    }

    local tags = normaliseStringArray(path .. ".tags", value.tags, diagnostics)
    if tags then
        threat.tags = tags
    end

    if value.metadata ~= nil then
        if type(value.metadata) == "table" then
            threat.metadata = deepCopy(value.metadata)
        else
            pushDiagnostic(diagnostics, path .. ".metadata", "metadata must be a table when provided")
        end
    end

    return threat
end

local function normalisePlayer(path: string, value: any, diagnostics: { Diagnostic }): PlayerEvent?
    if type(value) ~= "table" then
        pushDiagnostic(diagnostics, path, string.format("expected table describing player event, received %s", type(value)))
        return nil
    end

    local action = value.action
    if type(action) ~= "string" or action == "" then
        pushDiagnostic(diagnostics, path .. ".action", "player action must be a non-empty string")
        return nil
    end

    local event: PlayerEvent = {
        action = action,
        value = value.value,
        duration = nil,
        parameters = nil,
    }

    if value.duration ~= nil then
        local duration = tonumber(value.duration)
        if duration and duration >= 0 then
            event.duration = duration
        else
            pushDiagnostic(diagnostics, path .. ".duration", "player duration must be a non-negative number")
        end
    end

    if value.parameters ~= nil then
        if type(value.parameters) == "table" then
            event.parameters = deepCopy(value.parameters)
        else
            pushDiagnostic(diagnostics, path .. ".parameters", "player parameters must be a table when provided")
        end
    end

    return event
end

local function normaliseNetwork(path: string, value: any, diagnostics: { Diagnostic }): NetworkEvent?
    if type(value) ~= "table" then
        pushDiagnostic(diagnostics, path, string.format("expected table describing network event, received %s", type(value)))
        return nil
    end

    local eventName = value.event
    if type(eventName) ~= "string" or eventName == "" then
        pushDiagnostic(diagnostics, path .. ".event", "network event requires a non-empty event name")
        return nil
    end

    local event: NetworkEvent = {
        event = eventName,
        channel = nil,
        direction = nil,
        payload = nil,
    }

    if value.channel ~= nil and type(value.channel) ~= "string" then
        pushDiagnostic(diagnostics, path .. ".channel", "network channel must be a string when provided")
    else
        event.channel = value.channel
    end

    if value.direction ~= nil and type(value.direction) ~= "string" then
        pushDiagnostic(diagnostics, path .. ".direction", "network direction must be a string when provided")
    else
        event.direction = value.direction
    end

    if value.payload ~= nil then
        if type(value.payload) == "table" then
            event.payload = deepCopy(value.payload)
        else
            pushDiagnostic(diagnostics, path .. ".payload", "network payload must be a table when provided")
        end
    end

    return event
end

local function normaliseRule(path: string, value: any, diagnostics: { Diagnostic }): RuleEvent?
    if type(value) ~= "table" then
        pushDiagnostic(diagnostics, path, string.format("expected table describing rule event, received %s", type(value)))
        return nil
    end

    local ruleName = value.rule or value.name or value.id
    if type(ruleName) ~= "string" or ruleName == "" then
        pushDiagnostic(diagnostics, path .. ".rule", "rule events require a non-empty rule name")
        return nil
    end

    if value.value == nil then
        pushDiagnostic(diagnostics, path .. ".value", "rule events require a value to toggle to")
        return nil
    end

    local event: RuleEvent = {
        rule = ruleName,
        value = value.value,
        transition = nil,
        duration = nil,
    }

    if value.transition ~= nil then
        if type(value.transition) == "string" and value.transition ~= "" then
            event.transition = value.transition
        else
            pushDiagnostic(diagnostics, path .. ".transition", "transition must be a non-empty string when provided")
        end
    end

    if value.duration ~= nil then
        local duration = tonumber(value.duration)
        if duration and duration >= 0 then
            event.duration = duration
        else
            pushDiagnostic(diagnostics, path .. ".duration", "duration must be a non-negative number when provided")
        end
    end

    return event
end

local function normaliseTimelineEntry(index: number, entry: any, diagnostics: { Diagnostic }): TimelineEntry?
    local path = string.format("manifest.timeline[%d]", index)

    if type(entry) ~= "table" then
        pushDiagnostic(diagnostics, path, string.format("expected table entry, received %s", type(entry)))
        return nil
    end

    local timeValue = entry.time
    if timeValue == nil then
        pushDiagnostic(diagnostics, path .. ".time", "timeline entries require a time value")
        return nil
    end

    local timeNumber = tonumber(timeValue)
    if timeNumber == nil then
        pushDiagnostic(diagnostics, path .. ".time", "time must be a number")
        return nil
    end

    if timeNumber < 0 then
        pushDiagnostic(diagnostics, path .. ".time", "time must be non-negative", "warning")
    end

    local notes
    if entry.notes ~= nil then
        if type(entry.notes) == "string" then
            notes = entry.notes
        else
            pushDiagnostic(diagnostics, path .. ".notes", "notes must be a string when provided")
        end
    end

    local entryType: string? = nil
    if type(entry.type) == "string" then
        entryType = entry.type
    elseif type(entry.kind) == "string" then
        entryType = entry.kind
    elseif type(entry.macro) == "string" then
        entryType = "macro"
    elseif entry.threat ~= nil then
        entryType = "threat"
    elseif entry.player ~= nil then
        entryType = "player"
    elseif entry.network ~= nil then
        entryType = "network"
    elseif entry.rule ~= nil then
        entryType = "rule"
    end

    if not entryType then
        pushDiagnostic(diagnostics, path .. ".type", "timeline entry must declare a type, kind, or recognised payload")
        return nil
    end

    entryType = entryType:lower()

    if entryType == "macro" then
        local macroName = entry.macro
        if type(macroName) ~= "string" or macroName == "" then
            pushDiagnostic(diagnostics, path .. ".macro", "macro entries require a non-empty name")
            return nil
        end

        local options
        if entry.options ~= nil then
            if type(entry.options) == "table" then
                options = deepCopy(entry.options)
            else
                pushDiagnostic(diagnostics, path .. ".options", "macro options must be a table when provided")
            end
        end

        return {
            kind = "macro",
            time = timeNumber,
            path = path,
            macro = normaliseMacroName(macroName),
            options = options,
            notes = notes,
        }
    elseif entryType == "threat" then
        local threat = normaliseThreat(path .. ".threat", entry.threat or entry, diagnostics)
        if threat then
            return {
                kind = "threat",
                time = timeNumber,
                path = path,
                threat = threat,
                notes = notes,
            }
        end
    elseif entryType == "player" then
        local player = normalisePlayer(path .. ".player", entry.player or entry, diagnostics)
        if player then
            return {
                kind = "player",
                time = timeNumber,
                path = path,
                player = player,
                notes = notes,
            }
        end
    elseif entryType == "network" then
        local network = normaliseNetwork(path .. ".network", entry.network or entry, diagnostics)
        if network then
            return {
                kind = "network",
                time = timeNumber,
                path = path,
                network = network,
                notes = notes,
            }
        end
    elseif entryType == "rule" then
        local ruleSource
        if type(entry.rule) == "table" then
            ruleSource = entry.rule
        else
            ruleSource = {
                rule = entry.rule,
                value = entry.value,
                transition = entry.transition,
                duration = entry.duration,
            }
        end

        local rule = normaliseRule(path .. ".rule", ruleSource, diagnostics)
        if rule then
            return {
                kind = "rule",
                time = timeNumber,
                path = path,
                rule = rule,
                notes = notes,
            }
        end
    else
        pushDiagnostic(diagnostics, path .. ".type", string.format("unrecognised timeline type '%s'", entryType))
    end

    return nil
end

function ScenarioSchema.validate(manifest: any): (boolean, ValidationResult?, { Diagnostic })
    local diagnostics: { Diagnostic } = {}

    if type(manifest) ~= "table" then
        pushDiagnostic(diagnostics, "manifest", string.format("expected table manifest, received %s", type(manifest)))
        return false, nil, diagnostics
    end

    local version = manifest.version
    if version == nil then
        version = DEFAULT_VERSION
    elseif type(version) ~= "number" then
        pushDiagnostic(diagnostics, "manifest.version", "scenario version must be a number")
        version = DEFAULT_VERSION
    elseif version ~= DEFAULT_VERSION then
        pushDiagnostic(
            diagnostics,
            "manifest.version",
            string.format("unsupported scenario version %s (expected %d)", tostring(version), DEFAULT_VERSION)
        )
    end

    local metadataValue = manifest.metadata
    if type(metadataValue) ~= "table" then
        pushDiagnostic(diagnostics, "manifest.metadata", "scenario metadata must be provided as a table")
        metadataValue = {}
    end

    local id = metadataValue.id
    if type(id) ~= "string" or id == "" then
        pushDiagnostic(diagnostics, "manifest.metadata.id", "scenario metadata requires a non-empty id")
        id = ""
    end

    local label = metadataValue.label
    if type(label) ~= "string" or label == "" then
        pushDiagnostic(diagnostics, "manifest.metadata.label", "scenario metadata requires a non-empty label")
        label = ""
    end

    local description: string? = nil
    if metadataValue.description ~= nil then
        if type(metadataValue.description) == "string" then
            description = metadataValue.description
        else
            pushDiagnostic(diagnostics, "manifest.metadata.description", "description must be a string when provided")
        end
    end

    local tags = normaliseStringArray("manifest.metadata.tags", metadataValue.tags, diagnostics)
    local history = normaliseStringArray("manifest.metadata.history", metadataValue.history, diagnostics)

    local metadata = {
        id = id,
        label = label,
        description = description,
        tags = tags,
        history = history,
    }

    local config
    if manifest.config ~= nil then
        if type(manifest.config) == "table" then
            config = deepCopy(manifest.config)
        else
            pushDiagnostic(diagnostics, "manifest.config", "config must be a table when provided")
        end
    end

    local timelineRaw = manifest.timeline
    if type(timelineRaw) ~= "table" then
        pushDiagnostic(diagnostics, "manifest.timeline", "timeline must be provided as an array of entries")
        timelineRaw = {}
    end

    local timeline: { TimelineEntry } = {}
    for index, entry in ipairs(timelineRaw) do
        local normalised = normaliseTimelineEntry(index, entry, diagnostics)
        if normalised then
            timeline[#timeline + 1] = normalised
        end
    end

    if #timeline == 0 then
        pushDiagnostic(diagnostics, "manifest.timeline", "timeline must contain at least one valid entry")
    else
        table.sort(timeline, function(a, b)
            if a.time == b.time then
                return a.path < b.path
            end
            return a.time < b.time
        end)
    end

    local hasErrors = false
    for _, diagnostic in ipairs(diagnostics) do
        if diagnostic.severity == nil or diagnostic.severity == "error" then
            hasErrors = true
            break
        end
    end

    local result: ValidationResult = {
        version = version,
        metadata = metadata,
        config = config,
        timeline = timeline,
    }

    return not hasErrors, result, diagnostics
end

return ScenarioSchema
