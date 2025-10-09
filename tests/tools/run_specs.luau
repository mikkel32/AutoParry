local fs = require("@lune/fs")
local serde = require("@lune/serde")
local roblox = require("@lune/roblox")
local process = require("@lune/process")

local rootEnv = getfenv(1)
assert(type(rootEnv) == "table", "failed to capture root environment")

local function splitPath(path: string): (boolean, { string })
    local isAbsolute = path:sub(1, 1) == "/"
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part ~= "" then
            table.insert(parts, part)
        end
    end
    return isAbsolute, parts
end

local function joinParts(isAbsolute: boolean, parts: { string }): string
    if #parts == 0 then
        return isAbsolute and "/" or "."
    end
    local path = table.concat(parts, "/")
    if isAbsolute then
        return "/" .. path
    end
    return path
end

local function normalizePath(path: string): string
    local isAbsolute, parts = splitPath(path)
    local stack = {}
    for _, part in ipairs(parts) do
        if part == "." then
            -- ignore
        elseif part == ".." then
            if #stack > 0 and stack[#stack] ~= ".." then
                table.remove(stack)
            elseif not isAbsolute then
                table.insert(stack, "..")
            end
        else
            table.insert(stack, part)
        end
    end
    return joinParts(isAbsolute, stack)
end

local function joinPath(base: string, relative: string): string
    if relative:sub(1, 1) == "/" then
        return normalizePath(relative)
    end
    if base == "/" then
        base = ""
    end
    return normalizePath(base .. "/" .. relative)
end

local function parentPath(path: string): string
    local isAbsolute, parts = splitPath(path)
    if #parts > 0 then
        table.remove(parts)
    end
    return joinParts(isAbsolute, parts)
end

local rawArgs = { ... }
local rootDir: string?
local index = 1
while index <= #rawArgs do
    local value = rawArgs[index]
    if value == "--root" and rawArgs[index + 1] then
        rootDir = rawArgs[index + 1]
        index += 2
    elseif type(value) == "string" and not string.find(value, "^-", 1, true) and rootDir == nil then
        rootDir = value
        index += 1
    else
        index += 1
    end
end

if rootDir == nil then
    rootDir = process.env.AUTO_PARRY_ROOT or process.env.PWD or "."
end

rootDir = normalizePath(rootDir)
local testsDir = joinPath(rootDir, "tests")
local fixturesDir = joinPath(testsDir, "fixtures")

local specFilter = process.env.SPEC_FILTER

local function shouldIncludeSpec(name: string): boolean
    if specFilter == nil or specFilter == "" then
        return true
    end
    local lowered = string.lower(specFilter)
    return string.find(string.lower(name), lowered, 1, true) ~= nil
end

local function readFile(path: string): string
    local ok, contents = pcall(fs.readFile, path)
    if not ok then
        error(string.format("Failed to read %s: %s", path, tostring(contents)), 0)
    end
    return contents
end

-- bootstrap roblox-style globals
local function setGlobal(name: string, value: any)
    if value == nil then
        return
    end
    _G[name] = value
    rootEnv[name] = value
end

local function cloneArray<T>(array: { T }): { T }
    local copy = {}
    for index = 1, #array do
        copy[index] = array[index]
    end
    return copy
end

