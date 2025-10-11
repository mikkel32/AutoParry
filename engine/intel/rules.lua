--!strict

local Optimiser = require(script.Parent:WaitForChild("optimiser"))

export type PolicyHooks = {
    listen: (({ [string]: any }) -> ()) -> any?,
    trace: ({ [string]: any }) -> (),
    recommend: (Optimiser.Recommendation, { [string]: any }?) -> any,
    getState: () -> Optimiser.KnobState?,
    scaleDelta: (string, number, number?) -> number,
}

export type PolicyModule = {
    id: string,
    label: string,
    description: string,
    subscribe: (autoParry: any, hooks: PolicyHooks) -> any?,
    tags: { string }?,
}

export type PolicyPreferences = {
    default: string?,
    enable: { string }?,
    disable: { string }?,
}

export type ActivationOptions = {
    optimiser: any?,
    policies: PolicyPreferences?,
    runId: string?,
    baseline: { [string]: number }?,
    artifactRoot: string?,
    writer: Optimiser.Writer?,
    onTrace: ((string, { [string]: any }) -> ())?,
    onRecommendation: ((string, Optimiser.Recommendation, { [string]: any }?, any) -> ())?,
}

export type Session = {
    policies: { string },
    optimiser: any,
    warnings: { string }?,
    disconnect: (Session) -> (),
    flushArtifacts: (Session, Optimiser.FlushOptions?) -> (boolean, { [string]: string }?, string?),
}

local Rules = {}

local registry: { [string]: PolicyModule } = {}
local registryOrder: { string } = {}

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

local function now(): number
    local ok, value = pcall(os.clock)
    if ok and type(value) == "number" then
        return value
    end

    return 0
end

local function disconnectConnection(connection: any)
    if type(connection) == "table" then
        local disconnect = connection.disconnect or connection.Disconnect
        if type(disconnect) == "function" then
            disconnect(connection)
        end
    elseif type(connection) == "function" then
        connection()
    end
end

local function normalisePolicyName(name: string): string
    local lowered = name:lower()
    lowered = lowered:gsub("[_%s]+", "-")
    lowered = lowered:gsub("[^%w%-]", "")
    return lowered
end

