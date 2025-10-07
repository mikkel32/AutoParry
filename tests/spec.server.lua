local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local TestHarness = ReplicatedStorage:WaitForChild("TestHarness")
local SpecsFolder = TestHarness:WaitForChild("Specs")

local function collectSpecs()
    local modules = {}
    for _, child in ipairs(SpecsFolder:GetChildren()) do
        if child:IsA("ModuleScript") then
            table.insert(modules, child)
        end
    end
    table.sort(modules, function(a, b)
        return a.Name < b.Name
    end)
    return modules
end

local function makeExpect(testName)
    local function format(value)
        if typeof(value) == "string" then
            return string.format("%q", value)
        end
        return tostring(value)
    end

    local function expect(actual)
        local expectation = {}

        function expectation:toEqual(expected)
            if actual ~= expected then
                error(string.format("[%s] expected %s but got %s", testName, format(expected), format(actual)), 0)
            end
        end

        function expectation:toBeCloseTo(expected, tolerance)
            tolerance = tolerance or 1e-3
            if typeof(actual) ~= "number" or typeof(expected) ~= "number" then
                error(string.format("[%s] expected numbers but received %s and %s", testName, format(actual), format(expected)), 0)
            end
            if math.abs(actual - expected) > tolerance then
                error(string.format("[%s] expected %s to be within %s of %s", testName, format(actual), format(tolerance), format(expected)), 0)
            end
        end

        function expectation:toBeGreaterThanOrEqual(threshold)
            if typeof(actual) ~= "number" or actual < threshold then
                error(string.format("[%s] expected %s to be >= %s", testName, format(actual), format(threshold)), 0)
            end
        end

        function expectation:toBeTruthy()
            if not actual then
                error(string.format("[%s] expected value to be truthy but received %s", testName, format(actual)), 0)
            end
        end

        return expectation
    end

    return expect
end

local cases = {}
local artifacts = {}

for _, moduleScript in ipairs(collectSpecs()) do
    local register = require(moduleScript)
    local specName = moduleScript.Name

    register({
        test = function(name, fn)
            table.insert(cases, {
                name = string.format("%s %s", specName, name),
                callback = fn,
            })
        end,
        artifact = function(name, payload)
            artifacts[name] = payload
        end,
    })
end

local failures = 0

for _, case in ipairs(cases) do
    local expect = makeExpect(case.name)
    local ok, err = xpcall(function()
        case.callback(expect)
    end, debug.traceback)

    if ok then
        print(string.format("[PASS] %s", case.name))
    else
        failures += 1
        warn(string.format("[FAIL] %s\n%s", case.name, err))
    end
end

local function emitArtifacts()
    local names = {}
    for name in pairs(artifacts) do
        table.insert(names, name)
    end
    table.sort(names)

    for _, name in ipairs(names) do
        local payload = artifacts[name]
        local ok, encoded = pcall(HttpService.JSONEncode, HttpService, payload)
        if ok then
            print(string.format("[ARTIFACT] %s %s", name, encoded))
        else
            warn(string.format("[ARTIFACT] failed to encode %s: %s", tostring(name), tostring(encoded)))
        end
    end
end

emitArtifacts()

if failures > 0 then
    error(string.format("[AutoParrySpec] %d test(s) failed", failures), 0)
else
    print(string.format("[AutoParrySpec] %d test(s) passed", #cases))
end
