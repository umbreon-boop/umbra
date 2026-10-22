return function(h)
    local q = h.quote
    local fail = h.fail

    do
        local pipe = io.popen(("ls %s/*.lua %s/*.lua 2>/dev/null"):format(q(h.here .. "/../src"), q(h.here)))
        local scripts = {}
        if pipe then
            for line in pipe:lines() do
                scripts[#scripts + 1] = line
            end
            pipe:close()
        end
        for _, path in ipairs(scripts) do
            local handle = io.open(path, "rb")
            local text = handle:read("*a")
            handle:close()
            local name = path:match("[^/\\]+$")
            local line_number = 0
            for line in (text .. "\n"):gmatch("([^\n]*)\n") do
                line_number = line_number + 1
                if line:match("^\t") then
                    fail("style: tab indentation", ("%s:%d"):format(name, line_number))
                end
                if line:match("[ \t]+$") then
                    fail("style: trailing whitespace", ("%s:%d"):format(name, line_number))
                end

                local declared = line:match("^%s*local%s+function%s+([%w_]+)") or line:match("^%s*local%s+([%w_]+)%s*=")
                if declared and declared:match("^%l+%u") then
                    fail("style: camelCase local", ("%s:%d `%s`"):format(name, line_number, declared))
                end

                if line:match("^[%a_][%w_]*%s*=") and not line:match("^%s*%-%-") then
                    fail(
                        "style: assignment to a global",
                        ("%s:%d `%s`"):format(name, line_number, line:match("^([%w_]+)"))
                    )
                end
            end
        end
    end

    for _, case in ipairs({
        { "lua", "if type(x) == 'table' then print(x.type) end\n", "if type(x)", "x.type" },
        { "luau", "type Id = number\nexport type P = string\nprint(type(1))\n", "\nexport type P", "print(type(1))" },
    }) do
        local out = h.printer.format(case[2], case[1], { force = true }, h.ecl) or ""
        if not out:find(case[3], 1, true) or not out:find(case[4], 1, true) then
            fail("formatter treated `type` as a keyword where it is a name", ("%q -> %q"):format(case[2], out))
        end
    end

    do
        local source = "local x = 1\n--[[ Example:\n        if x then\n            y()\n        end\n]]\n"
        for _, force in ipairs({ false, true }) do
            local out = h.printer.format(source, "lua", { force = force }, h.ecl) or ""
            if not out:find("--[[ Example:\n        if x then\n            y()\n        end\n]]\n", 1, true)
                or h.printer.format(out, "lua", { force = force }, h.ecl) ~= out then
                fail("a long comment lost its inner indentation", ("%q"):format(out))
            end
        end
    end

    do
        local source = "local t = { function() while x do end end; if a then b else c }\nlocal z = 1\n"
        local out = h.printer.format(source, "luau", { force = true }, h.ecl) or ""
        if not out:find("\nlocal z = 1", 1, true) then
            fail("a loop left the formatter's block stack unbalanced", ("%q"):format(out))
        end
    end

    for _, source in ipairs({ "print(t[ [=[a]=] ])\n", "print(t[ [[a]] ])\n" }) do
        local out = h.printer.format(source, "luajit", { force = true }, h.ecl) or ""
        if not h.same(h.code_tokens(out) or {}, h.code_tokens(source)) then
            fail("--force joined two tokens into one", ("%q -> %q"):format(source, out))
        end
    end
end
