return function(h)
    local q = h.quote
    local ecl, printer = h.ecl, h.printer
    local scope, macro = h.scope, h.macro
    local fail = h.fail

    local function have_lune()
        local pipe = io.popen("command -v lune 2>/dev/null")
        if not pipe then
            return false
        end
        local path = pipe:read("*l")
        pipe:close()
        return path ~= nil and path ~= ""
    end

    if not have_lune() then
        io.stderr:write("note: lune not found; skipping the Luau runtime checks\n")
    else
        local tmp = os.getenv("TMPDIR") or "/tmp"
        local function run_luau(source)
            local path = ("%s/umbra-test-%d.luau"):format(tmp, os.time() + math.random(1e6))
            local handle = assert(io.open(path, "wb"))
            handle:write(source)
            handle:close()
            local pipe = io.popen("lune run " .. q(path) .. " 2>&1")
            local output = pipe:read("*a")
            pipe:close()
            os.remove(path)
            return (output:gsub("%s+$", ""))
        end

        for _, case in ipairs({

            "local function add(a: number, b: number): number return a + b end\n" .. "print(add(2, 3))\n",

            "local n = 7\nprint(if n > 3 then 'big' else 'small')\n",

            "type Pair = { first: number, second: number }\n"
                .. "local function sum(p: Pair): number return p.first + p.second end\n"
                .. "print(sum({ first = 1, second = 2 }))\n",

            "local M = {}\nfunction M.greet(who: string): string return `hi {who}` end\n" .. "print(M.greet('bob'))\n",

            "local t = { n = 1 }\nt.n += 4\nprint(t.n)\n",
        }) do
            local want = run_luau(case)
            local tokens = ecl.tokens(case, "luau")

            local stages = {
                { "strip_types", ecl.render(printer.strip_types(tokens, case, "luau", ecl)) },
            }
            local stripped = printer.strip_types(tokens, case, "luau", ecl)
            stages[#stages + 1] = { "macro", ecl.render((macro.expand(stripped, "luau", ecl))) }
            stages[#stages + 1] = { "rename", ecl.render(scope.rename(stripped, { dialect = "luau" }, ecl)) }
            stages[#stages + 1] = { "localize", ecl.render((scope.localize(stripped, { dialect = "luau" }, ecl))) }
            stages[#stages + 1] = { "minify", printer.minify(stripped, "luau", ecl) }
            stages[#stages + 1] = { "format", printer.format(case, "luau", nil, ecl) }

            for _, stage in ipairs(stages) do
                local got = run_luau(stage[2])
                if got ~= want then
                    fail(
                        ("%s changed the result under lune"):format(stage[1]),
                        ("%q gave %q, want %q"):format(case, got, want)
                    )
                end
            end
        end
    end
end
