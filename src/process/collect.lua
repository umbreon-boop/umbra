local resolve = require("process.resolve")
local scope = require("process.scope")

local collector = {}

--- The text a string literal token spells, or nil when it has escapes.
local function literal(text)
    local quote = text:sub(1, 1)
    if quote == '"' or quote == "'" then
        local body = text:sub(2, -2)
        return not body:find("\\", 1, true) and body or nil
    end
    local level = text:match("^%[(=*)%[")
    if level then
        return (text:sub(#level + 3, -#level - 3):gsub("^\r?\n", ""))
    end
end

--- Every `require` of a literal name, as `{ name, call, argument, parenthesized }`
--- where `call` and `argument` index the `require` and string tokens. With
--- `info` from `scope.resolve`, only calls to the global `require` count.
function collector.requires(tokens, ecl, info)
    local T = ecl.T
    local code = {}
    for index, token in ipairs(tokens) do
        if not token.is_trivia then
            code[#code + 1] = index
        end
    end
    local function at(n)
        return code[n] and tokens[code[n]]
    end
    local function is(n, name)
        local token = at(n)
        return token ~= nil and token.type == T[name]
    end
    local function is_string(n)
        return is(n, "String") or is(n, "LongString")
    end

    -- `local require = require` keeps calls through the local bundleable.
    local aliases = {}
    if info then
        for n = 1, #code - 3 do
            if is(n, "Local") and is(n + 1, "Identifier") and is(n + 2, "Assign")
                and info.global[code[n + 3]] == "require"
                and not (is(n + 4, "LeftParenthesis") or is(n + 4, "String") or is(n + 4, "LongString")
                    or is(n + 4, "Dot") or is(n + 4, "Colon") or is(n + 4, "Comma")) then
                aliases[info.owner[code[n + 1]] or false] = true
            end
        end
    end
    local function is_require(index)
        return not info or info.global[index] == "require" or aliases[info.owner[index] or false]
    end

    local found = {}
    for n = 1, #code do
        local token = at(n)
        if token.type == T.Identifier and token.text == "require" and not (is(n - 1, "Dot") or is(n - 1, "Colon"))
            and is_require(code[n]) then
            local argument
            if is_string(n + 1) then
                argument = n + 1
            elseif is(n + 1, "LeftParenthesis") and is_string(n + 2) and is(n + 3, "RightParenthesis") then
                argument = n + 2
            end
            local name = argument and literal(at(argument).text)
            if name then
                found[#found + 1] = {
                    name = name,
                    call = code[n],
                    argument = code[argument],
                    parenthesized = argument == n + 2,
                }
            end
        end
    end
    return found
end

--- Every module reachable from `entry_path`, keyed by path, in load order.
function collector.collect(ecl, entry_path, dialect, roots, package_context)
    local modules, order, seen = {}, {}, {}

    local function visit(path, context)
        if seen[path] then
            return
        end
        seen[path] = true

        local source = resolve.read(path)
        if not source then
            error(("cannot read module %q"):format(path))
        end
        local chunk, err = ecl.parse(source, dialect or "luau")
        if not chunk and not dialect then
            chunk, err = ecl.parse(source, "lua")
        end
        if not chunk then
            error(("%s: %s"):format(path, err))
        end
        local tokens = chunk:tokens()
        local info = assert(scope.resolve(tokens, ecl, dialect, nil, source, chunk))
        local calls = collector.requires(tokens, ecl, info)
        chunk:free()

        local replace = {}
        -- A shebang cannot stand inside a loader, and bundles add none.
        if tokens[1] and tokens[1].kind == ecl.SHEBANG then
            replace[1] = ""
        end
        for _, call in ipairs(calls) do
            local target, child_context
            if call.name:sub(1, 1) == "@" then
                local alias = call.name:match("^@([%w_-]+)")
                local dependency = alias and context and context.dependencies and context.dependencies[alias]
                if type(dependency) == "string" then
                    dependency = { root = dependency, dependencies = {} }
                end
                if dependency then
                    target = resolve.module(call.name, resolve.dirname(path), { [alias] = dependency.root })
                    child_context = dependency
                else
                    error(("%s: dependency module %q is not declared by this package"):format(path, call.name))
                end
            else
                target = resolve.module(call.name, resolve.dirname(path), roots)
                child_context = context
            end
            if target then
                -- A loader receives the name `require` would have passed, or,
                -- for an `@package` import, its resolved path.
                replace[call.call] = "__bundle_require"
                local name = call.name:sub(1, 1) == "@" and ("%q"):format(target) or tokens[call.argument].text
                local arguments = ("%q, %s"):format(target, name)
                replace[call.argument] = call.parenthesized and arguments or "(" .. arguments .. ")"
                visit(target, child_context)
            elseif call.name:sub(1, 1) == "@" then
                error(("%s: dependency module %q was not found; run `umbra update`"):format(path, call.name))
            end
        end

        local parts = {}
        for index, token in ipairs(tokens) do
            parts[index] = replace[index] or token.text
        end
        modules[path] = table.concat(parts)
        order[#order + 1] = path
    end

    visit(entry_path, package_context or { dependencies = {} })
    return modules, order
end

return collector
