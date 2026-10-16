# Writing API documentation

`umbra doc` reads special comments out of Lua source and writes one Markdown
page per top-level class. This is the format Umbra's own API pages under
`docs/API` are written in. The command line is:

```text
umbra doc [--dialect NAME] [--out DIR] [--private] [SRC_DIR]
```

The defaults are `--dialect luau`, `--out docs/API`, and `./src`. The output
directory is created if it does not exist.

## Doc blocks

A doc block is either a run of `---` lines or one long comment (`--[[ ... ]]`
or `--[=[ ... ]=]`) immediately before a declaration:

```lua
--- Adds two numbers.
--- @param a number -- the first
--- @param b number -- the second
--- @return number -- their sum
local function add(a, b)
    return a + b
end
```

Consecutive `---` lines join into a single block. A long comment is always one
block, which is why it is the usual choice when the text is long or contains
`---`.

Inside a block, a line that begins with `@` is a tag. Every other line is
prose, and the prose becomes the description of the declaration. A tag line
has the form `@tag arguments`, and most arguments are split from a
description by ` -- `:

```text
@param name type -- description
```

The type is optional; an omitted type is shown as `any`. When there is no
` -- ` at all, the whole tail is treated as the type.

## Classes

A class is a named page. Declare one with `@class`. `@interface` also
starts a page, but unlike `@class` it does not become the scope for the
blocks that follow, so attach its members with `@within`:

```lua
--[=[
    A growable list of values.

    @class List
]=]
local List = {}
```

Functions and properties declared after a `@class` block attach to it until
the next `@class` block. A function declared on a class table, such as
`function eclipsed.parse`, attaches to that class directly, even across a
later `@class`.

Use `@within` to attach a block to a class explicitly. This is required when
the block is written away from the code it describes:

```lua
--[=[
    Counts the nodes.

    @within Tree
    @function countNodes
    @param deep boolean -- whether to recurse
]=]
```

`@function` documents a function; `@method` documents a method (one defined
with `:`). Both take the bare name. A block matches a declaration of that
name on the class named by its `@within` first, then any declaration of that
name, so two blocks for `make` on different classes stay separate. If a
matching declaration exists, the block overrides the documentation read from
the syntax; if not, the block is still emitted on the class named by
`@within`. Child classes and interfaces are scoped by their parent, so a
`Node` may appear under both `Tree` and `Graph`. Use the dotted path when
attaching a member to one of same-named children, for example
`@within Tree.Node` or `@within Graph.Node`. Dotted paths can name deeper
children too, such as `@within Tree.Node.Leaf`.

## Tags

| Tag | Form | Meaning |
|---|---|---|
| `@class` | `@class Name` | Start a class page. |
| `@interface` | `@interface Name` | Start an interface page. |
| `@location` | `@location path/to/directory` | Write the class page under this directory, relative to `--out`; missing directories are created. |
| `@within` | `@within Name` or `@within Parent.Child` | Attach this block to a class or scoped child. |
| `@function` | `@function name` | Document a function away from its declaration. |
| `@method` | `@method name` | Document a method away from its declaration. |
| `@param` | `@param name type -- description` | Describe a parameter. `@arg` is a synonym. |
| `@return` | `@return type -- description` | Describe one return value. Repeat for several. |
| `@prop` | `@prop name type -- description` | Describe a property. |
| `@type` | `@type name [definition] -- description` | Describe an exported type alias. The definition is optional when the tag is attached to a type declaration. |
| `@error` | `@error type -- description` | Describe a raised error. |
| `@tag` | `@tag text` | Add a freeform tag to the class or callable. |
| `@realm` | `@realm text` | Note where the code runs, such as `server`. |
| `@deprecated` | `@deprecated [text]` | Mark the declaration deprecated. |
| `@since` | `@since version` | Note the release it appeared in. |
| `@unreleased` | `@unreleased` | Mark it as not yet in a stable release. |
| `@yields` | `@yields` | Note that a callable yields. |
| `@private` | `@private` | Hide it unless `--private` is given. |
| `@ignore` | `@ignore` | Hide it always. |

A property can also be written as a `.` line:

```text
.children { Node } -- the child nodes
```

which is the same as `@prop children { Node } -- the child nodes`.

When a property block contains exactly one property with no inline
description, the prose of the block is used as its description. A `@class`
or `@interface` block keeps its prose for the class itself:

```lua
--[=[
    The cache submodule.

    @prop cache Cache
]=]
```

`@return` is singular per line; repeat the tag to document several values.
The generator reads every block in a file before it matches declarations, so a
`@class` or `@interface` may sit anywhere; keep it before the code it should
scope.

## Pages

Each top-level class is written to `<Name>.md`, with characters other than
letters, digits, `-` and `_` replaced by `_`. The first top-level class
declared in the root `init.lua` or `lib.lua` is written to `index.md` instead.
When two pages would get the same file name, the later one gets a `-2`, `-3`,
... suffix, so no page overwrites another. A class with `@within` is rendered
on its parent's page. Classes whose `@within` names form a cycle are reported,
and the first of them becomes a top-level page.

`umbra doc` fails when a source file does not parse or when `SRC_DIR` does
not exist.

## Drift

The generator checks that what you wrote still matches the code. A `@param`
that names no parameter of the declaration, a `@within` on a class block that
names no class, or a `@function` with nowhere to attach is reported and
counted as drift. This is the point of generating API pages from source: a
rename in code without a rename in its docs is surfaced instead of published.
