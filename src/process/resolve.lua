--[=[
    Module and entry path resolution.

    @class resolver
]=]
local resolver = {}

local function read(path)
    local handle = io.open(path, "rb")
    if not handle then
        return nil
    end
    local text = handle:read("*a")
    handle:close()
    return text
end

--[=[
    The directory part of `path`, or `.` when it has none.

    @param path string -- a file path
    @return string -- the directory
]=]
function resolver.dirname(path)
    return path:match("^(.*)/[^/]*$") or "."
end

--[=[
    Reads a whole file, or returns `nil` when it cannot be opened.

    @param path string -- the file path
    @return string -- the file contents
]=]
function resolver.read(path)
    return read(path)
end

--[=[
    Finds the entry file for `path`: the path itself, with `.lua`/`.luau`
    appended, or a package entry name inside it.

    @param path string -- a file or directory path
    @return string -- the resolved entry path
]=]
function resolver.entry(path)
    for _, candidate in ipairs({ path, path .. ".lua", path .. ".luau" }) do
        if read(candidate) ~= nil then
            return candidate
        end
    end
    for _, name in ipairs({ "init.lua", "init.luau", "main.lua", "main.luau", "lib.lua", "lib.luau" }) do
        local candidate = path .. "/" .. name
        if read(candidate) ~= nil then
            return candidate
        end
    end
    error(("cannot read entry %q"):format(path))
end

--[=[
    Finds the default build entry, preserving `src/main.lua` and accepting
    package-style entry files when the project has no main script.

    @param root string -- the project root
    @return string -- the resolved entry path
]=]
function resolver.default_entry(root)
    root = root or "."
    for _, name in ipairs({
        "src/main.lua", "src/main.luau", "src/init.lua", "src/init.luau", "src/lib.lua", "src/lib.luau",
        "main.lua", "main.luau", "init.lua", "init.luau", "lib.lua", "lib.luau",
    }) do
        local candidate = root == "." and name or root .. "/" .. name
        if read(candidate) ~= nil then
            return candidate
        end
    end
    error(("cannot read default entry %q"):format(root == "." and "src/main.lua" or root))
end

--[=[
    Collapses `.` and `..` segments while keeping a leading `..` or slash.

    @param path string -- an unresolved path
    @return string -- the normalised path
]=]
function resolver.normalise(path)
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." and #parts > 0 and parts[#parts] ~= ".." then
            parts[#parts] = nil
        elseif part ~= "." then
            parts[#parts + 1] = part
        end
    end
    return (path:sub(1, 1) == "/" and "/" or "") .. table.concat(parts, "/")
end

--[=[
    Resolves `spec` as required from a file in `from_dir`: relative specs
    against that directory, dotted names against each of `roots` in order,
    and `@package` imports through the matching package root.

    @param spec string -- the require string
    @param from_dir string -- the requiring file's directory
    @param roots table -- the search roots, or a package alias table
    @return string -- the resolved module path
]=]
function resolver.module(spec, from_dir, roots)
    local bases, project_bases = {}, {}
    if spec:sub(1, 1) == "@" then
        local name, file = spec:match("^@([%w_-]+)/(.*)$")
        if file == "" then
            return nil
        end
        if not name then
            name = spec:match("^@([%w_-]+)$")
        end
        local root = name and type(roots) == "table" and roots[name]
        if root then
            if file then
                local relative = resolver.normalise(file)
                if relative == ".." or relative:match("^%.%./") or relative:sub(1, 1) == "/" then
                    return nil
                end
                file = relative
            end
            local base = resolver.normalise(root .. (file and "/" .. file or ""))
            project_bases[1] = resolver.normalise(root .. "/src" .. (file and "/" .. file or ""))
            bases[1] = base
        end
    elseif spec:sub(1, 1) == "/" then
        bases[1] = resolver.normalise(spec)
    elseif spec:sub(1, 1) == "." then
        bases[1] = resolver.normalise(from_dir .. "/" .. spec)
    else
        if type(roots) == "string" then
            roots = { roots }
        end
        for _, root in ipairs(roots or {}) do
            local relative = spec:gsub("%.", "/")
            project_bases[#project_bases + 1] = resolver.normalise(root .. "/src/" .. relative)
            bases[#bases + 1] = resolver.normalise(root .. "/" .. relative)
        end
    end
    for _, base in ipairs(project_bases) do
        local candidates = { base, base .. ".lua", base .. ".luau", base .. "/init.lua", base .. "/init.luau", base .. "/main.lua", base .. "/main.luau", base .. "/lib.lua", base .. "/lib.luau" }
        for _, candidate in ipairs(candidates) do
            if read(candidate) then return resolver.normalise(candidate) end
        end
    end
    for _, base in ipairs(bases) do
        local candidates = {
            base,
            base .. ".lua",
            base .. ".luau",
            base .. "/init.lua",
            base .. "/init.luau",
            base .. "/main.lua",
            base .. "/main.luau",
            base .. "/lib.lua",
            base .. "/lib.luau",
        }
        for _, candidate in ipairs(candidates) do
            if read(candidate) then
                return resolver.normalise(candidate)
            end
        end
    end
    return nil
end

return resolver
