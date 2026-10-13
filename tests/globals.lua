return function(h)
    local ecl, scope = h.ecl, h.scope
    local fail = h.fail

    for _, case in ipairs({

        "local t = {}\nfor i=1,3 do t[i] = tostring(i) .. tostring(i) .. tostring(i) end\nreturn table.concat(t)\n",

        "local r = {}\nlocal function g() end\ng = function() return 1 end\nr[1] = g()\nreturn r[1]\n",

        "return tostring(1)\n",

        "return rawget(_G, 'x') or tostring(1) .. tostring(2) .. tostring(3)\n",

        "local t = {}\nrawset(t, 'k', 1)\nreturn tostring(t.k) .. tostring(t.k) .. tostring(t.k)\n",

        "local out = {}\ntable.insert(out, 1)\ntable.insert(out, 2)\ntable.insert(out, 3)\nreturn #out\n",
    }) do
        local out, cached = scope.localize(ecl.tokens(case, "lua"), { dialect = "lua" }, ecl)
        local text = ecl.render(out)
        local before = loadstring(case, "before")
        local after, err = loadstring(text, "after")
        if not after then
            fail("localize output does not load", ("%q -> %q (%s)"):format(case, text, err))
        elseif before then
            local a, b = before(), after()
            if a ~= b then
                fail("localize changed the result", ("%q gave %s, was %s"):format(case, tostring(b), tostring(a)))
            end
        end

        for _, entry in ipairs(cached or {}) do
            if not text:find("local " .. entry.fresh .. "=", 1, true) then
                fail("localize renamed a global without declaring it", ("%s -> %s"):format(entry.name, entry.fresh))
            end
            if case:find("%." .. entry.name .. "%f[%W]") then
                fail("localize cached a field name as if it were a global", ("%s in %q"):format(entry.name, case))
            end
        end
    end
end
