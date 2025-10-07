local TestHarness = script.Parent.Parent
local Harness = require(TestHarness:WaitForChild("Harness"))

local Scheduler = Harness.Scheduler

local function waitForStage(scheduler, autoparry, target, maxSteps)
    local limit = maxSteps or 40
    local progress

    for _ = 1, limit do
        progress = autoparry.getInitProgress()
        if progress.stage == target or progress.stage == "timeout" then
            return progress
        end

        scheduler:wait()
    end

    error(string.format("Timed out waiting for init stage '%s'", tostring(target)), 0)
end

return function(t)
    t.test("resolves the local player once it becomes available", function(expect)
        local scheduler = Scheduler.new(1)
        local services, remotes, players = Harness.createBaseServices(scheduler)
        remotes:Add(Harness.createRemote())

        local stubPlayer = { Name = "LocalPlayer" }
        scheduler:schedule(3, function()
            players.LocalPlayer = stubPlayer
        end)

        local autoparry = Harness.loadAutoparry({
            scheduler = scheduler,
            services = services,
        })

        local stages = {}
        local connection = autoparry.onInitStatus(function(progress)
            table.insert(stages, { stage = progress.stage, target = progress.target })
        end)

        local ready = waitForStage(scheduler, autoparry, "ready")

        expect(autoparry ~= nil):toBeTruthy()
        expect(players.LocalPlayer):toEqual(stubPlayer)
        expect(scheduler:clock()):toBeCloseTo(3, 1e-3)
        expect(ready.elapsed):toBeCloseTo(3, 1e-3)
        expect(stages[1].stage):toEqual("waiting-player")
        expect(stages[#stages].stage):toEqual("ready")

        local snapshot = autoparry.getInitProgress()
        snapshot.stage = "mutated"
        expect(autoparry.getInitProgress().stage):toEqual("ready")

        if connection then
            connection:Disconnect()
        end
    end)

    t.test("resolves the parry remote after it is created", function(expect)
        local scheduler = Scheduler.new(1)
        local services, remotes = Harness.createBaseServices(scheduler, {
            initialLocalPlayer = { Name = "LocalPlayer" },
        })

        scheduler:schedule(4, function()
            remotes:Add(Harness.createRemote())
        end)

        local autoparry = Harness.loadAutoparry({
            scheduler = scheduler,
            services = services,
        })

        local stages = {}
        local connection = autoparry.onInitStatus(function(progress)
            table.insert(stages, { stage = progress.stage, target = progress.target })
        end)

        local ready = waitForStage(scheduler, autoparry, "ready")

        expect(autoparry ~= nil):toBeTruthy()
        expect(remotes:FindFirstChild("ParryButtonPress") ~= nil):toBeTruthy()
        expect(scheduler:clock()):toBeCloseTo(4, 1e-3)
        expect(ready.elapsed):toBeCloseTo(4, 1e-3)

        local sawRemoteStage = false
        for _, item in ipairs(stages) do
            if item.stage == "waiting-remotes" and item.target == "remote" then
                sawRemoteStage = true
                break
            end
        end

        expect(sawRemoteStage):toEqual(true)

        if connection then
            connection:Disconnect()
        end
    end)

    t.test("errors after 10 seconds when the local player never appears", function(expect)
        local scheduler = Scheduler.new(1)
        local services, remotes = Harness.createBaseServices(scheduler)
        remotes:Add(Harness.createRemote())

        local autoparry = Harness.loadAutoparry({
            scheduler = scheduler,
            services = services,
        })

        local progress = waitForStage(scheduler, autoparry, "timeout", 20)

        expect(progress.stage):toEqual("timeout")
        expect(progress.reason):toEqual("local-player")
        expect(progress.elapsed):toBeGreaterThanOrEqual(10)
        expect(scheduler:clock()):toBeGreaterThanOrEqual(10)

        local ok, err = pcall(function()
            autoparry.enable()
        end)

        expect(ok):toEqual(false)
        expect(err):toEqual("AutoParry: LocalPlayer unavailable")
    end)

    t.test("errors after 10 seconds when the remotes folder is absent", function(expect)
        local scheduler = Scheduler.new(1)
        local services = Harness.createBaseServices(scheduler, {
            includeRemotes = false,
            initialLocalPlayer = { Name = "LocalPlayer" },
        })

        local autoparry = Harness.loadAutoparry({
            scheduler = scheduler,
            services = services,
        })

        local progress = waitForStage(scheduler, autoparry, "timeout", 20)

        expect(progress.stage):toEqual("timeout")
        expect(progress.reason):toEqual("remotes-folder")
        expect(progress.elapsed):toBeGreaterThanOrEqual(10)
        expect(scheduler:clock()):toBeGreaterThanOrEqual(10)

        local ok, err = pcall(function()
            autoparry.enable()
        end)

        expect(ok):toEqual(false)
        expect(err):toEqual("AutoParry: ReplicatedStorage.Remotes missing")
    end)

    t.test("errors after 10 seconds when the parry remote never appears", function(expect)
        local scheduler = Scheduler.new(1)
        local services = Harness.createBaseServices(scheduler, {
            initialLocalPlayer = { Name = "LocalPlayer" },
        })

        local autoparry = Harness.loadAutoparry({
            scheduler = scheduler,
            services = services,
        })

        local progress = waitForStage(scheduler, autoparry, "timeout", 20)

        expect(progress.stage):toEqual("timeout")
        expect(progress.reason):toEqual("parry-remote")
        expect(progress.elapsed):toBeGreaterThanOrEqual(10)
        expect(scheduler:clock()):toBeGreaterThanOrEqual(10)

        local ok, err = pcall(function()
            autoparry.enable()
        end)

        expect(ok):toEqual(false)
        expect(err):toEqual("AutoParry: ParryButtonPress remote missing")
    end)
end
