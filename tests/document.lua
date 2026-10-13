return function(h)
    local q = h.quote
    local ecl, fail = h.ecl, h.fail
    local tmp = os.getenv("TMPDIR") or "/tmp"

    local function generate_files(sources)
        local dir = ("%s/umbra-docs-%d"):format(tmp, os.time() + math.random(1e6))
        os.execute(("mkdir -p %s %s"):format(q(dir .. "/src"), q(dir .. "/out")))
        for path, source in pairs(sources) do
            local full = dir .. "/src/" .. path
            os.execute("mkdir -p " .. q(full:match("^(.*)/") or dir .. "/src"))
            local handle = assert(io.open(full, "wb"))
            handle:write(source)
            handle:close()
        end

        local script = h.here .. "/../src/main.lua"
        os.execute(
            ("luajit %s doc --dialect luau --out %s %s >/dev/null 2>%s"):format(
                q(script),
                q(dir .. "/out"),
                q(dir .. "/src"),
                q(dir .. "/err")
            )
        )
        local err_file = io.open(dir .. "/err", "rb")
        local diagnostics = err_file and err_file:read("*a") or ""
        if err_file then
            err_file:close()
        end

        local pages = {}
        local output_dir = dir .. "/out"
        local pipe = io.popen("find " .. q(output_dir) .. " -type f -name '*.md' | sort")
        for path in pipe:lines() do
            local page = io.open(path, "rb")
            local name = path:sub(#output_dir + 2):gsub("%.md$", "")
            pages[name] = page:read("*a")
            page:close()
        end
        pipe:close()
        os.execute("rm -rf " .. q(dir))
        return pages, diagnostics
    end

    local function generate(source)
        return generate_files({ ["mod.lua"] = source })
    end

    local source = table.concat({
        "--[=[",
        "\tA tree.",
        "",
        "\t@class Tree",
        "]=]",
        "local Tree = {}",
        "",
        "--[=[",
        "\tOne node, holding more nodes.",
        "",
        "\t@interface Node",
        "\t@prop children { Node } -- its children, themselves nodes",
        "]=]",
        "",
        "--[=[",
        "\tInsert a value.",
        "",
        "\t@within Tree",
        "\t@param value any -- the value to store",
        "\t@return Tree -- the same tree",
        "]=]",
        "function Tree.insert(self, value, unusedThird)",
        "\treturn self",
        "end",
        "",
        "function Tree.undocumented(a, b)",
        "\treturn a + b",
        "end",
        "",
        "--[=[",
        "\tCounted from afar.",
        "",
        "\t@function countNodes",
        "\t@within Tree",
        "\t@param deep boolean -- whether to recurse",
        "]=]",
        "",
        "function Tree.countNodes(deep)",
        "\treturn 0",
        "end",
        "",
        "return Tree",
    }, "\n") .. "\n"

    local pages = generate(source)

    if not pages.Tree then
        fail("docs", "no page was written for `@class Tree`")
        return
    end

    local merged = generate([[
--[=[
    First description.
    @class Merge
    @tag first
]=]
local Merge = {}
--[=[
    Second description.
    @class Merge
    @tag second
]=]
return Merge
]])
    if not merged.Merge or not merged.Merge:find("First description.", 1, true)
        or merged.Merge:find("Second description.", 1, true)
        or not merged.Merge:find("`first`", 1, true) or not merged.Merge:find("`second`", 1, true) then
        fail("repeated class blocks did not preserve the first description and merge tags", merged.Merge or "no page")
    end

    local multi, cycle_diagnostics = generate_files({
        ["00-child.lua"] = "--[=[\nChild.\n@class Child\n@within Parent\n]=]\n",
        ["10-parent.lua"] = "--[=[\nParent.\n@class Parent\n]=]\n",
        ["init.lua"] = "--[=[\nPackage.\n@class Package\n]=]\n",
        ["cycle-a.lua"] = "--[=[\nA.\n@class CycleA\n@within CycleB\n]=]\n",
        ["cycle-b.lua"] = "--[=[\nB.\n@class CycleB\n@within CycleA\n]=]\n",
    })
    if not multi.index then
        fail("the @class declaration in init.lua did not select index.md", "no index page")
    end
    if not cycle_diagnostics:find("cycle%-a%.lua") then
        fail("cycle warning did not name the file declaring the class", cycle_diagnostics)
    end

    if not pages.Node then
        fail("docs", "`@interface Node` did not get its own page")
    elseif not pages.Node:find("children", 1, true) then
        fail("docs", "the interface's `@prop` is missing from its page")
    end

    if pages.Tree:find("children", 1, true) then
        fail("docs", "the interface's `@prop` leaked onto the enclosing class")
    end

    for name, page in pairs(pages) do
        if page:find("undocumented", 1, true) then
            fail("docs", ("an undocumented function was given an entry on %s"):format(name))
        end
    end

    if pages.Node and pages.Node:find("insert", 1, true) then
        fail("docs", "`@interface` captured a function that belongs to the class")
    end

    if not pages.Tree:find("countNodes", 1, true) then
        fail("docs", "`@function` did not attach a block written away from the code")
    end

    if not pages.Tree:find("insert", 1, true) then
        fail("docs", "a documented function is missing")
    end
    if pages.Tree:find("unusedThird", 1, true) then
        fail("docs", "`@param` did not override the signature read from the syntax")
    end

    local store = generate(table.concat({
        "--[=[",
        "\tA store.",
        "",
        "\t@class Store",
        "]=]",
        "local Store = {}",
        "",
        "--[=[",
        "\tMake one.",
        "",
        "\t@return Store -- a fresh store",
        "]=]",
        "function Store.new() return setmetatable({}, Store) end",
        "",
        "--[=[",
        "\tRead a key.",
        "",
        "\t@param key string -- the key",
        "]=]",
        "function Store:get(key) return self[key] end",
        "",
        "return Store",
    }, "\n") .. "\n").Store

    if not store then
        fail("docs", "no page for the store fixture")
        return
    end
    if not store:find("## Methods", 1, true) then
        fail("docs", "`function Store:get` did not produce a Methods section")
    end
    if not store:find("## Functions", 1, true) then
        fail("docs", "`function Store.new` did not produce a Functions section")
    end

    if not store:find("### `get`", 1, true) then
        fail("docs", "a method heading is not the bare name")
    end
    if store:find("Store:get", 1, true) or store:find("Store.new", 1, true) then
        fail("docs", "a heading still carries the module name")
    end

    local functions_at = store:find("## Functions", 1, true)
    local new_at = store:find("### `new`", 1, true)
    if not (new_at and functions_at and new_at > functions_at) then
        fail("docs", "a dot-defined function was filed under Methods")
    end

    local pkg, diagnostics = generate(table.concat({
        "--[=[",
        "\tThe package.",
        "",
        "\t@class Pkg",
        "]=]",
        "local Pkg = {",
        "\t--[=[",
        "\t\tThe cache submodule.",
        "",
        "\t\t@prop cache Cache",
        "\t]=]",
        "\tcache = 1,",
        "}",
        "",
        "--[=[",
        "\tDocuments nothing at all.",
        "",
        "\t@within Pkg",
        "\t@function missingEntirely",
        "]=]",
        "",
        "return Pkg",
    }, "\n") .. "\n")

    local page = pkg.Pkg or pkg.index
    if not page then
        fail("docs", "no page for the table-constructor fixture")
    else
        if not page:find("cache", 1, true) then
            fail("docs", "a `@prop` inside a table constructor was not documented")
        end
        if not page:find("The cache submodule.", 1, true) then
            fail("docs", "the prose above `@prop` was dropped instead of describing it")
        end

        local seen = 0
        for _ in page:gmatch("`cache`") do
            seen = seen + 1
        end
        if seen ~= 1 then
            fail("docs", ("`@prop cache` was recorded %d times, not once"):format(seen))
        end
    end

    if page and not page:find("missingEntirely", 1, true) then
        fail("docs", "a self-describing `@function` block was dropped")
    end

    local _, orphaned = generate(table.concat({
        "--[=[",
        "\tNo class, no @within.",
        "",
        "\t@function nowhereToGo",
        "]=]",
        "local x = 1",
        "return x",
    }, "\n") .. "\n")
    if not orphaned:find("nowhereToGo", 1, true) then
        fail("docs", "a block with no class and no `@within` was dropped silently")
    end

    local called = generate(table.concat({
        "--[=[",
        "\tA module.",
        "",
        "\t@class Called",
        "]=]",
        'local Interface = require("./interface")',
        "",
        "Interface.New({",
        "\t--[=[",
        "\t\t@prop nop bool",
        "\t\t@within Called",
        "",
        "\t\tDoes nothing at all",
        "\t]=]",
        "\tnop = function(v) end,",
        "\t--[=[",
        "\t\t@prop kick bool",
        "\t\t@within Called",
        "",
        "\t\tStops a kick",
        "\t]=]",
        "\tkick = function(v) end,",
        "})",
    }, "\n") .. "\n").Called

    if not called then
        fail("docs", "no page for the call-argument fixture")
    else
        for _, name in ipairs({ "nop", "kick" }) do
            if not called:find("`" .. name .. "`", 1, true) then
                fail("docs", ("`@prop %s` in a call argument was ignored"):format(name))
            end
        end

        local seen = 0
        for _ in called:gmatch("`nop`") do
            seen = seen + 1
        end
        if seen ~= 1 then
            fail("docs", ("`@prop nop` was recorded %d times"):format(seen))
        end
    end

    local piped = generate(table.concat({
        "--[=[",
        "\tA module.",
        "",
        "\t@class Piped",
        "]=]",
        "local Piped = {}",
        "",
        "--[=[",
        "\tPicks a mode.",
        "",
        "\t@within Piped",
        '\t@param mode "camera" | "input" -- which mode',
        '\t@param value string -- accepts string | nil values; use `string | nil` or ```lua type T = A | B```',
        "]=]",
        "function Piped.pick(mode) end",
        "",
        "return Piped",
    }, "\n") .. "\n").Piped

    if not piped then
        fail("docs", "no page for the union-type fixture")
    else
        if not piped:find("accepts string &#124; nil values", 1, true) then
            fail("docs", "a union type in a description was not rendered as a literal pipe")
        end
        if not piped:find("`string | nil`", 1, true) or not piped:find("```lua type T = A | B```", 1, true) then
            fail("docs", "pipes inside inline and fenced code were escaped")
        end
        for line in piped:gmatch("[^\n]+") do
            if line:sub(1, 1) == "|" and not line:find("^|%-%-%-") then
                local columns = 0
                local in_code = false
                for index = 1, #line do
                    local char = line:sub(index, index)
                    if char == "`" then
                        in_code = not in_code
                    elseif char == "|" and not in_code then
                        columns = columns + 1
                    end
                end
                if columns ~= 4 then
                    fail("docs", ("a table row has %d separators, not 4: %s"):format(columns, line))
                    break
                end
            end
        end
    end

    local named_type = generate(table.concat({
        "--[=[",
        "\tA task module.",
        "\t@class Tasks",
        "]=]",
        "local Tasks = {}",
        "",
        "---@type Task",
        "type Task = { id: number }",
        "",
        "return Tasks",
    }, "\n")).Tasks or ""
    if not named_type:find("`Task`", 1, true) or not named_type:find("type Task = { id: number }", 1, true) then
        fail("a name-only @type tag includes its type declaration", named_type)
    end

    local located = generate(table.concat({
        "--[=[",
        "\tA class in a nested output directory.",
        "\t@class Located",
        "\t@location groups/utilities/cleanup",
        "]=]",
        "local Located = {}",
        "return Located",
    }, "\n"))
    if not located["groups/utilities/cleanup/Located"] then
        fail("@location creates nested class page directories", "the nested page was not returned")
    end

    local lined = generate(table.concat({
        "--[=[",
        "\tA counter.",
        "",
        "\t@class Counter",
        "]=]",
        "local Counter = {}",
        "",
        "--- Adds to the count.",
        "--- @within Counter",
        "--- @param amount number -- how much to add",
        "function Counter.add(amount)",
        "\treturn amount",
        "end",
        "",
        "return Counter",
        "",
    }, "\n"))
    local page = lined.Counter or ""
    if not page:find("Adds to the count.", 1, true) or not page:find("how much to add", 1, true) then
        fail("a block of --- lines is one doc comment", page)
    end

    local classes = generate(table.concat({
        "--- A first class.",
        "--- @class A",
        "local A = {}",
        "--- @class B",
        "local B = {}",
        "--[[",
        "\t@function make",
        "\t@within A",
        "]]",
        "--[[",
        "\t@function make",
        "\t@within B",
        "]]",
        "--- Arrives late.",
        "function A.late() end",
        "return A",
        "",
    }, "\n"))
    local a, b = classes.A or "", classes.B or ""
    if not a:find("A first class.", 1, true) then
        fail("a --- class block keeps the lines after its first", a)
    end
    if not (a:find("make", 1, true) and b:find("make", 1, true)) then
        fail("floating functions of the same name stay with their own class", a .. "\n----\n" .. b)
    end
    if not a:find("late", 1, true) or b:find("late", 1, true) then
        fail("a function is documented on the table it is declared on", a .. "\n----\n" .. b)
    end

    local cycle, cycle_diagnostics = generate(table.concat({
        "--[=[", "\t@class Alpha", "\t@within Beta", "]=]",
        "--[=[", "\t@class Beta", "\t@within Alpha", "]=]",
        "return {}", "",
    }, "\n"))
    if not next(cycle) or not cycle_diagnostics:find("ancestor", 1, true) then
        fail("classes in a @within cycle are reported and still documented", cycle_diagnostics)
    end

    local single = generate(table.concat({
        "--[=[", "\tA thing that holds a value.", "", "\t@class Foo", "\t@prop size number", "]=]",
        "return {}", "",
    }, "\n"))
    local _, copies = (single.Foo or ""):gsub("A thing that holds a value%.", "")
    if copies ~= 1 then
        fail("a class description stays off its only property", single.Foo or "")
    end
end
