# Plugins

Umbra plugins add subcommands to the `umbra` CLI. A plugin is a Lua module
file named `<command>.lua`, or a package directory containing `init.lua`.
Each plugin returns a table with a `run` function:

```lua
local command_name, plugin_path = ...

return {
    description = "Print a greeting",
    usage = function()
        io.stderr:write("Usage: umbra hello [NAME]\n")
    end,
    run = function(arguments, eclipsed, umbra)
        local name = arguments[1] or "world"
        print(("hello, %s"):format(name))
        return true
    end,
}
```

Umbra loads the plugin with two arguments: its command name and file path. It
calls `run(arguments, eclipsed, umbra)`, where `arguments` holds the
subcommand arguments after the command name, `--` included, and `eclipsed` is the loaded
[eclipsed binding](eclipsed.md). Return `true` or `nil` on success; return
`false, message` to report a command error. The optional `description`
appears in `umbra --help`, and `usage()` is printed after an error.

## Install and discover plugins

Set `UMBRA_MODS` to a colon-separated list of plugin search directories. The
older `UMBRA_MODULES` name is accepted when `UMBRA_MODS` is unset or empty.
Without either variable, Umbra searches `$XDG_CONFIG_HOME/umbra/modules`, which
defaults to `$HOME/.config/umbra/modules`. Earlier search directories take
priority when command names collide.

```sh
mkdir -p "$HOME/.config/umbra/modules"
cp hello.lua "$HOME/.config/umbra/modules/hello.lua"
umbra hello Ada
```

A package can keep helper files beside `init.lua`:

```text
modules/
└── greet/
    ├── init.lua
    └── names.lua
```

Use the package-qualified name to load a helper, such as
`require("greet.names")`. Umbra adds the plugin search directory to the end
of `package.path` before executing a plugin, so a plugin cannot replace one
of Umbra's own modules, and a module installed for Lua itself takes priority
over a helper with the same name. Bundled plugins should use the
helpers passed through `umbra` instead of requiring Umbra internals directly;
those internal files are packed into the standalone executable.

## The helper table

The third `run` argument is documented under [`umbra`](API/umbra.md). It
exposes `eclipsed`, `diagnostics`, `bundle`, `format`, `document`,
`resolve`, and `run(arguments)`, which dispatches another Umbra command with
the current CLI options.

Built-in command names cannot be replaced by plugins. A plugin package with
the same name is shadowed by the built-in command and produces a warning.

## Bundling a plugin

A plugin that is compiled into Umbra itself is written the same way, but it
should reach Umbra's internals only through the `umbra` table. `run` can call
`umbra.run` to reuse another command's parsing and behaviour.
