return function(h)
    local ecl, printer = h.ecl, h.printer
    local fail = h.fail

    for _, case in ipairs({
        "local a: | number | string = 1",
        "local b: & number & string = 1",
        "local c = f<<number>>(1)",
        "local d: {x: number} = nil :: any",
        "type E = number\nreturn 1",
    }) do
        local stripped = ecl.render(printer.strip_types(ecl.tokens(case, "luau"), case, "luau", ecl))
        if not ecl.check(stripped, "luau") then
            fail("regression case", ("%q -> %q"):format(case, stripped))
        end
    end
end