local function registerPolicy(policy: PolicyModule)
    local id = normalisePolicyName(policy.id)
    policy.id = id
    registry[id] = policy

    local seen = false
    for _, existing in ipairs(registryOrder) do
        if existing == id then
            seen = true
            break
        end
    end

    if not seen then
        registryOrder[#registryOrder + 1] = id
    end
end

local function describePolicy(policy: PolicyModule)
    return {
        id = policy.id,
        label = policy.label,
        description = policy.description,
        tags = policy.tags and cloneTable(policy.tags) or nil,
    }
end

function Rules.getPolicy(id: string): PolicyModule?
    return registry[normalisePolicyName(id)]
end

function Rules.listPolicies(): { { [string]: any } }
    local result = {}
    for _, id in ipairs(registryOrder) do
        local policy = registry[id]
        if policy then
            result[#result + 1] = describePolicy(policy)
        end
    end
    return result
end

local function resolveDefault(preferences: PolicyPreferences?): string
    if not preferences or not preferences.default then
        return "none"
    end

    local default = preferences.default:lower()
    if default == "all" or default == "tuned" then
        return "all"
    end
    if default == "baseline" or default == "none" then
        return "none"
    end
    return "none"
end

local function selectPolicies(preferences: PolicyPreferences?): ({ string }, { string })
    local selected: { [string]: boolean } = {}
    local warnings: { string } = {}

    local defaultMode = resolveDefault(preferences)
    if defaultMode == "all" then
        for id in pairs(registry) do
            selected[id] = true
        end
    end

    if preferences then
        if type(preferences.enable) == "table" then
            for _, name in ipairs(preferences.enable) do
                local policyId = normalisePolicyName(tostring(name))
                if registry[policyId] then
                    selected[policyId] = true
                else
                    warnings[#warnings + 1] = string.format("unknown policy '%s'", tostring(name))
                end
            end
        end

        if type(preferences.disable) == "table" then
            for _, name in ipairs(preferences.disable) do
                local policyId = normalisePolicyName(tostring(name))
                if selected[policyId] then
                    selected[policyId] = nil
                elseif not registry[policyId] then
                    warnings[#warnings + 1] = string.format("unknown policy '%s'", tostring(name))
                end
            end
        end
    end

    local order = {}
    for _, id in ipairs(registryOrder) do
        if selected[id] then
            order[#order + 1] = id
        end
    end

    return order, warnings
end

local function buildHooks(autoParry: any, optimiser: any?, session, policyId: string, options: ActivationOptions?): PolicyHooks
    local connections = session._connections

    local function listen(callback)
        local connection = autoParry.onTelemetry(function(event)
            if optimiser and type(optimiser.observeTelemetry) == "function" then
                optimiser:observeTelemetry(event)
            end
            callback(event)
        end)

        connections[#connections + 1] = connection
        return connection
    end

    local function trace(payload)
        if optimiser and type(optimiser.recordTrace) == "function" then
            optimiser:recordTrace(policyId, payload)
        end
        if options and type(options.onTrace) == "function" then
            options.onTrace(policyId, payload)
        end
    end

    local function recommend(recommendation, metadata)
        local applied
        if optimiser and type(optimiser.propose) == "function" then
            applied = optimiser:propose(policyId, recommendation, metadata)
        end
        if options and type(options.onRecommendation) == "function" then
            options.onRecommendation(policyId, recommendation, metadata, applied)
        end
        return applied
    end

    local function getState()
        if optimiser and type(optimiser.getState) == "function" then
            return optimiser:getState()
        end
        return nil
    end

    local function scaleDelta(key, direction, magnitude)
        if optimiser and type(optimiser.scaleDelta) == "function" then
            return optimiser:scaleDelta(key, direction, magnitude)
        end

        local base = 0.002
        if key == "pressScheduleSlack" then
            base = 0.003
        elseif key == "pressMaxLookahead" then
            base = 0.05
        end

        local sign = direction >= 0 and 1 or -1
        if type(magnitude) == "number" and magnitude ~= 0 then
            base *= math.abs(magnitude)
        end
        return sign * base
    end

    return {
        listen = listen,
        trace = trace,
        recommend = recommend,
        getState = getState,
        scaleDelta = scaleDelta,
    }
end

local function captureBaseline(autoParry: any, provided: { [string]: number }?)
    local baseline = {}
    if provided then
        for key, value in pairs(provided) do
            if type(value) == "number" then
                baseline[key] = value
            end
        end
    end

    local getter = autoParry and autoParry.getConfig
    if type(getter) == "function" then
        local ok, config = pcall(getter)
        if ok and type(config) == "table" then
            for _, key in ipairs({ "pressReactionBias", "pressScheduleSlack", "pressMaxLookahead" }) do
                if baseline[key] == nil and type(config[key]) == "number" then
                    baseline[key] = config[key]
                end
            end
        end
    end

    return baseline
end

function Rules.attach(autoParry: any, options: ActivationOptions?): Session
    assert(autoParry ~= nil, "AutoParry reference is required")
    assert(type(autoParry.onTelemetry) == "function", "AutoParry must expose onTelemetry")

    options = options or {}

    local optimiser = options.optimiser
    if optimiser == nil then
        local baseline = captureBaseline(autoParry, options.baseline)
        optimiser = Optimiser.new({
            runId = options.runId,
            baseline = baseline,
            artifactRoot = options.artifactRoot,
            writer = options.writer,
        })
    end

    local selected, warnings = selectPolicies(options.policies)

    local session = {
        policies = cloneTable(selected),
        optimiser = optimiser,
        warnings = #warnings > 0 and warnings or nil,
        _connections = {},
    }

    function session:disconnect()
        for index = #self._connections, 1, -1 do
            disconnectConnection(self._connections[index])
            self._connections[index] = nil
        end
    end

    function session:flushArtifacts(flushOptions: Optimiser.FlushOptions?)
        if self.optimiser and type(self.optimiser.flushArtifacts) == "function" then
            return self.optimiser:flushArtifacts(flushOptions)
        end
        return false, nil, "optimiser missing"
    end

    if optimiser and type(optimiser.recordTrace) == "function" then
        optimiser:recordTrace("session", {
            timestamp = now(),
            note = "intel-session-start",
            payload = { policies = cloneTable(selected) },
        })
    end

    for _, policyId in ipairs(selected) do
        local policy = registry[policyId]
        if policy then
            local hooks = buildHooks(autoParry, optimiser, session, policyId, options)
            local ok, connection = pcall(policy.subscribe, policy, autoParry, hooks)
            if ok and connection then
                local tracked = false
                for _, existing in ipairs(session._connections) do
                    if existing == connection then
                        tracked = true
                        break
                    end
                end
                if not tracked then
                    session._connections[#session._connections + 1] = connection
                end
            elseif not ok and optimiser and type(optimiser.recordTrace) == "function" then
                optimiser:recordTrace(policyId, {
                    timestamp = now(),
                    note = "policy-subscribe-error",
                    payload = { error = tostring(connection) },
                })
            end
        end
    end

    return session :: any
end

local CooldownGuard: PolicyModule = {
    id = "cooldown-guard",
    label = "Cooldown guard",
    description = "Keeps reaction bias aligned with recent press cadence.",
    subscribe = function(_self, autoParry, hooks)
        local lastPressTime: number? = nil
        local reactionWindow = {
            low = 0.03,
            high = 0.09,
        }

        return hooks.listen(function(event)
            if type(event) ~= "table" or event.type ~= "press" then
                return
            end

            local reaction = tonumber(event.reactionTime) or tonumber(event.metrics and event.metrics.reactionTime) or 0
            local sequence = tonumber(event.sequence)
            local timestamp = type(event.time) == "number" and event.time or nil
            local note = "steady"

            if timestamp and lastPressTime then
                local gap = timestamp - lastPressTime
                if gap < reactionWindow.low then
                    note = "press-gap-tight"
                elseif gap > reactionWindow.high * 2 then
                    note = "press-gap-wide"
                end
            end

            lastPressTime = timestamp or lastPressTime

            hooks.trace({
                sequence = sequence,
                timestamp = timestamp,
                note = note,
                metrics = {
                    reaction = reaction,
                    decision = tonumber(event.decisionToPressTime) or nil,
                },
                payload = {
                    immediate = event.immediate,
                },
            })

            local delta
            local reason

            if reaction > reactionWindow.high then
                delta = hooks.scaleDelta("pressReactionBias", -1)
                reason = "reaction-slow"
            elseif reaction < reactionWindow.low then
                delta = hooks.scaleDelta("pressReactionBias", 1)
                reason = "reaction-fast"
            end

            if delta and delta ~= 0 then
                hooks.recommend({
                    pressReactionBiasDelta = delta,
                }, {
                    sequence = sequence,
                    reaction = reaction,
                    reason = reason,
                })
            end
        end)
    end,
}

local ThreatBudget: PolicyModule = {
    id = "threat-budget-enforcement",
    label = "Threat budget enforcement",
    description = "Expands or trims schedule slack when threat budget drifts.",
    subscribe = function(_self, autoParry, hooks)
        return hooks.listen(function(event)
            if type(event) ~= "table" or event.type ~= "schedule" then
                return
            end

            local slack = tonumber(event.slack) or 0
            local sequence = tonumber(event.sequence)
            local timestamp = type(event.time) == "number" and event.time or nil
            local reason = "budget-steady"
            local delta

            if slack < 0.006 then
                delta = hooks.scaleDelta("pressScheduleSlack", 1)
                reason = "budget-tight"
            elseif slack > 0.04 then
                delta = hooks.scaleDelta("pressScheduleSlack", -1)
                reason = "budget-loose"
            end

            hooks.trace({
                sequence = sequence,
                timestamp = timestamp,
                note = reason,
                metrics = {
                    slack = slack,
                    lead = tonumber(event.lead) or nil,
                },
                payload = {
                    reason = event.reason,
                    immediate = event.immediate,
                },
            })

            if delta and delta ~= 0 then
                hooks.recommend({
                    pressScheduleSlackDelta = delta,
                }, {
                    sequence = sequence,
                    slack = slack,
                    reason = reason,
                })
            end
        end)
    end,
}

local OscillationPanic: PolicyModule = {
    id = "oscillation-panic-handler",
    label = "Oscillation panic handler",
    description = "Extends lookahead when oscillation telemetry triggers panic conditions.",
    subscribe = function(_self, autoParry, hooks)
        return hooks.listen(function(event)
            if type(event) ~= "table" then
                return
            end

            if event.type ~= "schedule" and event.type ~= "press" then
                return
            end

            local reason = tostring(event.reason or "")
            local tempo = tonumber(event.tempo) or tonumber(event.oscillationTempo) or 0
            local volatility = tonumber(event.volatility) or tonumber(event.oscillationVolatility) or 0
            local panicActive = event.panic == true or event.panicActive == true
            if type(event.telemetry) == "table" and event.telemetry.panicActive == true then
                panicActive = true
            end

            local severity = 0
            if reason:find("oscillation") then
                severity += 1
            end
            if tempo >= 28 then
                severity += 1
            end
            if volatility >= 0.5 then
                severity += 1
            end
            if panicActive then
                severity += 1
            end

            local sequence = tonumber(event.sequence)
            local timestamp = type(event.time) == "number" and event.time or nil
            local note = severity > 0 and "panic-escalate" or "panic-relax"

            hooks.trace({
                sequence = sequence,
                timestamp = timestamp,
                note = note,
                metrics = {
                    tempo = tempo,
                    volatility = volatility,
                    slack = tonumber(event.slack) or nil,
                    lookahead = tonumber(event.lookahead) or tonumber(event.eta) or nil,
                },
                payload = {
                    reason = reason,
                    panic = panicActive,
                },
            })

            if severity > 0 then
                local delta = hooks.scaleDelta("pressMaxLookahead", 1, severity)
                if delta ~= 0 then
                    hooks.recommend({
                        pressMaxLookaheadDelta = delta,
                    }, {
                        sequence = sequence,
                        reason = note,
                        tempo = tempo,
                        volatility = volatility,
                    })
                end
            elseif event.type == "schedule" and (tonumber(event.slack) or 0) > 0.05 then
                local delta = hooks.scaleDelta("pressMaxLookahead", -1, 0.5)
                if delta ~= 0 then
                    hooks.recommend({
                        pressMaxLookaheadDelta = delta,
                    }, {
                        sequence = sequence,
                        reason = note,
                        slack = tonumber(event.slack) or 0,
                    })
                end
            end
        end)
    end,
}

registerPolicy(CooldownGuard)
registerPolicy(ThreatBudget)
registerPolicy(OscillationPanic)

return Rules
