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

function Util.deepCopy(value)
    if typeof(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, val in pairs(value) do
        copy[Util.deepCopy(key)] = Util.deepCopy(val)
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

return Util
