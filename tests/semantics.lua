--- Every case must print the same output, and fail or succeed alike, before
--- and after a default bundle. Luau cases run under `lune` when installed.

local function quote(text)
    return "'" .. text:gsub("'", "'\\''") .. "'"
end

local function has(command)
    local pipe = io.popen(("command -v %s 2>/dev/null"):format(command))
    local found = pipe:read("*l")
    pipe:close()
    return found ~= nil
end

local runtimes = { lua = "luajit", luajit = "luajit", luau = has("lune") and "lune run" or nil }

local function run(runtime, path, args)
    local directory = path:match("^(.*)/")
    local pipe = io.popen(("cd %s && %s %s %s 2>&1; echo \"__exit:$?\""):format(
        quote(directory), runtime, quote(path), args or ""
    ))
    local output = pipe:read("*a")
    pipe:close()
    local status = tonumber(output:match("__exit:(%d+)%s*$"))
    return status == 0, (output:gsub("__exit:%d+%s*$", ""):gsub("%S*umbra%-semantics[^:]*:%d*:?", "<file>:"))
end

local function upvalue_heavy()
    local lines, names = {}, {}
    for i = 1, 55 do
        names[i] = ("v%02d"):format(i)
        lines[#lines + 1] = ("local %s = %d"):format(names[i], i)
    end
    lines[#lines + 1] = "local function heavy()"
    lines[#lines + 1] = "  local s = " .. table.concat(names, " + ")
    for _ = 1, 4 do
        lines[#lines + 1] = "  s = s + math.floor(1.5) + string.len('ab') + table.concat({}) : len()"
            .. " + select('#', 1) + tonumber('1') + #tostring(1) + #type(1) + (next({}) or 0)"
            .. " + (rawlen and 0 or 0) + (pcall(error) and 0 or 1) + #os.date('%Y') + (io and 1 or 0)"
    end
    lines[#lines + 1] = "  return s"
    lines[#lines + 1] = "end"
    lines[#lines + 1] = "print(heavy())"
    return table.concat(lines, "\n")
end

local cases = {
    { "elseif inside a function expression", "local ff = function(a) if a == 1 then return 1 elseif a == 2 then return 2 end return 3 end\nprint(ff(2))" },
    { "shadowed local after elseif", "local g = 10\nlocal ff = function(a) if a == 1 then return 1 elseif a == 2 then return 2 end return 3 end\nlocal g = 20\nprint(ff(2), g)" },
    { "a local named type", "local counter = 1\nlocal kind = type\ncounter = 2\nprint(counter, kind(1))" },
    { "locals named export and const", "local export, const = 1, 2\nlocal function f(export) return export + const end\nprint(f(5), export)" },
    { "global function stays global", "function helperfunction(x) return x end\nfor i = 1, 6 do helperfunction(i) end\nprint(type(rawget(package.loaded._G, 'helperfunction')))" },
    { "upvalue limit", upvalue_heavy() },
    { "dead field write does not swallow statements", "local M = {}\nM.unused = 1\nprint('after unused')\nif true then print('if kept') end\nlocal x = 1\nprint(M.other, x)" },
    { "self reads keep methods", "local M = {}\nfunction M:helper() return 'helper ok' end\nfunction M:run() return self:helper() end\nprint(M:run())" },
    { "impure dead writes keep their effects", "local n = 0\nlocal function nextid() n = n + 1 return n end\nlocal M = {}\nM.id = nextid()\nprint('n =', n)" },
    { "instances through setmetatable", "local Class = {}\nClass.__index = Class\nfunction Class.new(v) return setmetatable({ v = v }, Class) end\nfunction Class:get() return self.v end\nfunction Class:unused() return 0 end\nprint(Class.new(7):get())" },
    { "block shadowing", "local x = 1\ndo local x = 2 print(x) end\nprint(x)" },
    { "local refers to the outer name", "local x = 3\ndo local x = x + 1 print(x) end\nprint(x)" },
    { "repeat condition sees the body", "local i = 0\nrepeat local j = i i = i + 1 until j >= 2\nprint(i)" },
    { "recursive local function", "local function fact(n) if n <= 1 then return 1 end return n * fact(n - 1) end\nprint(fact(5))" },
    { "function expression is not recursive", "local f = 1\nlocal f = function() return type(f) end\nprint(f())" },
    { "varargs", "local function count(...) return select('#', ...) end\nprint(count(1, nil, 3))" },
    { "goto and labels", "local s = 0\nfor i = 1, 3 do\n  if i == 2 then goto continue end\n  s = s + i\n  ::continue::\nend\nprint(s)" },
    { "numeric for scoping", "local i = 'outer'\nfor i = 1, 2 do end\nfor i = i:len(), 6 do io.write(i, ' ') end\nprint(i)" },
    { "methods on strings", "local s = 'abc'\nprint(s:upper(), ('x'):rep(3))" },
    { "macro locals do not capture", "--@inline\nlocal function show(x)\n  local y = 'inner'\n  print(x)\nend\nlocal y = 'outer'\nshow(y)" },
    { "macro arguments are evaluated once", "local calls = 0\nlocal function next_value() calls = calls + 1 return calls end\n--@inline\nlocal function thrice(x)\n  for i = 1, 3 do print(x) end\nend\nthrice(next_value())\nprint('calls', calls)" },
    { "macros match by binding, not name", "--@inline\nlocal function size(s)\n  return 42\nend\nlocal str = 'hello'\nprint(size(str), pcall(function() return str:size() end))" },
    { "macro arguments are evaluated in order", "local function a() print('a') return 1 end\nlocal function b() print('b') return 2 end\n--@inline\nlocal function sub(x, y)\n  return y - x\nend\nprint(sub(a(), b()))" },
    { "qualified macros match their table", "local M = {}\nlocal Other = { get = function(x) return 'other ' .. x end }\n--@inline\nfunction M.get(x)\n  return 'M ' .. x\nend\nprint(M.get('a'), Other.get('b'))" },
    { "macro return does not escape", "--@inline\nlocal function guard(x)\n  if not x then return end\n  print('guard passed')\nend\nlocal function run(v)\n  guard(v)\n  print('run continues')\nend\nrun(false)" },
    { "macro upvalues are not rebound", "local prefix = 'outer-prefix'\n--@inline\nlocal function say(x)\n  print(prefix, x)\nend\nlocal function run()\n  local prefix = 'shadowed'\n  say(1)\nend\nrun()" },
    { "macro parameters may be assigned", "--@inline\nlocal function bump(x)\n  x = x + 1\n  print(x)\nend\nlocal v = 1\nbump(v)\nprint(v)" },
    { "macro writes to an outer local", "local seen\n--@inline\nlocal function mark(x) seen = x end\nlocal function f() mark(3) return seen end\nprint(f())" },
    { "macro body effects stay after argument effects", "function effect(t) io.write(t, ' ') return 1 end\n--@inline\nlocal function f(x) return effect('body') + x end\nprint(f(effect('arg')))" },
    { "expression macros keep multiple returns", "function pair() return 1, 2 end\n--@inline\nlocal function two() return pair() end\nprint(two())" },
    { "macro arguments are not discarded", "--@inline\nlocal function ping() print('ping') end\nping(print('arg'))" },
    { "an inline body hoists above an assignment", "--@inline\nlocal function f(x)\n  local y = x * 2\n  print('body', y)\n  return y + 1\nend\nlocal a = f(3)\nprint('value', a)" },
    { "if expression scoping", "value = 'global'\nlocal function pick()\n  local value = if true then 1 else 2\n  return value\nend\nprint(pick(), value)", "luau" },
    { "compound assignment to a global", "counter = 1\nlocal function bump() counter += 1 end\nbump() bump()\nprint(counter, type(print))", "luau" },
    { "interpolation reads locals", "local longname = 'x'\nlocal other = 1\nprint(`{longname}-{other}`, longname, other)", "luau" },
    { "the entry receives the script's arguments", "print(select('#', ...), ...)", args = "A B" },
    { "a module receives the name it was required by", "print(require('lib'))", files = { ["lib.lua"] = "return (...)" } },
    { "an entry with a shebang bundles", "#!/usr/bin/env luajit\nprint('ok')" },
    { "a bundled module is in package.loaded", "local a = require('sub.a')\nprint(a, package.loaded['sub.a'])",
        files = { ["sub/a.lua"] = "return 'a'" } },
    { "a module that failed to load is not a circular require", "local function load() return require('bad') end\npcall(load)\nlocal _, e = pcall(load)\nprint(tostring(e):find('circular') == nil)",
        files = { ["bad.lua"] = "error('bad')" } },
    { "a dead write that could raise is kept", "print((pcall(function()\n  local t = {}\n  t.x = 'a' + 1\nend)))" },
    { "a dead write of a trapped global is kept", "setmetatable(_G, { __index = function(_, k) error('undefined ' .. k) end })\nprint((pcall(function()\n  local t = {}\n  t.x = missing\nend)))" },
    { "lifted macro arguments keep operand order", "local n, m = 1, 1\nlocal function f() n = n + 1 m = 9 return n end\n--@inline\nlocal function twice(x) return x + x end\nlocal function show(a, b) return a .. ',' .. b end\nprint(n + twice(f()))\nprint(n .. twice(f()))\nprint(show(m, twice(f())))" },
    { "lifted macro arguments keep operand order in Luau", "local n, m = 1, 1\nlocal function f() n = n + 1 m = 9 return n end\n--@inline\nlocal function twice(x) return x + x end\nlocal function show(a, b) return a .. ',' .. b end\nprint(n + twice(f()))\nprint(n .. twice(f()))\nprint(show(m, twice(f())))", "luau" },
    { "a local alias of require is still bundled", "local require = require\nprint(require('lib'))",
        files = { ["lib.lua"] = "return 'bundled'" } },
    { "a statement dropped at the start of a block", "local g = print\ndo\n  type X = number\n  (g)('x')\nend", "luau" },
    { "a local named require is not bundled", "local function require(n) return 'custom:' .. n end\nprint(require('util'))",
        files = { ["util.lua"] = "return 'util module'" } },
    { "a dropped statement does not join two calls", "local t = {}\nlocal g = print\nt.y = 2\n(g)('paren')" },
    { "a dropped type alias does not join two calls", "local g = print\ntype X = number\n(g)('paren')", "luau" },
    { "interpolation keeps fields alive", "local t = {}\nt.x = 'hello'\nprint(`value {t.x}`)", "luau" },
    { "macros substitute inside interpolation", "--@inline\nlocal function greet(name) return `hi {name}` end\nlocal who = 'bob'\nprint(greet(who))", "luau" },
    { "a macro closure keeps its argument's value", "--@inline\nlocal function const(v) return function() return v end end\nlocal x = 1\nlocal f = const(x)\nx = 2\nprint(f())" },
    { "a macro argument is read before the body runs", "--@inline\nlocal function addg(x) return bump() + x end\nlocal n = 1\nfunction bump() n = n + 10 return 0 end\nprint(addg(n))" },
    { "a patched qualified macro is not inlined", "local M = {}\n--@inline\nfunction M.f() return 1 end\nlocal function patch(t) t.f = function() return 2 end end\npatch(M)\nprint(M.f())" },
    { "a macro patched through an alias is not inlined", "local M = {}\n--@inline\nfunction M.f() return 3 end\nlocal Alias = M\nAlias.f = function() return 99 end\nprint(M.f())" },
    { "a macro replaced by index is not inlined", "local N = {}\n--@inline\nfunction N.g(a) return a * 2 end\nN['g'] = function(a) return a * 3 end\nprint(N.g(5))" },
    { "a global defined by unbundled code is read late", "local n = 'compat'\nrequire(n)\nprint(utf8.char(65), utf8.char(66), utf8.char(67), utf8.char(68), utf8.char(69), utf8.char(70))", "luajit",
        files = { ["compat.lua"] = "utf8 = { char = string.char }" }, runtime = { "compat.lua" } },
}

return function(h)
    local process_bundle = require("process.bundle")
    local root = os.tmpname()
    os.remove(root)
    root = root .. "-umbra-semantics"
    assert(os.execute("mkdir -p " .. quote(root)))

    for index, case in ipairs(cases) do
        local name, source, dialect = case[1], case[2], case[3] or "lua"
        local runtime = runtimes[dialect]
        if runtime then
            local directory = ("%s/case%d"):format(root, index)
            assert(os.execute("mkdir -p " .. quote(directory)))
            local entry = ("%s/main.%s"):format(directory, dialect)
            local handle = assert(io.open(entry, "wb"))
            handle:write(source, "\n")
            handle:close()
            for file, text in pairs(case.files or {}) do
                local folder = file:match("^(.*)/")
                if folder then assert(os.execute("mkdir -p " .. quote(directory .. "/" .. folder))) end
                handle = assert(io.open(directory .. "/" .. file, "wb"))
                handle:write(text, "\n")
                handle:close()
            end
            local expected_ok, expected = run(runtime, entry, case.args)

            local ok, bundled = pcall(process_bundle.run, h.ecl, { dialect = dialect, entry = entry })
            if not ok or not bundled then
                h.fail("semantics: " .. name, "bundling failed: " .. tostring(bundled))
            else
                -- The bundle runs alone, so a module it failed to include
                -- cannot be found beside it at runtime.
                local alone = directory .. "/bundle"
                assert(os.execute("mkdir -p " .. quote(alone)))
                for _, file in ipairs(case.runtime or {}) do
                    assert(os.execute(("cp %s %s"):format(quote(directory .. "/" .. file), quote(alone))))
                end
                local out = ("%s/out.%s"):format(alone, dialect)
                handle = assert(io.open(out, "wb"))
                handle:write(bundled)
                handle:close()
                local actual_ok, actual = run(runtime, out, case.args)
                if actual_ok ~= expected_ok or actual ~= expected then
                    h.fail("semantics: " .. name, ("expected %q, got %q"):format(expected, actual))
                end
            end
        end
    end
    os.execute("rm -rf " .. quote(root))
end
