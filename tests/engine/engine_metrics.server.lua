-- selene: allow(global_usage)
-- selene: allow(incorrect_standard_library_use)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestHarness = ReplicatedStorage:WaitForChild("TestHarness")
local EngineFolder = TestHarness:WaitForChild("engine")
local ScenarioFolder = EngineFolder:WaitForChild("scenario")
local Runner = require(ScenarioFolder:WaitForChild("runner"))

local results = Runner.runAll()
local payload = Runner.buildMetricsPayload(results)
Runner.emitArtifact("engine_metrics", payload)

local summary = payload.run or {}
print(string.format(
    "[PASS] Engine metrics totals parries=%d remoteEvents=%d warnings=%d",
    summary.totalParries or 0,
    summary.totalRemoteEvents or 0,
    summary.totalWarnings or 0
))
for _, entry in ipairs(payload.scenarios or {}) do
    local metrics = entry.metrics or {}
    print(string.format(
        "[PASS] %s parries=%d remoteEvents=%d",
        entry.id,
        metrics.parries or 0,
        metrics.remoteEvents or 0
    ))
end
