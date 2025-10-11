--!strict

local args = { ... }

local function scriptDirectory(): string
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    local dir = source:match("^(.*)/[^/]+$")
    return dir or "."
end

local function joinPath(base: string, ...: string): string
    local result = base or ""
    local segments = { ... }
    for _, segment in ipairs(segments) do
        if segment ~= nil and segment ~= "" then
            local cleaned = tostring(segment)
            if result == "" then
                result = cleaned
            else
                if result:sub(-1) ~= "/" then
                    result = result .. "/"
                end
                cleaned = cleaned:gsub("^/+", "")
                result = result .. cleaned
            end
        end
    end
    return result
end

local function normalisePath(path: string): string
    local segments = {}
    for segment in path:gmatch("[^/]+") do
        if segment == ".." then
            if #segments > 0 then
                table.remove(segments)
            end
        elseif segment ~= "." and segment ~= "" then
            table.insert(segments, segment)
        end
    end
    local prefix = path:sub(1, 1) == "/" and "/" or ""
    if #segments == 0 then
        if prefix ~= "" then
            return prefix
        end
        return "."
    end
    return prefix .. table.concat(segments, "/")
end

local scriptDir = normalisePath(scriptDirectory())
local rootDir = normalisePath(joinPath(scriptDir, "../.."))
local scenarioDir = normalisePath(joinPath(rootDir, "tests/scenarios"))
local engineScenarioDir = normalisePath(joinPath(rootDir, "tests/engine"))

local outDir: string? = nil
local verbose = false

local index = 1
while index <= #args do
    local argument = args[index]
    if argument == "--out" and index < #args then
        outDir = args[index + 1]
        index = index + 2
    elseif argument == "--verbose" then
        verbose = true
        index = index + 1
    elseif argument == "--root" and index < #args then
        rootDir = normalisePath(args[index + 1])
        scenarioDir = normalisePath(joinPath(rootDir, "tests/scenarios"))
        index = index + 2
    else
        index = index + 1
    end
end

if not outDir then
    outDir = normalisePath(joinPath(rootDir, "tests/artifacts/scenarios"))
else
    outDir = normalisePath(outDir)
end

local isWindows = package.config:sub(1, 1) == "\\"

local function ensureDirectory(path: string)
    if isWindows then
        os.execute(string.format('if not exist "%s" mkdir "%s"', path, path))
    else
        os.execute(string.format('mkdir -p "%s"', path))
    end
end

local function listDirectoryEntries(directory: string, predicate: ((string) -> boolean)?): { string }
    local command
    if isWindows then
        command = string.format('dir /b "%s"', directory)
    else
        command = string.format('ls -1 "%s"', directory)
    end

    local handle = io.popen(command)
    if not handle then
        return {}
    end

    local entries = {}
    for line in handle:lines() do
        if line ~= "" then
            if not predicate or predicate(line) then
                table.insert(entries, line)
            end
        end
    end
    handle:close()
    table.sort(entries)
    return entries
end

