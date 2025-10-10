local TestHarness = script.Parent.Parent
local RuntimeFolder = TestHarness:WaitForChild("engine")
local Runtime = require(RuntimeFolder:WaitForChild("runtime"))

local Scheduler = Runtime.Scheduler

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
        local services, remotes, players = Runtime.createBaseServices(scheduler)
        remotes:Add(Runtime.createParryButtonPress({ scheduler = scheduler }))

        local stubPlayer = { Name = "LocalPlayer" }
        scheduler:schedule(3, function()
            players:_setLocalPlayer(stubPlayer)
        end)

        local autoparry = Runtime.loadAutoparry({
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
        expect(ready.successEvents ~= nil):toEqual(true)
        expect(ready.successEvents.ParrySuccess):toEqual(false)
        expect(ready.successEvents.ParrySuccessAll):toEqual(false)

        local snapshot = autoparry.getInitProgress()
        snapshot.stage = "mutated"
        expect(autoparry.getInitProgress().stage):toEqual("ready")

        if connection then
            connection:Disconnect()
        end
    end)

    t.test("resolves the parry remote after it is created", function(expect)
        local scheduler = Scheduler.new(1)
        local services, remotes = Runtime.createBaseServices(scheduler, {
            initialLocalPlayer = { Name = "LocalPlayer" },
        })

        scheduler:schedule(4, function()
            remotes:Add(Runtime.createParryButtonPress({ scheduler = scheduler }))
        end)

        local autoparry = Runtime.loadAutoparry({
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
        expect(ready.remoteName):toEqual("ParryButtonPress")
        expect(ready.remoteVariant):toEqual("modern")
        expect(ready.successEvents.ParrySuccess):toEqual(false)
        expect(ready.successEvents.ParrySuccessAll):toEqual(false)

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
        local services, remotes = Runtime.createBaseServices(scheduler)
        remotes:Add(Runtime.createParryButtonPress({ scheduler = scheduler }))

        local autoparry = Runtime.loadAutoparry({
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
        local services = Runtime.createBaseServices(scheduler, {
            includeRemotes = false,
            initialLocalPlayer = { Name = "LocalPlayer" },
        })

        local autoparry = Runtime.loadAutoparry({
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
        local services = Runtime.createBaseServices(scheduler, {
            initialLocalPlayer = { Name = "LocalPlayer" },
        })

        local autoparry = Runtime.loadAutoparry({
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
        expect(err):toEqual("AutoParry: parry remote missing (ParryButtonPress.parryButtonPress)")
    end)

    t.test("errors when the parry remote lacks a supported fire method", function(expect)
        local scheduler = Scheduler.new(1)
        local services, remotes = Runtime.createBaseServices(scheduler, {
            initialLocalPlayer = { Name = "LocalPlayer" },
        })

        local invalidContainer, invalidChild = Runtime.createParryButtonPress({ scheduler = scheduler })
        invalidChild.Fire = nil
        invalidChild.FireServer = nil
        remotes:Add(invalidContainer)

        local autoparry = Runtime.loadAutoparry({
            scheduler = scheduler,
            services = services,
        })

        local progress = waitForStage(scheduler, autoparry, "error", 20)

        expect(progress.stage):toEqual("error")
        expect(progress.target):toEqual("remote")
        expect(progress.reason):toEqual("parry-remote-missing-method")
        expect(progress.className):toEqual("BindableEvent")
        expect(progress.message):toEqual("AutoParry: ParryButtonPress.parryButtonPress missing Fire")

        local ok, err = pcall(function()
            autoparry.enable()
        end)

        expect(ok):toEqual(false)
        expect(err):toEqual("AutoParry: ParryButtonPress.parryButtonPress missing Fire")
    end)

    t.test("listens for parry success events when they exist", function(expect)
        local scheduler = Scheduler.new(1)
        local services, remotes = Runtime.createBaseServices(scheduler, {
            initialLocalPlayer = { Name = "LocalPlayer" },
        })

        local parryContainer = Runtime.createParryButtonPress({ scheduler = scheduler })
        remotes:Add(parryContainer)
        local successRemote = Runtime.createRemote({ name = "ParrySuccess" })
        remotes:Add(successRemote)
        local successAllRemote = Runtime.createRemote({ name = "ParrySuccessAll" })
        remotes:Add(successAllRemote)

        local autoparry = Runtime.loadAutoparry({
            scheduler = scheduler,
            services = services,
        })

        local ready = waitForStage(scheduler, autoparry, "ready")

        expect(ready.successEvents.ParrySuccess):toEqual(true)
        expect(ready.successEvents.ParrySuccessAll):toEqual(true)
        expect(autoparry.getLastParrySuccessTime()):toEqual(0)
        expect(autoparry.getLastParryBroadcastTime()):toEqual(0)

        local successLog = {}
        local broadcastLog = {}

        local successConnection = autoparry.onParrySuccess(function(...)
            table.insert(successLog, { time = scheduler:clock(), payload = { ... } })
        end)

        local broadcastConnection = autoparry.onParryBroadcast(function(...)
            table.insert(broadcastLog, { time = scheduler:clock(), payload = { ... } })
        end)

        Runtime.fireRemoteClient(successRemote, "local")
        scheduler:wait()

        expect(#successLog):toEqual(1)
        expect(autoparry.getLastParrySuccessTime()):toBeCloseTo(successLog[1].time, 1e-3)

        Runtime.fireRemoteClient(successAllRemote, "broadcast")
        scheduler:wait()

        expect(#broadcastLog):toEqual(1)
        expect(autoparry.getLastParryBroadcastTime()):toBeCloseTo(broadcastLog[1].time, 1e-3)
        expect(autoparry.getLastParryBroadcastTime()):toBeGreaterThanOrEqual(autoparry.getLastParrySuccessTime())

        if successConnection then
            successConnection:Disconnect()
        end

        if broadcastConnection then
            broadcastConnection:Disconnect()
        end

        autoparry.destroy()
    end)

    t.test("restarts initialization when the parry remote is removed", function(expect)
        local scheduler = Scheduler.new(1)
        local services, remotes = Runtime.createBaseServices(scheduler, {
            initialLocalPlayer = { Name = "LocalPlayer" },
        })

        local parryContainer = Runtime.createParryButtonPress({ scheduler = scheduler })
        remotes:Add(parryContainer)

        local autoparry = Runtime.loadAutoparry({
            scheduler = scheduler,
            services = services,
        })

        local stages = {}
        local connection = autoparry.onInitStatus(function(progress)
            table.insert(stages, progress)
        end)

        local ready = waitForStage(scheduler, autoparry, "ready")
        expect(ready.remoteName):toEqual("ParryButtonPress")

        remotes:Remove(parryContainer.Name)
        scheduler:wait()

        local sawRestart = false
        local restartDetails
        for _, stage in ipairs(stages) do
            if stage.stage == "restarting" then
                sawRestart = true
                restartDetails = stage
            end
        end

        expect(sawRestart):toEqual(true)
        expect(restartDetails ~= nil):toEqual(true)
        expect(restartDetails.reason):toEqual("parry-remote-removed")
        expect(restartDetails.remoteName):toEqual("ParryButtonPress")

            scheduler:schedule(2, function()
                remotes:Add(Runtime.createParryButtonPress({ scheduler = scheduler }))
            end)

        local readyAgain = waitForStage(scheduler, autoparry, "ready")
        expect(readyAgain.remoteName):toEqual("ParryButtonPress")
        expect(readyAgain.elapsed):toBeGreaterThan(ready.elapsed)

        if connection then
            connection:Disconnect()
        end
    end)
end
