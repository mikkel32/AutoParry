--!strict

local Exporter = {}
Exporter.__index = Exporter

Exporter.VERSION = 1
Exporter.TRACE_VERSION = 1

export type TelemetryEvent = { [string]: any }
export type TelemetrySnapshot = {
    sequence: number?,
    history: { TelemetryEvent }?,
    activationLatency: number?,
    remoteLatencyActive: boolean?,
    lastEvent: TelemetryEvent?,
    smartTuning: { [string]: any }?,
    stats: { [string]: any }?,
    adaptiveState: { [string]: any }?,
}

export type DiagnosticsSnapshot = { [string]: any }
export type SmartTuningSnapshot = { [string]: any }
export type ParryLogEntry = {
    timestamp: number?,
    ball: any,
}

export type TelemetryPayload = {
    version: number,
    generatedAt: number?,
    metadata: { [string]: any }?,
    telemetry: TelemetrySnapshot?,
    smartTuning: SmartTuningSnapshot?,
    diagnostics: DiagnosticsSnapshot?,
    parryLog: { ParryLogEntry }?,
    events: { TelemetryEvent }?,
}

export type TraceStep = {
    t: number?,
    agents: { [number]: { [string]: any } }?,
    projectiles: { [number]: { [string]: any } }?,
    rules: any?,
}

export type TracePayload = {
    version: number,
    agents: { string }?,
    projectiles: { string }?,
    rules: { string }?,
    steps: { any },
    metadata: { [string]: any }?,
}

export type Writer = (path: string, contents: string) -> (boolean, string?)

export type ExportOptions = {
    runId: string?,
    artifactRoot: string?,
    writer: Writer?,
    generatedAt: number?,
    metadata: { [string]: any }?,
    telemetry: TelemetrySnapshot?,
    smartTuning: SmartTuningSnapshot?,
    diagnostics: DiagnosticsSnapshot?,
    parryLog: { ParryLogEntry }?,
    events: { TelemetryEvent }?,
    steps: { TraceStep }?,
    trace: TracePayload?,
    traceMetadata: { [string]: any }?,
}

local function now(): number
    local ok, value = pcall(os.clock)
    if ok and type(value) == "number" then
        return value
    end
    ok, value = pcall(tick)
    if ok and type(value) == "number" then
        return value
    end
    return 0
end

local function isArray(value: { [any]: any }): (boolean, number)
    local count = 0
    local maxIndex = 0
    for key in pairs(value) do
        if type(key) ~= "number" then
            return false, 0
        end
        if key > maxIndex then
            maxIndex = key
        end
        count += 1
    end
    if maxIndex == 0 then
        return true, 0
    end
    return maxIndex == count, maxIndex
end

