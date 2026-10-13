return function(h)
    local ecl, shake = h.ecl, h.shake
    local fail = h.fail

    for _, case in ipairs({

        {
            "local M = {}\nfunction M.used() return 1 end\nfunction M.dead() return 2 end\nreturn M.used()\n",
            "M.dead",
        },

        { "local M = {}\nfunction M.go() return 1 end\nlocal m = M\nreturn m.go()\n", "" },

        { "local M = {}\nfunction M.a() end\nfunction M.b() end\nreturn M\n", "" },

        { "local M = {}\nfunction M.a() end\nfunction M.b() end\nlocal k = 'a'\nreturn M[k]\n", "" },

        { "local M = {}\nfunction M.a() end\nprint(M)\nreturn 1\n", "" },

        { "local M = {}\nfunction M.a() end\nfunction M.b() end\nreturn M['a']\n", "M.b" },

        { "local M = {}\n--@use M.kept\nfunction M.kept() end\nfunction M.dead() end\nreturn 1\n", "M.dead" },

        {
            "local mt = getmetatable(x)\nmt.__index = function() end\nmt.__call = function() end\nreturn 1\n",
            "",
        },

        {
            "local function patch(instance)\n  instance.Enabled = false\n  instance.Visible = false\nend\nreturn patch\n",
            "",
        },

        { "local t = makeThing()\nt.handler = function() end\nreturn 1\n", "" },

        { "local M = {}\nM.__index = function() end\nfunction M.dead() end\nreturn 1\n", "M.dead" },
    }) do
        local source, want = case[1], case[2]
        local tokens = ecl.tokens(source, "luau")
        local report = shake.analyse(tokens, "luau", ecl)
        local names = {}
        for _, entry in ipairs(shake.unreachable(report)) do
            names[#names + 1] = entry.table_name .. "." .. entry.field
        end
        local got = table.concat(names, ",")
        if got ~= want then
            fail("reachability", ("%q gave [%s], want [%s]"):format(source, got, want))
        end

        local out = ecl.render((shake.remove(tokens, report, ecl)))
        if not ecl.check(out, "luau") then
            fail("shake broke the parse", ("%q -> %q"):format(source, out))
        end
    end

    for _, case in ipairs({
        { "line", "local M = {}\n--@use M.kept\nfunction M.kept() end\nreturn 1\n" },
        { "long", "local M = {}\n--[[ @use M.kept ]]\nfunction M.kept() end\nreturn 1\n" },
        { "long, levelled", "local M = {}\n--[==[\n  @use M.kept\n]==]\nfunction M.kept() end\nreturn 1\n" },
        { "method spelling", "local M = {}\n--[[ @use M:kept ]]\nfunction M.kept() end\nreturn 1\n" },
    }) do
        local directives = shake.directives(ecl.tokens(case[2], "luau"))
        if not directives["M.kept"] then
            fail("@use directive", ("not seen in a %s comment"):format(case[1]))
        end
    end
end
