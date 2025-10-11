-- selene: allow(global_usage)
-- selene: allow(incorrect_standard_library_use)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestHarness = ReplicatedStorage:WaitForChild("TestHarness")
local EngineFolder = TestHarness:WaitForChild("engine")
local ScenarioFolder = EngineFolder:WaitForChild("scenario")
local Runner = require(ScenarioFolder:WaitForChild("runner"))

local function hasEnginePerfTag(plan)
    local metadata = plan.metadata or {}
    local tags = metadata.tags
    if typeof(tags) ~= "table" then
        return false
    end
    for _, tag in ipairs(tags) do
        if string.lower(tostring(tag)) == "engine-perf" then
            return true
        end
    end
    return false
end

local results = Runner.runAll({
    planFilter = function(plan)
        return hasEnginePerfTag(plan)
    end,
})

if #results == 0 then
    error("engine-perf suite did not resolve any scenarios tagged with 'engine-perf'", 0)
end

local payload = Runner.buildMetricsPayload(results)
Runner.emitArtifact("engine_perf_metrics", payload)

local summary = payload.run or {}
print(string.format(
    "[PASS] Engine perf summary scenarios=%d duration=%.2fs warnings=%d",
    summary.scenarios or 0,
    summary.totalDuration or 0,
    summary.totalWarnings or 0
))

local ok = true

for _, scenario in ipairs(results) do
    local metrics = scenario.metrics or {}
    local performance = metrics.performance or {}
    local scheduler = performance.scheduler or {}
    local queue = scheduler.queue or {}
    local gc = scheduler.gc or {}
    local utilisation = scheduler.utilisation or 0
    local lateness = scheduler.lateness or {}
    local averageLatenessMs = (lateness.average or 0) * 1000
    local maxLatenessMs = (lateness.max or 0) * 1000

    local message = string.format(
        "[PASS] %s threats=%d parries=%d hitches=%d queueMax=%.0f util=%.3f gcΔ=%.2fKB lateAvg=%.2fms lateMax=%.2fms",
        scenario.id,
        metrics.threats or 0,
        metrics.parries or 0,
        metrics.hitches or 0,
        queue.maxDepth or 0,
        utilisation,
        gc.deltaKb or 0,
        averageLatenessMs,
        maxLatenessMs
    )
    print(message)

    if scenario.id == "engine_perf_mass_pressure" and (metrics.threats or 0) < 5000 then
        ok = false
        print(string.format(
            "[FAIL] %s expected 5000 threats, observed %d",
            scenario.id,
            metrics.threats or 0
        ))
    end

    if scenario.id == "engine_perf_hitch_resilience" and (metrics.hitches or 0) < 5 then
        ok = false
        print(string.format(
            "[FAIL] %s expected ≥5 hitch injections, observed %d",
            scenario.id,
            metrics.hitches or 0
        ))
    end

    if scenario.id == "engine_perf_flicker_window" and (metrics.threats or 0) < 5 then
        ok = false
        print(string.format(
            "[FAIL] %s expected flicker threats to execute, observed %d",
            scenario.id,
            metrics.threats or 0
        ))
    end
end

if not ok then
    error("engine-perf suite did not satisfy required workload invariants", 0)
end
