local process_bundle = require("process.bundle")
local diagnostics = require("diag")
local dependencies = require("cli.dependencies")

local function paint(code, text)
    return diagnostics.paint(code, text)
end

local function literal(text)
    return paint("32", text)
end

local build_command = {}

local function usage()
    io.stderr:write(
        ("%s umbra %s %s\n\n%s:\n"):format(
            paint("1", "Usage:"), literal("build [OPTIONS]"), literal("[ENTRY]"), paint("1", "Arguments")
        )
            .. ("  %s     Lua entry point (default: src/main.lua, then package entry files)\n\n%s:\n"):format(
                literal("[ENTRY]"), paint("1", "Options")
            )
            .. ("  %s  Output path (default: target/artifact.lua)\n"):format(literal("-o, --output <FILE>"))
            .. ("  %s Lua dialect [default: luau]\n"):format(literal("-d, --dialect <NAME>"))
            .. ("  %s     Also resolve modules from %s; repeatable\n"):format(literal("-I, --path <DIR>"), literal("DIR"))
            .. ("      %s          Stop after module inlining\n"):format(literal("--plain"))
            .. ("      %s, %s, %s\n"):format(literal("--[no-]strip-types"), literal("--[no-]macros"), literal("--[no-]shake"))
            .. ("      %s, %s, %s\n"):format(literal("--[no-]rename"), literal("--[no-]cache-globals"), literal("--[no-]minify"))
    )
end

local function parse(arguments)
    local options = { dialect = "luau", plain = false, paths = {} }
    local stages = {
        ["strip-types"] = "strip_types", macros = "macros", shake = "shake",
        rename = "rename", ["cache-globals"] = "cache_globals", minify = "minify",
    }
    local positional, index = {}, 1
    while index <= #arguments do
        local value = arguments[index]
        if value == "--dialect" or value == "-d" or value == "--path" or value == "-I"
            or value == "--output" or value == "-o" then
            if index == #arguments then
                return nil, ("a value is required for '%s', but none was supplied"):format(literal(value))
            end
            index = index + 1
            if value == "--dialect" or value == "-d" then
                options.dialect = arguments[index]
            elseif value == "--path" or value == "-I" then
                options.paths[#options.paths + 1] = arguments[index]
            else
                options.output = arguments[index]
            end
        elseif value == "--plain" then
            options.plain = true
        elseif value == "-h" or value == "--help" then
            options.help = true
            return options
        elseif value:sub(1, 2) == "--" then
            local name = value:sub(3)
            local disabled = name:sub(1, 3) == "no-"
            if disabled then name = name:sub(4) end
            local stage = stages[name]
            if not stage then return nil, ("unexpected argument '%s'"):format(literal(value)) end
            options[stage] = not disabled
        elseif value:sub(1, 1) == "-" then
            return nil, ("unexpected argument '%s'"):format(literal(value))
        else
            positional[#positional + 1] = value
        end
        index = index + 1
    end
    if #positional > 1 then return nil, ("unexpected argument '%s'"):format(literal(positional[2])) end
    options.entry = positional[1]
    options.output = options.output or "target/artifact.lua"
    if options.output == "-" then options.stdout = true end
    options.dependencies = dependencies.load()
    return options
end

local function write_output(source, output, module_count, stdout)
    if stdout then
        io.write(source)
    else
        os.execute("mkdir -p -- " .. require("shell").quote(require("process.resolve").dirname(output)))
        local handle, err = io.open(output, "wb")
        if not handle then error(err, 0) end
        handle:write(source)
        handle:close()
        local detail = module_count
            and ("%d modules, %d bytes -> %s"):format(module_count, #source, output)
            or ("%d bytes -> %s"):format(#source, output)
        diagnostics.finished("Built", detail)
    end
    diagnostics.summary()
end

function build_command.run(arguments, library)
    local options, error_message = parse(arguments)
    if not options then return false, error_message end
    if options.help then usage(); return true end
    local source, module_count = process_bundle.run(library, options)
    if not source then return false end
    write_output(source, options.output, module_count, options.stdout)
    return true
end

build_command.parse = parse
build_command.usage = usage
return build_command
