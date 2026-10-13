return function(h)
    local q = h.quote
    local resolve = require("process.resolve")
    local collect = require("process.collect")
    local process_bundle = require("process.bundle")

    local function expect(what, actual, expected)
        if actual ~= expected then
            h.fail(what, ("expected %s, got %s"):format(tostring(expected), tostring(actual)))
        end
    end

    local root = os.tmpname()
    os.remove(root)
    assert(os.execute(("mkdir -p %s %s %s %s %s %s %s %s"):format(
        q(root .. "/sub"), q(root .. "/pkg"), q(root .. "/pkg_lib"), q(root .. "/vendor/lib"),
        q(root .. "/vendor/core"), q(root .. "/vendor/package-lib"), q(root .. "/libentry"), q(root .. "/initentry")
    )))

    local function write(path, text)
        local handle = assert(io.open(root .. "/" .. path, "wb"))
        handle:write(text)
        handle:close()
    end

    write(
        "main.lua",
        table.concat({
            '-- require("ghost")',
            "local s = \"require('ghost')\"",
            'local a = require("a")',
            'local b = require "sub.b"',
            "local again = require [[sub.b]]",
            'local pkg = require("pkg")',
            'local pkg_lib = require("pkg_lib")',
            'local lib = require("lib")',
            'local aliased = require("@lib")',
            'local package_lib = require("@package-lib")',
            'local aliased_file = require("@lib/helper.lua")',
            'local nested = require("@lib/nested.lua")',
            'local named = require("@lib/named.lua")',
            'local external = require("umbra_external")',
            "return { a = a, b = b, again = again, pkg = pkg, pkg_lib = pkg_lib, lib = lib, aliased = aliased, package_lib = package_lib, aliased_file = aliased_file, nested = nested, named = named, external = external, s = s }",
            "",
        }, "\n")
    )
    write("ghost.lua", 'error("ghost was loaded")\n')
    write("a.lua", "return { name = ... }\n")
    write("sub/b.lua", "B_RUNS = (B_RUNS or 0) + 1\n")
    write("pkg/init.lua", 'return require("./helper")\n')
    write("pkg/helper.lua", 'return "helper"\n')
    write("pkg_lib/lib.lua", 'return require("./helper")\n')
    write("pkg_lib/helper.lua", 'return "lib entry helper"\n')
    write("vendor/lib/init.lua", 'return "vendored"\n')
    write("vendor/lib/helper.lua", 'return "aliased helper"\n')
    write("vendor/lib/nested.lua", 'return require("@core")\n')
    write("vendor/lib/named.lua", "return (...)\n")
    write("vendor/package-lib/lib.lua", 'return require("@core")\n')
    write("vendor/core/lib.lua", 'return "transitive dependency"\n')
    write("libentry/lib.lua", 'return require("@package-lib")\n')
    write("initentry/init.lua", 'return require("@package-lib")\n')
    write("cycle_x.lua", 'return require("cycle_y")\n')
    write("cycle_y.lua", 'return require("cycle_x")\n')

    expect("normalise collapses dots", resolve.normalise("a/./b/../c"), "a/c")
    expect("normalise keeps leading ..", resolve.normalise("../x"), "../x")
    expect("normalise keeps absolute", resolve.normalise("/a//b"), "/a/b")
    assert(os.execute("mkdir -p " .. q(root .. "/default_project/src")))
    write("default_project/src/lib.lua", "return {}\n")
    expect("default build entry accepts src/lib.lua", resolve.default_entry(root .. "/default_project"), root .. "/default_project/src/lib.lua")
    expect("dotted names resolve", resolve.module("sub.b", root, { root }), root .. "/sub/b.lua")
    expect("packages resolve to init", resolve.module("pkg", root, root), root .. "/pkg/init.lua")
    expect("package modules resolve to lib.lua", resolve.module("pkg_lib", root, { root }), root .. "/pkg_lib/lib.lua")
    expect("relative names resolve", resolve.module("./helper", root .. "/pkg", {}), root .. "/pkg/helper.lua")
    expect("later roots are searched", resolve.module("lib", root, { root, root .. "/vendor" }), root .. "/vendor/lib/init.lua")
    expect("missing modules are nil", resolve.module("nope", root, { root }), nil)
    expect("absolute names resolve as written", resolve.module(root .. "/a", root .. "/sub", {}), root .. "/a.lua")
    expect("entry accepts a directory", resolve.entry(root .. "/pkg"), root .. "/pkg/init.lua")
    expect("entry directories accept lib.lua", resolve.entry(root .. "/libentry"), root .. "/libentry/lib.lua")
    expect("entry directories accept init.lua", resolve.entry(root .. "/initentry"), root .. "/initentry/init.lua")
    expect("@module paths resolve", resolve.module("@lib/helper.lua", root, { lib = root .. "/vendor/lib" }), root .. "/vendor/lib/helper.lua")
    expect("@module defaults to init.lua", resolve.module("@lib", root, { lib = root .. "/vendor/lib" }), root .. "/vendor/lib/init.lua")
    expect("@module falls back to lib.lua", resolve.module("@package-lib", root, { ["package-lib"] = root .. "/vendor/package-lib" }), root .. "/vendor/package-lib/lib.lua")
    expect("@module imports cannot escape their package", resolve.module("@lib/../../main.lua", root, { lib = root .. "/vendor/lib" }), nil)

    local calls = collect.requires(
        h.ecl.tokens('x.require("no") ; require "one" ; require("two") ; require(name) ; require("a\\"b")', "lua"),
        h.ecl
    )
    local names = {}
    for _, call in ipairs(calls) do
        names[#names + 1] = call.name
    end
    expect("only literal, unqualified requires are found", table.concat(names, ","), "one,two")

    local modules, order = collect.collect(h.ecl, root .. "/main.lua", "lua", {
        root, root .. "/vendor",
    }, { dependencies = {
        lib = { root = root .. "/vendor/lib", dependencies = {
            core = { root = root .. "/vendor/core", dependencies = {} },
        } },
        ["package-lib"] = { root = root .. "/vendor/package-lib", dependencies = {
            core = { root = root .. "/vendor/core", dependencies = {} },
        } },
    } })
    expect("ghost in a comment is not collected", modules[root .. "/ghost.lua"], nil)
    expect("entry is collected last", order[#order], root .. "/main.lua")
    expect("each module is collected once", #order, 13)

    local function run(source)
        local chunk, err = loadstring(source)
        if not chunk then
            return nil, err
        end
        return pcall(chunk)
    end

    package.preload.umbra_external = function()
        return "external"
    end

    local function check_result(label, source)
        B_RUNS = nil
        local ok, result = run(source)
        if not ok then
            h.fail(label .. " bundle did not run", tostring(result))
            return
        end
        expect(label .. ": modules receive their name", result.a.name, "a")
        expect(label .. ": @package modules receive their path", result.named, root .. "/vendor/lib/named.lua")
        expect(label .. ": nil-returning modules yield true", result.b, true)
        expect(label .. ": modules run once", B_RUNS, 1)
        expect(label .. ": cached value is shared", result.again, true)
        expect(label .. ": relative requires inside packages", result.pkg, "helper")
        expect(label .. ": package lib.lua entry", result.pkg_lib, "lib entry helper")
        expect(label .. ": extra roots", result.lib, "vendored")
        expect(label .. ": @module dependency import", result.aliased, "vendored")
        expect(label .. ": dependency lib.lua entry", result.package_lib, "transitive dependency")
        expect(label .. ": @module/file import", result.aliased_file, "aliased helper")
        expect(label .. ": package-scoped transitive dependency", result.nested, "transitive dependency")
        expect(label .. ": unresolved requires fall back", result.external, "external")
        expect(label .. ": strings are untouched", result.s, "require('ghost')")
    end

    local dependencies = {
        lib = { root = root .. "/vendor/lib", dependencies = {
            core = { root = root .. "/vendor/core", dependencies = {} },
        } },
        ["package-lib"] = { root = root .. "/vendor/package-lib", dependencies = {
            core = { root = root .. "/vendor/core", dependencies = {} },
        } },
    }
    local options = {
        dialect = "lua", entry = root .. "/main.lua", paths = { root .. "/vendor" }, dependencies = dependencies,
    }
    options.plain = true
    check_result("plain", (process_bundle.run(h.ecl, options)))
    options.plain, options.shake = false, false
    check_result("optimised", (process_bundle.run(h.ecl, options)))

    for _, entry in ipairs({ root .. "/libentry", root .. "/initentry" }) do
        local built = process_bundle.run(h.ecl, {
            dialect = "lua", entry = entry, dependencies = dependencies, plain = true,
        })
        local ok_entry, value = run(built)
        if not ok_entry or value ~= "transitive dependency" then
            h.fail("package entry builds with transitive dependencies", tostring(value))
        end
    end

    local cycle = process_bundle.run(h.ecl, { dialect = "lua", entry = root .. "/cycle_x.lua", plain = true })
    local ok, err = run(cycle)
    if ok or not tostring(err):find("circular require", 1, true) then
        h.fail("circular requires are reported", tostring(err))
    end

    write("macros.lua", "local Macros = {}\n--@macro\nfunction Macros.double(x) return x * 2 end\nreturn Macros\n")
    write("uses_macros.lua", 'local Macro = require("macros")\nreturn Macro.double(21)\n')
    local inlined = process_bundle.run(h.ecl, { dialect = "lua", entry = root .. "/uses_macros.lua" })
    if not inlined or inlined:find("double", 1, true) then
        h.fail("macros are inlined through require", tostring(inlined))
    elseif select(2, run(inlined)) ~= 42 then
        h.fail("an inlined cross-module macro changed the result", inlined)
    end

    package.preload.umbra_external = nil
    B_RUNS = nil
    os.execute("rm -rf " .. q(root))
end
