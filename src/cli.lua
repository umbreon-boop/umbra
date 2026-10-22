local diagnostics = require("diag")

local function paint(code, text)
    return diagnostics.paint(code, text)
end

local function literal(text)
    return paint("32", text)
end

local function header(text)
    return paint("1", text)
end

local function warning_label(text)
    return paint("1;33", text)
end

local cli = {}

local builtins = {
    {
        name = "build",
        description = "Build the current project",
        load = function()
            return require("cli.build")
        end,
    },
    {
        name = "add",
        description = "Add a Git dependency",
        needs_eclipsed = false,
        load = function() return require("cli.dependencies").add end,
    },
    {
        name = "update",
        description = "Update all Git dependencies",
        needs_eclipsed = false,
        load = function() return require("cli.dependencies").update end,
    },
    {
        name = "doc",
        description = "Generate Markdown documentation",
        load = function()
            return require("cli.doc")
        end,
    },
    {
        name = "fmt",
        description = "Format Lua source files",
        needs_eclipsed = false,
        needs_interface = false,
        load = function()
            return require("cli.fmt")
        end,
    },
}

--[=[
    The helper table passed to a module's `run` function.

    @class umbra
    @prop eclipsed eclipsed -- the loaded native parser binding
    @prop diagnostics diagnostics -- diagnostic formatting and source locations
    @prop bundle bundle -- the bundle pipeline
    @prop format formatter -- the formatter pipeline
    @prop document documentation -- documentation generation
    @prop resolve resolver -- module and entry path resolution
    @prop run function -- dispatches another Umbra command with the current options
]=]
local function interface(library, options)
    return {
        -- The loaded native parser binding; see `docs/API/eclipsed.md`.
        eclipsed = library,
        -- Diagnostics, phases and resolver shared with built-in commands.
        diagnostics = require("diag"),
        bundle = require("process.bundle"),
        format = require("process.format"),
        document = require("process.document"),
        resolve = require("process.resolve"),
        -- Dispatches another command with the same CLI options.
        run = function(arguments)
            return cli.run(arguments, options)
        end,
    }
end

local warned = {}

-- Built-in commands followed by user modules, as `{ name, description,
-- load }`. A module named like a built-in is skipped with a warning.
function cli.commands(options, skip_modules)
    local list, taken = {}, {}
    for _, command in ipairs(builtins) do
        list[#list + 1] = command
        taken[command.name] = true
    end
    if skip_modules then
        return list
    end
    local modules = require("modules")
    for _, module in ipairs(modules.discover(options and options.directories)) do
        if taken[module.name] then
            if not warned[module.path] then
                warned[module.path] = true
                io.stderr:write(
                    ("%s module %s is shadowed by the built-in command\n"):format(
                        warning_label("warning:"), literal(module.path)
                    )
                )
            end
        else
            taken[module.name] = true
            list[#list + 1] = {
                name = module.name,
                module = module,
                load = function()
                    return modules.load(module)
                end,
            }
        end
    end
    return list
end

local function describe(command)
    if command.description then
        return command.description
    end
    local loaded, err = command.load()
    if not loaded then
        return ("(failed to load: %s)"):format(err)
    end
    return loaded.description or ""
end

function cli.usage(commands)
    io.stderr:write(
        ("%s umbra %s...\n\n%s:\n"):format(
            header("Usage:"), literal("<COMMAND> [OPTIONS]"), header("Commands")
        )
    )
    local wrote_modules = false
    for _, command in ipairs(commands or cli.commands()) do
        if command.module and not wrote_modules then
            io.stderr:write("\nModules:\n")
            wrote_modules = true
        end
        io.stderr:write(("  %s%s\n"):format(literal(("%-8s"):format(command.name)), describe(command)))
    end
end

function cli.run(arguments, options)
    local values = arguments or {}
    if #values == 0 or values[1] == "-h" or values[1] == "--help" then
        local commands = cli.commands(options)
        cli.usage(commands)
        return values[1] ~= nil
    end

    local name, command = values[1], nil
    local builtin = false
    for _, candidate in ipairs(builtins) do
        if candidate.name == name then
            builtin = true
            break
        end
    end
    local commands = cli.commands(options, builtin)
    for _, candidate in ipairs(commands) do
        if candidate.name == name then
            command = candidate
        end
    end
    if not command then
        io.stderr:write(
            ("%s unrecognized subcommand '%s'\n\n"):format(paint("1;31", "error:"), literal(name))
        )
        cli.usage(commands)
        return false
    end

    local command_arguments = { unpack(values, 2) }

    local handler, load_error = command.load()
    if not handler then
        io.stderr:write(
            ("%s cannot load module '%s': %s\n"):format(
                paint("1;31", "error:"), literal(name), load_error
            )
        )
        return false
    end
    local library
    if command.module or command.needs_eclipsed ~= false then
        local loaded, result = pcall(require("eclipsed").load)
        if not loaded then
            io.stderr:write(("%s %s\n"):format(paint("1;31", "error:"), result))
            return false
        end
        library = result
    end
    local fn, usage
    if type(handler) == "function" then
        fn = handler
    else
        fn = handler.run
        usage = handler.usage
    end
    if not fn then
        io.stderr:write(
            ("%s command '%s' has no run handler\n"):format(paint("1;31", "error:"), literal(name))
        )
        return false
    end
    local umbra
    if command.needs_interface ~= false then
        umbra = interface(library, options)
    end
    local ok, result, message = pcall(fn, command_arguments, library, umbra)
    if not ok then
        io.stderr:write(("%s %s\n"):format(paint("1;31", "error:"), result))
        return false
    end
    if result == false and message then
        io.stderr:write(("%s %s\n"):format(paint("1;31", "error:"), message))
        if usage then
            io.stderr:write("\n")
            usage()
        end
    end
    return result ~= false
end

return cli
