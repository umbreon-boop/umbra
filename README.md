# Umbra

Umbra builds Lua and Luau projects into a single runnable Lua file. It
resolves declared Git dependencies, strips type annotations, expands macros,
and can format and document the same sources.

## Commands

| Command | What it does |
|---|---|
| `umbra build [ENTRY] [-o FILE]` | Bundle an entry point. |
| `umbra add <name> <git-url> [--rev <commit>]` | Add and resolve a Git dependency. |
| `umbra update` | Resolve the dependency graph again. |
| `umbra fmt [PATH]` | Format Lua sources. |
| `umbra doc [SRC_DIR]` | Generate Markdown API pages. |

`umbra` with no command, or `umbra --help`, lists the built-in commands and
any installed modules.
