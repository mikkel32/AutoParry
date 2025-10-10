-- selene: allow(global_usage)
-- selene: allow(incorrect_standard_library_use)

local function findTestHarness(instance)
    local current = instance
    while current do
        if current.Name == "TestHarness" then
            return current
        end
        current = current.Parent
    end

    error("Failed to locate TestHarness ancestor from Harness module")
end

local TestHarness = findTestHarness(script)
local RuntimeFolder = TestHarness:WaitForChild("engine")

return require(RuntimeFolder:WaitForChild("runtime"))
