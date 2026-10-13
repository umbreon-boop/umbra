local shell = require("shell")
local printer = require("process.printer")
local diagnostics = require("diag")
local formatter = {}

-- The code tokens of `source`, without the `;`s layout may add or remove.
local function code(source, dialect, library)
    local out = {}
    for _, token in ipairs(library.tokens(source, dialect) or {}) do
        if not token.is_trivia and token.text ~= ";" then
            out[#out + 1] = token.text
        end
    end
    return table.concat(out, "\0")
end

function formatter.run(library, options)
    local dialect, check, force = options.dialect, options.check, options.force
    local indent, root = options.indent, options.root

    local opts = { indent = "\t" }
    if indent and indent ~= "tabs" then
        opts.indent = (" "):rep(tonumber(indent))
    end

    local function files(path)
        local out = {}
        local pipe = io.popen("find " .. shell.quote(path) .. ' -type f \\( -name "*.lua" -o -name "*.luau" \\) | sort')
        for line in pipe:lines() do
            out[#out + 1] = line
        end
        pipe:close()
        return out
    end

    local changed, rewritten, failed, total = 0, 0, 0, 0
    for _, path in ipairs(files(root)) do
        total = total + 1
        local handle = io.open(path, "rb")
        local source = handle:read("*a")
        handle:close()

        opts.force = force
        local formatted, err = printer.format(source, dialect, opts, library)
        if not formatted then
            diagnostics.error(("could not parse `%s`"):format(path), nil, err)
            failed = failed + 1
        elseif formatted ~= source then
            changed = changed + 1
            if check then
                diagnostics.finished("Would format", path)
            else
                local ok, cerr = library.check(formatted, dialect)
                if not ok then
                    cerr = ("the formatted output would not parse: %s"):format(cerr)
                elseif code(formatted, dialect, library) ~= code(source, dialect, library) then
                    ok, cerr = false, "the formatted output would change the code, not only its layout"
                end
                if not ok then
                    diagnostics.error(
                        ("refused to rewrite `%s`"):format(path),
                        nil,
                        cerr
                    )
                    failed = failed + 1
                else
                    local out = assert(io.open(path, "wb"))
                    out:write(formatted)
                    out:close()
                    rewritten = rewritten + 1
                    diagnostics.finished("Formatted", path)
                end
            end
        end
    end

    diagnostics.finished(
        check and "Checked" or "Formatted",
        ("%d file%s, %d %s"):format(
            total,
            total == 1 and "" or "s",
            check and changed or rewritten,
            check and "would change" or "rewritten"
        )
    )
    diagnostics.summary()
    return failed == 0 and (not check or changed == 0)
end

return formatter
