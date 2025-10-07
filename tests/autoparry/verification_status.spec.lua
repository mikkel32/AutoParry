local TestHarness = script.Parent.Parent
local Harness = require(TestHarness:WaitForChild("Harness"))

local Scheduler = Harness.Scheduler

local function waitForStage(scheduler, autoparry, stage, maxSteps)
    local limit = maxSteps or 60

    for _ = 1, limit do
        local progress = autoparry.getInitProgress()
        if progress.stage == stage then
            return progress
        end

        scheduler:wait()
    end

    error(string.format("Timed out waiting for init stage '%s'", tostring(stage)), 0)
end

return function(t)
    t.test("waits for ball telemetry verification before enabling", function(expect)
        local scheduler = Scheduler.new(1)
        local services, remotes = Harness.createBaseServices(scheduler, {
            initialLocalPlayer = { Name = "LocalPlayer" },
        })

        local workspace = Harness.createContainer(scheduler, "Workspace")
        services.Workspace = workspace

        local originalWorkspace = rawget(_G, "workspace")
        rawset(_G, "workspace", workspace)

        local ok, err = pcall(function()
            remotes:Add(Harness.createParryButtonPress({ scheduler = scheduler }))

            local autoparry = Harness.loadAutoparry({
                scheduler = scheduler,
                services = services,
            })

            local verifying = {}
            local connection = autoparry.onInitStatus(function(progress)
                if progress.stage == "verifying-balls" then
                    table.insert(verifying, { status = progress.status, elapsed = progress.elapsed })
                end
            end)

            scheduler:schedule(3, function()
                workspace:Add(Harness.createContainer(scheduler, "Balls"))
            end)

            local beforeEnable = scheduler:clock()
            autoparry.enable()
            local afterEnable = scheduler:clock()

            expect(afterEnable):toBeGreaterThanOrEqual(beforeEnable + 3)
            expect(#verifying > 0):toEqual(true)
            expect(verifying[1].status):toEqual("pending")

            local sawWaiting = false
            for index, snapshot in ipairs(verifying) do
                if snapshot.status == "waiting" then
                    sawWaiting = true
                end

                if index == #verifying then
                    expect(snapshot.status):toEqual("ok")
                    expect(snapshot.elapsed):toBeGreaterThanOrEqual(3)
                end
            end

            expect(sawWaiting):toEqual(true)

            if connection then
                connection:Disconnect()
            end

            autoparry.destroy()
        end)

        rawset(_G, "workspace", originalWorkspace)

        if not ok then
            error(err, 0)
        end
    end)

    t.test("reports missing success remotes during verification", function(expect)
        local scheduler = Scheduler.new(1)
        local services, remotes = Harness.createBaseServices(scheduler, {
            initialLocalPlayer = { Name = "LocalPlayer" },
        })

        local workspace = Harness.createContainer(scheduler, "Workspace")
        services.Workspace = workspace
        workspace:Add(Harness.createContainer(scheduler, "Balls"))

        local originalWorkspace = rawget(_G, "workspace")
        rawset(_G, "workspace", workspace)

        local ok, err = pcall(function()
            remotes:Add(Harness.createParryButtonPress({ scheduler = scheduler }))

            local autoparry = Harness.loadAutoparry({
                scheduler = scheduler,
                services = services,
            })

            local observedStatus
            local configuredStatus
            local connection = autoparry.onInitStatus(function(progress)
                if progress.stage == "verifying-success-remotes" then
                    if progress.status == "observed" then
                        observedStatus = progress
                    elseif progress.status == "configured" then
                        configuredStatus = progress
                    end
                end
            end)

            local ready = waitForStage(scheduler, autoparry, "ready")
            expect(ready.successEvents.ParrySuccess):toEqual(false)
            expect(ready.successEvents.ParrySuccessAll):toEqual(false)

            expect(observedStatus ~= nil):toEqual(true)
            expect(observedStatus.remotes ~= nil):toEqual(true)
            expect(observedStatus.remotes.ParrySuccess.available):toEqual(false)
            expect(observedStatus.remotes.ParrySuccessAll.available):toEqual(false)

            expect(configuredStatus ~= nil):toEqual(true)
            expect(configuredStatus.success ~= nil):toEqual(true)
            expect(configuredStatus.success.results.ParrySuccess.code):toEqual("removeevents-missing")
            expect(configuredStatus.success.results.ParrySuccessAll.code):toEqual("removeevents-missing")

            if connection then
                connection:Disconnect()
            end

            autoparry.destroy()
        end)

        rawset(_G, "workspace", originalWorkspace)

        if not ok then
            error(err, 0)
        end
    end)

    t.test("restarts verification ladder after the parry remote is removed", function(expect)
        local scheduler = Scheduler.new(1)
        local services, remotes = Harness.createBaseServices(scheduler, {
            initialLocalPlayer = { Name = "LocalPlayer" },
        })

        local workspace = Harness.createContainer(scheduler, "Workspace")
        services.Workspace = workspace
        workspace:Add(Harness.createContainer(scheduler, "Balls"))

        local originalWorkspace = rawget(_G, "workspace")
        rawset(_G, "workspace", workspace)

        local ok, err = pcall(function()
            local parryContainer = Harness.createParryButtonPress({ scheduler = scheduler })
            remotes:Add(parryContainer)

            local autoparry = Harness.loadAutoparry({
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

            scheduler:schedule(2, function()
                remotes:Add(Harness.createParryButtonPress({ scheduler = scheduler }))
            end)

            local readyAgain = waitForStage(scheduler, autoparry, "ready", 80)
            expect(readyAgain.elapsed):toBeGreaterThan(ready.elapsed)

            local restartIndex
            for index, progress in ipairs(stages) do
                if progress.stage == "restarting" and progress.reason == "parry-remote-removed" then
                    restartIndex = index
                    break
                end
            end

            expect(restartIndex ~= nil):toEqual(true)

            local sawPending, sawWaiting, sawOk = false, false, false
            for index = restartIndex + 1, #stages do
                local progress = stages[index]
                if progress.stage == "waiting-remotes" and progress.target == "remote" then
                    if progress.status == "pending" then
                        sawPending = true
                    elseif progress.status == "waiting" then
                        sawWaiting = true
                    elseif progress.status == "ok" then
                        sawOk = true
                        expect(progress.remoteName):toEqual("ParryButtonPress")
                    end
                end
            end

            expect(sawPending):toEqual(true)
            expect(sawWaiting):toEqual(true)
            expect(sawOk):toEqual(true)

            if connection then
                connection:Disconnect()
            end

            autoparry.destroy()
        end)

        rawset(_G, "workspace", originalWorkspace)

        if not ok then
            error(err, 0)
        end
    end)
end
