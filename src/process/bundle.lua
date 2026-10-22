local collect = require("process.collect")
local resolve = require("process.resolve")
local strip_types = require("process.strip_types")
local macros = require("process.macros")
local shake = require("process.shake_stage")
local rename = require("process.rename")
local localize = require("process.localize")
local minify = require("process.minify")
local check = require("process.check")
local diagnostics = require("diag")

local bundle = {}
local generated = "BUNDLER_GENERATED"

local function assemble(modules, order, entry_path)
    local parts = {
        "local __bundle_modules, __bundle_loaded, __bundle_loading = {}, {}, {}\n",
        "local function __bundle_require(name, ...)\n",
        "\tlocal value = __bundle_loaded[name]\n",
        "\tif value ~= nil then return value end\n",
        "\tlocal loader = __bundle_modules[name]\n",
        "\tif loader == nil then return require(name) end\n",
        "\tif __bundle_loading[name] then error(\"circular require of '\" .. name .. \"'\", 2) end\n",
        "\t__bundle_loading[name] = true\n",
        "\tlocal ok, result = pcall(loader, ...)\n",
        "\t__bundle_loading[name] = nil\n",
        "\tif not ok then error(result, 0) end\n",
        "\tvalue = result\n",
        "\tif value == nil then value = true end\n",
        "\t__bundle_loaded[name] = value\n",
        ("\tif name ~= %q and type(package) == \"table\" then package.loaded[(...)] = value end\n"):format(entry_path),
        "\treturn value\n",
        "end\n",
    }
    local origin, cursor = {}, 0
    for _, piece in ipairs(parts) do
        cursor = cursor + #piece
    end
    origin[#origin + 1] = { from = 1, to = cursor, path = generated }
    for _, path in ipairs(order) do
        local header = ("__bundle_modules[%q] = function(...)\n"):format(path)
        parts[#parts + 1] = header
        origin[#origin + 1] = { from = cursor + 1, to = cursor + #header, path = generated }
        cursor = cursor + #header
        origin[#origin + 1] = {
            from = cursor + 1,
            to = cursor + #modules[path],
            path = path,
        }
        parts[#parts + 1] = modules[path]
        cursor = cursor + #modules[path]
        parts[#parts + 1] = "\nend\n"
        origin[#origin + 1] = { from = cursor + 1, to = cursor + 5, path = generated }
        cursor = cursor + 5
    end
    local footer = ("return __bundle_require(%q, ...)\n"):format(entry_path)
    parts[#parts + 1] = footer
    origin[#origin + 1] = { from = cursor + 1, to = cursor + #footer, path = generated }

    local views = {}
    local function view(path)
        if not views[path] then
            views[path] = diagnostics.source(path, modules[path])
        end
        return views[path]
    end
    return table.concat(parts),
    function(offset)
        if not offset then
            return nil
        end
        for _, span in ipairs(origin) do
            if offset >= span.from and offset <= span.to then
                if span.path == generated then
                    return { path = generated }
                end
                return { source = view(span.path), offset = offset - span.from + 1 }
            end
        end
        return nil
    end
end

local function context(modules, order, entry_path)
    local source, locate = assemble(modules, order, entry_path)
    local function place(entry)
        local where = locate(entry.offset)
        if where then
            if where.path == generated then
                return nil
            end
            where.length = entry.length
        end
        return where
    end
    return {
        source = source,
        module_count = #order,
        report = function(warning)
            local where = locate(warning.offset)
            if where and where.path == generated then
                return
            end
            if where then
                where.length = warning.length
            end
            diagnostics.warn(warning.text, where, warning.note)
        end,
        report_error = function(entry)
            diagnostics.error(entry.text, place(entry), entry.note)
        end,
    }
end

function bundle.run(library, options)
    local entry = options.entry or resolve.default_entry()
    local entry_path = resolve.entry(resolve.normalise(entry))
    local roots = { resolve.dirname(entry_path) }
    for _, root in ipairs(options.paths or {}) do
        roots[#roots + 1] = resolve.normalise(root)
    end
    local package_context = {
        root = ".",
        dependencies = options.dependencies or {},
    }
    local modules, order = collect.collect(library, entry_path, options.dialect, roots, package_context)
    local assembled = context(modules, order, entry_path)
    local chunk, parse_error = library.parse(assembled.source, options.dialect)
    if not chunk then
        diagnostics.error("the assembled bundle does not parse", nil, parse_error)
        return nil
    end
    if options.plain then
        chunk:free()
        return assembled.source, assembled.module_count
    end

    local tokens = chunk:tokens()
    chunk:free()
    if not tokens then
        diagnostics.error("the assembled bundle does not lex")
        return nil
    end
    if options.strip_types ~= false then
        tokens = strip_types.run(tokens, assembled.source, options.dialect, library)
        if not tokens then
            return nil
        end
    end
    if options.macros ~= false then
        tokens = macros.run(tokens, options.dialect, assembled, library)
        if not tokens then
            return nil
        end
    end
    if options.shake ~= false then
        tokens = shake.run(tokens, options.dialect, assembled, library)
        if not tokens then
            return nil
        end
    end
    if options.rename ~= false then
        tokens = rename.run(tokens, options.dialect, library)
        if not check.source(tokens, options.dialect, "renaming produced source that does not parse", library) then
            return nil
        end
    end
    if options.cache_globals ~= false then
        tokens = localize.run(tokens, options.dialect, library)
        if not check.source(tokens, options.dialect, "caching globals produced source that does not parse", library) then
            return nil
        end
    end
    if options.minify == false then
        return library.render(tokens)
    end
    return minify.run(tokens, options.dialect, library)
end

return bundle
