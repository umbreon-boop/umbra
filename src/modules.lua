local shell = require("shell")

local modules = {}

local NAME = "^[%a_][%w_-]*$"

-- Directories searched for user modules, in priority order.
function modules.directories()
    local configured = os.getenv("UMBRA_MODS")
    if not configured or configured == "" then
        configured = os.getenv("UMBRA_MODULES")
    end
    if configured and configured ~= "" then
        local out = {}
        for directory in configured:gmatch("[^:]+") do
            out[#out + 1] = directory
        end
        return out
    end
    local config = os.getenv("XDG_CONFIG_HOME")
    if not config or config == "" then
        config = (os.getenv("HOME") or "") .. "/.config"
    end
    return { config .. "/umbra/modules" }
end

local function exists(path)
    local handle = io.open(path, "rb")
    if handle then
        handle:close()
    end
    return handle ~= nil
end

local function entries(directory)
    local names = {}
    local pipe = io.popen("ls -1A -- " .. shell.quote(directory) .. " 2>/dev/null")
    if pipe then
        for name in pipe:lines() do
            names[#names + 1] = name
        end
        pipe:close()
    end
    table.sort(names)
    return names
end

-- Every module in the search directories, in priority order.
function modules.discover(directories)
    local found, seen = {}, {}
    for _, directory in ipairs(directories or modules.directories()) do
        for _, entry in ipairs(entries(directory)) do
            local name, path = entry:match("^(.+)%.lua$"), nil
            if name then
                path = directory .. "/" .. entry
            elseif exists(directory .. "/" .. entry .. "/init.lua") then
                name, path = entry, directory .. "/" .. entry .. "/init.lua"
            end
            if name and name:match(NAME) and not seen[name] then
                seen[name] = true
                found[#found + 1] = { name = name, path = path, directory = directory }
            end
        end
    end
    return found
end

local searched = {}

-- Loads a discovered module, returning its command table or `nil, message`.
function modules.load(module)
    if module.command then
        return module.command
    end
    local chunk, err = loadfile(module.path)
    if not chunk then
        return nil, err
    end
    if not searched[module.directory] then
        searched[module.directory] = true
        -- Appended, so that a module cannot shadow one of Umbra's own.
        package.path = ("%s;%s/?.lua;%s/?/init.lua"):format(package.path, module.directory, module.directory)
    end
    local ok, command = pcall(chunk, module.name, module.path)
    if not ok then
        return nil, command
    end
    if type(command) ~= "table" or type(command.run) ~= "function" then
        return nil, ("%s must return a table with a `run` function"):format(module.path)
    end
    module.command = command
    return command
end

return modules
