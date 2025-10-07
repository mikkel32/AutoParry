-- selene: allow(global_usage)
local TestHarness = script.Parent.Parent
local SourceMap = require(TestHarness:WaitForChild("AutoParrySourceMap"))

local function createVirtualRequire()
    local cache = {}

    local function virtualRequire(path)
        local source = SourceMap[path]
        assert(source, "Missing source map entry for " .. tostring(path))

        if cache[path] ~= nil then
            return cache[path]
        end

        local chunk, err = loadstring(source, "=" .. path)
        assert(chunk, err)

        local previous = rawget(_G, "ARequire")
        rawset(_G, "ARequire", virtualRequire)

        local ok, result = pcall(chunk)

        if previous == nil then
            rawset(_G, "ARequire", nil)
        else
            rawset(_G, "ARequire", previous)
        end

        if not ok then
            error(result, 0)
        end

        cache[path] = result
        return result
    end

    return virtualRequire
end

local function loadVerificationDashboard()
    local originalRequire = rawget(_G, "ARequire")
    local virtualRequire = createVirtualRequire()
    rawset(_G, "ARequire", virtualRequire)

    local chunk, err = loadstring(SourceMap["src/ui/verification_dashboard.lua"], "=src/ui/verification_dashboard.lua")
    assert(chunk, err)

    local ok, dashboard = pcall(chunk)

    if originalRequire == nil then
        rawset(_G, "ARequire", nil)
    else
        rawset(_G, "ARequire", originalRequire)
    end

    if not ok then
        error(dashboard, 0)
    end

    return dashboard
end

local function createContainer()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "VerificationDashboardSpec"

    local frame = Instance.new("Frame")
    frame.Name = "Root"
    frame.Size = UDim2.new(0, 960, 0, 540)
    frame.Parent = screenGui

    return screenGui, frame
end

return function(t)
    t.test("updates step states across the verification timeline", function(expect)
        local Dashboard = loadVerificationDashboard()
        local screenGui, frame = createContainer()

        local dashboard = Dashboard.new({ parent = frame })

        -- Player stage transitions
        dashboard:update({ stage = "waiting-player", status = "pending", elapsed = 0 })
        expect(dashboard._steps.player.state):toEqual("active")
        expect(dashboard._steps.player.status.Text):toEqual("Waiting for player…")

        dashboard:update({ stage = "waiting-player", status = "ok", elapsed = 1.25 })
        expect(dashboard._steps.player.state):toEqual("ok")
        expect(dashboard._steps.player.status.Text):toEqual("Player ready (1.3 s)")

        -- Remotes folder and parry remote discovery
        dashboard:update({ stage = "waiting-remotes", target = "folder", status = "pending", elapsed = 0 })
        expect(dashboard._steps.remotes.state):toEqual("active")
        expect(dashboard._steps.remotes.status.Text):toEqual("Searching for Remotes folder…")

        dashboard:update({ stage = "waiting-remotes", target = "folder", status = "ok", elapsed = 0.6 })
        expect(dashboard._steps.remotes.state):toEqual("active")
        expect(dashboard._steps.remotes.status.Text):toEqual("Remotes folder located")

        dashboard:update({ stage = "waiting-remotes", target = "remote", status = "waiting", elapsed = 1.4 })
        expect(dashboard._steps.remotes.state):toEqual("active")
        expect(dashboard._steps.remotes.status.Text):toEqual("Scanning for parry remote…")

        dashboard:update({ stage = "waiting-remotes", target = "remote", status = "ok", remoteName = "ParryButtonPress", remoteVariant = "modern", elapsed = 2.2 })
        expect(dashboard._steps.remotes.state):toEqual("ok")
        expect(dashboard._steps.remotes.status.Text):toEqual("ParryButtonPress (modern)")

        -- Success remote wiring
        dashboard:update({ stage = "verifying-success-remotes", status = "observed" })
        expect(dashboard._steps.success.state):toEqual("active")
        expect(dashboard._steps.success.status.Text):toEqual("Hooking success events…")

        dashboard:update({ stage = "verifying-success-remotes", status = "configured", remotes = { ParrySuccess = {}, ParrySuccessAll = {} } })
        expect(dashboard._steps.success.state):toEqual("ok")
        expect(dashboard._steps.success.status.Text):toEqual("Success listeners bound")

        -- Balls verification
        dashboard:update({ stage = "verifying-balls", status = "waiting", elapsed = 3.1 })
        expect(dashboard._steps.balls.state):toEqual("active")
        expect(dashboard._steps.balls.status.Text):toEqual("Searching for balls…")

        dashboard:update({ stage = "verifying-balls", status = "ok", elapsed = 3.8 })
        expect(dashboard._steps.balls.state):toEqual("ok")
        expect(dashboard._steps.balls.status.Text):toEqual("Ball telemetry online")

        -- Final ready snapshot should lock all steps
        dashboard:update({
            stage = "ready",
            remoteName = "ParryButtonPress",
            remoteVariant = "modern",
            successEvents = { ParrySuccess = true, ParrySuccessAll = true, Balls = true },
        })

        expect(dashboard._steps.player.state):toEqual("ok")
        expect(dashboard._steps.player.status.Text):toEqual("Player locked")
        expect(dashboard._steps.remotes.status.Text):toEqual("ParryButtonPress (modern)")
        expect(dashboard._steps.success.status.Text):toEqual("Success listeners wired")
        expect(dashboard._steps.balls.status.Text):toEqual("Ball telemetry streaming")

        dashboard:destroy()
        screenGui:Destroy()
    end)

    t.test("surfaces warnings when the balls folder times out", function(expect)
        local Dashboard = loadVerificationDashboard()
        local screenGui, frame = createContainer()

        local dashboard = Dashboard.new({ parent = frame })

        dashboard:update({ stage = "verifying-balls", status = "warning", reason = "timeout", elapsed = 5.0 })

        expect(dashboard._steps.balls.state):toEqual("warning")
        expect(dashboard._steps.balls.status.Text):toEqual("Ball folder timeout")
        expect(dashboard._steps.balls.tooltip.Text):toEqual("AutoParry will continue without ball telemetry if the folder is missing.")

        dashboard:destroy()
        screenGui:Destroy()
    end)
end