local function listScenarioFiles(): { { root: string, name: string } }
    local entries = {}

    local function append(root: string, files: { string })
        for _, name in ipairs(files) do
            entries[#entries + 1] = { root = root, name = name }
        end
    end

    append(
        scenarioDir,
        listDirectoryEntries(scenarioDir, function(name)
            return name:match("%.lua[uU]?$") ~= nil
        end)
    )

    append(
        engineScenarioDir,
        listDirectoryEntries(engineScenarioDir, function(name)
            return name:match("%.manifest%.lua$") ~= nil
        end)
    )

    table.sort(entries, function(a, b)
        if a.name == b.name then
            return a.root < b.root
        end
        return a.name < b.name
    end)

    return entries
end

local function extendPackagePath()
    local additions = {
        rootDir .. "/?.lua",
        rootDir .. "/?/init.lua",
        rootDir .. "/?.luau",
        rootDir .. "/?/init.luau",
    }
    package.path = package.path .. ";" .. table.concat(additions, ";")
end

local function describeValue(value: any): string
    local valueType = type(value)
    if valueType == "string" then
        return string.format("%q", value)
    end
    return tostring(value)
end

local function loadManifest(path: string): any
    local chunk, err = loadfile(path)
    if not chunk then
        error(string.format("Failed to load %s: %s", path, tostring(err)))
    end

    local ok, manifest = pcall(chunk)
    if not ok then
        error(string.format("Manifest execution failed for %s: %s", path, tostring(manifest)))
    end

    return manifest
end

local Planner = require("engine.scenario.planner")

local function isArray(value: table): boolean
    local count = 0
    local maxIndex = 0
    for key in pairs(value) do
        if type(key) ~= "number" then
            return false
        end
        if key > maxIndex then
            maxIndex = key
        end
        count = count + 1
    end
    return count == maxIndex
end

local function encodeLuau(value: any, indent: number?, visited: table?): string
    indent = indent or 0
    local prefix = string.rep("    ", indent)
    local nextPrefix = string.rep("    ", indent + 1)

    local valueType = type(value)
    if valueType == "string" then
        return string.format("%q", value)
    elseif valueType == "number" or valueType == "boolean" or value == nil then
        return tostring(value)
    elseif valueType == "table" then
        visited = visited or {}
        if visited[value] then
            error("Cannot serialise cyclic table in scenario output")
        end
        visited[value] = true

        local entries = {}
        if isArray(value) then
            for index = 1, #value do
                entries[index] = nextPrefix .. encodeLuau(value[index], indent + 1, visited)
            end
            visited[value] = nil
            if #entries == 0 then
                return "{}"
            end
            return string.format("{\n%s\n%s}", table.concat(entries, ",\n"), prefix)
        end

        local keys = {}
        for key in pairs(value) do
            table.insert(keys, key)
        end
        table.sort(keys, function(a, b)
            return tostring(a) < tostring(b)
        end)

        for _, key in ipairs(keys) do
            local encodedKey
            if type(key) == "string" and key:match("^[_%a][_%w]*$") then
                encodedKey = key .. " = "
            else
                encodedKey = "[" .. encodeLuau(key, indent + 1, visited) .. "] = "
            end
            local encodedValue = encodeLuau(value[key], indent + 1, visited)
            table.insert(entries, nextPrefix .. encodedKey .. encodedValue)
        end
        visited[value] = nil
        if #entries == 0 then
            return "{}"
        end
        return string.format("{\n%s\n%s}", table.concat(entries, ",\n"), prefix)
    end

    error("Unsupported value type for serialization: " .. describeValue(value))
end

local function writeTextFile(path: string, contents: string)
    local file, err = io.open(path, "w")
    if not file then
        error(string.format("Failed to write %s: %s", path, tostring(err)))
    end
    file:write(contents)
    file:close()
end

local function writeBinaryFile(path: string, contents: string)
    local file, err = io.open(path, "wb")
    if not file then
        error(string.format("Failed to write %s: %s", path, tostring(err)))
    end
    file:write(contents)
    file:close()
end

local function emitDiagnostics(label: string, diagnostics)
    for _, diagnostic in ipairs(diagnostics or {}) do
        local severity = diagnostic.severity or "error"
        io.stderr:write(string.format("[%s] %s %s: %s\n", label, severity:upper(), diagnostic.path, diagnostic.message))
    end
end

local function compileScenario(manifestPath: string, manifest: any, label: string?)
    label = label or manifestPath

    if type(manifest) ~= "table" then
        error(string.format("Scenario manifest %s must return a table", label))
    end

    if type(manifest.scenarios) == "table" then
        for index, entry in ipairs(manifest.scenarios) do
            local nestedLabel = string.format("%s[%d]", label, index)
            compileScenario(manifestPath, entry, nestedLabel)
        end
        return
    end

    local ok, plan, diagnostics = Planner.plan(manifest)

    if not ok or not plan then
        emitDiagnostics(label, diagnostics)
        error(string.format("Scenario %s failed validation", label))
    elseif diagnostics and #diagnostics > 0 then
        emitDiagnostics(label, diagnostics)
    end

    local encoded = encodeLuau(plan, 0)
    local moduleSource = "return " .. encoded .. "\n"

    local chunk, err = load("return " .. encoded, "scenario:" .. (plan.metadata.id or label))
    if not chunk then
        error(string.format("Failed to compile bytecode for %s: %s", label, tostring(err)))
    end
    local bytecode = string.dump(chunk)

    ensureDirectory(outDir)

    local baseName = plan.metadata.id
    if not baseName then
        local tail = label:match("([^/]+)$") or label
        tail = tail:gsub("%.manifest", "")
        tail = tail:gsub("%.lua[uU]?", "")
        tail = tail:gsub("[%[%]]", "-")
        baseName = tail
    end
    local robloxPath = normalisePath(joinPath(outDir, baseName .. ".roblox.lua"))
    local lunePath = normalisePath(joinPath(outDir, baseName .. ".lune.luac"))

    writeTextFile(robloxPath, moduleSource)
    writeBinaryFile(lunePath, bytecode)

    if verbose then
        io.stdout:write(string.format("Compiled %s -> %s, %s\n", label, robloxPath, lunePath))
    end
end

local function main()
    extendPackagePath()

    local ok, filesOrErr = pcall(listScenarioFiles)
    if not ok then
        error(filesOrErr)
    end

    local files = filesOrErr
    if #files == 0 then
        io.stderr:write(
            string.format(
                "No scenario manifests found in %s or %s\n",
                scenarioDir,
                engineScenarioDir
            )
        )
        return
    end

    for _, entry in ipairs(files) do
        if entry.name:match("%.lua[uU]?$") then
            local manifestPath = normalisePath(joinPath(entry.root, entry.name))
            local manifest = loadManifest(manifestPath)
            local okCompile, err = pcall(compileScenario, manifestPath, manifest, manifestPath)
            if not okCompile then
                io.stderr:write(string.format("Compilation failed for %s: %s\n", manifestPath, tostring(err)))
                os.exit(1)
            end
        end
    end
end

main()
