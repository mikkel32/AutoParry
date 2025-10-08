local TestHarness = script.Parent.Parent
local Harness = require(TestHarness:WaitForChild("Harness"))

local Scheduler = Harness.Scheduler

local function deepCopy(value)
    if typeof(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, child in pairs(value) do
        copy[key] = deepCopy(child)
    end
    return copy
end

local function loadAutoparry()
    local scheduler = Scheduler.new(0.25)
    local services, remotes = Harness.createBaseServices(scheduler, {
        initialLocalPlayer = { Name = "LocalPlayer" },
    })

    remotes:Add(Harness.createParryButtonPress({ scheduler = scheduler }))

    local autoparry = Harness.loadAutoparry({
        scheduler = scheduler,
        services = services,
    })

    return autoparry
end

return function(t)
    t.test("configure accepts valid overrides for all default options", function(expect)
        local autoparry = loadAutoparry()
        local defaults = autoparry.getConfig()
        local defaultsSnapshot = deepCopy(defaults)

        local validOverrides = {
            cooldown = defaults.cooldown + 0.05,
            minSpeed = defaults.minSpeed + 15,
            pingOffset = defaults.pingOffset + 0.02,
            minTTI = defaults.minTTI + 0.05,
            maxTTI = defaults.maxTTI + 0.10,
            safeRadius = defaults.safeRadius + 5,
            targetHighlightName = (defaults.targetHighlightName and (defaults.targetHighlightName .. "_Override")) or "HighlightOverride",
            ballsFolderName = (defaults.ballsFolderName and (defaults.ballsFolderName .. "_Override")) or "Projectiles",
            playerTimeout = defaults.playerTimeout + 5,
            remotesTimeout = defaults.remotesTimeout + 5,
            ballsFolderTimeout = defaults.ballsFolderTimeout + 5,
            verificationRetryInterval = defaults.verificationRetryInterval + 0.1,
        }

        for key, value in pairs(validOverrides) do
            local result = autoparry.configure({ [key] = value })
            expect(result[key]):toEqual(value)
        end

        local mutated = autoparry.getConfig()
        for key, expected in pairs(validOverrides) do
            expect(mutated[key]):toEqual(expected)
        end

        local reset = autoparry.resetConfig()
        for key, expected in pairs(defaultsSnapshot) do
            expect(reset[key]):toEqual(expected)
        end

        for key in pairs(reset) do
            expect(defaultsSnapshot[key] ~= nil):toBeTruthy()
        end

        autoparry.destroy()
    end)

    t.test("configure rejects invalid overrides for default options", function(expect)
        local autoparry = loadAutoparry()
        local defaults = autoparry.getConfig()

        local invalidOverrides = {
            cooldown = -1,
            minSpeed = -5,
            pingOffset = "offset",
            minTTI = -0.25,
            maxTTI = -0.5,
            safeRadius = -10,
            targetHighlightName = "",
            ballsFolderName = "",
            playerTimeout = -1,
            remotesTimeout = -1,
            ballsFolderTimeout = -1,
            verificationRetryInterval = -0.1,
        }

        for key, value in pairs(invalidOverrides) do
            local ok, err = pcall(function()
                autoparry.configure({ [key] = value })
            end)

            expect(ok):toEqual(false)
            expect(err):toEqual(("AutoParry.configure: invalid value for '%s'"):format(key))

            local current = autoparry.getConfig()
            expect(current[key]):toEqual(defaults[key])
        end

        autoparry.destroy()
    end)

    t.test("targetHighlightName accepts nil but rejects empty strings", function(expect)
        local autoparry = loadAutoparry()
        local defaults = autoparry.getConfig()

        local result = autoparry.configure({ targetHighlightName = nil })
        expect(result.targetHighlightName == nil):toBeTruthy()

        local current = autoparry.getConfig()
        expect(current.targetHighlightName == nil):toBeTruthy()

        local ok, err = pcall(function()
            autoparry.configure({ targetHighlightName = "" })
        end)

        expect(ok):toEqual(false)
        expect(err):toEqual("AutoParry.configure: invalid value for 'targetHighlightName'")

        local afterFailure = autoparry.getConfig()
        expect(afterFailure.targetHighlightName == nil):toBeTruthy()

        local restored = autoparry.resetConfig()
        expect(restored.targetHighlightName):toEqual(defaults.targetHighlightName)

        autoparry.destroy()
    end)
end
