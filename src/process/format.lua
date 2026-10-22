local printer = require("process.printer")
local diagnostics = require("diag")
local formatter = {}

-- The code tokens of `input`, without the `;`s and call-sugar parentheses
-- that are layout.
local function code_tokens(input, dialect, library)
    local tokens = {}
    for _, token in ipairs(input) do
        if not token.is_trivia and token.text ~= ";" then
            tokens[#tokens + 1] = token
        end
    end

    local out = {}
    for index, token in ipairs(tokens) do
        -- StyLua adds a trailing comma to multiline tables; it is layout.
        if not (token.text == "," and tokens[index + 1] and tokens[index + 1].text == "}") then
            out[#out + 1] = token
        end
    end

    local function callable(token)
        return token.text:match("^[%a_][%w_]*$") ~= nil
            or token.text == ")" or token.text == "]" or token.text == "}"
    end

    local matching = {}
    do
        local stack, positions = {}, {}
        for index, token in ipairs(out) do
            local text = token.text
            if text == "(" or text == "{" or text == "[" then
                stack[#stack + 1] = text
                positions[#positions + 1] = index
            elseif text == ")" or text == "}" or text == "]" then
                local open = stack[#stack]
                if (open == "(" and text == ")") or (open == "{" and text == "}")
                    or (open == "[" and text == "]")
                then
                    matching[positions[#positions]] = index
                    stack[#stack] = nil
                    positions[#positions] = nil
                end
            end
        end
    end

    -- Parentheses around a type assertion are layout when they cover the whole
    -- expression and the context already ends there: `env = (f() :: any)`.
    local removed = {}
    local precedence = {
        ["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true, ["//"] = true,
        ["%"] = true, ["^"] = true, [".."] = true, ["=="] = true, ["~="] = true,
        ["<"] = true, [">"] = true, ["<="] = true, [">="] = true,
        ["and"] = true, ["or"] = true,
    }
    for index, token in ipairs(out) do
        if token.text == "(" and index > 1 and (out[index - 1].text == "=" or out[index - 1].text == "else") then
            local close = matching[index]
            if close then
                local cast, depth = false, 0
                for inner = index + 1, close - 1 do
                    local text = out[inner].text
                    if text == "(" or text == "{" or text == "[" then
                        depth = depth + 1
                    elseif text == ")" or text == "}" or text == "]" then
                        depth = depth - 1
                    elseif text == "::" and depth == 0 then
                        cast = true
                    end
                end
                local following = out[close + 1]
                local attached = following and (following.text == "." or following.text == ":"
                    or following.text == "[" or following.text == "("
                    or precedence[following.text])
                if cast and not attached then
                    removed[index], removed[close] = true, true
                end
            end
        end
    end

    -- Parentheses that cover an entire `if`/`elseif`/`while` condition are
    -- redundant; the formatter removes them.
    for index, token in ipairs(out) do
        if token.text == "if" or token.text == "elseif" or token.text == "while" then
            local open = index + 1
            if open <= #out and out[open].text == "(" then
                local close = matching[open]
                local following = close and out[close + 1]
                if following and (following.text == "then" or following.text == "do") then
                    removed[open], removed[close] = true, true
                end
            end
        end
    end

    -- `f("x")` and `f({ ... })` are the same code as `f "x"` and `f {}`.
    local index = 1
    while index <= #out do
        local token = out[index]
        if token.text == "(" and index > 1 and callable(out[index - 1]) then
            local close = matching[index]
            if close then
                local content = {}
                for inner = index + 1, close - 1 do
                    content[#content + 1] = out[inner]
                end
                local sugar = #content == 1
                    and (content[1].type == library.T.String or content[1].type == library.T.LongString)
                if not sugar and #content > 0 and content[1].text == "{" then
                    sugar = matching[index + 1] == close - 1
                end
                if sugar then
                    removed[index], removed[close] = true, true
                end
            end
        end
        index = index + 1
    end

    local text = {}
    for index, token in ipairs(out) do
        if not removed[index] then
            text[#text + 1] = token.text
        end
    end
    return table.concat(text, "\0")
end

local function code_source(source, dialect, library)
    return code_tokens(library.tokens(source, dialect) or {}, dialect, library)
end

local function format_file(library, options, path, opts)
    local check = options.check
    local handle = io.open(path, "rb")
    local source = handle:read("*a")
    handle:close()

    opts.force = options.force
    opts.code = check and nil or code_tokens
    local formatted, err, source_code = printer.format(source, options.dialect, opts, library)
    if not formatted then
        diagnostics.error(("could not parse `%s`"):format(path), nil, err)
        return "failed"
    end
    if formatted == source then
        return "unchanged"
    end
    if check then
        diagnostics.finished("Would format", path)
        return "changed"
    end

    local chunk, perr = library.parse(formatted, options.dialect)
    if not chunk then
        diagnostics.error(
            ("refused to rewrite `%s`"):format(path),
            nil,
            ("the formatted output would not parse: %s"):format(perr)
        )
        return "failed"
    end
    local output_code = code_tokens(chunk:tokens(nil, nil, true), options.dialect, library)
    chunk:free()
    if output_code ~= (source_code or code_source(source, options.dialect, library)) then
        diagnostics.error(
            ("refused to rewrite `%s`"):format(path),
            nil,
            "the formatted output would change the code, not only its layout"
        )
        return "failed"
    end

    local out = assert(io.open(path, "wb"))
    out:write(formatted)
    out:close()
    diagnostics.finished("Formatted", path)
    return "rewritten"
end

local function format_files(library, options, paths)
    local opts = { indent = "\t" }
    if options.indent and options.indent ~= "tabs" then
        opts.indent = (" "):rep(tonumber(options.indent))
    end
    local changed, rewritten, failed = 0, 0, 0
    for _, path in ipairs(paths) do
        local status = format_file(library, options, path, opts)
        if status == "failed" then
            failed = failed + 1
        elseif status == "changed" then
            changed = changed + 1
        elseif status == "rewritten" then
            changed = changed + 1
            rewritten = rewritten + 1
        end
    end
    return { changed = changed, rewritten = rewritten, failed = failed, total = #paths }
end

local function fork_available()
    if jit.os ~= "Linux" and jit.os ~= "OSX" then
        return nil
    end
    local ok, ffi = pcall(require, "ffi")
    if not ok then
        return nil
    end
    pcall(ffi.cdef, [[
        int fork(void);
        int waitpid(int pid, int *status, int options);
    ]])
    return ffi
end

local function parallel_files(library, options, paths)
    local ffi = fork_available()
    local jobs = tonumber(os.getenv("UMBRA_JOBS")) or 12
    jobs = math.max(1, math.min(jobs, #paths, 16))
    if not ffi or jobs < 2 then
        return format_files(library, options, paths)
    end

    local sized = {}
    for index, path in ipairs(paths) do
        local handle = io.open(path, "rb")
        local size = handle and handle:seek("end") or 0
        if handle then
            handle:close()
        end
        sized[index] = { path = path, size = size }
    end
    table.sort(sized, function(a, b)
        return a.size > b.size
    end)

    local groups, loads = {}, {}
    for index = 1, jobs do
        groups[index] = {}
        loads[index] = 0
    end
    for _, item in ipairs(sized) do
        local best = 1
        for index = 2, jobs do
            if loads[index] < loads[best] then
                best = index
            end
        end
        groups[best][#groups[best] + 1] = item.path
        loads[best] = loads[best] + item.size
    end

    io.stdout:flush()
    io.stderr:flush()
    local workers, results = {}, {}
    local fallback = {}
    for index = 1, jobs - 1 do
        local result_path = os.tmpname()
        local pid = ffi.C.fork()
        if pid == 0 then
            local result = format_files(library, options, groups[index])
            local file = io.open(result_path, "wb")
            if file then
                file:write(("%d %d %d %d"):format(
                    result.changed, result.rewritten, result.failed, result.total
                ))
                file:close()
            end
            io.stdout:flush()
            io.stderr:flush()
            os.exit(result.failed == 0 and 0 or 1, true)
        elseif pid > 0 then
            workers[#workers + 1] = pid
            results[#results + 1] = { path = result_path, total = #groups[index] }
        else
            fallback[#fallback + 1] = groups[index]
            os.remove(result_path)
        end
    end

    local own = format_files(library, options, groups[jobs])
    local changed, rewritten, failed, total = own.changed, own.rewritten, own.failed, #paths
    for index, pid in ipairs(workers) do
        local status = ffi.new("int[1]")
        ffi.C.waitpid(pid, status, 0)
        local result = results[index]
        local file = io.open(result.path, "rb")
        local values = file and file:read("*a") or ""
        if file then
            file:close()
        end
        os.remove(result.path)
        local c, r, f, n = values:match("^(%d+) (%d+) (%d+) (%d+)$")
        if c and status[0] == 0 then
            changed = changed + tonumber(c)
            rewritten = rewritten + tonumber(r)
            failed = failed + tonumber(f)
        else
            failed = failed + result.total
        end
    end

    for _, group in ipairs(fallback) do
        local result = format_files(library, options, group)
        changed = changed + result.changed
        rewritten = rewritten + result.rewritten
        failed = failed + result.failed
    end
    return { changed = changed, rewritten = rewritten, failed = failed, total = total }
end

function formatter.run(library, options)
    local dialect, check, force = options.dialect, options.check, options.force
    local root = options.root

    local function files(path)
        if path:match("%.luau?$") then
            local handle = io.open(path, "rb")
            if handle then
                handle:close()
                return { path }
            end
        end
        local shell = require("shell")
        local out = {}
        local pipe = io.popen("find " .. shell.quote(path) .. ' -type f \\( -name "*.lua" -o -name "*.luau" \\)')
        for line in pipe:lines() do
            out[#out + 1] = line
        end
        pipe:close()
        return out
    end

    local paths = files(root)
    table.sort(paths)
    local result
    if not check and #paths > 1 and not os.getenv("UMBRA_NO_PARALLEL") then
        result = parallel_files(library, options, paths)
    else
        result = format_files(library, options, paths)
    end

    diagnostics.finished(
        check and "Checked" or "Formatted",
        ("%d file%s, %d %s"):format(
            result.total,
            result.total == 1 and "" or "s",
            check and result.changed or result.rewritten,
            check and "would change" or "rewritten"
        )
    )
    diagnostics.summary()
    return result.failed == 0 and (not check or result.changed == 0)
end

return formatter
