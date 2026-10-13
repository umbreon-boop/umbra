local shell = require("shell")

local dependencies = {}
local manifest_name = "package.toml"
local lock_name = "package.lock"
local target = "target"

local function read(path)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local text = handle:read("*a")
    handle:close()
    return text
end

local function write(path, text)
    local handle, err = io.open(path, "wb")
    if not handle then return nil, err end
    handle:write(text)
    handle:close()
    return true
end

local function run(command)
    local ok = os.execute(command)
    return ok == true or ok == 0
end

local function capture(command)
    local pipe = io.popen(command .. " 2>/dev/null")
    if not pipe then return nil end
    local value = pipe:read("*l")
    pipe:close()
    return value
end

local function quote(text)
    return (text:gsub("\\", "\\\\"):gsub('"', '\\"'))
end

local escapes = { b = "\b", t = "\t", n = "\n", f = "\f", r = "\r", ['"'] = '"', ["\\"] = "\\" }

--- The TOML basic or literal string starting at `position`, and the position
--- after it.
local function read_string(text, position)
    local delimiter = text:sub(position, position)
    if delimiter == "'" then
        local close = text:find("'", position + 1, true)
        if close then return text:sub(position + 1, close - 1), close + 1 end
    elseif delimiter == '"' then
        local out, index = {}, position + 1
        while index <= #text do
            local char = text:sub(index, index)
            if char == '"' then return table.concat(out), index + 1 end
            if char == "\\" then
                char = escapes[text:sub(index + 1, index + 1)]
                if not char then return nil end
                index = index + 1
            end
            out[#out + 1] = char
            index = index + 1
        end
    end
    return nil
end

--- A dependency value: a Git URL string or `{ git = "...", rev = "..." }`.
local function parse_dependency(value)
    local dep, index
    local url, after = read_string(value, 1)
    if url then
        dep, index = { git = url }, after
    elseif value:sub(1, 1) == "{" then
        dep, index = {}, 2
        while true do
            index = value:find("%S", index) or #value + 1
            if value:sub(index, index) == "}" and next(dep) == nil then
                index = index + 1
                break
            end
            local key, start = value:match("^([%w_-]+)%s*=%s*()", index)
            if not key then return nil, "malformed inline table" end
            if key ~= "git" and key ~= "rev" then return nil, ("unsupported key %q"):format(key) end
            dep[key], index = read_string(value, start)
            if not dep[key] then return nil, ("`%s` must be a string"):format(key) end
            index = value:find("%S", index) or #value + 1
            local separator = value:sub(index, index)
            index = index + 1
            if separator == "}" then break end
            if separator ~= "," then return nil, "malformed inline table" end
        end
        if not dep.git then return nil, "missing `git`" end
    else
        return nil, "expected a Git URL string or an inline table"
    end
    if not value:sub(index):match("^%s*$") and not value:sub(index):match("^%s*#") then
        return nil, "unexpected text after the value"
    end
    return dep
end

--- The text and `[dependencies]` of a manifest, or `nil, message` for a
--- declaration it cannot read.
local function parse_manifest(path)
    local found, inside, number = {}, false, 0
    local text = read(path) or ""
    for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        number = number + 1
        local section = line:match("^%s*%[([^%]]+)%]%s*$")
        if section then
            inside = section == "dependencies"
            if section:match("^dependencies%.") then
                return nil, ("%s:%d: dependency tables are not supported"):format(path, number)
            end
        elseif inside and not line:match("^%s*$") and not line:match("^%s*#") then
            local name, value = line:match("^%s*([%w_-]+)%s*=%s*(.-)%s*$")
            local dep, err
            if name then
                dep, err = parse_dependency(value)
            else
                err = "expected `name = value`"
            end
            if not dep then return nil, ("%s:%d: %s"):format(path, number, err) end
            found[name] = dep
        end
    end
    return text, found
end

local function declaration(name, dep)
    if dep.rev then
        return ('%s = { git = "%s", rev = "%s" }'):format(name, quote(dep.git), quote(dep.rev))
    end
    return ('%s = "%s"'):format(name, quote(dep.git))
end

--- `text` with `line` added to the end of its `[dependencies]` section,
--- leaving every other line as it was.
local function add_declaration(text, line)
    local lines = {}
    for each in text:gmatch("([^\n]*)\n") do lines[#lines + 1] = each end
    local tail = text:match("[^\n]*$")
    if tail ~= "" then lines[#lines + 1] = tail end
    local crlf = text:find("\r\n", 1, true) and "\r" or ""
    local inside, last = false, nil
    for index, each in ipairs(lines) do
        local section = each:match("^%s*%[([^%]]+)%]%s*\r?$")
        if section then
            inside = section == "dependencies"
            if inside then last = index end
        elseif inside and each:match("%S") then
            last = index
        end
    end
    if last then
        table.insert(lines, last + 1, line .. crlf)
    else
        if #lines > 0 and lines[#lines]:match("%S") then lines[#lines + 1] = crlf end
        lines[#lines + 1] = "[dependencies]" .. crlf
        lines[#lines + 1] = line .. crlf
    end
    return table.concat(lines, "\n") .. "\n"
end

local function exists_dir(path)
    local ok = os.execute("test -d " .. shell.quote(path))
    return ok == true or ok == 0
end

local function repository_name(url)
    local path = url:gsub("%.git$", ""):gsub("[?#].*$", "")
    path = path:match("^[%w+.-]+://[^/]+(/.*)$") or path:match("^[^:]+:(.+)$") or path
    local owner, repo = path:match("([^/]+)/([^/]+)/?$")
    owner, repo = owner or "repo", repo or path:match("([^/]+)/?$") or "repo"
    owner = owner:gsub("[^%w_-]", "_")
    repo = repo:gsub("[^%w_-]", "_")
    return owner .. "." .. repo
end

local function git(git_dir, arguments)
    return "git --git-dir=" .. shell.quote(git_dir) .. " " .. arguments
end

--- The commit that `rev` names on the remote, or `nil` when `git ls-remote`
--- does not list it (as for a short commit hash).
local function remote_commit(url, rev)
    local pipe = io.popen("git ls-remote -- " .. shell.quote(url) .. " " .. shell.quote(rev) .. " 2>/dev/null")
    if not pipe then return nil end
    local refs = {}
    for line in pipe:lines() do
        local commit, ref = line:match("^(%x+)%s+(%S+)$")
        if commit then
            -- An annotated tag also lists the commit it points to as `<ref>^{}`.
            local peeled = ref:match("^(.*)%^{}$")
            if peeled then refs[peeled] = commit:lower() else refs[ref] = refs[ref] or commit:lower() end
        end
    end
    pipe:close()
    -- The order Git uses to resolve a short ref name.
    for _, pattern in ipairs({ "%s", "refs/%s", "refs/tags/%s", "refs/heads/%s" }) do
        local commit = refs[pattern:format(rev)]
        if commit then return commit end
    end
    return nil
end

local function materialize(dep)
    if not dep or not dep.git or dep.git == "" then return nil, nil, "dependency has no Git URL" end
    if dep.git:sub(1, 1) == "-" or (dep.rev and dep.rev:sub(1, 1) == "-") then
        return nil, nil, ("refusing a Git URL or revision starting with '-' (%q)"):format(dep.rev or dep.git)
    end
    local repo_name = repository_name(dep.git)
    local exact = dep.rev and dep.rev:match("^[%da-fA-F]+$") and #dep.rev == 40 and dep.rev:lower()
    -- Ask the remote which commit an unpinned revision names, so that an
    -- installed commit is not fetched again.
    local commit = exact or remote_commit(dep.git, dep.rev or "HEAD")
    local destination = commit and (target .. "/" .. repo_name .. "." .. commit) or nil
    if destination and exists_dir(destination) then return destination, commit end

    local git_dir = capture("mktemp -d")
    local stage = capture("mktemp -d " .. shell.quote(target .. "/.umbra-stage-XXXXXX"))
    local function cleanup()
        for _, path in ipairs({ git_dir, stage }) do
            os.execute("rm -rf -- " .. shell.quote(path))
        end
    end
    if not git_dir or not stage
        or not run("git -c init.defaultBranch=main init -q --bare " .. shell.quote(git_dir))
        or not run(git(git_dir, "remote add -- origin " .. shell.quote(dep.git))) then
        cleanup()
        return nil, nil, ("cannot prepare repository %q"):format(dep.git)
    end
    local wanted = dep.rev or "HEAD"
    if not run(git(git_dir, "fetch -q --depth 1 -- origin " .. shell.quote(wanted))) then
        cleanup()
        return nil, nil, ("cannot fetch revision %q from %q"):format(wanted, dep.git)
    end
    commit = capture(git(git_dir, "rev-parse FETCH_HEAD^{commit}"))
    if not commit then
        cleanup()
        return nil, nil, ("cannot resolve revision %q from %q"):format(wanted, dep.git)
    end
    commit = commit:lower()
    destination = target .. "/" .. repo_name .. "." .. commit
    if exists_dir(destination) then
        cleanup()
        return destination, commit
    end
    if not run(git(git_dir, "archive " .. shell.quote(commit)) .. " | tar -x -C " .. shell.quote(stage))
        or not run("mv -- " .. shell.quote(stage) .. " " .. shell.quote(destination)) then
        cleanup()
        return nil, nil, ("cannot install %q at %s"):format(dep.git, destination)
    end
    cleanup()
    return destination, commit
end

local function dependency_count(deps)
    local count = 0
    for _ in pairs(deps) do count = count + 1 end
    return count
end

local function update_graph(root_dependencies)
    if not run("mkdir -p " .. shell.quote(target)) then return nil, "cannot create target directory" end
    local records, expanded, resolved = {}, {}, {}
    local function visit(parent_path, declared)
        local names = {}
        for name in pairs(declared) do names[#names + 1] = name end
        table.sort(names)
        for _, alias in ipairs(names) do
            local dep = declared[alias]
            local ref = dep.rev or "HEAD"
            if dep.rev and #dep.rev == 40 and dep.rev:match("^[%da-fA-F]+$") then
                ref = dep.rev:lower()
            end
            local key = dep.git .. "\0" .. ref
            local result = resolved[key]
            if not result then
                local path, commit, err = materialize(dep)
                if not path then return nil, ("dependency %s: %s"):format(alias, err) end
                result = { path = path, commit = commit }
                resolved[key] = result
            end
            local path, commit = result.path, result.commit
            records[#records + 1] = table.concat({ parent_path, alias, dep.git, commit, path, dep.rev or "" }, "\t")
            if not expanded[path] then
                expanded[path] = true
                local manifest, children = parse_manifest(path .. "/" .. manifest_name)
                if not manifest then return nil, ("dependency %s: %s"):format(alias, children) end
                local ok, child_err = visit(path, children)
                if not ok then return nil, child_err end
            end
        end
        return true
    end
    local ok, err = visit(".", root_dependencies)
    if not ok then return nil, err end
    table.sort(records)
    local lines = { "# Generated by umbra update. parent<TAB>alias<TAB>git<TAB>commit<TAB>path<TAB>rev" }
    for _, record in ipairs(records) do lines[#lines + 1] = record end
    local written, write_err = write(lock_name, table.concat(lines, "\n") .. "\n")
    if not written then return nil, write_err end
    return records
end

local diagnostics = require("diag")

local function paint(code, text)
    return diagnostics.paint(code, text)
end

local function literal(text)
    return paint("32", text)
end

local function value(text)
    return paint("36", text)
end

local function add_usage()
    io.stderr:write(
        ("%s umbra %s %s %s\n\n%s:\n"):format(
            paint("1", "Usage:"), literal("add"), literal("<NAME>"), literal("<GIT-URL>"), paint("1", "Arguments")
        )
            .. ("  %s      Dependency alias [possible values: alphanumeric, %s, %s]\n"):format(
                literal("<NAME>"), literal("`-`"), literal("_")
            )
            .. ("  %s   Git repository URL\n\n%s:\n"):format(literal("<GIT-URL>"), paint("1", "Options"))
            .. ("      %s  Pin the dependency to %s\n"):format(literal("--rev <COMMIT>"), value("<COMMIT>"))
            .. ("  %s          Print help\n"):format(literal("-h, --help"))
    )
end

local function update_usage()
    io.stderr:write(
        ("%s umbra %s\n\n%s:\n"):format(paint("1", "Usage:"), literal("update"), paint("1", "Options"))
            .. ("  %s  Print help\n"):format(literal("-h, --help"))
    )
end

local function add_run(arguments)
    local name, url, rev, index = nil, nil, nil, 1
    while index <= #arguments do
        local value = arguments[index]
        if value == "--rev" then
            if index == #arguments then
                return false,
                    ("a value is required for '%s', but none was supplied"):format(literal("--rev"))
            end
            index = index + 1
            rev = arguments[index]
        elseif value == "-h" or value == "--help" then
            add_usage()
            return true
        elseif value:sub(1, 1) == "-" then
            return false, ("unexpected argument '%s'"):format(literal(value))
        elseif not name then
            name = value
        elseif not url then
            url = value
        else
            return false, ("unexpected argument '%s'"):format(literal(value))
        end
        index = index + 1
    end
    if not name or not url then
        local missing = {}
        if not name then missing[#missing + 1] = literal("<NAME>") end
        if not url then missing[#missing + 1] = literal("<GIT-URL>") end
        return false, ("the following required arguments were not provided:\n  %s"):format(
            table.concat(missing, "\n  ")
        )
    end
    if not name:match("^[%w_-]+$") then
        return false,
            ("invalid value '%s' for '%s': expected alphanumeric characters, %s or %s"):format(
                name, literal("<NAME>"), literal("`-`"), literal("_")
            )
    end
    if url:sub(1, 1) == "-" or (rev and rev:sub(1, 1) == "-") then
        return false, "a Git URL or revision may not start with '-'"
    end
    local original = read(manifest_name)
    local text, declared = parse_manifest(manifest_name)
    if not text then return false, declared end
    if declared[name] then return false, ("dependency %q already exists"):format(name) end
    declared[name] = { git = url, rev = rev }
    local ok, err = write(manifest_name, add_declaration(text, declaration(name, declared[name])))
    if not ok then return false, err end
    local records, update_err = update_graph(declared)
    if not records then
        if original then write(manifest_name, original) else os.remove(manifest_name) end
        return false, update_err
    end
    io.stdout:write(("Added %s\n"):format(name))
    return true
end

local function update_run(arguments)
    for index, value in ipairs(arguments) do
        if value == "-h" or value == "--help" then
            update_usage()
            return true
        end
        return false, ("unexpected argument '%s'"):format(literal(value))
    end
    local text, declared = parse_manifest(manifest_name)
    if not text then return false, declared end
    local records, err = update_graph(declared)
    if not records then return false, err end
    local count = #records
    io.stdout:write(("Updated %d dependenc%s\n"):format(count, count == 1 and "y" or "ies"))
    return true
end

dependencies.add = {
    description = "Add a Git dependency",
    run = add_run,
    usage = add_usage,
}

dependencies.update = {
    description = "Update all Git dependencies",
    run = update_run,
    usage = update_usage,
}

local function fail(message)
    error(message .. "; run `umbra update`", 0)
end

--- Checks the packages declared in `manifest_path` against what the lock
--- installed for them.
local function check_declared(manifest_path, node, owner)
    local text, declared = parse_manifest(manifest_path)
    if not text then error(declared, 0) end
    for alias, dep in pairs(declared) do
        local child, locked = node.dependencies[alias], node.locked[alias]
        local name = owner and ("%q of %s"):format(alias, owner) or ("%q"):format(alias)
        if not child then fail(("dependency %s is not installed"):format(name)) end
        local exact = dep.rev and #dep.rev == 40 and dep.rev:match("^[%da-fA-F]+$")
        if locked.git ~= dep.git
            or (locked.rev and locked.rev ~= (dep.rev or ""))
            or (exact and child.commit ~= dep.rev:lower()) then
            fail(("dependency %s changed in its package.toml"):format(name))
        end
    end
end

function dependencies.load()
    local nodes = { ["."] = { root = ".", dependencies = {}, locked = {} } }
    local text = read(lock_name) or ""
    for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        if line:sub(1, 1) ~= "#" and line ~= "" then
            local fields = {}
            for field in (line .. "\t"):gmatch("([^\t]*)\t") do fields[#fields + 1] = field end
            -- Locks written before revs were recorded have five fields.
            if #fields ~= 5 and #fields ~= 6 then
                error(("malformed %s line: %s"):format(lock_name, line), 0)
            end
            local parent, alias, git, commit, path, rev = unpack(fields)
            if not path:match("^" .. target .. "/[%w_.-]+$") or path:find("..", 1, true) then
                error(("%s names a path outside %s/: %s"):format(lock_name, target, path), 0)
            end
            nodes[parent] = nodes[parent] or { root = parent, dependencies = {}, locked = {} }
            nodes[path] = nodes[path] or { root = path, dependencies = {}, locked = {} }
            nodes[path].git, nodes[path].commit = git, commit
            nodes[parent].dependencies[alias] = nodes[path]
            nodes[parent].locked[alias] = { git = git, commit = commit, rev = rev }
        end
    end
    check_declared(manifest_name, nodes["."])
    for path, node in pairs(nodes) do
        if path ~= "." then check_declared(path .. "/" .. manifest_name, node, path) end
    end
    return nodes["."].dependencies
end

return dependencies
