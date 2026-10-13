local process_format = require("process.format")
local diagnostics = require("diag")

local function paint(code, text)
    return diagnostics.paint(code, text)
end

local function literal(text)
    return paint("32", text)
end

local function value(text)
    return paint("36", text)
end

local format_command = {}

local function usage()
    io.stderr:write(
        ("%s umbra %s %s\n\n%s:\n"):format(
            paint("1", "Usage:"), literal("fmt [OPTIONS]"), literal("[PATH]"), paint("1", "Arguments")
        )
            .. ("  %s               File or directory [default: %s]\n\n%s:\n"):format(
                literal("[PATH]"), value("./src"), paint("1", "Options")
            )
            .. ("  %s  Lua dialect [default: %s]\n"):format(literal("-d, --dialect <NAME>"), value("luau"))
            .. ("      %s           Check without writing\n"):format(literal("--check"))
            .. ("      %s           Enforce whitespace and line-break rules\n"):format(literal("--force"))
            .. ("      %s  Indent with N spaces or tabs [default: %s]\n"):format(
                literal("--indent <VALUE>"), value("tabs")
            )
    )
end

local function parse(arguments)
    local options = { dialect = "luau", check = false, force = false, indent = "tabs" }
    local positional, index = {}, 1
    while index <= #arguments do
        local value = arguments[index]
        if value == "--dialect" or value == "-d" or value == "--indent" then
            if index == #arguments then
                return nil, ("a value is required for '%s', but none was supplied"):format(literal(value))
            end
            index = index + 1
            if value == "--indent" then
                options.indent = arguments[index]
            else
                options.dialect = arguments[index]
            end
        elseif value == "--check" then
            options.check = true
        elseif value == "--force" then
            options.force = true
        elseif value == "-h" or value == "--help" then
            options.help = true
            return options
        elseif value:sub(1, 1) == "-" then
            return nil, ("unexpected argument '%s'"):format(literal(value))
        else
            positional[#positional + 1] = value
        end
        index = index + 1
    end
    if options.indent ~= "tabs" and not options.indent:match("^%d+$") then
        return nil, ("invalid value '%s' for '%s': expected %s or a number of spaces"):format(
            options.indent, literal("--indent"), value("tabs")
        )
    end
    if #positional > 1 then
        return nil, ("unexpected argument '%s'"):format(literal(positional[2]))
    end
    options.root = positional[1] or "./src"
    return options
end

function format_command.run(arguments, library)
    local options, error_message = parse(arguments)
    if not options then
        return false, error_message
    end
    if options.help then
        usage()
        return true
    end
    local exists = os.execute("test -e " .. require("shell").quote(options.root))
    if exists ~= true and exists ~= 0 then
        return false, ("no such file or directory '%s'"):format(options.root)
    end
    return process_format.run(library, options)
end

format_command.parse = parse
format_command.usage = usage

return format_command
