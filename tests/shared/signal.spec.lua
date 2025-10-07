-- selene: allow(global_usage)
local TestHarness = script.Parent.Parent
local SourceMap = require(TestHarness:WaitForChild("AutoParrySourceMap"))

local function loadUtilModule()
    local chunk, err = loadstring(SourceMap["src/shared/util.lua"], "=src/shared/util.lua")
    assert(chunk, err)

    local previous = rawget(_G, "ARequire")
    local ok, result = pcall(chunk)

    if previous == nil then
        rawset(_G, "ARequire", nil)
    else
        rawset(_G, "ARequire", previous)
    end

    if not ok then
        error(result, 0)
    end

    return result
end

local function withTaskQueue(callback)
    local originalSpawn = task.spawn
    local queue = {}

    task.spawn = function(callbackFn, ...)
        local args = { ... }
        args.n = select("#", ...)
        table.insert(queue, { callback = callbackFn, args = args })
    end

    local function pendingCount()
        return #queue
    end

    local function flush()
        local pending = queue
        queue = {}

        for index = 1, #pending do
            local job = pending[index]
            local count = job.args.n or #job.args

            if count == 0 then
                job.callback()
            else
                job.callback(table.unpack(job.args, 1, count))
            end
        end
    end

    local ok, result = pcall(callback, pendingCount, flush)

    task.spawn = originalSpawn

    if not ok then
        error(result, 0)
    end

    return result
end

return function(t)
    local Util = loadUtilModule()
    local Signal = Util.Signal

    t.test("connect returns disconnectable connections", function(expect)
        withTaskQueue(function(pendingCount, flush)
            local signal = Signal.new()
            local calls = {}

            local function record(name, ...)
                calls[name] = calls[name] or {}
                table.insert(calls[name], { ... })
            end

            local firstConnection = signal:connect(function(...)
                record("first", ...)
            end)

            local secondConnection = signal:connect(function(...)
                record("second", ...)
            end)

            expect(typeof(firstConnection) == "table"):toBeTruthy()
            expect(typeof(secondConnection) == "table"):toBeTruthy()

            signal:fire("alpha", 1)
            expect(pendingCount()):toEqual(2)
            expect(calls.first == nil):toBeTruthy() -- handlers haven't run yet
            flush()

            expect(#calls.first):toEqual(1)
            expect(calls.first[1][1]):toEqual("alpha")
            expect(calls.first[1][2]):toEqual(1)
            expect(#calls.second):toEqual(1)

            firstConnection:Disconnect()
            expect(rawget(firstConnection, "_signal")):toEqual(nil)

            signal:fire("beta")
            expect(pendingCount()):toEqual(1)
            flush()

            expect(#calls.first):toEqual(1)
            expect(#calls.second):toEqual(2)
            expect(calls.second[2][1]):toEqual("beta")

            secondConnection:disconnect()

            signal:fire("gamma")
            expect(pendingCount()):toEqual(0)
            flush()

            expect(#calls.second):toEqual(2)
        end)
    end)

    t.test("handlers can mutate connections while firing", function(expect)
        withTaskQueue(function(_, flush)
            local signal = Signal.new()

            local firstCalls = {}
            local secondCalls = {}
            local thirdCalls = {}

            local firstConnection
            firstConnection = signal:connect(function(value)
                table.insert(firstCalls, value)
                firstConnection:Disconnect()

                signal:connect(function(nextValue)
                    table.insert(thirdCalls, nextValue)
                end)
            end)

            signal:connect(function(value)
                table.insert(secondCalls, value)
            end)

            signal:fire("alpha")
            flush()

            signal:fire("beta")
            flush()

            expect(#firstCalls):toEqual(1)
            expect(firstCalls[1]):toEqual("alpha")

            expect(#secondCalls):toEqual(2)
            expect(secondCalls[1]):toEqual("alpha")
            expect(secondCalls[2]):toEqual("beta")

            expect(#thirdCalls):toEqual(1)
            expect(thirdCalls[1]):toEqual("beta")
        end)
    end)

    t.test("fire dispatches asynchronously via task.spawn", function(expect)
        withTaskQueue(function(pendingCount, flush)
            local signal = Signal.new()
            local called = false

            signal:connect(function()
                called = true
            end)

            expect(called):toEqual(false)
            expect(pendingCount()):toEqual(0)

            signal:fire("payload")

            expect(pendingCount()):toEqual(1)
            expect(called):toEqual(false)

            flush()

            expect(called):toEqual(true)
            expect(pendingCount()):toEqual(0)
        end)
    end)

    t.test("destroy prevents future events and new signals remain isolated", function(expect)
        withTaskQueue(function(pendingCount, flush)
            local destroyedSignal = Signal.new()
            local destroyedCalls = 0

            destroyedSignal:connect(function()
                destroyedCalls += 1
            end)

            destroyedSignal:destroy()

            local stub = destroyedSignal:connect(function()
                destroyedCalls += 10
            end)

            expect(typeof(stub) == "table"):toBeTruthy()
            expect(typeof(stub.Disconnect) == "function"):toBeTruthy()

            destroyedSignal:fire()
            expect(pendingCount()):toEqual(0)
            flush()
            expect(destroyedCalls):toEqual(0)

            local freshSignal = Signal.new()
            local freshCalls = 0

            freshSignal:connect(function()
                freshCalls += 1
            end)

            freshSignal:fire()
            expect(pendingCount()):toEqual(1)
            flush()
            expect(freshCalls):toEqual(1)

            freshSignal:destroy()
            freshSignal:fire()
            expect(pendingCount()):toEqual(0)
            flush()
            expect(freshCalls):toEqual(1)

            local independentSignal = Signal.new()
            local independentCalls = 0

            independentSignal:connect(function()
                independentCalls += 1
            end)

            independentSignal:fire()
            expect(pendingCount()):toEqual(1)
            flush()
            expect(independentCalls):toEqual(1)
        end)
    end)

    t.test("handles large connection volumes without leaking", function(expect)
        withTaskQueue(function(_, flush)
            local signal = Signal.new()
            local connections = {}
            local total = 512
            local callCount = 0

            for index = 1, total do
                connections[index] = signal:connect(function()
                    callCount += 1
                end)
            end

            local function countActive()
                local active = 0
                for _, _ in pairs(signal._connections) do
                    active += 1
                end
                return active
            end

            expect(signal._nextId):toEqual(total)
            expect(countActive()):toEqual(total)

            signal:fire()
            flush()
            expect(callCount):toEqual(total)

            for index = 1, total, 2 do
                local connection = connections[index]
                if connection then
                    connection:Disconnect()
                    connections[index] = nil
                end
            end

            expect(countActive()):toEqual(math.floor(total / 2))

            signal:fire()
            flush()
            expect(callCount):toEqual(total + math.floor(total / 2))

            local additional = {}
            for index = 1, total do
                additional[index] = signal:connect(function()
                    callCount += 1
                end)
            end

            expect(signal._nextId):toEqual(total * 2)
            expect(countActive()):toEqual(math.floor(total / 2) + total)

            signal:fire()
            flush()
            expect(callCount):toEqual(total * 3)

            for _, connection in pairs(connections) do
                if connection then
                    connection:Disconnect()
                end
            end

            for _, connection in ipairs(additional) do
                connection:Disconnect()
            end

            expect(countActive()):toEqual(0)

            signal:fire()
            flush()
            expect(callCount):toEqual(total * 3)
        end)
    end)
end
