-- selene: allow(global_usage)
-- selene: allow(incorrect_standard_library_use)

local TestHarness = script.Parent.Parent
local EngineFolder = TestHarness:WaitForChild("engine")
local TelemetryFolder = EngineFolder:WaitForChild("telemetry")
local Exporter = require(TelemetryFolder:WaitForChild("exporter"))
local TelemetryTestUtils = require(TestHarness:WaitForChild("TelemetryTestUtils"))
local SourceMap = require(TestHarness:WaitForChild("AutoParrySourceMap"))
local HttpService = game:GetService("HttpService")
local serde = require("@lune/serde")

local BASELINE_PATH = "tests/artifacts/engine/baselines/telemetry_exporter.json"

local function formatValue(value)
    if typeof(value) == "table" then
        local okMethod, encodeMethod = pcall(function()
            return HttpService.JSONEncode
        end)
        if okMethod and typeof(encodeMethod) == "function" then
            local ok, encoded = pcall(encodeMethod, HttpService, value)
            if ok then
                return encoded
            end
        end
        local okSerde, encoded = pcall(serde.encode, "json", value)
        if okSerde then
            return encoded
        end
    end
    if typeof(value) == "number" then
        return string.format("%.6f", value)
    end
    return tostring(value)
end

local function formatPath(pathSegments: { any }, extra: any?): string
    local buffer = {}
    for index, segment in ipairs(pathSegments) do
        if type(segment) == "number" then
            buffer[#buffer + 1] = string.format("[%d]", segment)
        else
            if index > 1 then
                buffer[#buffer + 1] = "."
            end
            buffer[#buffer + 1] = tostring(segment)
        end
    end
    if extra ~= nil then
        if type(extra) == "number" then
            buffer[#buffer + 1] = string.format("[%d]", extra)
        else
            if #buffer > 0 then
                buffer[#buffer + 1] = "."
            end
            buffer[#buffer + 1] = tostring(extra)
        end
    end
    return table.concat(buffer)
end

local function compare(expected, actual, pathSegments, differences, tolerances)
    if expected == nil then
        if actual ~= nil then
            table.insert(differences, string.format("%s unexpected value %s", formatPath(pathSegments), formatValue(actual)))
        end
        return
    end

    if actual == nil then
        table.insert(differences, string.format("%s is missing (expected %s)", formatPath(pathSegments), formatValue(expected)))
        return
    end

    local expectedType = typeof(expected)
    local actualType = typeof(actual)
    local pathKey = formatPath(pathSegments)

    if expectedType == "number" and actualType == "number" then
        local tolerance = tolerances[pathKey]
        if tolerance then
            if math.abs(expected - actual) > tolerance then
                table.insert(differences, string.format("%s expected %s ± %.6f but got %s", pathKey, formatValue(expected), tolerance, formatValue(actual)))
            end
        elseif expected ~= actual then
            table.insert(differences, string.format("%s expected %s but got %s", pathKey, formatValue(expected), formatValue(actual)))
        end
        return
    end

    if expectedType ~= actualType then
        table.insert(differences, string.format("%s type mismatch: expected %s but got %s", pathKey, expectedType, actualType))
        return
    end

    if expectedType ~= "table" then
        if expected ~= actual then
            table.insert(differences, string.format("%s expected %s but got %s", pathKey, formatValue(expected), formatValue(actual)))
        end
        return
    end

    local expectedArray = #expected > 0
    local actualArray = #actual > 0

    if expectedArray or actualArray then
        local maxLength = math.max(#expected, #actual)
        for index = 1, maxLength do
            pathSegments[#pathSegments + 1] = index
            compare(expected[index], actual[index], pathSegments, differences, tolerances)
            pathSegments[#pathSegments] = nil
        end
        return
    end

    local visited = {}
    for key, value in pairs(expected) do
        pathSegments[#pathSegments + 1] = key
        compare(value, actual[key], pathSegments, differences, tolerances)
        pathSegments[#pathSegments] = nil
        visited[key] = true
    end

    for key, value in pairs(actual) do
        if not visited[key] then
            table.insert(differences, string.format("%s unexpected value %s", formatPath(pathSegments, key), formatValue(value)))
        end
    end
end

local function readBaseline()
    local source = SourceMap[BASELINE_PATH]
    assert(source, string.format("Telemetry exporter baseline missing (%s)", BASELINE_PATH))

    source = source:gsub("^%-%-[^\n]*\n", "")

    local decoded

    local okMethod, decodeMethod = pcall(function()
        return HttpService.JSONDecode
    end)

    if okMethod and typeof(decodeMethod) == "function" then
        local ok, result = pcall(decodeMethod, HttpService, source)
        if ok then
            decoded = result
        end
    end

    if decoded == nil then
        local ok, result = pcall(serde.decode, "json", source)
        if not ok then
            error(string.format("Failed to decode telemetry exporter baseline: %s", tostring(result)), 0)
        end
        decoded = result
    end

    local tolerances = {}
    if typeof(decoded.tolerances) == "table" then
        for key, value in pairs(decoded.tolerances) do
            if typeof(key) == "string" and typeof(value) == "number" then
                tolerances[key] = value
            end
        end
    end

    return decoded.payload or {}, decoded.trace or {}, tolerances, decoded
end

return function(t)
    t.test("telemetry exporter payload matches baseline", function(expect)
        local stats = TelemetryTestUtils.buildStats({
            counters = {
                press = 6,
                schedule = 5,
                latency = 3,
            },
        })

        local diagnostics = {
            summary = TelemetryTestUtils.buildSummary(stats, {
                pressCount = 6,
                scheduleCount = 5,
                latencyCount = 3,
                immediateRate = 0.5,
            }),
            recommendations = {
                {
                    source = "unit-test",
                    deltas = {
                        pressReactionBias = 0.002,
                        pressScheduleSlack = -0.001,
                    },
                },
            },
            insights = {
                focus = 0.91,
                stability = 0.77,
            },
        }

        local telemetry = {
            sequence = 42,
            activationLatency = 0.08,
            remoteLatencyActive = true,
            history = {
                {
                    type = "schedule",
                    sequence = 40,
                    time = 1.04,
                    reason = "baseline",
                    target = {
                        position = Vector3.new(0, 0, 92),
                        velocity = Vector3.new(0, 0, -160),
                    },
                    rules = {
                        highlight = true,
                    },
                },
                {
                    type = "press",
                    sequence = 41,
                    time = 1.168,
                    reactionTime = 0.124,
                    decisionToPressTime = 0.018,
                    decision = {
                        manifold = 0.46,
                        threatTempo = 34,
                        threatIntensity = 0.72,
                        simulation = {
                            peakIntrusion = 0.31,
                            urgency = 0.64,
                            orientation = CFrame.new(),
                        },
                    },
                    kinematics = {
                        position = Vector3.new(0, 0, 78),
                        velocity = Vector3.new(0, 0, -162),
                    },
                },
            },
            lastEvent = {
                type = "press",
                sequence = 41,
                time = 1.168,
                reactionTime = 0.124,
            },
            smartTuning = {
                enabled = true,
                mu = 0.03,
                sigma = 0.4,
                base = {
                    reactionBias = 0.02,
                    scheduleSlack = 0.015,
                    confidencePadding = 0.2,
                },
                target = {
                    reactionBias = 0.018,
                    scheduleSlack = 0.012,
                    confidencePadding = 0.18,
                },
                applied = {
                    reactionBias = 0.019,
                    scheduleSlack = 0.013,
                    confidencePadding = 0.19,
                },
            },
            stats = stats,
            adaptiveState = stats.adaptiveState,
        }

        local parryLog = {
            {
                timestamp = 1.168,
                ball = {
                    Name = "BaselineThreat",
                    Position = Vector3.new(0, 0, 78),
                    AssemblyLinearVelocity = Vector3.new(0, 0, -162),
                },
            },
            {
                timestamp = 1.312,
                ball = "LegacyBallId",
            },
        }

        local metadata = {
            runId = "telemetry-exporter-spec",
            version = 2,
        }

        local steps = {
            {
                t = 0,
                agents = {
                    {
                        name = "player",
                        position = Vector3.new(0, 0, 0),
                        velocity = Vector3.new(0, 0, 0),
                    },
                },
                projectiles = {
                    {
                        name = "BaselineThreat",
                        position = Vector3.new(0, 0, 100),
                        velocity = Vector3.new(0, 0, -160),
                        contact = false,
                    },
                },
                rules = {
                    {
                        name = "highlight-gate",
                        state = true,
                    },
                    {
                        name = "cooldown-guard",
                        state = false,
                    },
                },
            },
            {
                t = 1 / 120,
                agents = {
                    {
                        name = "player",
                        position = Vector3.new(0, 0, 0),
                        velocity = Vector3.new(0, 0, 0),
                    },
                },
                projectiles = {
                    {
                        name = "BaselineThreat",
                        position = Vector3.new(0, 0, 98.666),
                        velocity = Vector3.new(0, 0, -160),
                        contact = false,
                    },
                },
                rules = {
                    ["highlight-gate"] = false,
                    ["cooldown-guard"] = true,
                },
            },
            {
                t = 0.45,
                agents = {
                    {
                        name = "player",
                        position = Vector3.new(0, 0, 0),
                        velocity = Vector3.new(0, 0, 0),
                    },
                },
                projectiles = {
                    {
                        name = "BaselineThreat",
                        position = Vector3.new(0, 0, 28),
                        velocity = Vector3.new(0, 0, -165),
                        contact = true,
                    },
                },
                rules = {
                    ["highlight-gate"] = false,
                    ["cooldown-guard"] = true,
                },
            },
        }

        local payload = Exporter.buildPayload({
            generatedAt = 123.456,
            metadata = metadata,
            telemetry = telemetry,
            diagnostics = diagnostics,
            parryLog = parryLog,
            events = telemetry.history,
        })

        local trace = Exporter.buildTrace({
            steps = steps,
            traceMetadata = {
                frequency = 240,
            },
        })

        local baselinePayload, baselineTrace, tolerances, baseline = readBaseline()

        local differences = {}
        compare(baselinePayload, payload, { "payload" }, differences, tolerances)
        compare(baselineTrace, trace, { "trace" }, differences, tolerances)

        if t.artifact then
            t.artifact("telemetry_exporter", {
                payload = payload,
                trace = trace,
                tolerances = tolerances,
                differences = differences,
                baseline = baseline,
            })
        end

        local writes = {}
        local ok, paths = Exporter.writeArtifacts({
            runId = "telemetry-spec",
            artifactRoot = "tests/artifacts/engine/telemetry",
            writer = function(path, contents)
                writes[#writes + 1] = { path = path, contents = contents }
                return true
            end,
            generatedAt = payload.generatedAt,
            metadata = metadata,
            telemetry = telemetry,
            diagnostics = diagnostics,
            parryLog = parryLog,
            events = telemetry.history,
            steps = steps,
            traceMetadata = { frequency = 240 },
        })

        expect(ok):toEqual(true)
        expect(paths):toBeTruthy()
        expect(#writes):toEqual(2)

        local encodedPayload = Exporter.encodePayload(payload)
        local encodedTrace = Exporter.encodeTrace(trace)

        expect(writes[1].contents):toEqual(encodedPayload)
        expect(writes[2].contents):toEqual(encodedTrace)

        if #differences > 0 then
            error(table.concat({
                "Telemetry exporter artifact drift detected.",
                "Review tests/artifacts/engine/baselines/telemetry_exporter.json and confirm the updates are intentional.",
                "If the new payloads are correct, update the baseline file accordingly.",
                "Differences:\n- " .. table.concat(differences, "\n- "),
            }, "\n"), 0)
        end
    end)
end
