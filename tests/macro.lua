return function(h)
    local ecl, macro = h.ecl, h.macro
    local fail = h.fail
    local same = h.same

    for _, case in ipairs({
            "--@inline\nlocal function double(x) return x * 2 end\nreturn double(5)\n",
            "--@inline\nlocal function pair(x) return x, x * 2 end\nlocal a, b = pair(3)\nreturn a .. ':' .. b\n",
            "--@inline\nlocal function pair(x) return x, x * 2 end\nlocal a = pair(3)\nreturn a\n",
            "local out = {}\n--@inline\nlocal function pair(x) out[#out + 1] = x return x, x * 2 end\n"
            .. "local a, b = pair(3)\nreturn a .. ':' .. b .. ':' .. table.concat(out, ',')\n",
            "--@inline\nlocal function add(a, b) return a + b end\nreturn add(1, 2) * 3\n",
            "--@inline\nlocal function add(a, b) return a + b end\nreturn add(add(1, 2), 4)\n",
            "local k = 6\n--@inline\nlocal function square(x) return x * x end\nreturn square(k)\n",
            "--@inline\nlocal function neg(x) return -x end\nreturn neg(2) ^ 2\n",
            "--[[ @inline ]]\nlocal function inc(n) return n + 1 end\nreturn inc(7)\n",
            "--@inline\nlocal function greet(n) return 'hi ' .. n end\nreturn greet('bob')\n",
            "local seen\n--@inline\nlocal function mark(x) seen = x end\nlocal function f() mark(3) return seen end\nreturn f()\n",
            "local Module = {}\n--@inline\nfunction Module.method(x) return x + 1 end\nreturn Module.method(2)\n",
            "local Module = {}\n--@inline\nfunction Module.method(x) if x > 0 then return x end end\n"
            .. "local function f() return Module.method(2) end\nreturn f()\n",
            "local Module = { value = 4 }\n--@inline\nfunction Module:method(x) return self.value + x end\n"
            .. "return Module:method(3)\n",
            "local y = 9\n--@inline\nlocal function inner(x) local y = x return y end\n"
            .. "local function f() return inner(3) end\nreturn f() .. y\n",
            "local y = 1\n--@inline\nlocal function f(x) local y = x * 2 return y end\nlocal z = f(3)\nreturn y + z * 10\n",
            "local x = 1\n--@inline\nlocal function f(x) local w = 1 return x + w end\nlocal z = f(3)\nreturn x + z * 10\n",
            "local n = 0\nlocal function g() n = n + 1 return n end\n--@inline\nlocal function f(x) local w = 1 return x + w end\n"
            .. "local z = f(g())\nreturn z * 10 + n\n",
            "local n = 0\nlocal function f() n = n + 1 return n + 2 end\n--@inline\nlocal function square(x) return x * x end\n"
            .. "local s = square(f())\nreturn s * 10 + n\n",
            "local base = 10\n--@inline\nlocal function add_base(x) return x + base end\nreturn add_base(1)\n",
            "local n = 0\nlocal function bump() n = n + 10 return 0 end\n--@inline\nlocal function addg(x) return bump() + x end\n"
            .. "n = 1\nlocal r = addg(n)\nreturn r\n",
            "local log = {}\n--@inline\nlocal function push(x) return table.insert(log, x .. x) end\n"
            .. "push(tostring(#log + 1))\nreturn log[1]\n",
            "--@inline\nlocal function const(v) return function() return v end end\nlocal x = 1\nlocal f = const(x)\nx = 2\nreturn f()\n",
            "local n = 0\nlocal function f() n = n + 1 return n + 2 end\n--@inline\nlocal function square(x) return x * x end\n"
            .. "return square(f()) * 10 + n\n",
            "local out = {}\nlocal function emit(v) out[#out + 1] = v end\nlocal n = 0\nlocal function f() n = n + 1 return n end\n"
            .. "--@inline\nlocal function twice(x) return x + x end\nemit(twice(f()))\nreturn out[1] * 10 + n\n",
            "local n = 1\nlocal function f() n = n + 1 return n end\n--@inline\nlocal function twice(x) return x + x end\n"
            .. "return n + twice(f())\n",
            "local n = 1\nlocal function f() n = n + 1 return n end\n--@inline\nlocal function twice(x) return x + x end\n"
            .. "return n .. twice(f())\n",
            "local m = 1\nlocal function f() m = 5 return 1 end\n--@inline\nlocal function twice(x) return x + x end\n"
            .. "local function show(a, b) return a .. ',' .. b end\nreturn show(m, twice(f()))\n",
            "G_LIFT = 1\nlocal function f() G_LIFT = 7 return 1 end\n--@inline\nlocal function twice(x) return x + x end\n"
            .. "return G_LIFT + twice(f())\n",
            "local function f() return 1 end\n--@inline\nlocal function twice(x) return x + x end\nreturn ('ab'):rep(twice(f()))\n",
            "local n = 1\nlocal function f() n = 10 return 1 end\n--@inline\nlocal function add(a, b) return a + b end\nreturn add(n, f())\n",
            "local t, i = {}, 1\nlocal function f() i = 3 return 0 end\n--@inline\nlocal function twice(x) return x + x end\nt[i], t[3] = twice(f()), 0\nreturn t[1] or -1, t[3] or -1\n",
            "local t, order = {}, {}\nlocal function g() order[#order + 1] = 'g' return 1 end\nlocal function f() order[#order + 1] = 'f' return 1 end\n--@inline\nlocal function twice(x) return x + x end\nt[g()] = twice(f())\nreturn order[1], order[2]\n",
            "local t, order = {}, {}\nlocal function g() order[#order + 1] = 'g' return 1 end\nlocal function f() order[#order + 1] = 'f' return 1 end\n--@inline\nlocal function s(x) local y = f() return x + y end\nt[g()] = s(3)\nreturn order[1], order[2]\n",
            "local n = 1\nlocal function f() n = 10 return 1 end\n--@inline\nlocal function twice(x) return x + x end\n--@macro\nlocal function double(x) return x + x end\nreturn twice(f()) + double(3)\n",
            "_G.G_SAFE = 1\nlocal function change() rawset(_G, 'G_SAFE', 9) return 1 end\n--@inline\nlocal function twice(x) return x + x end\nreturn G_SAFE + twice(change())\n",
            "local t = setmetatable({}, { __index = function() return 4 end })\nlocal function f() rawset(t, 'x', 9) return 1 end\n--@inline\nlocal function twice(x) return x + x end\nreturn t.x + twice(f())\n",
            "--@inline\nlocal function id(x) return x end\nreturn id{1}\n",
            "--@inline\nlocal function id(x) return x end\nreturn id'x'\n",
            "local order = {}\nlocal function arg() order[#order + 1] = 'arg' return 1 end\n"
            .. "--@inline\nlocal function ping() order[#order + 1] = 'body' end\nping(arg())\n"
            .. "return table.concat(order, ',')\n",
            "local n = 0\nlocal function bump() n = n + 1 return n end\n"
            .. "--@inline\nlocal function ping() n = n + 10 end\nping(bump(), bump())\nreturn n\n",
            "local seen = {}\n--@inline\nlocal function mark(x) seen[#seen + 1] = x end\n"
            .. "local a = mark(3)\nreturn tostring(a), #seen, seen[1]\n",
            "local seen = {}\nlocal t = {}\n--@inline\nlocal function mark(x) seen[#seen + 1] = x end\n"
            .. "t.x = mark(4)\nreturn tostring(t.x), #seen, seen[1]\n",
            "local out = {}\n--@inline\nlocal function value(x)\n  out[#out + 1] = x\n  local y = x * 2\n  return y\nend\n"
            .. "if value(3) > 5 then out[#out + 1] = 'yes' end\nreturn table.concat(out, ',')\n",
            "local out = {}\n--@inline\nlocal function value(x)\n  out[#out + 1] = x\n  return x * 2\nend\n"
            .. "return 1 + value(3), table.concat(out, ',')\n",
            "local out = {}\nlocal function add(a, b) return a + b end\n"
            .. "--@inline\nlocal function value(x)\n  out[#out + 1] = x\n  return x * 2\nend\n"
            .. "return add(1, value(3)), table.concat(out, ',')\n",
            "local out = {}\n--@inline\nlocal function start(x)\n  out[#out + 1] = x\n  local y = x\n  return y\nend\n"
            .. "local total = 0\nfor i = start(1), 3 do total = total + i end\n"
            .. "return total, table.concat(out, ',')\n",
        }) do
        local out = ecl.render((macro.expand(ecl.tokens(case, "lua"), "lua", ecl)))
        local _, expansion_report = macro.expand(ecl.tokens(case, "lua"), "lua", ecl)
        if expansion_report.expanded == 0 then
            fail("inline did not expand", ("%q"):format(case))
        end
        local before = loadstring(case, "before")
        local after, err = loadstring(out, "after")
        if not after then
            fail("inline output does not load", ("%q -> %q (%s)"):format(case, out, err))
        else
            local a, b = before(), after()
            if
                type(a) ~= type(b)
                or (type(a) ~= "table" and a ~= b)
                or (type(a) == "table" and not same({ a.x, a.y, a[1], a.n }, { b.x, b.y, b[1], b.n }))
            then
                fail("inline changed the result", ("%q gave %s, was %s"):format(case, tostring(b), tostring(a)))
            end
        end
    end

    for _, case in ipairs({
            "--@inline\nlocal function g(x) return x end\nreturn map(g)\n",

            "--@inline\nlocal function f(x) return f(x) end\nreturn f(1)\n",
            -- A method call reaches whatever the receiver holds, not the macro.
            "--@inline\nlocal function add(self, n) return self.value + n end\n"
            .. "local object = { value = 4, add = add }\nreturn object:add(3)\n",
            "--@inline\nlocal function add(self, n) return self.value + n end\n"
            .. "local function make() return { value = 4, add = add } end\nreturn make():add(3)\n",
            "--@inline self\nlocal function f(x) return x end\nlocal obj = {f = f}\nreturn obj:f(3)\n",
            "local function f() return 1 end\n--@inline\nlocal function twice(x) return x + x end\nreturn ok and twice(f())\n",
            "local o = { v = 1 }\nfunction o:add(x) return self.v + x end\nlocal function f() return 1 end\n"
            .. "--@inline\nlocal function twice(x) return x + x end\nreturn o:add(twice(f()))\n",
            "local function f() return 1 end\n--@inline\nlocal function twice(x) return x + x end\n"
            .. "while twice(f()) < 3 do end\n",
            "--@inline\nlocal function pair(x) return x, x * 2 end\n"
            .. "local a = pair(3) + 1\nreturn a\n",
        }) do
        local out, report = macro.expand(ecl.tokens(case, "lua"), "lua", ecl)
        if report.expanded ~= 0 then
            fail("inline inlined something unsafe", ("%q -> %q"):format(case, ecl.render(out)))
        end
        if #report.warnings == 0 then
            fail("inline refused silently", ("%q"):format(case))
        end
    end

    -- @macro overwrites call sites that @inline would leave alone.
    for _, case in ipairs({
            "local base = 10\n--@macro\nlocal function addBase(x) return x + base end\nreturn addBase(1)\n",
            "--@macro\nlocal function square(x) return x * x end\nreturn square(f())\n",
            "--@macro\nlocal function ping() print('ping') end\nping(print('arg'))\n",
            "--@macro\nlocal function guard(x) if not x then return end end\nguard(false)\n",
            "local M = {}\n--@macro\nfunction M.f() return 1 end\nM.f = function() return 2 end\nreturn M.f()\n",
        }) do
        local out, report = macro.expand(ecl.tokens(case, "lua"), "lua", ecl)
        local rendered = ecl.render(out)
        if report.expanded == 0 then
            fail("macro did not overwrite", ("%q -> %q"):format(case, rendered))
        end
        if not ecl.check(rendered, "lua") then
            fail("macro output does not parse", rendered)
        end
    end

    -- An overwritten call is duplicated at each use, as the marker promises.
    local dup = table.concat({
        "local n = 0",
        "local function bump() n = n + 1 return n end",
        "--@macro",
        "local function twice(x) return x + x end",
        "local value = twice(bump())",
        "return value, n",
        "",
    }, "\n")
    local dup_out = ecl.render((macro.expand(ecl.tokens(dup, "lua"), "lua", ecl)))
    local dup_chunk = loadstring(dup_out)
    if not dup_chunk then
        fail("overwrite output does not load", dup_out)
    else
        local value, count = dup_chunk()
        if value ~= 3 or count ~= 2 then
            fail("overwrite did not evaluate its argument at each use", ("%s -> %s"):format(dup_out, tostring(value)))
        end
    end

    -- A statement macro that ends in a return supplies an initializer: its
    -- earlier statements hoist above the assignment.
    for _, case in ipairs({
            "--@inline\nlocal function f(x)\n  local y = x * 2\n  return y + 1\nend\nlocal a = f(3)\nreturn a\n",
            "--@inline\nlocal function f(x)\n  return x * 3\nend\nlocal a = f(4)\nreturn a\n",
            "local M = {}\n--@inline\nfunction M.f(x)\n  local y = x + 1\n  return y\nend\nlocal a = M.f(2)\nreturn a\n",
            "local M = { value = 4 }\n--@inline\nfunction M:add(n)\n  local v = self.value\n  return v + n\nend\nlocal a = M:add(3)\nreturn a\n",
        }) do
        local out = ecl.render((macro.expand(ecl.tokens(case, "lua"), "lua", ecl)))
        local _, hoist_report = macro.expand(ecl.tokens(case, "lua"), "lua", ecl)
        if hoist_report.expanded == 0 then
            fail("inline did not hoist a value-producing statement macro", ("%q"):format(case))
        end
        local before = loadstring(case, "before")
        local after, err = loadstring(out, "after")
        if not after then
            fail("hoist output does not load", ("%q -> %q (%s)"):format(case, out, err))
        else
            local a, b = before(), after()
            if a ~= b then
                fail("hoist changed the result", ("%q gave %s, was %s"):format(case, tostring(b), tostring(a)))
            end
        end
    end

    local no_tail = "--@inline\nlocal function f(x)\n  print(x)\nend\nlocal a = f(1)\nreturn a\n"
    local no_tail_out, no_tail_report = macro.expand(ecl.tokens(no_tail, "lua"), "lua", ecl)
    local no_tail_source = ecl.render(no_tail_out)
    local no_tail_before, no_tail_after = loadstring(no_tail), loadstring(no_tail_source)
    if no_tail_report.expanded == 0 or not no_tail_after then
        fail("hoist refused a body with no return", no_tail_source)
    elseif no_tail_before() ~= no_tail_after() then
        fail("hoist changed a body with no return", no_tail_source)
    end

    local nested = [[
local Macros = {}
--@macro
function Macros.inner() return 2 end
--@macro
function Macros.outer() return Macros.inner() + 1 end
local Alias = { outer = function() return 0 end }
return Macros.outer(), Alias.outer()
]]
    local nested_out, nested_report = macro.expand(ecl.tokens(nested, "lua"), "lua", ecl)
    local nested_source = ecl.render(nested_out)
    if
        nested_report.expanded < 2
        or nested_source:find("return Macros%.outer")
        or nested_source:find("return Macros%.inner")
        or not nested_source:find("Alias.outer", 1, true)
    then
        fail("nested macros did not settle", nested_source)
    end

    local second_round = [[
--@macro
local function wrap() return twice(f()) + double(3) end
local function f() return 3 end
--@inline
local function twice(x) return x + x end
--@macro
local function double(x) return x + x end
return wrap()
]]
    local round_out, round_report = macro.expand(ecl.tokens(second_round, "lua"), "lua", ecl)
    if round_report.expanded < 3 or not ecl.check(ecl.render(round_out), "lua") then
        fail("inline rejected a safe site after an earlier expansion round", ecl.render(round_out))
    end
    local ok_before, a1, a2 = pcall(assert(loadstring(nested)))
    local ok_after, b1, b2 = pcall(assert(loadstring(nested_source)))
    if not ok_after or a1 ~= b1 or a2 ~= b2 or not ok_before then
        fail("nested macros changed the result", nested_source)
    end

    -- Inlining accounts for every local it introduces, but macro declarations
    -- that the final pass drops do not count against the caller's function.
    local function local_case(count)
        local names = {}
        for index = 1, count do
            names[index] = "v" .. index
        end
        return "local function run(x)\n local " .. table.concat(names, ",")
            .. "\n --@inline\n local function twice(y) return y + y end\n twice(x + 1)\n return x\nend\nreturn run(1)\n"
    end
    local at_limit, at_limit_report = macro.expand(ecl.tokens(local_case(197), "lua"), "lua", ecl)
    local at_limit_source = ecl.render(at_limit)
    if #(at_limit_report.errors or {}) ~= 0 or at_limit_report.expanded == 0 or not loadstring(at_limit_source) then
        fail("inline counted a macro declaration that was dropped", at_limit_source)
    end
    local over_limit = local_case(198)
    local over_out, over_report = macro.expand(ecl.tokens(over_limit, "lua"), "lua", ecl)
    if #(over_report.errors or {}) ~= 1 then
        fail("inline did not report the local variable limit", ("%q -> %q"):format(over_limit, ecl.render(over_out)))
    elseif not over_report.errors[1].text:find("would leave 201 locals", 1, true) then
        fail("inline reported the wrong local variable count", over_report.errors[1].text)
    end

    local callback = [[
--@macro
local function invoke(handler) sink(handler) end
invoke(function(self, ...)
    local count = select("#", ...)
    for index = 1, count do
        if select(index, ...) == self then return true end
    end
end)
]]
    local callback_out, callback_report = macro.expand(ecl.tokens(callback, "lua"), "lua", ecl)
    local callback_source = ecl.render(callback_out)
    local callback_ok = ecl.check(callback_source, "lua")
    if callback_report.expanded == 0 or not callback_ok then
        fail("macro callback argument did not parse", callback_source)
    end
end
