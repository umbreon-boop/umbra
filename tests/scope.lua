return function(h)
    local ecl, scope = h.ecl, h.scope
    local fail = h.fail

    for _, case in ipairs({

        { "local print = print\nprint('hi')\n", "A,-,A" },

        { "local a = 1\ndo local a = 2 print(a) end\nprint(a)\n", "A,B,-,B,-,A" },

        { "local n = 1\nlocal function f(n) return n end\nreturn f(2) + n\n", "A,B,C,C,B,A" },

        { "local i = 0\nrepeat local done = i > 2 i = i + 1 until done\nreturn i\n", "A,B,A,A,A,B,A" },

        { "local t = {} for i = 1, 3 do t[i] = i end return t\n", "A,B,A,B,B,A" },

        {
            "local t = {}\nt.go = function(n) return (rawget(_G, 'f') or print)(n) end\nreturn t\n",
            "A,A,-,B,-,-,-,B,A",
        },

        { "local M = {}\nfunction M.f() return 1 end\nreturn M.f()\n", "A,A,-,A,-" },
    }) do
        local source, want = case[1], case[2]
        local tokens = ecl.tokens(source, "lua")
        local info = scope.resolve(tokens, ecl)
        local label, seen, got = {}, 0, {}
        for i, token in ipairs(tokens) do
            if token.type == ecl.T.Identifier then
                local binding = info.owner[i]
                if binding == nil then
                    got[#got + 1] = "-"
                else
                    if not label[binding] then
                        seen = seen + 1
                        label[binding] = string.char(64 + seen)
                    end
                    got[#got + 1] = label[binding]
                end
            end
        end
        got = table.concat(got, ",")
        if got ~= want then
            fail("resolution", ("%q gave %s, want %s"):format(source, got, want))
        end
    end

    for _, case in ipairs({

        "local print = print\nprint('hi')\n",

        "local M = {}\nfunction M:go(a) return self.x + a end\nreturn M\n",

        "local a = 1\ndo local a = 2 print(a) end\nprint(a)\n",

        "local i = 0\nrepeat local done = i > 2 i = i + 1 until done\nreturn i\n",

        "local n = 1\nlocal function f(n) return n end\nreturn f(2) + n\n",

        "local load_token_types\nfunction load_token_types() end\nreturn load_token_types()\n",

        "local a, b = 1, 2\na, b = b, a\nlocal t = { a = 1, b = 2 }\nreturn a, b, t\n",
    }) do
        local tokens = ecl.tokens(case, "lua")
        local renamed = scope.rename(tokens, { dialect = "lua" }, ecl)
        local out = ecl.render(renamed)
        if not ecl.check(out, "lua") then
            fail("rename regression case broke the parse", ("%q -> %q"):format(case, out))
        else
            local a, b = scope.resolve(tokens, ecl), scope.resolve(renamed, ecl)
            local map, rmap = {}, {}
            for i = 1, #tokens do
                local x, y = a.owner[i], b.owner[i]
                if (x == nil) ~= (y == nil) or (x and ((map[x] and map[x] ~= y) or (rmap[y] and rmap[y] ~= x))) then
                    fail("rename regression case changed a binding", ("%q -> %q"):format(case, out))
                    break
                end
                if x then
                    map[x], rmap[y] = y, x
                end
            end
        end
    end

    do
        local source = "for i = 1, 3 do if i == 2 then continue end print(i) print(i) end\n"
        local tokens = ecl.tokens(source, "luau")
        local out = ecl.render(scope.localize(tokens, { dialect = "luau" }, ecl))
        if not ecl.check(out, "luau") then
            fail("localise regression case broke the parse", ("%q -> %q"):format(source, out))
        end
        if out:find("continue", 1, true) == nil then
            fail("localise renamed continue", ("%q -> %q"):format(source, out))
        end
    end

    do
        local source = "local function f() return debug.traceback('x') end\n"
            .. "print(1) print(2) print(3) print(4) print(5) print(f())\n"
        local _, cached, why = scope.localize(ecl.tokens(source, "lua"), { dialect = "lua" }, ecl)
        if why or #cached == 0 then
            fail("debug.traceback stopped global caching", tostring(why))
        end
        local _, _, blocked = scope.localize(ecl.tokens("debug.setfenv(f, {}) print(1)\n", "lua"), { dialect = "lua" }, ecl)
        if not blocked then
            fail("debug.setfenv did not stop global caching", "")
        end
    end
end
