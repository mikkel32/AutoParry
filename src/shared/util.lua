-- mikkel32/AutoParry : src/shared/util.lua
-- Shared helpers for table utilities and lightweight signals.

local Util = {}

local Signal = {}
Signal.__index = Signal

function Signal.new()
    return setmetatable({ _connections = {}, _nextId = 0 }, Signal)
end

function Signal:connect(handler)
    assert(typeof(handler) == "function", "Signal:connect expects a function")
    if not self._connections then
        local stub = { Disconnect = function() end }
        stub.disconnect = stub.Disconnect
        return stub
    end

    self._nextId = self._nextId + 1
    local id = self._nextId
    self._connections[id] = handler

    local connection = { _signal = self, _id = id }

    function connection.Disconnect(conn)
        local signal = rawget(conn, "_signal")
        if signal and signal._connections then
            signal._connections[conn._id] = nil
        end
        conn._signal = nil
    end

    connection.disconnect = connection.Disconnect

    return connection
end

function Signal:fire(...)
    if not self._connections then
        return
    end

    for _, handler in pairs(self._connections) do
        task.spawn(handler, ...)
    end
end

function Signal:destroy()
    self._connections = nil
end

Util.Signal = Signal

function Util.deepCopy(value, seen)
    if typeof(value) ~= "table" then
        return value
    end

    seen = seen or {}
    local existing = seen[value]
    if existing ~= nil then
        return existing
    end

    local copy = {}
    seen[value] = copy

    for key, val in pairs(value) do
        local copiedKey = Util.deepCopy(key, seen)
        local copiedValue = Util.deepCopy(val, seen)
        copy[copiedKey] = copiedValue
    end

    local metatable = getmetatable(value)
    if metatable ~= nil then
        if typeof(metatable) == "table" then
            setmetatable(copy, Util.deepCopy(metatable, seen))
        else
            setmetatable(copy, metatable)
        end
    end

    return copy
end

function Util.merge(into, from)
    assert(typeof(into) == "table", "Util.merge: into must be a table")
    if typeof(from) ~= "table" then
        return into
    end

    for key, value in pairs(from) do
        into[key] = value
    end

    return into
end

function Util.setConstraintSize(constraint, minSize, maxSize)
    if typeof(constraint) ~= "Instance" then
        return
    end

    if constraint.ClassName ~= "UISizeConstraint" and not constraint:IsA("UISizeConstraint") then
        return
    end

    minSize = minSize or Vector2.new(0, 0)
    maxSize = maxSize or Vector2.new(0, 0)

    local minX = math.max(0, minSize.X or 0)
    local minY = math.max(0, minSize.Y or 0)
    local maxX = math.max(minX, maxSize.X or 0)
    local maxY = math.max(minY, maxSize.Y or 0)

    local currentMax = constraint.MaxSize or Vector2.new(math.huge, math.huge)
    local newMin = Vector2.new(minX, minY)
    local newMax = Vector2.new(maxX, maxY)

    if currentMax.X < minX or currentMax.Y < minY then
        constraint.MaxSize = newMax
        constraint.MinSize = newMin
    else
        constraint.MinSize = newMin
        constraint.MaxSize = newMax
    end
end

return Util
