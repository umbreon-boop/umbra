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

## Guides

- [Projects and dependencies](dependencies.md)
- [Writing API documentation](docgen.md)
- [Macros](macros.md)
- [Plugins](plugins.md)
- [The eclipsed binding](eclipsed.md)

The pages under `API/` are generated from the `---` and `--[[ ]]` comments in
Umbra's own sources by `umbra doc`. The guides above are written by hand.