local function createSignal()
    local listeners = {}
    local signal = {}

    function signal:Connect(callback)
        local connection = { Connected = true }

        function connection:Disconnect()
            self.Connected = false
        end

        connection._callback = callback
        listeners[#listeners + 1] = connection
        return connection
    end

    function signal:Fire(...)
        for _, connection in ipairs(listeners) do
            if connection.Connected and connection._callback then
                connection._callback(...)
            end
        end
    end

    return signal
end

local ENUM_ITEM_METATABLE = { __enumItem = true }

function ENUM_ITEM_METATABLE:__tostring()
    local enumType = rawget(self, "EnumType")
    local enumName = enumType and enumType.Name or "?"
    return string.format("Enum.%s.%s", enumName, rawget(self, "Name") or "?")
end

local function createDynamicEnumType(name: string, entries: { any }?, options: { dynamic: boolean }?)
    local allowDynamic = true
    if options and options.dynamic == false then
        allowDynamic = false
    end

    local enumType = { Name = name }
    local items = {}
    local ordered = {}

    local function addEntry(entryName: string, value: number?)
        local existing = items[entryName]
        if existing then
            return existing
        end

        local enumItem = setmetatable({
            Name = entryName,
            Value = value or (#ordered + 1),
        }, ENUM_ITEM_METATABLE)

        enumItem.EnumType = enumType
        items[entryName] = enumItem
        ordered[#ordered + 1] = enumItem
        return enumItem
    end

    if entries then
        for index, entry in ipairs(entries) do
            if type(entry) == "table" then
                addEntry(entry.name or entry.Name, entry.value or entry.Value or index)
            else
                addEntry(entry, index)
            end
        end
    end

    function enumType:GetEnumItems()
        return cloneArray(ordered)
    end

    function enumType:_add(entryName: string, value: number?)
        return addEntry(entryName, value)
    end

    return setmetatable(enumType, {
        __index = function(_, key)
            if key == "GetEnumItems" or key == "_add" or key == "Name" then
                return rawget(enumType, key)
            end

            if type(key) == "string" then
                local item = items[key]
                if item then
                    return item
                end
                if allowDynamic then
                    return addEntry(key)
                end
            end

            return rawget(enumType, key)
        end,
        __enumType = true,
        __tostring = function()
            return "Enum." .. name
        end,
    })
end

local baseEnum = roblox.Enum

local function resolveBaseEnumType(name: string)
    if baseEnum == nil then
        return nil
    end

    local ok, value = pcall(function()
        return baseEnum[name]
    end)

    if ok and value ~= nil then
        return value
    end

    return nil
end

local enumAliases: { [string]: { [string]: any } } = {
    Font = {
        GothamSemibold = function(fontEnum)
            local okBold, bold = pcall(function()
                return fontEnum.GothamBold
            end)
            if okBold and bold ~= nil then
                return bold
            end

            local okRegular, regular = pcall(function()
                return fontEnum.Gotham
            end)
            if okRegular and regular ~= nil then
                return regular
            end

            return nil
        end,
    },
}

local function createAliasEnumProxy(enumType, aliases)
    local cache = {}

    local function resolve(key)
        if cache[key] ~= nil then
            return cache[key]
        end

        local alias = aliases[key]
        if alias ~= nil then
            local resolved
            local aliasType = type(alias)
            if aliasType == "string" then
                local ok, value = pcall(function()
                    return enumType[alias]
                end)
                if ok and value ~= nil then
                    resolved = value
                end
            elseif aliasType == "function" then
                resolved = alias(enumType)
            elseif aliasType == "userdata" then
                resolved = alias
            end

            if resolved ~= nil then
                cache[key] = resolved
                return resolved
            end
        end

        local ok, value = pcall(function()
            return enumType[key]
        end)
        if ok then
            cache[key] = value
            return value
        end

        cache[key] = nil
        return nil
    end

    local proxy = {}

    return setmetatable(proxy, {
        __index = function(_, key)
            if key == "GetEnumItems" then
                return function()
                    local items = enumType:GetEnumItems()
                    local copy = cloneArray(items)
                    for aliasName in pairs(aliases) do
                        local resolved = resolve(aliasName)
                        if resolved ~= nil then
                            local alreadyPresent = false
                            for _, item in ipairs(copy) do
                                if item == resolved then
                                    alreadyPresent = true
                                    break
                                end
                            end
                            if not alreadyPresent then
                                copy[#copy + 1] = resolved
                            end
                        end
                    end
                    return copy
                end
            end

            return resolve(key)
        end,
        __enumType = true,
        __tostring = function()
            return tostring(enumType)
        end,
    })
end

local stubEnumDefinitions = {
    ApplyStrokeMode = { entries = { "Border" }, dynamic = false },
    AutomaticSize = { entries = { "None", "X", "Y", "XY" }, dynamic = false },
    EasingDirection = { entries = { "In", "Out", "InOut" }, dynamic = false },
    EasingStyle = { entries = { "Linear", "Quad", "Sine" }, dynamic = false },
    ElasticBehavior = { entries = { "Never" }, dynamic = false },
    FillDirection = { entries = { "Horizontal", "Vertical" }, dynamic = false },
    HorizontalAlignment = { entries = { "Left", "Center", "Right" }, dynamic = false },
    VerticalAlignment = { entries = { "Top", "Center", "Bottom" }, dynamic = false },
    TextXAlignment = { entries = { "Left", "Center", "Right" }, dynamic = false },
    TextYAlignment = { entries = { "Top", "Center", "Bottom" }, dynamic = false },
    ScrollBarInset = { entries = { "Always" }, dynamic = false },
    ScrollingDirection = { entries = { "X", "Y" }, dynamic = false },
    SortOrder = { entries = { "LayoutOrder", "Name" }, dynamic = false },
    Material = { entries = { "SmoothPlastic" }, dynamic = false },
    PartType = { entries = { "Ball" }, dynamic = false },
    ZIndexBehavior = { entries = { "Sibling", "Global" }, dynamic = false },
}

local keyCodeEntries = {
    "A",
    "B",
    "C",
    "D",
    "E",
    "F",
    "G",
    "H",
    "I",
    "J",
    "K",
    "L",
    "M",
    "N",
    "O",
    "P",
    "Q",
    "R",
    "S",
    "T",
    "U",
    "V",
    "W",
    "X",
    "Y",
    "Z",
    "Zero",
    "One",
    "Two",
    "Three",
    "Four",
    "Five",
    "Six",
    "Seven",
    "Eight",
    "Nine",
    "Space",
    "Tab",
    "Return",
    "Backspace",
    "Escape",
    "Insert",
    "Delete",
    "Home",
    "End",
    "PageUp",
    "PageDown",
    "CapsLock",
    "NumLock",
    "ScrollLock",
    "Print",
    "SysReq",
    "Pause",
    "Menu",
    "Left",
    "Right",
    "Up",
    "Down",
    "LeftShift",
    "RightShift",
    "LeftControl",
    "RightControl",
    "LeftAlt",
    "RightAlt",
    "LeftMeta",
    "RightMeta",
    "ButtonA",
    "ButtonB",
    "ButtonX",
    "ButtonY",
    "ButtonL1",
    "ButtonR1",
    "ButtonL2",
    "ButtonR2",
    "Thumbstick1",
    "Thumbstick2",
    "F1",
    "F2",
    "F3",
    "F4",
    "F5",
    "F6",
    "F7",
    "F8",
    "F9",
    "F10",
    "F11",
    "F12",
    "Minus",
    "Equals",
    "LeftBracket",
    "RightBracket",
    "Backslash",
    "Semicolon",
    "Quote",
    "Comma",
    "Period",
    "Slash",
    "Grave",
}

stubEnumDefinitions.KeyCode = { entries = keyCodeEntries, dynamic = true }

local enumCache = {}
local dynamicEnums = {}

local EnumProxy = setmetatable({}, {
    __index = function(_, key)
        local cached = enumCache[key]
        if cached ~= nil then
            return cached
        end

        local baseType = resolveBaseEnumType(key)
        if baseType ~= nil then
            local aliases = enumAliases[key]
            local value = baseType
            if aliases ~= nil then
                value = createAliasEnumProxy(baseType, aliases)
            end
            enumCache[key] = value
            return value
        end

        local definition = stubEnumDefinitions[key]
        if definition ~= nil then
            local allowDynamic = definition.dynamic
            if allowDynamic == nil then
                allowDynamic = true
            end
            local stub = createDynamicEnumType(key, definition.entries, { dynamic = allowDynamic })
            enumCache[key] = stub
            return stub
        end

        local enumType = dynamicEnums[key]
        if not enumType then
            enumType = createDynamicEnumType(key, nil, { dynamic = true })
            dynamicEnums[key] = enumType
        end

        enumCache[key] = enumType
        return enumType
    end,
})

setGlobal("Enum", EnumProxy)

local originalTypeof = typeof
local function typeofWithEnums(value)
    local mt = type(value) == "table" and getmetatable(value) or nil
    if type(mt) == "table" then
        if rawget(mt, "__enumItem") then
            return "EnumItem"
        end
        if rawget(mt, "__enumType") then
            return "Enum"
        end
        if rawget(mt, "__instanceStub") then
            return "Instance"
        end
    end
    return originalTypeof(value)
end

setGlobal("typeof", typeofWithEnums)

local gameInstance = roblox.Instance.new("DataModel")
local servicesCache = {}

local gameProxy = {
    _instance = gameInstance,
    _services = servicesCache,
}

function gameProxy:GetService(name: string)
    local service = self._services[name]
    if service == nil then
        service = self._instance:GetService(name)
        self._services[name] = service
    end
    return service
end

function gameProxy:FindService(name: string)
    local service = self._services[name]
    if service ~= nil then
        return service
    end

    local ok, result = pcall(self._instance.GetService, self._instance, name)
    if ok then
        self._services[name] = result
        return result
    end

    return nil
end

setGlobal("game", gameProxy)
setGlobal("workspace", gameProxy:GetService("Workspace"))
setGlobal("CoreGui", gameProxy:GetService("CoreGui"))

local baseInstance = roblox.Instance

local stubbedInstanceClasses = {
    PlayerGui = true,
    ScreenGui = true,
    TextButton = true,
    TextLabel = true,
    BillboardGui = true,
    Highlight = true,
}

local InstanceStub = {}
InstanceStub.__index = InstanceStub

local function setStubParent(self, parent)
    local current = rawget(self, "Parent")
    if current == parent then
        return
    end

    if current and rawget(current, "_children") then
        local siblings = current._children
        for index, child in ipairs(siblings) do
            if child == self then
                table.remove(siblings, index)
                break
            end
        end
    end

    rawset(self, "Parent", parent)

    if parent and rawget(parent, "_children") then
        local siblings = parent._children
        siblings[#siblings + 1] = self
    end
end

function InstanceStub:Add(child)
    child.Parent = self
end

function InstanceStub:GetChildren()
    return cloneArray(rawget(self, "_children") or {})
end

function InstanceStub:FindFirstChild(name)
    for _, child in ipairs(self._children) do
        if child.Name == name then
            return child
        end
    end
    return nil
end

function InstanceStub:FindFirstChildOfClass(className)
    for _, child in ipairs(self._children) do
        if child.ClassName == className then
            return child
        end
    end
    return nil
end

function InstanceStub:FindFirstChildWhichIsA(className)
    return self:FindFirstChildOfClass(className)
end

function InstanceStub:WaitForChild(name)
    local child = self:FindFirstChild(name)
    if child then
        return child
    end
    error(string.format("%s is not a valid child of %s", name, self.Name or self.ClassName or "Instance"), 2)
end

function InstanceStub:IsA(className)
    return self.ClassName == className
end

function InstanceStub:Destroy()
    local children = cloneArray(self._children)
    for _, child in ipairs(children) do
        if child.Destroy then
            child:Destroy()
        end
    end

    local parent = rawget(self, "Parent")
    if parent and rawget(parent, "_children") then
        local siblings = parent._children
        for index, sibling in ipairs(siblings) do
            if sibling == self then
                table.remove(siblings, index)
                break
            end
        end
    end

    rawset(self, "Parent", nil)
    self._children = {}
end

local InstanceStubMetatable

local function createInstanceStub(className)
    local stub = {
        ClassName = className,
        Name = className,
        _children = {},
    }

    if className == "TextButton" then
        stub.MouseButton1Click = createSignal()
    end

    return setmetatable(stub, InstanceStubMetatable)
end

InstanceStubMetatable = {
    __index = InstanceStub,
    __newindex = function(self, key, value)
        if key == "Parent" then
            setStubParent(self, value)
            return
        end
        rawset(self, key, value)
    end,
    __instanceStub = true,
    __tostring = function(self)
        local name = rawget(self, "Name") or rawget(self, "ClassName") or "Instance"
        return string.format("%s(%s)", rawget(self, "ClassName") or "Instance", name)
    end,
}

local InstanceProxy = setmetatable({}, {
    __index = baseInstance,
})

function InstanceProxy.new(className: string, ...)
    if stubbedInstanceClasses[className] then
        local instance = createInstanceStub(className)
        local parent = select(1, ...)
        if parent ~= nil then
            instance.Parent = parent
        end
        return instance
    end

    return baseInstance.new(className, ...)
end

setGlobal("Instance", InstanceProxy)

local baseCFrame = roblox.CFrame
local CFrameProxy = setmetatable({}, {
    __index = baseCFrame,
})

function CFrameProxy.new(...)
    local argCount = select("#", ...)
    if argCount == 2 then
        local first = select(1, ...)
        local second = select(2, ...)
        if typeof(first) == "Vector3" and typeof(second) == "Vector3" then
            if baseCFrame.lookAt then
                return baseCFrame.lookAt(first, second)
            end
        end
    end

    return baseCFrame.new(...)
end

setGlobal("CFrame", CFrameProxy)
setGlobal("Vector3", roblox.Vector3)
setGlobal("Vector2", roblox.Vector2)
setGlobal("UDim", roblox.UDim)
setGlobal("UDim2", roblox.UDim2)
setGlobal("Color3", roblox.Color3)
setGlobal("ColorSequence", roblox.ColorSequence)
setGlobal("ColorSequenceKeypoint", roblox.ColorSequenceKeypoint)
setGlobal("NumberSequence", roblox.NumberSequence)
setGlobal("NumberSequenceKeypoint", roblox.NumberSequenceKeypoint)
setGlobal("TweenInfo", roblox.TweenInfo)

local function runAsync(fn: (...any) -> (), ...)
    local args = table.pack(...)
    local thread = coroutine.create(function()
        fn(table.unpack(args, 1, args.n))
    end)
    local ok, result = coroutine.resume(thread)
    if not ok then
        error(result, 0)
    end
    return thread
end

local taskGlobals = {
    wait = function(seconds: number?): number
        return seconds or 0
    end,
    spawn = function(fn: (...any) -> (), ...)
        return runAsync(fn, ...)
    end,
    defer = function(fn: (...any) -> (), ...)
        return runAsync(fn, ...)
    end,
    delay = function(_seconds: number, fn: (...any) -> (), ...)
        return runAsync(fn, ...)
    end,
}

setGlobal("task", taskGlobals)

local baseOs = os
local osGlobals = {}
for key, value in pairs(baseOs) do
    osGlobals[key] = value
end
setGlobal("os", osGlobals)

local RandomStub = {}
RandomStub.__index = RandomStub

function RandomStub.new(seed: number?)
    local baseSeed
    if seed ~= nil then
        baseSeed = seed
    elseif osGlobals.time then
        baseSeed = osGlobals.time()
    elseif osGlobals.clock then
        baseSeed = math.floor(osGlobals.clock() * 1e3)
    else
        baseSeed = 0
    end

    local state = baseSeed % 0x80000000
    return setmetatable({ _state = state % 0x80000000 }, RandomStub)
end

local function advanceRandom(self)
    self._state = (self._state * 1103515245 + 12345) % 0x80000000
    return self._state / 0x80000000
end

function RandomStub:NextNumber(min: number?, max: number?)
    local value = advanceRandom(self)
    min = min or 0
    max = max or 1
    return min + (max - min) * value
end

setGlobal("Random", {
    new = function(seed: number?)
        return RandomStub.new(seed)
    end,
})

for key, value in pairs(roblox) do
    if key ~= "Enum" and rootEnv[key] == nil then
        setGlobal(key, value)
    end
end
local function wrapCompiler(compiler)
    return function(source: string, chunkName: string?)
        local chunk, err = compiler(source, chunkName)
        if chunk then
            setfenv(chunk, rootEnv)
        end
        return chunk, err
    end
end

local function resolveLoadstring()
    if type(loadstring) == "function" then
        return wrapCompiler(loadstring)
    end

    local envLoadstring = rawget(rootEnv, "loadstring")
    if type(envLoadstring) == "function" then
        return wrapCompiler(envLoadstring)
    end

    local loader = rawget(_G, "load") or rawget(rootEnv, "load") or load
    if type(loader) == "function" then
        return function(source: string, chunkName: string?)
            local chunk, err = loader(source, chunkName, "t", rootEnv)
            if chunk then
                setfenv(chunk, rootEnv)
            end
            return chunk, err
        end
    end

    error("loadstring is not available in this environment", 0)
end

assert(type(_G) == "table", "global environment is missing")
local loadstringCompat = resolveLoadstring()
_G.loadstring = loadstringCompat
loadstring = loadstringCompat
rootEnv.loadstring = loadstringCompat
assert(type(_G.loadstring) == "function", "loadstring failed to initialize")

local ModuleScript = {}
ModuleScript.__index = ModuleScript

function ModuleScript.new(name: string, path: string)
    local self = setmetatable({}, ModuleScript)
    self.Name = name
    self.ClassName = "ModuleScript"
    self.Parent = nil
    self._path = path
    self._source = nil
    self._value = nil
    self._loaded = false
    return self
end

function ModuleScript:_mockSetParent(parent)
    self.Parent = parent
end

function ModuleScript:IsA(className)
    return className == "ModuleScript"
end

function ModuleScript:_loadSource()
    if not self._source then
        self._source = readFile(self._path)
    end
    return self._source
end

function ModuleScript:_require()
    if not self._loaded then
        local chunk, err = loadstring(self:_loadSource(), "=" .. self._path)
        assert(chunk, err)
        local previousScript = rawget(rootEnv, "script")
        rawset(rootEnv, "script", self)
        setfenv(chunk, rootEnv)
        local ok, result = pcall(chunk)
        rawset(rootEnv, "script", previousScript)
        if not ok then
            error(result, 0)
        end
        self._value = result
        self._loaded = true
    end
    return self._value
end

local originalRequire = require
local function moduleRequire(target)
    if type(target) == "table" and getmetatable(target) == ModuleScript then
        return target:_require()
    end
    return originalRequire(target)
end
_G.require = moduleRequire
require = moduleRequire

local function createFolder(name: string)
    local folder = { Name = name, ClassName = "Folder", Parent = nil }
    local children = {}

    function folder:_mockSetParent(parent)
        self.Parent = parent
    end

    function folder:IsA(className)
        return className == "Folder"
    end

    function folder:Add(child)
        children[child.Name] = child
        if child._mockSetParent then
            child:_mockSetParent(self)
        else
            child.Parent = self
        end
        return child
    end

    function folder:FindFirstChild(childName)
        return children[childName]
    end

    function folder:WaitForChild(childName)
        local child = children[childName]
        if not child then
            error(string.format("%s is missing child %s", self.Name, tostring(childName)), 0)
        end
        return child
    end

    function folder:GetChildren()
        local list = {}
        for _, child in pairs(children) do
            table.insert(list, child)
        end
        table.sort(list, function(a, b)
            return a.Name < b.Name
        end)
        return list
    end

    return folder
end

local sourceMapModule = ModuleScript.new("AutoParrySourceMap", joinPath(fixturesDir, "AutoParrySourceMap.lua"))
local harnessModule = ModuleScript.new("Harness", joinPath(testsDir, "autoparry/harness.lua"))
local contextModule = ModuleScript.new("Context", joinPath(testsDir, "autoparry/Context.lua"))

local TestHarness = createFolder("TestHarness")
local SpecsFolder = createFolder("Specs")
TestHarness:Add(SpecsFolder)
TestHarness:Add(sourceMapModule)
TestHarness:Add(harnessModule)
TestHarness:Add(contextModule)

local ReplicatedStorageStub = createFolder("ReplicatedStorage")
setGlobal("ReplicatedStorage", ReplicatedStorageStub)
gameProxy._services["ReplicatedStorage"] = ReplicatedStorageStub
gameProxy.ReplicatedStorage = ReplicatedStorageStub
ReplicatedStorageStub:Add(TestHarness)

local placeProjectPath = joinPath(fixturesDir, "place.project.json")
local projectConfig = serde.decode("json", readFile(placeProjectPath))
local specsConfig = projectConfig.tree.ReplicatedStorage.TestHarness.Specs
for name, node in pairs(specsConfig) do
    if type(node) == "table" and node["$path"] and shouldIncludeSpec(name) then
        local resolved = joinPath(fixturesDir, node["$path"])
        SpecsFolder:Add(ModuleScript.new(name, resolved))
    end
end

sourceMapModule:_mockSetParent(TestHarness)
harnessModule:_mockSetParent(TestHarness)
contextModule:_mockSetParent(TestHarness)

local Harness = require(harnessModule)
local SourceMap = require(sourceMapModule)


local cases = {}
local artifacts = {}

for _, moduleScript in ipairs(SpecsFolder:GetChildren()) do
    if moduleScript:IsA("ModuleScript") and shouldIncludeSpec(moduleScript.Name) then
        local ok, register = pcall(require, moduleScript)
        if not ok then
            warn("[run-specs] failed to require", moduleScript.Name, register)
            error(register, 0)
        end
        local specName = moduleScript.Name
        register({
            test = function(name, fn)
                table.insert(cases, {
                    name = string.format("%s %s", specName, name),
                    callback = fn,
                })
            end,
            artifact = function(name, payload)
                artifacts[name] = payload
            end,
        })
    end
end

local function makeExpect(testName)
    local function format(value)
        if typeof(value) == "string" then
            return string.format("%q", value)
        end
        return tostring(value)
    end

    local function expect(actual)
        local expectation = {}

        function expectation:toEqual(expected)
            if actual ~= expected then
                error(string.format("[%s] expected %s but got %s", testName, format(expected), format(actual)), 0)
            end
        end

        function expectation:toBeCloseTo(expected, tolerance)
            tolerance = tolerance or 1e-3
            if typeof(actual) ~= "number" or typeof(expected) ~= "number" then
                error(string.format("[%s] expected numbers but received %s and %s", testName, format(actual), format(expected)), 0)
            end
            if math.abs(actual - expected) > tolerance then
                error(string.format("[%s] expected %s to be within %s of %s", testName, format(actual), format(tolerance), format(expected)), 0)
            end
        end

        function expectation:toBeGreaterThanOrEqual(threshold)
            if typeof(actual) ~= "number" or actual < threshold then
                error(string.format("[%s] expected %s to be >= %s", testName, format(actual), format(threshold)), 0)
            end
        end

        function expectation:toBeTruthy()
            if not actual then
                error(string.format("[%s] expected value to be truthy but received %s", testName, format(actual)), 0)
            end
        end

        return expectation
    end

    return expect
end

local failures = 0

for _, case in ipairs(cases) do
    local expect = makeExpect(case.name)
    local ok, err = xpcall(function()
        case.callback(expect)
    end, function(message)
        local okFormat, formatted = pcall(function()
            if typeof(message) == "string" then
                return message
            end
            return tostring(message)
        end)
        if not okFormat then
            formatted = "<error converting message>"
        end
        return debug.traceback(formatted, 2)
    end)

    if ok then
        print(string.format("[PASS] %s", case.name))
    else
        failures += 1
        warn(string.format("[FAIL] %s\n%s", case.name, err))
    end
end

local artifactNames = {}
for name in pairs(artifacts) do
    table.insert(artifactNames, name)
end

if #artifactNames > 0 then
    table.sort(artifactNames)
    for _, name in ipairs(artifactNames) do
        local payload = artifacts[name]
        local ok, encoded = pcall(serde.encode, "json", payload)
        if ok then
            print(string.format("[ARTIFACT] %s %s", name, encoded))
        else
            warn(string.format("[ARTIFACT] failed to encode %s: %s", tostring(name), tostring(encoded)))
        end
    end
end

if failures > 0 then
    error(string.format("[AutoParrySpec] %d test(s) failed", failures), 0)
else
    print(string.format("[AutoParrySpec] %d test(s) passed", #cases))
end
