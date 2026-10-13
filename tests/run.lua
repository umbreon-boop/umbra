local here = (arg[0]:match("^(.*)[/\\]") or ".")
package.path = here .. "/../src/?.lua;" .. package.path

local function suite(name)
    return assert(loadfile(("%s/%s.lua"):format(here, name)))()
end

local h = suite("harness")

local corpus = "eclipsed/tests/corpus"
local only
local i = 1
while i <= #arg do
    if arg[i] == "--corpus" then
        i = i + 1
        corpus = arg[i]
    elseif arg[i] == "--only" then
        i = i + 1
        only = arg[i]
    end
    i = i + 1
end

local counts = suite("corpus")(h, corpus)

for _, name in ipairs({
    "lexer",
    "types",
    "scope",
    "shake",
    "macro",
    "globals",
    "document",
    "luau",
    "style",
    "cli",
    "dependencies",
    "modules",
    "binding",
    "semantics",
}) do
    if not only or only == name then
        suite(name)(h)
    end
end

print(
    ("%d files: %d lexable, %d parsable, %d with types — %d failure(s)"):format(
        counts.files,
        counts.lexable,
        counts.parsable,
        counts.typed,
        h.failures
    )
)
os.exit(h.failures == 0 and 0 or 1)
