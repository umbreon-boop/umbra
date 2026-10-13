return function(h)
    local ecl, printer = h.ecl, h.printer

    do
        local source = table.concat({
            "local M = {",
            "--[=[",
            "Explains the first field.",
            "  An already indented line.",
            "]=]",
            "first = 1,",
            "-- between fields",
            "second = {",
            "--[[ nested long",
            "   comment ]]",
            "third = 3,",
            "},",
            "}",
            "return M",
        }, "\n") .. "\n"

        local function comment_count(text)
            local n = 0
            for _, token in ipairs(ecl.tokens(text, "luau")) do
                if token.is_comment then
                    n = n + 1
                end
            end
            return n
        end

        local formatted = printer.format(source, "luau", nil, ecl)
        if not ecl.check(formatted, "luau") then
            h.fail("table-constructor comments", "formatting broke the parse")
        end
        if comment_count(formatted) ~= comment_count(source) then
            h.fail(
                "table-constructor comments",
                ("%d comments in, %d out"):format(comment_count(source), comment_count(formatted))
            )
        end
        if printer.format(formatted, "luau", nil, ecl) ~= formatted then
            h.fail("table-constructor comments", "formatting is not idempotent")
        end

        if not formatted:find("\n\t--[=[", 1, true) then
            h.fail("table-constructor comments", "a long comment was not indented to its field's level")
        end
        if not formatted:find("\n\t]=]", 1, true) then
            h.fail("table-constructor comments", "a long comment's closing delimiter did not line up with its opener")
        end
        if not formatted:find("\n\t\t\tcomment ]]", 1, true) then
            h.fail("table-constructor comments", "a nested long comment did not indent with its nested table")
        end
    end

    do
        local source = table.concat({
            "local values = {",
            "--[[",
            "inside",
            "]]",
            "}",
        }, "\n") .. "\n"
        local formatted = printer.format(source, "luau", { indent = "    " }, ecl)
        if formatted:find("\t", 1, true) then
            fail("space indentation", "a long comment introduced a tab")
        end
        if not formatted:find("\n        inside", 1, true) then
            fail("space indentation", "a long comment did not follow the configured unit")
        end
    end

    do
        local source = table.concat({
            "local result = make({",
            "enabled = function(value)",
            "if value then",
            "return {",
            "ok = true,",
            "},",
            "elseif",
            "value == 2",
            "then",
            "return nil",
            "end",
            "end,",
            "})",
        }, "\n") .. "\n"
        local expected = table.concat({
            "local result = make({",
            "\tenabled = function(value)",
            "\t\tif value then",
            "\t\t\treturn {",
            "\t\t\t\tok = true,",
            "\t\t\t},",
            "\t\telseif",
            "\t\t\tvalue == 2",
            "\t\tthen",
            "\t\t\treturn nil",
            "\t\tend",
            "\tend,",
            "})",
        }, "\n") .. "\n"
        local formatted = printer.format(source, "luau", nil, ecl)
        if formatted ~= expected then
            h.fail("nested closure indentation", formatted)
        end
    end

    do
        local source = "local f=function(x)return x+1 end;return f(2)\n"
        local expected = "local f = function(x)\n\treturn x + 1\nend;\nreturn f(2)\n"
        local formatted = printer.format(source, "lua", { force = true }, ecl)
        if formatted ~= expected then
            h.fail("strict formatting", formatted)
        elseif not ecl.check(formatted, "lua") then
            h.fail("strict formatting", "formatting broke the parse")
        elseif printer.format(formatted, "lua", { force = true }, ecl) ~= formatted then
            h.fail("strict formatting", "formatting is not idempotent")
        end
    end

    do
        local source = "local Virtual = if cloneref then\n\tcloneref(game:GetService(\"VirtualInputManager\"))\nelse\n\tgame:GetService(\"VirtualInputManager\")\nlocal cam = workspace.CurrentCamera\n"
        local formatted = printer.format(source, "luau", { force = true }, ecl)
        if formatted ~= source then
            h.fail("preserve multiline if newlines with force", formatted)
        end
    end

    do
        local source = "function foo()\nend\n\n\nfunction bar()\nend\n"
        local formatted_force = printer.format(source, "luau", { force = true }, ecl)
        if formatted_force ~= source then
            h.fail("preserve multiple blank lines with force", formatted_force)
        end
        local formatted_std = printer.format(source, "luau", nil, ecl)
        if formatted_std ~= source then
            h.fail("preserve multiple blank lines without force", formatted_std)
        end
    end

    do
        local source = "local f=function(x)return x+1 end;return f(2)\n"
        local formatted_std = printer.format(source, "lua", nil, ecl)
        if formatted_std ~= source then
            h.fail("no newlines added without force", formatted_std)
        end
    end

    do
        local cases = {
            { "return\"\"", "return \"\"\n" },
            { "return{}", "return {}\n" },
            { "return;", "return;\n" },
            { "local{}", "local {}\n" },
            { "if\"\"then end", "if \"\" then\nend\n" },
            { "while\"\"do end", "while \"\" do\nend\n" },
            { "until\"\"", "until \"\"\n" },
            { "for i in\"\"do end", "for i in \"\" do\nend\n" },
            { "local function x()end", "local function x()\nend\n" },
            { "if a then elseif(b)then end", "if a then\nelseif (b) then\nend\n" },
            { "repeat print(1) until(b)", "repeat\n\tprint(1)\nuntil (b)\n" },
            { "for x in(t) do end", "for x in (t) do\nend\n" },
            { "if not(a) then end", "if not (a) then\nend\n" },
        }
        for _, case in ipairs(cases) do
            local input, expected = case[1], case[2]
            local formatted = printer.format(input, "lua", { force = true }, ecl)
            if formatted ~= expected then
                h.fail("keyword spacing rule", ("expected %q but got %q for %q"):format(expected, formatted, input))
            end
        end

        local luau_cases = {
            { "export type Mod = { a: number }", "export type Mod = { a: number }\n" },
            { "type Foo = { b: string }", "type Foo = { b: string }\n" },
            { "local x = if if a then 1 else 2 then 3 else 4", "local x = if if a then 1 else 2 then 3 else 4\n" },
            { "if if a then 1 else 2 then print(1) end", "if if a then 1 else 2 then\n\tprint(1)\nend\n" },
            { "while if a then 1 else 2 do print(1) end", "while if a then 1 else 2 do\n\tprint(1)\nend\n" },
            { "for x in if a then b else c do print(1) end", "for x in if a then b else c do\n\tprint(1)\nend\n" },
            { "if a then print(1) elseif if b then 1 else 2 then print(2) end", "if a then\n\tprint(1)\nelseif if b then 1 else 2 then\n\tprint(2)\nend\n" },
        }
        for _, case in ipairs(luau_cases) do
            local input, expected = case[1], case[2]
            local formatted = printer.format(input, "luau", { force = true }, ecl)
            if formatted ~= expected then
                h.fail("luau formatting rule", ("expected %q but got %q for %q"):format(expected, formatted, input))
            end
        end
    end

    local fail = h.fail

    for _, case in ipairs({
        { "local", "x", true },
        { "-", "-x", true },
        { "a", "b", true },
        { "..", ".5", true },
        { "[", "[", true },
        { ")", "(", false },
        { "1", "+", false },
        { "a", ",", false },
    }) do
        if ecl.needs_space(case[1], case[2], "lua") ~= case[3] then
            fail("needs_space", ("%q + %q should be %s"):format(case[1], case[2], tostring(case[3])))
        end
    end

    for _, case in ipairs({
        "return 0 and 1\n",
        "local x = 1 or 2\nreturn x\n",
        "if 0 and 1 then return 2 end\n",
        "return 0x10 and 1\n",
        "return 1 .. 2\n",
    }) do
        local minified = printer.minify(ecl.tokens(case, "lua"), "lua", ecl)
        local ok, why = loadstring(minified)
        if not ok then
            fail("minified numeral", ("%q -> %q (%s)"):format(case, minified, tostring(why)))
        end
    end
    for _, pair in ipairs({ { "0", "and" }, { "1", "or" }, { "0", "x" }, { "1", "e" } }) do
        if not ecl.needs_space(pair[1], pair[2], "lua") then
            fail("needs_space", ("%q + %q must need one"):format(pair[1], pair[2]))
        end
    end
end
