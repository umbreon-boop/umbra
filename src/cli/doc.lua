local process_documentation = require("process.document")
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

local docs_command = {}

local function usage()
    io.stderr:write(
        ("%s umbra %s %s\n\n%s:\n"):format(
            paint("1", "Usage:"), literal("doc [OPTIONS]"), literal("[SRC_DIR]"), paint("1", "Arguments")
        )
            .. ("  %s             Source directory [default: %s]\n\n%s:\n"):format(
                literal("[SRC_DIR]"), value("./src"), paint("1", "Options")
            )
            .. ("  %s  Lua dialect [default: %s]\n"):format(literal("-d, --dialect <NAME>"), value("luau"))
            .. ("      %s       Documentation directory [default: %s]\n"):format(literal("--out <DIR>"), value("docs/API"))
            .. ("      %s         Include private declarations\n"):format(literal("--private"))
    )
end

local function parse(arguments)
    local options = { dialect = "luau", output = "docs/API", private = false }
    local positional, index = {}, 1
    while index <= #arguments do
        local value = arguments[index]
        if value == "--dialect" or value == "-d" or value == "--out" then
            if index == #arguments then
                return nil, ("a value is required for '%s', but none was supplied"):format(literal(value))
            end
            index = index + 1
            if value == "--out" then
                options.output = arguments[index]
            else
                options.dialect = arguments[index]
            end
        elseif value == "--private" then
            options.private = true
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
    if #positional > 1 then
        return nil, ("unexpected argument '%s'"):format(literal(positional[2]))
    end
    options.root = positional[1] or "./src"
    return options
end

docs_command.parse = parse

function docs_command.run(arguments, library)
    local options, error_message = parse(arguments)
    if not options then
        return false, error_message
    end
    if options.help then
        usage()
        return true
    end
    if not os.rename(options.root, options.root) then
        return false, ("no such file or directory '%s'"):format(options.root)
    end
    return process_documentation.run(library, options) ~= nil and diagnostics.counts.error == 0
end

docs_command.usage = usage

return docs_command
