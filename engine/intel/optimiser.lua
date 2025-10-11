--!strict

local Optimiser = {}
Optimiser.__index = Optimiser

export type KnobState = {
    pressReactionBias: number,
    pressScheduleSlack: number,
    pressMaxLookahead: number,
}

export type Bounds = {
    pressReactionBias: { min: number, max: number },
    pressScheduleSlack: { min: number, max: number },
    pressMaxLookahead: { min: number, max: number },
}

export type Recommendation = {
    pressReactionBias: number?,
    pressReactionBiasDelta: number?,
    pressScheduleSlack: number?,
    pressScheduleSlackDelta: number?,
    pressMaxLookahead: number?,
    pressMaxLookaheadDelta: number?,
}

export type RecommendationRecord = {
    source: string,
    applied: KnobState,
    deltas: Recommendation?,
    metadata: { [string]: any }?,
    timestamp: number,
}

export type TraceRecord = {
    policy: string,
    timestamp: number,
    sequence: number?,
    note: string?,
    metrics: { [string]: any }?,
    payload: { [string]: any }?,
}

export type Writer = (string, string) -> (boolean, string?)

export type Options = {
    runId: string?,
    baseline: { [string]: number }?,
    bounds: Bounds?,
    learningRate: number?,
    stepSizes: { [string]: number }?,
    momentum: number?,
    artifactRoot: string?,
    writer: Writer?,
}

export type FlushOptions = {
    runId: string?,
    artifactRoot: string?,
    writer: Writer?,
}

local DEFAULT_BASELINE: KnobState = {
    pressReactionBias = 0.02,
    pressScheduleSlack = 0.015,
    pressMaxLookahead = 1.2,
}

