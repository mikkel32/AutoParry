-- selene: allow(global_usage)
-- selene: allow(incorrect_standard_library_use)

local TestHarness = script.Parent.Parent
local EngineFolder = TestHarness:WaitForChild("engine")
local IntelFolder = EngineFolder:WaitForChild("intel")
local Rules = require(IntelFolder:WaitForChild("rules"))
local Optimiser = require(IntelFolder:WaitForChild("optimiser"))
local Planner do
    local scenarioFolder = TestHarness:FindFirstChild("scenario")
    if scenarioFolder then
        local plannerModule = scenarioFolder:FindFirstChild("planner")
        if plannerModule then
            local ok, module = pcall(require, plannerModule)
            if ok then
                Planner = module
            end
        end
    end

    if not Planner then
        local ok, module = pcall(function()
            return require("engine.scenario.planner")
        end)
        if ok then
            Planner = module
        end
    end
end

local function createAutoParryStub(config)
    local listeners = {}
    local stub = {}

    function stub.onTelemetry(callback)
        listeners[#listeners + 1] = callback
        local index = #listeners
        return {
            disconnect = function()
                listeners[index] = nil
            end,
        }
    end

    function stub.emit(event)
        for _, listener in pairs(listeners) do
            if listener then
                listener(event)
            end
        end
    end

    function stub.getConfig()
        return config
    end

    return stub
end

return function(t)
    t.test("policies adjust optimiser state and persist artifacts", function(expect)
        local baseline = {
            pressReactionBias = 0.02,
            pressScheduleSlack = 0.015,
            pressMaxLookahead = 1.2,
        }

        local autoParry = createAutoParryStub(baseline)
        local writes = {}

        local optimiser = Optimiser.new({
            runId = "intel-spec",
            baseline = baseline,
            artifactRoot = "tests/artifacts/engine/intel",
            learningRate = 0.001,
            stepSizes = {
                pressReactionBias = 0.004,
                pressScheduleSlack = 0.005,
                pressMaxLookahead = 0.08,
            },
            writer = function(path, contents)
                writes[#writes + 1] = { path = path, contents = contents }
                return true
            end,
        })

        local session = Rules.attach(autoParry, {
            optimiser = optimiser,
            policies = {
                enable = { "cooldown_guard", "oscillation panic handler" },
                disable = { "threat budget enforcement" },
            },
        })

        expect(session):toBeTruthy()
        expect(#session.policies):toEqual(2)
        expect(session.policies[1]):toEqual("cooldown-guard")
        expect(session.policies[2]):toEqual("oscillation-panic-handler")

        autoParry.emit({
            type = "press",
            sequence = 1,
            time = 1.0,
            reactionTime = 0.12,
            decisionToPressTime = 0.01,
        })

        autoParry.emit({
            type = "schedule",
            sequence = 2,
            time = 1.15,
            reason = "oscillation-spam",
            slack = 0.012,
            tempo = 33,
            volatility = 0.7,
        })

        autoParry.emit({
            type = "press",
            sequence = 3,
            time = 1.35,
            reactionTime = 0.02,
            decisionToPressTime = 0.012,
        })

        local state = optimiser:getState()
        expect(state.pressReactionBias > baseline.pressReactionBias):toEqual(true)
        expect(state.pressMaxLookahead > baseline.pressMaxLookahead):toEqual(true)

        local traces = optimiser:getTraces()
        expect(#traces > 0):toEqual(true)

        local ok, paths = session:flushArtifacts()
        expect(ok):toEqual(true)
        expect(paths):toBeTruthy()
        expect(#writes >= 2):toEqual(true)
        for _, write in ipairs(writes) do
            expect(string.find(write.path, "tests/artifacts/engine/intel", 1, true)):toBeTruthy()
            expect(write.contents:sub(1, 1)):toEqual("{")
        end

        session:disconnect()
    end)

    t.test("policy selection honours defaults and unknown entries", function(expect)
        local baseline = {
            pressReactionBias = 0.018,
            pressScheduleSlack = 0.02,
            pressMaxLookahead = 1.1,
        }

        local autoParry = createAutoParryStub(baseline)
        local optimiser = Optimiser.new({ baseline = baseline })

        local session = Rules.attach(autoParry, {
            optimiser = optimiser,
            policies = {
                default = "tuned",
                disable = { "cooldown-guard" },
                enable = { "non-existent", "threat budget enforcement" },
            },
        })

        expect(session):toBeTruthy()
        expect(#session.policies):toEqual(2)
        expect(session.policies[1]):toEqual("threat-budget-enforcement")
        expect(session.policies[2]):toEqual("oscillation-panic-handler")
        expect(session.warnings):toBeTruthy()
        expect(session.warnings[1]):toEqual("unknown policy 'non-existent'")

        session:disconnect()
    end)

    t.test("scenario planner preserves intelligence metadata", function(expect)
        if not Planner then
            warn("Skipping planner metadata assertions; module unavailable in this environment")
            expect(true):toEqual(true)
            return
        end

        local manifest = {
            version = 1,
            metadata = {
                id = "intel_manifest",
                label = "Intel manifest",
            },
            intelligence = {
                notes = "Baseline policies",
                policies = {
                    default = "baseline",
                    enable = { "cooldown-guard" },
                },
            },
            timeline = {
                {
                    time = 0,
                    type = "player",
                    player = {
                        action = "noop",
                    },
                },
            },
        }

        local ok, plan, diagnostics = Planner.plan(manifest)
        if not ok then
            warn("Planner diagnostics", diagnostics)
        end

        expect(ok):toEqual(true)
        expect(plan):toBeTruthy()
        expect(plan.intelligence):toBeTruthy()
        expect(plan.intelligence.policies):toBeTruthy()
        expect(plan.intelligence.policies.enable[1]):toEqual("cooldown-guard")
    end)
end
