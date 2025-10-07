local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestHarness = ReplicatedStorage:WaitForChild("TestHarness")
local SourceMap = require(TestHarness:WaitForChild("AutoParrySourceMap"))

local function makeSignal()
    local handlers = {}
    local signal = {}

    function signal:Connect(handler)
        table.insert(handlers, handler)
        local connection = {}

        function connection.Disconnect()
            for index, fn in ipairs(handlers) do
                if fn == handler then
                    table.remove(handlers, index)
                    break
                end
            end
        end

        connection.disconnect = connection.Disconnect
        return connection
    end

    function signal:Fire(...)
        for _, handler in ipairs(handlers) do
            handler(...)
        end
    end

    return signal
end

local heartbeatSignal = makeSignal()
local parryRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("ParryButtonPress")
local parryCalls = 0

local function recordParryCall(self, ...)
    parryCalls = parryCalls + 1
    self.LastPayload = { ... }
end

function parryRemote:Fire(...)
    recordParryCall(self, ...)
end

parryRemote.FireServer = parryRemote.Fire

local statsStub = {
    Network = {
        ServerStatsItem = {
            ["Data Ping"] = {
                GetValue = function()
                    return 95
                end,
            },
        },
    },
}

local runServiceStub = {}
runServiceStub.Heartbeat = heartbeatSignal

local userInputStub = {}
userInputStub.InputBegan = makeSignal()

function userInputStub:IsKeyDown()
    return false
end

local playerCharacter = Instance.new("Model")
playerCharacter.Name = "Character"
playerCharacter.Parent = workspace

local root = Instance.new("Part")
root.Name = "HumanoidRootPart"
root.Anchored = true
root.Size = Vector3.new(2, 2, 2)
root.Position = Vector3.new(0, 5, 0)
root.Parent = playerCharacter
playerCharacter.PrimaryPart = root

local playersStub = {
    LocalPlayer = {
        Name = "LocalPlayer",
        Character = playerCharacter,
    },
}

local originalGetService = game.GetService
function game:GetService(name)
    if name == "Stats" then
        return statsStub
    elseif name == "RunService" then
        return runServiceStub
    elseif name == "UserInputService" then
        return userInputStub
    elseif name == "Players" then
        return playersStub
    end

    return originalGetService(self, name)
end

function game:HttpGet(url)
    local path = url:match("^https://raw%.githubusercontent%.com/[^/]+/[^/]+/(.+)$")
    if not path then
        error("Unexpected HttpGet request: " .. tostring(url))
    end

    local source = SourceMap[path]
    assert(source, "Missing source map entry for " .. path)
    return source
end

local ballsFolder = workspace:FindFirstChild("Balls")
assert(ballsFolder, "Expected workspace.Balls to exist")
ballsFolder:ClearAllChildren()

local function spawnBall(position, velocity)
    local part = Instance.new("Part")
    part.Name = "BladeBall"
    part.Anchored = true
    part.CanCollide = false
    part.Size = Vector3.new(1, 1, 1)
    part.Position = position
    part.AssemblyLinearVelocity = velocity
    part:SetAttribute("realBall", true)
    part.Parent = ballsFolder
    return part
end

spawnBall(Vector3.new(0, 5, -30), Vector3.new(0, 0, 120))

local loaderChunk = assert(loadstring(SourceMap["loader.lua"], "=loader.lua"))
local ok, api = pcall(loaderChunk, {
    repo = "mikkel32/AutoParry",
    branch = "main",
    entrypoint = "src/main.lua",
    refresh = true,
})

assert(ok, api)
assert(typeof(api) == "table", "Loader did not return the API table")
assert(api.getVersion() == "1.1.0", "Unexpected AutoParry version")
assert(api.isEnabled() == false, "AutoParry should start disabled")

api.setEnabled(true)

for _ = 1, 5 do
    heartbeatSignal:Fire()
end

api.destroy()

print("[AutoParryHarness] Loader bootstrap completed with " .. parryCalls .. " parry attempt(s)")
