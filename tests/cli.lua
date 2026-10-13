return function(h)
    local q = h.quote
    local cli = require("cli")
    local hermetic = { directories = {} }

    local function forwards(name)
        local seen
        local original = package.loaded["cli.build"]
        package.loaded["cli.build"] = {
            run = function(args)
                seen = args
                return true
            end,
        }
        local ok = cli.run({ "build", unpack(name) }, hermetic)
        package.loaded["cli.build"] = original
        return ok, seen
    end

    local ok, args = forwards({ "--dialect", "lua", "--plain", "in.lua", "out.lua" })
    if not ok or not h.same(args, { "--dialect", "lua", "--plain", "in.lua", "out.lua" }) then
        h.fail("CLI arguments were not forwarded", tostring(args and table.concat(args, " ")))
    end

    ok, args = forwards({ "-d", "luau" })
    if not ok or not h.same(args, { "-d", "luau" }) then
        h.fail("short dialect flag was not forwarded", tostring(args and table.concat(args, " ")))
    end

    ok = cli.run({ "nope" }, hermetic)
    if ok then
        h.fail("unknown command was accepted", "nope")
    end
    ok = cli.run({ "build", "--" }, hermetic)
    if ok then
        h.fail("`--` was accepted", "bundle --")
    end

    local build = require("cli.build")
    local options, error_message = build.parse({
        "--no-macros",
        "--cache-globals",
        "--no-minify",
        "entry.lua",
    })
    if
        not options
        or error_message
        or options.macros ~= false
        or options.cache_globals ~= true
        or options.minify ~= false
        or options.entry ~= "entry.lua"
    then
        h.fail("build stages were not parsed", error_message or "incorrect options")
    end

    local fmt = require("cli.fmt")
    local fmt_options, fmt_error = fmt.parse({ "--force", "entry.lua" })
    if not fmt_options or fmt_error or not fmt_options.force then
        h.fail("formatter force flag was not parsed", fmt_error or "incorrect options")
    end
    fmt_options, fmt_error = fmt.parse({})
    if not fmt_options or fmt_error or fmt_options.root ~= "./src" then
        h.fail("formatter source default was not parsed", fmt_error or tostring(fmt_options and fmt_options.root))
    end
    local doc = require("cli.doc")
    local doc_options, doc_error = doc.parse({})
    if not doc_options or doc_error or doc_options.root ~= "./src" then
        h.fail("documentation source default was not parsed", doc_error or tostring(doc_options and doc_options.root))
    end

    local process_bundle = require("process.bundle")
    local ok_bundle, source, module_count = pcall(process_bundle.run, h.ecl, {
        dialect = "luau",
        entry = "src/main.lua",
        plain = true,
    })
    if not ok_bundle or not source or module_count < 10 then
        h.fail("Umbra did not bundle itself", tostring(source or module_count))
    elseif not h.ecl.check(source, "luau") then
        h.fail("Umbra self-bundle does not parse", "assembled source was rejected")
    elseif not source:find("src/eclipsed.lua", 1, true) then
        h.fail("Umbra self-bundle missed bare modules", "eclipsed.lua was not collected")
    else
        local runtime_source, runtime_error = process_bundle.run(h.ecl, {
            dialect = "luau",
            entry = "src/main.lua",
        })
        if not runtime_source then
            h.fail("Umbra runtime bundle failed", tostring(runtime_error))
        else
            local base = os.tmpname()
            os.remove(base)
            local path = base .. "-umbra.lua"
            local handle = assert(io.open(path, "wb"))
            handle:write(runtime_source)
            handle:close()
            local pipe = assert(io.popen("luajit " .. q(path) .. " build --help 2>&1"))
            local output = pipe:read("*a")
            local ran = pipe:close()
            os.remove(path)
            if not ran or not output:find("Usage: umbra", 1, true) then
                h.fail("Umbra self-bundle did not run", output)
            end
        end
    end

    do
        local process_format = require("process.format")
        local base = os.tmpname()
        os.remove(base)
        local path = base .. ".lua"
        local original = "local f=function(x)return x+1 end;return f(2)\n"
        local handle = assert(io.open(path, "wb"))
        handle:write(original)
        handle:close()

        local formatted = process_format.run(h.ecl, { dialect = "lua", root = path })
        handle = assert(io.open(path, "rb"))
        local unchanged = handle:read("*a")
        handle:close()
        if not formatted or unchanged ~= original then
            h.fail("formatter changed layout without --force", unchanged)
        end

        handle = assert(io.open(path, "wb"))
        handle:write(original)
        handle:close()
        formatted = process_format.run(h.ecl, { dialect = "lua", force = true, root = path })
        handle = assert(io.open(path, "rb"))
        local forced = handle:read("*a")
        handle:close()
        os.remove(path)
        if not formatted or forced == original or not forced:find("\n\treturn x + 1\n", 1, true) then
            h.fail("formatter --force did not enforce layout", forced)
        end
    end

    do
        local modules = require("modules")
        local root = os.tmpname()
        os.remove(root)
        local first, second = root .. "/first", root .. "/second"
        assert(os.execute(("mkdir -p %s %s %s"):format(q(first .. "/pkg"), q(second), q(first .. "/bad name"))))
        local function write(path, text)
            local handle = assert(io.open(path, "wb"))
            handle:write(text)
            handle:close()
        end
        write(
            first .. "/hello.lua",
            table.concat({
                "local name, path = ...",
                "return {",
                '    description = "Say hello",',
                "    run = function(arguments, eclipsed, umbra)",
                "        UMBRA_HELLO = {",
                "            name = name,",
                "            path = path,",
                "            arguments = arguments,",
                "            shared = umbra.eclipsed == eclipsed,",
                '            parses = eclipsed.check("return 1", "lua"),',
                "            internals = type(umbra.bundle.run) == \"function\",",
                "        }",
                "        return true",
                "    end,",
                "}",
                "",
            }, "\n")
        )
        write(first .. "/pkg/init.lua", 'local refuse = require("pkg.helper")\nreturn { run = refuse }\n')
        write(first .. "/pkg/helper.lua", "return function() return false, 'helper refused' end\n")
        write(first .. "/broken.lua", "return {\n")
        write(first .. "/empty.lua", "return 42\n")
        write(first .. "/fmt.lua", "return { run = function() return true end }\n")
        write(first .. "/notes.txt", "not a module\n")
        write(second .. "/hello.lua", 'return { run = function() error("shadowed module ran") end }\n')
        write(second .. "/extra.lua", 'return { run = function(arguments) return arguments[1] == "go" end }\n')
        write(second .. "/dashes.lua", 'return { run = function(a) return a[1] == "--" and a[2] == "-x" end }\n')

        local directories = { first, second }
        local found = {}
        for _, module in ipairs(modules.discover(directories)) do
            found[#found + 1] = module.name
        end
        local listed = table.concat(found, ",")
        if listed ~= "broken,empty,fmt,hello,pkg,dashes,extra" then
            h.fail("modules were not discovered", listed)
        end

        local options = { directories = directories }
        local names = {}
        for _, command in ipairs(cli.commands(options)) do
            names[#names + 1] = command.name
        end
        if table.concat(names, ","):find("fmt,.*fmt") then
            h.fail("a module shadowed a built-in", table.concat(names, ","))
        end

        UMBRA_HELLO = nil
        if not cli.run({ "hello", "a", "b" }, options) then
            h.fail("a module command failed", "hello")
        end
        local seen = UMBRA_HELLO or {}
        if
            seen.name ~= "hello"
            or seen.path ~= first .. "/hello.lua"
            or not h.same(seen.arguments or {}, { "a", "b" })
            or not seen.shared
            or not seen.parses
            or not seen.internals
        then
            h.fail("a module did not receive its context", tostring(seen.path))
        end
        if cli.run({ "pkg" }, options) then
            h.fail("a failing package module succeeded", "pkg")
        end
        if cli.run({ "broken" }, options) or cli.run({ "empty" }, options) then
            h.fail("an invalid module ran", "broken/empty")
        end
        if not cli.run({ "extra", "go" }, options) or cli.run({ "extra" }, options) then
            h.fail("modules from later directories did not run", "extra")
        end
        if not cli.run({ "dashes", "--", "-x" }, options) then
            h.fail("a module did not receive `--` and what follows it", "dashes")
        end
        if package.path:find(first, 1, true) < package.path:find("/src/?.lua", 1, true) then
            h.fail("a module directory precedes Umbra's own modules", package.path)
        end
        UMBRA_HELLO = nil
        os.execute("rm -rf " .. q(root))
    end
end
