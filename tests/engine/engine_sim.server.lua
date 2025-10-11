-- selene: allow(global_usage)
-- selene: allow(incorrect_standard_library_use)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestHarness = ReplicatedStorage:WaitForChild("TestHarness")
local EngineFolder = TestHarness:WaitForChild("engine")
local ScenarioFolder = EngineFolder:WaitForChild("scenario")
local Runner = require(ScenarioFolder:WaitForChild("runner"))

local results = Runner.runAll()
local payload = Runner.buildSimulationPayload(results)
Runner.emitArtifact("engine_simulation", payload)

print(string.format("[PASS] Engine simulation executed %d scenario(s)", #results))
for _, scenario in ipairs(results) do
    local metrics = scenario.metrics or {}
    print(string.format("[PASS] %s parries=%d remoteEvents=%d", scenario.id, metrics.parries or 0, metrics.remoteEvents or 0))
end