local function sanitizeValue(value: any, visited: { [table]: boolean }?): any
    local valueType = typeof(value)

    if valueType == "Vector3" then
        return { x = value.X, y = value.Y, z = value.Z }
    elseif valueType == "Vector2" then
        return { x = value.X, y = value.Y }
    elseif valueType == "CFrame" then
        local components = { value:GetComponents() }
        return { cframe = components }
    elseif valueType == "Color3" then
        return { r = value.R, g = value.G, b = value.B }
    elseif valueType == "UDim2" then
        return {
            x = { scale = value.X.Scale, offset = value.X.Offset },
            y = { scale = value.Y.Scale, offset = value.Y.Offset },
        }
    elseif valueType == "NumberRange" then
        return { min = value.Min, max = value.Max }
    elseif valueType == "NumberSequence" then
        local keypoints = value.Keypoints
        local points = table.create(#keypoints)
        for index, keypoint in ipairs(keypoints) do
            points[index] = {
                time = keypoint.Time,
                value = keypoint.Value,
                envelope = keypoint.Envelope,
            }
        end
        return { keypoints = points }
    elseif valueType == "DateTime" then
        return {
            unix = value.UnixTimestamp,
            unixMillis = value.UnixTimestampMillis,
        }
    elseif valueType == "EnumItem" then
        return tostring(value)
    elseif valueType == "Instance" then
        return {
            className = value.ClassName,
            name = value.Name,
        }
    elseif valueType == "table" then
        visited = visited or {}
        if visited[value] then
            return "<cycle>"
        end
        visited[value] = true

        local result
        local asArray, length = isArray(value)
        if asArray then
            result = table.create(length)
            for index = 1, length do
                result[index] = sanitizeValue(value[index], visited)
            end
        else
            result = {}
            for key, item in pairs(value) do
                local keyType = typeof(key)
                if keyType == "string" or keyType == "number" then
                    local itemType = typeof(item)
                    if itemType ~= "function" and itemType ~= "thread" then
                        result[key] = sanitizeValue(item, visited)
                    end
                end
            end
        end

        visited[value] = nil
        return result
    end

    if valueType == "function" or valueType == "userdata" or valueType == "thread" then
        return tostring(value)
    end

    return value
end

local function sanitizeEvents(events: { TelemetryEvent }?): { TelemetryEvent }
    if typeof(events) ~= "table" then
        return {}
    end

    local sanitized = table.create(#events)
    for index, event in ipairs(events) do
        sanitized[index] = sanitizeValue(event)
    end
    return sanitized
end

local function sanitizeParryLog(parryLog: { ParryLogEntry }?): { ParryLogEntry }
    if typeof(parryLog) ~= "table" then
        return {}
    end

    local sanitized = {}
    for index, entry in ipairs(parryLog) do
        local ball = entry.ball
        local payload
        if typeof(ball) == "table" then
            payload = {
                name = ball.Name,
                position = sanitizeValue(ball.Position),
                velocity = sanitizeValue(ball.AssemblyLinearVelocity),
            }
        else
            payload = sanitizeValue(ball)
        end

        sanitized[index] = {
            timestamp = entry.timestamp,
            ball = payload,
        }
    end

    return sanitized
end

local function sanitizeTelemetrySnapshot(snapshot: TelemetrySnapshot?): TelemetrySnapshot
    if typeof(snapshot) ~= "table" then
        return snapshot
    end

    local sanitized: TelemetrySnapshot = {}

    for key, value in pairs(snapshot :: any) do
        sanitized[key] = sanitizeValue(value)
    end

    if snapshot.history then
        sanitized.history = sanitizeEvents(snapshot.history)
    end

    if snapshot.lastEvent then
        sanitized.lastEvent = sanitizeValue(snapshot.lastEvent)
    end

    if snapshot.smartTuning then
        sanitized.smartTuning = sanitizeValue(snapshot.smartTuning)
    end

    if snapshot.stats then
        sanitized.stats = sanitizeValue(snapshot.stats)
    end

    if snapshot.adaptiveState then
        sanitized.adaptiveState = sanitizeValue(snapshot.adaptiveState)
    end

    return sanitized
end

local function cloneTable<T>(source: T): T
    if type(source) ~= "table" then
        return source
    end
    local copy: any = {}
    for key, value in pairs(source :: any) do
        copy[key] = cloneTable(value)
    end
    return copy
end

local function encodeJSONString(value: string): string
    value = value:gsub("\\", "\\\\")
    value = value:gsub('"', '\\"')
    value = value:gsub("\b", "\\b")
    value = value:gsub("\f", "\\f")
    value = value:gsub("\n", "\\n")
    value = value:gsub("\r", "\\r")
    value = value:gsub("\t", "\\t")
    return '"' .. value .. '"'
end

local function encodeJSON(value: any): string
    local valueType = type(value)

    if valueType == "string" then
        return encodeJSONString(value)
    elseif valueType == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return "null"
        end
        return tostring(value)
    elseif valueType == "boolean" then
        return tostring(value)
    elseif value == nil then
        return "null"
    elseif valueType == "table" then
        local asArray, length = isArray(value)
        if asArray then
            local entries = table.create(length)
            for index = 1, length do
                entries[index] = encodeJSON(value[index])
            end
            return "[" .. table.concat(entries, ",") .. "]"
        end

        local entries = {}
        for key, entryValue in pairs(value) do
            local keyType = type(key)
            if keyType == "string" or keyType == "number" then
                local encodedKey = encodeJSONString(tostring(key))
                entries[#entries + 1] = encodedKey .. ":" .. encodeJSON(entryValue)
            end
        end
        table.sort(entries)
        return "{" .. table.concat(entries, ",") .. "}"
    end

    return "null"
end

local function ensureDirectory(path: string?): boolean
    if type(path) ~= "string" or path == "" then
        return false
    end

    local ok, packageConfig = pcall(function()
        return package.config
    end)

    local isWindows = ok and type(packageConfig) == "string" and packageConfig:sub(1, 1) == "\\"
    local command

    if isWindows then
        command = string.format('if not exist "%s" mkdir "%s"', path, path)
    else
        command = string.format('mkdir -p "%s"', path)
    end

    local success, result = pcall(function()
        return os.execute(command)
    end)

    if not success then
        return false
    end

    if type(result) == "number" then
        return result == 0
    end

    if type(result) == "boolean" then
        return result
    end

    return false
end

local function defaultWriter(path: string, contents: string): (boolean, string?)
    local ok, handle = pcall(io.open, path, "w")
    if not ok or not handle then
        return false, "unable to open file for writing"
    end

    handle:write(contents)
    handle:close()
    return true, nil
end

local function vectorComponents(value: any): (number, number, number)
    if typeof(value) == "Vector3" then
        return value.X, value.Y, value.Z
    end
    if typeof(value) == "Vector2" then
        return value.X, value.Y, 0
    end
    if typeof(value) == "table" then
        local x = tonumber(value.x) or tonumber(value.X) or 0
        local y = tonumber(value.y) or tonumber(value.Y) or 0
        local z = tonumber(value.z) or tonumber(value.Z) or 0
        return x, y, z
    end
    return 0, 0, 0
end

local function createRegistry()
    return {
        order = {},
        map = {},
    }
end

local function registryIndex(registry, name): number
    local key = tostring(name or "")
    local index = registry.map[key]
    if index then
        return index
    end

    registry.order[#registry.order + 1] = key
    index = #registry.order
    registry.map[key] = index
    return index
end

local function sanitizeRuleRecords(registry, rules): { any }
    local entries = {}

    if typeof(rules) ~= "table" then
        return entries
    end

    if #rules > 0 then
        for _, entry in ipairs(rules) do
            if typeof(entry) == "table" then
                local name = entry.name or entry.id or entry.rule
                local stateValue = entry.state
                if stateValue == nil then
                    stateValue = entry.value
                end
                if name ~= nil then
                    local index = registryIndex(registry, name)
                    entries[#entries + 1] = { index, sanitizeValue(stateValue) }
                end
            end
        end
        return entries
    end

    for name, value in pairs(rules) do
        local index = registryIndex(registry, name)
        entries[#entries + 1] = { index, sanitizeValue(value) }
    end

    table.sort(entries, function(a, b)
        return a[1] < b[1]
    end)

    return entries
end

function Exporter.sanitizeValue(value: any): any
    return sanitizeValue(value)
end

function Exporter.buildPayload(options: ExportOptions?): TelemetryPayload
    options = options or {}

    local payload: TelemetryPayload = {
        version = Exporter.VERSION,
    }

    if options.generatedAt then
        payload.generatedAt = options.generatedAt
    else
        payload.generatedAt = now()
    end

    if options.metadata then
        payload.metadata = sanitizeValue(options.metadata)
    end

    if options.telemetry then
        payload.telemetry = sanitizeTelemetrySnapshot(options.telemetry)
    end

    if options.smartTuning then
        payload.smartTuning = sanitizeValue(options.smartTuning)
    elseif options.telemetry and options.telemetry.smartTuning then
        payload.smartTuning = sanitizeValue(options.telemetry.smartTuning)
    end

    if options.diagnostics then
        payload.diagnostics = sanitizeValue(options.diagnostics)
    end

    if options.parryLog then
        payload.parryLog = sanitizeParryLog(options.parryLog)
    end

    if options.events then
        payload.events = sanitizeEvents(options.events)
    elseif options.telemetry and options.telemetry.history then
        payload.events = sanitizeEvents(options.telemetry.history)
    end

    return payload
end

function Exporter.buildTrace(options: ExportOptions?): TracePayload
    options = options or {}

    if options.trace then
        local cloned = cloneTable(options.trace)
        cloned.version = cloned.version or Exporter.TRACE_VERSION
        if cloned.metadata then
            cloned.metadata = sanitizeValue(cloned.metadata)
        end
        return cloned
    end

    local steps = {}
    local agentRegistry = createRegistry()
    local projectileRegistry = createRegistry()
    local ruleRegistry = createRegistry()

    local providedSteps = options.steps or {}

    for _, step in ipairs(providedSteps) do
        local stepTime = 0
        if typeof(step) == "table" and step.t ~= nil then
            stepTime = tonumber(step.t) or 0
        end

        local agentEntries = {}
        if typeof(step) == "table" and typeof(step.agents) == "table" then
            for _, agent in ipairs(step.agents) do
                if typeof(agent) == "table" then
                    local index = registryIndex(agentRegistry, agent.name)
                    local px, py, pz = vectorComponents(agent.position)
                    local vx, vy, vz = vectorComponents(agent.velocity)
                    agentEntries[#agentEntries + 1] = { index, px, py, pz, vx, vy, vz }
                end
            end
        end

        local projectileEntries = {}
        if typeof(step) == "table" and typeof(step.projectiles) == "table" then
            for _, projectile in ipairs(step.projectiles) do
                if typeof(projectile) == "table" then
                    local index = registryIndex(projectileRegistry, projectile.name)
                    local px, py, pz = vectorComponents(projectile.position)
                    local vx, vy, vz = vectorComponents(projectile.velocity)
                    local contact = projectile.contact and 1 or 0
                    projectileEntries[#projectileEntries + 1] = { index, px, py, pz, vx, vy, vz, contact }
                end
            end
        end

        local ruleEntries = {}
        if typeof(step) == "table" and step.rules ~= nil then
            ruleEntries = sanitizeRuleRecords(ruleRegistry, step.rules)
        end

        steps[#steps + 1] = { stepTime, agentEntries, projectileEntries, ruleEntries }
    end

    local trace: TracePayload = {
        version = Exporter.TRACE_VERSION,
        steps = steps,
    }

    if #agentRegistry.order > 0 then
        trace.agents = agentRegistry.order
    end

    if #projectileRegistry.order > 0 then
        trace.projectiles = projectileRegistry.order
    end

    if #ruleRegistry.order > 0 then
        trace.rules = ruleRegistry.order
    end

    if options.traceMetadata then
        trace.metadata = sanitizeValue(options.traceMetadata)
    end

    return trace
end

function Exporter.encode(value: any): string
    return encodeJSON(value)
end

function Exporter.encodePayload(payload: TelemetryPayload): string
    return encodeJSON(payload)
end

function Exporter.encodeTrace(trace: TracePayload): string
    return encodeJSON(trace)
end

local function determinePaths(root: string, runId: string)
    local base = string.format("%s/%s", root, runId)
    return {
        payload = base .. "-observability.json",
        trace = base .. "-trace.json",
    }
end

function Exporter.writeArtifacts(options: ExportOptions?): (boolean, { [string]: string }?, string?)
    options = options or {}

    local runId = options.runId or "telemetry"
    if type(runId) ~= "string" or runId == "" then
        return false, nil, "run id missing"
    end

    local root = options.artifactRoot or "tests/artifacts/engine/telemetry"
    if type(root) ~= "string" or root == "" then
        return false, nil, "artifact root missing"
    end

    local writer = options.writer or defaultWriter

    if writer == defaultWriter and not ensureDirectory(root) then
        return false, nil, "failed to prepare artifact directory"
    end

    local payload = Exporter.buildPayload(options)
    payload.metadata = payload.metadata or sanitizeValue(options.metadata)

    local trace = Exporter.buildTrace(options)

    local payloadContents = encodeJSON(payload)
    local traceContents = encodeJSON(trace)

    local paths = determinePaths(root, runId)

    local ok, err = writer(paths.payload, payloadContents)
    if not ok then
        return false, nil, err
    end

    ok, err = writer(paths.trace, traceContents)
    if not ok then
        return false, nil, err
    end

    return true, paths, nil
end

return Exporter
