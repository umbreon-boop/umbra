# Projects and dependencies

```text
umbra build [ENTRY] [-o FILE]
umbra add <name> <git-url> [--rev <commit>]
umbra update
```

`build` prefers `src/main.lua` and writes a plain Lua bundle to
`target/artifact.lua`; when that is absent it checks `src/init.lua`,
`src/lib.lua`, then project-root `main.lua`, `init.lua`, and `lib.lua` (with
`.luau` variants). `-o -` writes source to standard output. It does not add
a shebang or executable mode, and drops each source file's shebang line, so
wrappers such as `mise` remain responsible for the command's entry point.

## Declaring dependencies

Dependencies live in `package.toml`:

```toml
[dependencies]
json = "https://example.com/acme/json.git"
parser = { git = "https://example.com/acme/parser.git", rev = "0123456789abcdef0123456789abcdef01234567" }
```

The string form tracks the repository's default branch when updated. The
inline-table form pins a ref; use a full commit SHA for an immutable pin.
Values may be basic (`"..."`) or literal (`'...'`) strings followed by a `#`
comment; any other key or form is an error rather than being ignored. A URL
or ref may not start with `-`. `umbra add json <git-url> [--rev <commit>]`
adds one line to `[dependencies]`, leaving the rest of the file untouched,
and resolves it and its transitive dependencies. `umbra update` resolves the
whole graph again and records the selected commits in `package.lock`.

Each source tree is exported without `.git` history or Git metadata to
`target/<owner>.<repo>.<commit>`. The commit portion is the resolved full
SHA. The lockfile stores every dependency edge (parent package, local alias,
Git source, commit, exported path, and declared ref), so two libraries may use
different versions or the same alias without colliding, and a changed ref is
noticed before building. Commit `package.toml` and
`package.lock`; treat `target/` as generated build output. Builds do not
contact the network when every locked snapshot is present. If a declared
dependency has not been installed, or a snapshot named by the lock is missing,
`build` resolves the graph first, as `umbra update` would. A changed Git URL
or ref still requires an explicit `umbra update`.

## Package-scoped imports

Use Luau's string form of `require`:

```lua
local json = require("@json")
local encoder = require("@json/src/encode.lua")
local support = require("@json/src/support") -- tries support.lua, then support.luau
```

For project roots, module lookups try `src/` before the project root, so
`@json/encoder` can resolve to `target/.../src/encoder.lua` or
`target/.../src/encoder/init.lua`. With no file part, Umbra tries entry files
in `src/` and then the project root: `init.lua`, `init.luau`, `main.lua`,
`main.luau`, `lib.lua`, and `lib.luau`. Ordinary package-style imports such
as `require("json")` use the same project-root lookup. `@name/file` searches
only inside that package and cannot traverse out of it; relative imports from
submodules stay relative to their containing directory. An `@alias` is resolved from the
manifest of the package containing the `require`; a library's transitive
dependencies are therefore private to that library, and must be declared in
its own `package.toml`. Relative imports remain relative to the requiring
file. As with Lua's `require`, a bundled module receives the name it was
required by as `...`; a module imported through `@name` receives its resolved
path instead. A missing or undeclared `@` import is a build error; ordinary unresolved
`require` calls are left for the Lua runtime.