local DEFAULT_BOUNDS: Bounds = {
    pressReactionBias = { min = 0, max = 0.4 },
    pressScheduleSlack = { min = 0, max = 0.12 },
    pressMaxLookahead = { min = 0.25, max = 5 },
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

local function cloneTable<T>(source: T): T
    if type(source) ~= "table" then
        return source
    end

    local target: any = {}
    for key, value in pairs(source) do
        target[key] = cloneTable(value)
    end
    return target
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
                local entry = encodeJSONString(tostring(key)) .. ":" .. encodeJSON(entryValue)
                entries[#entries + 1] = entry
            end
        end
        table.sort(entries)
        return "{" .. table.concat(entries, ",") .. "}"
    end

    return "null"
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

local function clamp(bounds, value: number): number
    if type(bounds) ~= "table" then
        return value
    end
    local minValue = tonumber(bounds.min)
    local maxValue = tonumber(bounds.max)
    if minValue and value < minValue then
        value = minValue
    end
    if maxValue and value > maxValue then
        value = maxValue
    end
    return value
end

function Optimiser.new(options: Options?): any
    options = options or {}

    local baseline = cloneTable(DEFAULT_BASELINE)
    if options.baseline then
        for key, value in pairs(options.baseline) do
            if type(value) == "number" and type(baseline[key]) == "number" then
                baseline[key] = value
            end
        end
    end

    local bounds = cloneTable(DEFAULT_BOUNDS)
    if options.bounds then
        for key, value in pairs(options.bounds) do
            if type(value) == "table" then
                bounds[key] = {
                    min = tonumber(value.min) or bounds[key].min,
                    max = tonumber(value.max) or bounds[key].max,
                }
            end
        end
    end

    local stepSizes = {
        pressReactionBias = 0.0025,
        pressScheduleSlack = 0.0035,
        pressMaxLookahead = 0.06,
    }

    if options.stepSizes then
        for key, value in pairs(options.stepSizes) do
            if type(value) == "number" then
                stepSizes[key] = math.abs(value)
            end
        end
    end

    local momentum = 0.6
    if type(options.momentum) == "number" then
        if options.momentum < 0 then
            momentum = 0
        elseif options.momentum > 0.99 then
            momentum = 0.99
        else
            momentum = options.momentum
        end
    end

    local self = setmetatable({
        runId = options.runId or string.format("intel-%d", math.floor(now() * 1000)),
        baseline = baseline,
        state = cloneTable(baseline),
        bounds = bounds,
        learningRate = math.abs(options.learningRate or 0.0025),
        momentum = momentum,
        stepSizes = stepSizes,
        artifactRoot = options.artifactRoot or "tests/artifacts/engine/intel",
        writer = options.writer,
        _lastObservedSequence = nil,
        _lastMetrics = nil,
        traces = {},
        recommendations = {},
    }, Optimiser)

    return self
end

function Optimiser:getState(): KnobState
    return cloneTable(self.state)
end

function Optimiser:getStepSize(key: string): number
    local value = self.stepSizes[key]
    if type(value) == "number" then
        return value
    end
    return self.learningRate
end

function Optimiser:scaleDelta(key: string, direction: number, magnitude: number?): number
    local sign = direction >= 0 and 1 or -1
    local delta = self:getStepSize(key)
    if type(magnitude) == "number" and magnitude ~= 0 then
        delta *= math.abs(magnitude)
    end
    return sign * delta
end

function Optimiser:recordTrace(policyId: string, trace: { [string]: any })
    if type(trace) ~= "table" then
        return
    end
    local record: TraceRecord = {
        policy = policyId,
        timestamp = type(trace.timestamp) == "number" and trace.timestamp or now(),
        sequence = type(trace.sequence) == "number" and trace.sequence or nil,
        note = type(trace.note) == "string" and trace.note or nil,
        metrics = trace.metrics and cloneTable(trace.metrics) or nil,
        payload = cloneTable(trace.payload),
    }
    self.traces[#self.traces + 1] = record
end

local function normaliseRecommendationKeys(recommendation: Recommendation): Recommendation
    local result: Recommendation = {}
    for key, value in pairs(recommendation) do
        if type(value) == "number" then
            result[key] = value
        end
    end
    return result
end

function Optimiser:_applyAbsolute(key: string, value: number?): number?
    if type(value) ~= "number" then
        return nil
    end
    local clamped = clamp(self.bounds[key], value)
    self.state[key] = clamped
    return clamped
end

function Optimiser:_applyDelta(key: string, delta: number?): number?
    if type(delta) ~= "number" then
        return nil
    end
    if type(self.state[key]) ~= "number" then
        return nil
    end
    if delta == 0 then
        return self.state[key]
    end
    local candidate = self.state[key] + delta
    local clamped = clamp(self.bounds[key], candidate)
    self.state[key] = clamped
    return clamped
end

function Optimiser:propose(source: string, recommendation: Recommendation, metadata: { [string]: any }?)
    if type(recommendation) ~= "table" then
        return nil
    end

    local normalised = normaliseRecommendationKeys(recommendation)
    local applied: Recommendation = {}

    if normalised.pressReactionBias ~= nil then
        local value = self:_applyAbsolute("pressReactionBias", normalised.pressReactionBias)
        if value then
            applied.pressReactionBias = value
        end
    end

    if normalised.pressScheduleSlack ~= nil then
        local value = self:_applyAbsolute("pressScheduleSlack", normalised.pressScheduleSlack)
        if value then
            applied.pressScheduleSlack = value
        end
    end

    if normalised.pressMaxLookahead ~= nil then
        local value = self:_applyAbsolute("pressMaxLookahead", normalised.pressMaxLookahead)
        if value then
            applied.pressMaxLookahead = value
        end
    end

    if normalised.pressReactionBiasDelta ~= nil then
        local value = self:_applyDelta("pressReactionBias", normalised.pressReactionBiasDelta)
        if value then
            applied.pressReactionBias = value
        end
    end

    if normalised.pressScheduleSlackDelta ~= nil then
        local value = self:_applyDelta("pressScheduleSlack", normalised.pressScheduleSlackDelta)
        if value then
            applied.pressScheduleSlack = value
        end
    end

    if normalised.pressMaxLookaheadDelta ~= nil then
        local value = self:_applyDelta("pressMaxLookahead", normalised.pressMaxLookaheadDelta)
        if value then
            applied.pressMaxLookahead = value
        end
    end

    if next(applied) == nil then
        return nil
    end

    local record: RecommendationRecord = {
        source = source,
        applied = cloneTable(self.state),
        deltas = next(normalised) and cloneTable(normalised) or nil,
        metadata = metadata and cloneTable(metadata) or nil,
        timestamp = now(),
    }

    self.recommendations[#self.recommendations + 1] = record
    return cloneTable(self.state)
end

function Optimiser:getRecommendations(): { RecommendationRecord }
    return cloneTable(self.recommendations)
end

function Optimiser:getTraces(): { TraceRecord }
    return cloneTable(self.traces)
end

function Optimiser:observeTelemetry(event: { [string]: any })
    if type(event) ~= "table" then
        return
    end

    local sequence = tonumber(event.sequence)
    if sequence and self._lastObservedSequence == sequence then
        return
    end

    if sequence then
        self._lastObservedSequence = sequence
    end

    if event.type ~= "press" then
        return
    end

    local reaction = tonumber(event.reactionTime) or tonumber(event.metrics and event.metrics.reactionTime) or 0
    local slack = tonumber(event.decisionToPressTime) or tonumber(event.slack) or 0
    local lookahead = tonumber(event.lookahead) or tonumber(event.pressLookahead) or tonumber(event.eta) or 0

    local metrics = {
        reaction = reaction,
        slack = slack,
        lookahead = lookahead,
    }

    if self._lastMetrics then
        local deltaReaction = metrics.reaction - self._lastMetrics.reaction
        local deltaSlack = metrics.slack - self._lastMetrics.slack
        local deltaLookahead = metrics.lookahead - self._lastMetrics.lookahead

        local recommendation: Recommendation = {}
        local metadata = {
            sequence = sequence,
            source = "telemetry",
            deltas = {
                reaction = deltaReaction,
                slack = deltaSlack,
                lookahead = deltaLookahead,
            },
            metrics = cloneTable(metrics),
        }

        if math.abs(deltaReaction) > self.learningRate then
            local direction = deltaReaction > 0 and -1 or 1
            recommendation.pressReactionBiasDelta = self:scaleDelta("pressReactionBias", direction)
            metadata.adjustReaction = direction
        end

        if math.abs(deltaSlack) > self.learningRate then
            local direction = deltaSlack > 0 and -1 or 1
            recommendation.pressScheduleSlackDelta = self:scaleDelta("pressScheduleSlack", direction)
            metadata.adjustSlack = direction
        end

        if math.abs(deltaLookahead) > self:getStepSize("pressMaxLookahead") * 0.5 then
            local direction = deltaLookahead > 0 and -1 or 1
            recommendation.pressMaxLookaheadDelta = self:scaleDelta("pressMaxLookahead", direction)
            metadata.adjustLookahead = direction
        end

        if next(recommendation) then
            self:propose("telemetry-gradient", recommendation, metadata)
        end
    end

    self._lastMetrics = metrics
end

local function determinePaths(root: string, runId: string)
    local base = string.format("%s/%s", root, runId)
    return {
        traces = base .. "-traces.json",
        recommendations = base .. "-recommendations.json",
    }
end

function Optimiser:flushArtifacts(options: FlushOptions?): (boolean, { [string]: string }?, string?)
    options = options or {}
    local writer = options.writer or self.writer or defaultWriter
    local root = options.artifactRoot or self.artifactRoot
    local runId = options.runId or self.runId

    if type(root) ~= "string" or root == "" then
        return false, nil, "artifact root missing"
    end

    if type(runId) ~= "string" or runId == "" then
        return false, nil, "run id missing"
    end

    if writer == defaultWriter and not ensureDirectory(root) then
        return false, nil, "failed to prepare artifact directory"
    end

    local paths = determinePaths(root, runId)

    local tracePayload = {
        runId = runId,
        generatedAt = now(),
        traces = self:getTraces(),
    }

    local recommendationPayload = {
        runId = runId,
        generatedAt = now(),
        baseline = cloneTable(self.baseline),
        state = self:getState(),
        recommendations = self:getRecommendations(),
    }

    local traceContents = encodeJSON(tracePayload)
    local recommendationsContents = encodeJSON(recommendationPayload)

    local ok, err = writer(paths.traces, traceContents)
    if not ok then
        return false, nil, err
    end

    ok, err = writer(paths.recommendations, recommendationsContents)
    if not ok then
        return false, nil, err
    end

    return true, paths, nil
end

return Optimiser
