-- selene: allow(global_usage)
local TestHarness = script.Parent.Parent
local SourceMap = require(TestHarness:WaitForChild("AutoParrySourceMap"))

local function deepCopy(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, child in pairs(value) do
        copy[key] = deepCopy(child)
    end
    return copy
end

local function createConnection()
    local connection = { disconnected = false }

    function connection.Disconnect(conn)
        conn.disconnected = true
    end

    connection.disconnect = connection.Disconnect
    return connection
end

local function createState()
    local defaultConfig = {
        cooldown = 0.45,
        minSpeed = 150,
        pingOffset = 0.05,
        nested = {
            baseline = true,
        },
    }

    return {
        ui = {
            calls = {
                setEnabled = {},
                toggle = {},
            },
            destroyCalled = false,
            onToggleCount = 0,
        },
        parry = {
            enabled = false,
            defaultConfig = deepCopy(defaultConfig),
            config = deepCopy(defaultConfig),
            lastParryTime = 2.5,
            lastParrySuccessTime = 1.25,
            lastParryBroadcastTime = 1.75,
            primaryConnection = createConnection(),
            primaryConnectionAssigned = false,
            primaryCallback = nil,
            extraConnections = {},
            extraCallbacks = {},
            stateChangedCallbacks = {},
            destroyed = false,
            calls = {
                isEnabled = 0,
                setEnabled = {},
                configure = {},
                getConfig = 0,
                resetConfig = 0,
                setLogger = {},
                getLastParryTime = 0,
                getLastParrySuccessTime = 0,
                getLastParryBroadcastTime = 0,
                onStateChanged = 0,
                onParry = {},
                onParrySuccess = {},
                onParryBroadcast = {},
                destroy = 0,
                enable = 0,
            },
        },
    }
end

local function buildUiStubSource()
    return [===[
local state = rawget(_G, "__APITest")
if not state or not state.ui then
    error("UI stub missing test state", 0)
end

local UI = {}

function UI.mount(props)
    state.ui.props = props
    state.ui.mountCount = (state.ui.mountCount or 0) + 1

    local controller = {}
    controller._enabled = props.initialState and true or false
    controller._destroyed = false
    controller._onToggle = props.onToggle

    state.ui.controller = controller

    function controller:setEnabled(enabled, context)
        context = context or {}
        local normalized = enabled and true or false
        table.insert(state.ui.calls.setEnabled, {
            enabled = normalized,
            context = context,
            before = self._enabled,
        })

        if self._destroyed then
            return self._enabled
        end

        if self._enabled == normalized then
            return self._enabled
        end

        self._enabled = normalized

        if not context.silent and type(self._onToggle) == "function" then
            state.ui.onToggleCount = (state.ui.onToggleCount or 0) + 1
            self._onToggle(normalized, context)
        end

        state.ui.lastEnabled = self._enabled
        return self._enabled
    end

    function controller:toggle()
        local nextState = not self._enabled
        table.insert(state.ui.calls.toggle, {
            before = self._enabled,
            after = nextState,
        })
        return self:setEnabled(nextState)
    end

    function controller:destroy()
        self._destroyed = true
        state.ui.destroyCalled = true
    end

    function controller:isDestroyed()
        return self._destroyed
    end

    return controller
end

return UI
]===]
end

local function buildParryStubSource()
    return [===[
local state = rawget(_G, "__APITest")
if not state or not state.parry then
    error("Parry stub missing test state", 0)
end

local function deepCopy(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, child in pairs(value) do
        copy[key] = deepCopy(child)
    end
    return copy
end

local function createConnection()
    local connection = { disconnected = false }

    function connection.Disconnect(conn)
        conn.disconnected = true
    end

    connection.disconnect = connection.Disconnect
    return connection
end

local parryState = state.parry

local Parry = {}

function Parry.isEnabled()
    parryState.calls.isEnabled = parryState.calls.isEnabled + 1
    return parryState.enabled
end

function Parry.setEnabled(enabled)
    local normalized = enabled and true or false
    table.insert(parryState.calls.setEnabled, normalized)

    if parryState.enabled == normalized then
        return parryState.enabled
    end

    parryState.enabled = normalized

    for _, callback in ipairs(parryState.stateChangedCallbacks) do
        callback(normalized)
    end

    return parryState.enabled
end

function Parry.enable()
    parryState.calls.enable = (parryState.calls.enable or 0) + 1
    return Parry.setEnabled(true)
end

function Parry.configure(config)
    config = config or {}
    table.insert(parryState.calls.configure, deepCopy(config))
    for key, value in pairs(config) do
        parryState.config[key] = deepCopy(value)
    end
    return deepCopy(parryState.config)
end

function Parry.getConfig()
    parryState.calls.getConfig = parryState.calls.getConfig + 1
    return deepCopy(parryState.config)
end

function Parry.resetConfig()
    parryState.calls.resetConfig = parryState.calls.resetConfig + 1
    parryState.config = deepCopy(parryState.defaultConfig)
    return deepCopy(parryState.config)
end

function Parry.setLogger(fn)
    table.insert(parryState.calls.setLogger, fn)
end

function Parry.getLastParryTime()
    parryState.calls.getLastParryTime = parryState.calls.getLastParryTime + 1
    return parryState.lastParryTime
end

function Parry.getLastParrySuccessTime()
    parryState.calls.getLastParrySuccessTime = parryState.calls.getLastParrySuccessTime + 1
    return parryState.lastParrySuccessTime
end

function Parry.getLastParryBroadcastTime()
    parryState.calls.getLastParryBroadcastTime = parryState.calls.getLastParryBroadcastTime + 1
    return parryState.lastParryBroadcastTime
end

function Parry.onStateChanged(callback)
    parryState.calls.onStateChanged = parryState.calls.onStateChanged + 1
    table.insert(parryState.stateChangedCallbacks, callback)

    if not parryState.primaryConnectionAssigned then
        parryState.primaryConnectionAssigned = true
        parryState.primaryCallback = callback
        return parryState.primaryConnection
    end

    local connection = createConnection()
    table.insert(parryState.extraConnections, connection)
    table.insert(parryState.extraCallbacks, callback)
    return connection
end

function Parry.onParry(callback)
    table.insert(parryState.calls.onParry, callback)
    return createConnection()
end

function Parry.onParrySuccess(callback)
    table.insert(parryState.calls.onParrySuccess, callback)
    return createConnection()
end

function Parry.onParryBroadcast(callback)
    table.insert(parryState.calls.onParryBroadcast, callback)
    return createConnection()
end

function Parry.destroy()
    parryState.calls.destroy = parryState.calls.destroy + 1
    parryState.destroyed = true
end

return Parry
]===]
end

local function loadApi(options)
    local state = createState()
    local overrides = {
        ["src/ui/init.lua"] = buildUiStubSource(),
        ["src/core/autoparry.lua"] = buildParryStubSource(),
    }

    local loaderSource = SourceMap["loader.lua"]
    assert(loaderSource, "loader source missing from map")
    local loaderChunk, err = loadstring(loaderSource, "=loader.lua")
    assert(loaderChunk, err)

    local previousHttpGet = game.HttpGet
    local previousRequire = rawget(_G, "ARequire")
    local previousLoader = rawget(_G, "AutoParryLoader")

    local function cleanup()
        game.HttpGet = previousHttpGet

        if previousRequire == nil then
            rawset(_G, "ARequire", nil)
        else
            rawset(_G, "ARequire", previousRequire)
        end

        if previousLoader == nil then
            rawset(_G, "AutoParryLoader", nil)
        else
            rawset(_G, "AutoParryLoader", previousLoader)
        end

        rawset(_G, "__APITest", nil)
    end

    local function fakeHttpGet(_, url)
        local prefix = "https://raw.githubusercontent.com/"
        assert(string.sub(url, 1, #prefix) == prefix, "unexpected url: " .. tostring(url))

        local remainder = string.sub(url, #prefix + 1)
        local path = remainder:match("^[^/]+/[^/]+/[^/]+/(.+)$")
        assert(path, "failed to parse path from url: " .. tostring(url))

        local override = overrides[path]
        if override then
            return override
        end

        local source = SourceMap[path]
        assert(source, "missing source map entry for " .. tostring(path))
        return source
    end

    game.HttpGet = fakeHttpGet
    rawset(_G, "__APITest", state)

    local ok, result = pcall(loaderChunk, options or {})

    cleanup()

    if not ok then
        error(result, 0)
    end

    return result, state
end

return function(t)
    t.test("delegates API calls to Parry and UI via loader", function(expect)
        local api, state = loadApi()

        expect(type(api)):toEqual("table")
        expect(state.ui.mountCount):toEqual(1)
        expect(#state.parry.stateChangedCallbacks):toEqual(1)
        expect(state.parry.calls.onStateChanged):toEqual(1)

        local initialSync = state.ui.calls.setEnabled[1]
        expect(initialSync ~= nil):toBeTruthy()
        expect(initialSync.enabled):toEqual(false)
        expect(initialSync.context.silent):toEqual(true)
        expect(state.parry.calls.isEnabled):toEqual(1)

        expect(api.getVersion()):toEqual("1.1.0")

        local enabledNow = api.isEnabled()
        expect(enabledNow):toEqual(false)
        expect(state.parry.calls.isEnabled):toEqual(2)

        local controller = api.getUiController()
        expect(controller):toEqual(state.ui.controller)
        expect(controller:isDestroyed()):toEqual(false)

        local beforeSetEnabledCalls = #state.ui.calls.setEnabled
        local beforeParrySet = #state.parry.calls.setEnabled
        local beforeParryIsEnabled = state.parry.calls.isEnabled

        local setTrueResult = api.setEnabled(true)
        expect(setTrueResult):toEqual(true)
        expect(state.parry.enabled):toEqual(true)
        expect(#state.parry.calls.setEnabled):toEqual(beforeParrySet + 1)
        expect(state.parry.calls.setEnabled[#state.parry.calls.setEnabled]):toEqual(true)
        expect(state.parry.calls.isEnabled):toEqual(beforeParryIsEnabled + 1)
        expect(#state.ui.calls.setEnabled):toEqual(beforeSetEnabledCalls + 2)

        local directEnable = state.ui.calls.setEnabled[beforeSetEnabledCalls + 1]
        expect(directEnable.enabled):toEqual(true)
        expect(directEnable.context.silent == true):toEqual(false)

        local syncEnable = state.ui.calls.setEnabled[beforeSetEnabledCalls + 2]
        expect(syncEnable.enabled):toEqual(true)
        expect(syncEnable.context.silent):toEqual(true)
        expect(syncEnable.context.source):toEqual("parry")

        local beforeDisableCalls = #state.ui.calls.setEnabled
        local beforeDisableParrySet = #state.parry.calls.setEnabled
        local beforeDisableIsEnabled = state.parry.calls.isEnabled

        local setFalseResult = api.setEnabled(false)
        expect(setFalseResult):toEqual(false)
        expect(state.parry.enabled):toEqual(false)
        expect(#state.parry.calls.setEnabled):toEqual(beforeDisableParrySet + 1)
        expect(state.parry.calls.setEnabled[#state.parry.calls.setEnabled]):toEqual(false)
        expect(state.parry.calls.isEnabled):toEqual(beforeDisableIsEnabled + 1)
        expect(#state.ui.calls.setEnabled):toEqual(beforeDisableCalls + 2)

        local directDisable = state.ui.calls.setEnabled[beforeDisableCalls + 1]
        expect(directDisable.enabled):toEqual(false)
        expect(directDisable.context.silent == true):toEqual(false)

        local syncDisable = state.ui.calls.setEnabled[beforeDisableCalls + 2]
        expect(syncDisable.enabled):toEqual(false)
        expect(syncDisable.context.silent):toEqual(true)
        expect(syncDisable.context.source):toEqual("parry")

        local toggleResult = api.toggle()
        expect(toggleResult):toEqual(true)
        expect(state.parry.enabled):toEqual(true)
        expect(#state.ui.calls.toggle):toEqual(1)
        local toggleCall = state.ui.calls.toggle[1]
        expect(toggleCall.before):toEqual(false)
        expect(toggleCall.after):toEqual(true)
        expect(state.parry.calls.setEnabled[#state.parry.calls.setEnabled]):toEqual(true)

        local configureResult = api.configure({
            pingOffset = 0.25,
            nested = {
                baseline = false,
                extra = "value",
            },
        })
        expect(#state.parry.calls.configure):toEqual(1)
        local configureCall = state.parry.calls.configure[1]
        expect(configureCall.pingOffset):toEqual(0.25)
        expect(configureCall.nested.baseline):toEqual(false)
        expect(configureCall.nested.extra):toEqual("value")
        expect(state.parry.calls.getConfig):toEqual(1)
        expect(configureResult.pingOffset):toEqual(0.25)
        expect(configureResult.nested.baseline):toEqual(false)
        expect(configureResult.nested.extra):toEqual("value")

        local currentConfig = api.getConfig()
        expect(state.parry.calls.getConfig):toEqual(2)
        expect(currentConfig.pingOffset):toEqual(0.25)
        expect(currentConfig.nested.extra):toEqual("value")

        local resetResult = api.resetConfig()
        expect(state.parry.calls.resetConfig):toEqual(1)
        expect(resetResult.pingOffset):toEqual(state.parry.defaultConfig.pingOffset)
        expect(resetResult.nested.baseline):toEqual(state.parry.defaultConfig.nested.baseline)

        local postResetConfig = api.getConfig()
        expect(state.parry.calls.getConfig):toEqual(3)
        expect(postResetConfig.pingOffset):toEqual(state.parry.defaultConfig.pingOffset)
        expect(postResetConfig.nested.baseline):toEqual(state.parry.defaultConfig.nested.baseline)

        local logger = function() end
        expect(#state.parry.calls.setLogger):toEqual(0)
        api.setLogger(logger)
        expect(#state.parry.calls.setLogger):toEqual(1)
        expect(state.parry.calls.setLogger[1]):toEqual(logger)

        local lastTime = api.getLastParryTime()
        expect(lastTime):toEqual(state.parry.lastParryTime)
        expect(state.parry.calls.getLastParryTime):toEqual(1)

        local observer = function() end

        local stateChangedConnection = api.onStateChanged(observer)
        expect(stateChangedConnection ~= nil):toBeTruthy()
        expect(type(stateChangedConnection.Disconnect)):toEqual("function")
        expect(state.parry.calls.onStateChanged):toEqual(2)
        expect(#state.parry.stateChangedCallbacks):toEqual(2)
        expect(state.parry.stateChangedCallbacks[2]):toEqual(observer)
        expect(state.parry.extraConnections[1]):toEqual(stateChangedConnection)

        local parryConnection = api.onParry(function() end)
        expect(#state.parry.calls.onParry):toEqual(1)
        expect(type(parryConnection.Disconnect)):toEqual("function")

        local destroyConnection = state.parry.primaryConnection
        expect(destroyConnection.disconnected):toEqual(false)
        expect(state.parry.calls.destroy):toEqual(0)
        expect(state.ui.destroyCalled):toEqual(false)

        api.destroy()

        expect(state.parry.calls.destroy):toEqual(1)
        expect(state.parry.destroyed):toEqual(true)
        expect(destroyConnection.disconnected):toEqual(true)
        expect(state.ui.destroyCalled):toEqual(true)
        expect(controller:isDestroyed()):toEqual(true)
    end)
end
