-- selene: allow(global_usage)
-- selene: allow(incorrect_standard_library_use)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestHarness = ReplicatedStorage:WaitForChild("TestHarness")
local EngineFolder = TestHarness:WaitForChild("engine")
local ScenarioFolder = EngineFolder:WaitForChild("scenario")
local Runner = require(ScenarioFolder:WaitForChild("runner"))

local results = Runner.runAll()
local payload = Runner.buildReplayPayload(results)
Runner.emitArtifact("engine_replay", payload)

print(string.format("[PASS] Engine replay captured %d scenario(s)", #results))
for _, replay in ipairs(payload.replays) do
    local remoteCount = #(replay.remoteLog or {})
    local parryCount = #(replay.parryLog or {})
    print(string.format("[PASS] %s remoteEvents=%d parries=%d", replay.id, remoteCount, parryCount))
end
