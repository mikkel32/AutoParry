local TestHarness = script.Parent.Parent
local Harness = require(TestHarness:WaitForChild("Harness"))

local Scheduler = Harness.Scheduler

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

        expect(autoparry ~= nil):toBeTruthy()
        expect(players.LocalPlayer):toEqual(stubPlayer)
        expect(scheduler:clock()):toBeCloseTo(3, 1e-3)
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

        expect(autoparry ~= nil):toBeTruthy()
        expect(remotes:FindFirstChild("ParryButtonPress") ~= nil):toBeTruthy()
        expect(scheduler:clock()):toBeCloseTo(4, 1e-3)
    end)

    t.test("errors after 10 seconds when the local player never appears", function(expect)
        local scheduler = Scheduler.new(1)
        local services, remotes = Harness.createBaseServices(scheduler)
        remotes:Add(Harness.createRemote())

        local ok, err = pcall(function()
            Harness.loadAutoparry({
                scheduler = scheduler,
                services = services,
            })
        end)

        expect(ok):toEqual(false)
        expect(err):toEqual("AutoParry: LocalPlayer unavailable")
        expect(scheduler:clock()):toBeGreaterThanOrEqual(11)
    end)

    t.test("errors after 10 seconds when the remotes folder is absent", function(expect)
        local scheduler = Scheduler.new(1)
        local services = Harness.createBaseServices(scheduler, {
            includeRemotes = false,
            initialLocalPlayer = { Name = "LocalPlayer" },
        })

        local ok, err = pcall(function()
            Harness.loadAutoparry({
                scheduler = scheduler,
                services = services,
            })
        end)

        expect(ok):toEqual(false)
        expect(err):toEqual("AutoParry: ReplicatedStorage.Remotes missing")
        expect(scheduler:clock()):toBeGreaterThanOrEqual(10)
    end)

    t.test("errors after 10 seconds when the parry remote never appears", function(expect)
        local scheduler = Scheduler.new(1)
        local services = Harness.createBaseServices(scheduler, {
            initialLocalPlayer = { Name = "LocalPlayer" },
        })

        local ok, err = pcall(function()
            Harness.loadAutoparry({
                scheduler = scheduler,
                services = services,
            })
        end)

        expect(ok):toEqual(false)
        expect(err):toEqual("AutoParry: ParryButtonPress remote missing")
        expect(scheduler:clock()):toBeGreaterThanOrEqual(10)
    end)
end
