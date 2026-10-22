local ffi = require("ffi")
local new_table = require("table.new")

local ABI_VERSION = 2

local home = os.getenv("HOME") or ""
local library_extension = jit.os == "OSX" and "dylib" or "so"

local function dirname(path)
    local directory = path and path:match("^(.*)[/\\][^/\\]+$")
    if directory and directory ~= "" then
        return directory
    end
    return path and path:match("^[/\\]") and "/" or "."
end

local app_directory = dirname(arg and arg[0])

local function join(directory, path)
    if directory == "." then
        return "./" .. path
    end
    return directory:gsub("[/\\]$", "") .. "/" .. path
end

local function expand(path)
    if home ~= "" then
        path = path:gsub("^~", home)
    end
    if not path:match("^/") and not path:match("^%a:[/\\]") and not path:match("^\\\\") then
        path = join(app_directory, path)
    end
    return path
end

local function exists(path)
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

local function default_path(adjacent, installed, legacy)
    local path = join(app_directory, adjacent)
    if exists(path) then
        return path
    end
    path = join(home .. "/.local/lib", installed)
    if exists(path) then
        return path
    end
    return join(home .. "/.local/lib", legacy or installed)
end

local default_lib = default_path(
    "libeclipsed." .. library_extension,
    "libeclipsed." .. library_extension,
    "eclipsed." .. library_extension
)
local default_header = default_path("eclipsed.h", "eclipsed.h")

--[=[
    The Eclipsed LuaJIT FFI binding.

    @class eclipsed
]=]
local eclipsed = {}
local C
-- `ffi.cdef` cannot run twice, so a `load()` retried after `ffi.load`
-- failed must not define the header again.
local defined

--[=[
    Enum values from the header without their `ECL_` prefix, such as
    `const.EXPR_KIND_NAME`.

    @prop const table -- enum values from the header
]=]
eclipsed.const = setmetatable({}, {
    __index = function(_, name)
        error(("unknown Eclipsed constant %q"):format(tostring(name)), 2)
    end,
})
local load_token_types

-- The header as `ffi.cdef` accepts it: preprocessed for a pre-C23 C
-- compiler, so only `#ifndef` branches survive, without comments.
local function cdef_of(header)
    header = header:gsub("/%*.-%*/", "")
    local active, out = { true }, {}
    for line in (header .. "\n"):gmatch("([^\n]*)\n") do
        local directive = line:match("^%s*#%s*(%a+)")
        if directive == "ifndef" then
            active[#active + 1] = active[#active]
        elseif directive == "ifdef" or directive == "if" then
            active[#active + 1] = false
        elseif directive == "else" then
            local taken = table.remove(active)
            active[#active + 1] = active[#active] and not taken
        elseif directive == "endif" then
            table.remove(active)
        elseif not directive and active[#active] then
            out[#out + 1] = (line:gsub("//.*", ""))
        end
    end
    return table.concat(out, "\n")
end

local function define(header_path)
    local configured = header_path or os.getenv("ECL_H") or os.getenv("ECLIPSED_HEADER")
    local path = configured and expand(configured) or default_header
    local file, err = io.open(path, "r")
    if not file then
        error(("cannot read Eclipsed header %q: %s"):format(path, err), 3)
    end
    local header = file:read("*a")
    file:close()
    local defined, err = pcall(ffi.cdef, cdef_of(header))
    if not defined then
        error(("Eclipsed header %q is not a C header of this ABI (%s); rebuild and reinstall it"):format(path, err), 3)
    end
    for name, value in header:gmatch("ECL_([%u%d_]+) = (%d+)") do
        eclipsed.const[name] = tonumber(value)
    end
end

--[=[
    Loads the Eclipsed shared library and its C header once, and returns this
    binding. Calling it again returns the same binding.

    @param path string -- library path, overriding the environment
    @param header_path string -- header path, overriding the environment
    @return eclipsed -- this binding
]=]
function eclipsed.load(path, header_path)
    if C then
        return eclipsed
    end
    if not defined then
        define(header_path)
        defined = true
    end
    local configured = path or os.getenv("ECL_LIB") or os.getenv("ECLIPSED_LIB")
    local library_path = configured and expand(configured) or default_lib
    local lib = ffi.load(library_path)
    local probed, abi = pcall(function()
        return lib.ecl_abi_version()
    end)
    if not probed then
        error(("Eclipsed library %q predates ABI versioning; rebuild and reinstall it"):format(library_path), 2)
    end
    if abi ~= ABI_VERSION then
        error(("Eclipsed library has ABI %d, this binding needs %d"):format(abi, ABI_VERSION), 2)
    end
    C = lib
    load_token_types()
    return eclipsed
end

local function lib()
    return assert(C, "Eclipsed is not loaded; call eclipsed.load() first")
end

local function dialect_id(name)
    local id = lib().ecl_dialect_from_name(name or "lua")
    if id < 0 then
        error(("unknown dialect %q (lua, luau, luajit, cfxlua)"):format(tostring(name)), 3)
    end
    return id
end

--[=[
    Returns the loaded native Eclipsed library version.

    @return string -- the version string
]=]
function eclipsed.version()
    return ffi.string(lib().ecl_version())
end

--[=[
    Returns a dialect name.

    @param id number -- a numeric dialect identifier
    @return string|nil -- the name, or `nil` if unknown
]=]
function eclipsed.dialect_name(id)
    local name = lib().ecl_dialect_name(id)
    return name ~= nil and ffi.string(name) or nil
end

-- Runs `call(err)`; on failure returns `nil`, the message and the 1-based
-- inclusive range it concerns.
local function attempt(call)
    local err = ffi.new("EclError[1]")
    if call(err) == 0 then
        return true
    end
    local e = err[0]
    local message = e.message ~= nil and ffi.string(e.message) or "unknown error"
    local first, last = e.start + 1, e["end"]
    lib().ecl_error_free(err)
    return nil, message, first, last
end

--[=[
    Checks whether `source` parses in `dialect`.

    @param source string -- the source text
    @param dialect string -- `lua`, `luau`, `luajit`, or `cfxlua`
    @return boolean -- `true` when parsing succeeds
    @return string -- the failure message, when it does not
    @return number -- the 1-based first byte of the failing range
    @return number -- the 1-based last byte of the failing range
]=]
function eclipsed.check(source, dialect)
    local id = dialect_id(dialect)
    local ok, message, first, last = attempt(function(err)
        return lib().ecl_check(source, #source, id, err)
    end)
    if ok then
        return true
    end
    return false, message, first, last
end

--[=[
    Returns the comment tokens of `source`.

    @param source string -- the source text
    @param dialect string -- the Lua dialect name
    @return { EclToken } -- the comment tokens
    @return string -- the failure message, when lexing fails
]=]
function eclipsed.comments(source, dialect)
    local tokens, err = eclipsed.tokens(source, dialect)
    if not tokens then
        return nil, err
    end
    local out = {}
    for _, token in ipairs(tokens) do
        if token.is_comment then
            out[#out + 1] = token
        end
    end
    return out
end

--[=[
    Token kinds, one per trivia class.

    @prop SYNTAX number -- code, not trivia
    @prop WHITESPACE number -- spaces and tabs
    @prop NEWLINE number -- line breaks
    @prop LINE_COMMENT number -- a `--` comment
    @prop LONG_COMMENT number -- a long-bracket comment
    @prop C_COMMENT number -- a `/* ... */` comment in CFXLua
    @prop SHEBANG number -- a leading `#!` line
]=]
eclipsed.SYNTAX = 0
eclipsed.WHITESPACE = 1
eclipsed.NEWLINE = 2
eclipsed.LINE_COMMENT = 3
eclipsed.LONG_COMMENT = 4
eclipsed.C_COMMENT = 5
eclipsed.SHEBANG = 6

--[=[
    Token type names are loaded from the native library on `load()`.

    @prop T table -- maps token type names to numeric IDs
    @prop type_name table -- maps numeric IDs back to names
]=]
eclipsed.T = setmetatable({}, {
    __index = function(_, name)
        error(("unknown token type %q"):format(tostring(name)), 2)
    end,
})
eclipsed.type_name = {}

function load_token_types()
    for id = 0, lib().ecl_token_type_count() - 1 do
        local name = ffi.string(lib().ecl_token_type_name(id))
        rawset(eclipsed.T, name, id)
        eclipsed.type_name[id] = name
    end
end

local function is_comment_kind(kind)
    return kind == eclipsed.LINE_COMMENT or kind == eclipsed.LONG_COMMENT or kind == eclipsed.C_COMMENT
end

local function convert_tokens(raw, count, source, skip_whitespace, want_positions, code_only)
    local trivia = eclipsed.const.TRIVIA_WHITESPACE
    local syntax = eclipsed.SYNTAX
    local whitespace = eclipsed.WHITESPACE
    local line_comment = eclipsed.LINE_COMMENT
    local long_comment = eclipsed.LONG_COMMENT
    local c_comment = eclipsed.C_COMMENT
    local sub = string.sub
    count = tonumber(count)
    local out = new_table(count, 0)
    local at, ending
    if want_positions then
        at, ending = new_table(0, count), new_table(0, count)
    end
    local written = 0
    for i = 0, count - 1 do
        local token = raw[i]
        local id = tonumber(token.token_type)
        if not skip_whitespace or id ~= trivia then
            local kind = id >= trivia and id - trivia + whitespace or syntax
            local first, last = token.start + 1, token["end"]
            written = written + 1
            out[written] = {
                kind = kind,
                type = id,
                start = first,
                end_ = last,
                text = sub(source, first, last),
                is_trivia = kind ~= syntax,
                is_comment = kind == line_comment or kind == long_comment or kind == c_comment,
            }
            if at and kind == syntax then
                at[first - 1] = written
                ending[last] = written
            end
        end
    end
    return out, at, ending
end

--[=[
    Lexes `source` and returns tokens with 1-based inclusive byte ranges.
    Trivia tokens retain their original text.

    @param source string -- the source text
    @param dialect string -- the Lua dialect name
    @return { EclToken } -- the token records
    @return string -- the failure message, when lexing fails
]=]
function eclipsed.tokens(source, dialect, skip_whitespace)
    local id = dialect_id(dialect)
    local array = ffi.new("EclTokenArray[1]")
    local ok, err = attempt(function(e)
        return lib().ecl_lex(source, #source, id, array, e)
    end)
    if not ok then
        return nil, err
    end
    local out = convert_tokens(array[0].ptr, array[0].len, source, skip_whitespace)
    lib().ecl_token_array_free(array)
    return out
end

--[=[
    Concatenates token text without changing whitespace or comments.

    @param tokens { EclToken } -- tokens from `tokens()` or `Chunk:tokens()`
    @return string -- the reconstructed source
]=]
function eclipsed.render(tokens)
    local parts = {}
    for i = 1, #tokens do
        parts[i] = tokens[i].text
    end
    return table.concat(parts)
end

--[=[
    Reports whether joining `a` and `b` would change how they lex.

    @param a string -- the left text
    @param b string -- the right text
    @param dialect string -- the Lua dialect name
    @return boolean -- `true` when a separator is required
]=]
function eclipsed.needs_space(a, b, dialect)
    return lib().ecl_needs_space(a, #a, b, #b, dialect_id(dialect)) ~= 0
end

--[=[
    Removes comments and unnecessary whitespace from `source`.

    @param source string -- the source text
    @param dialect string -- the Lua dialect name
    @return string -- the minified source
    @return string -- the failure message, when lexing or parsing fails
]=]
function eclipsed.minify(source, dialect)
    local id = dialect_id(dialect)
    local out = ffi.new("EclString[1]")
    local ok, err = attempt(function(e)
        return lib().ecl_minify(source, #source, id, out, e)
    end)
    if not ok then
        return nil, err
    end
    local text = ffi.string(out[0].ptr, out[0].len)
    lib().ecl_string_free(out)
    return text
end

--[=[
    A parsed chunk that keeps the native tree alive for repeated queries.

    @class Chunk
]=]
local Chunk = {}
Chunk.__index = Chunk

--[=[
    Parses `source` once for any number of queries.

    @param source string -- the source text
    @param dialect string -- the Lua dialect name
    @return Chunk -- the parsed chunk
    @return string -- the failure message, when parsing fails
    @return number -- the 1-based first byte of the failing range
    @return number -- the 1-based last byte of the failing range
]=]
function eclipsed.parse(source, dialect)
    local id = dialect_id(dialect)
    local out = ffi.new("EclChunk*[1]")
    local ok, err, first, last = attempt(function(e)
        return lib().ecl_parse(source, #source, id, out, e)
    end)
    if not ok then
        return nil, err, first, last
    end
    return setmetatable({ handle = ffi.gc(out[0], lib().ecl_chunk_free), source = source }, Chunk)
end

--[=[
    Releases the native chunk immediately; later queries raise an error.
]=]
function Chunk:free()
    if self.handle then
        lib().ecl_chunk_free(ffi.gc(self.handle, nil))
        self.handle = nil
    end
end

local function live(chunk)
    if not chunk.handle then
        error("chunk has been freed", 3)
    end
    return chunk.handle
end

--[=[
    Returns the number of top-level statements.

    @return number -- the statement count
]=]
function Chunk:statement_count()
    local _, count = self:statements()
    return count
end

--[=[
    Returns the root of the syntax tree as a borrowed `EclStmt *` and its
    length. The pointer expires with the chunk.

    @return userdata -- a borrowed `EclStmt *`
    @return number -- the statement count
]=]
function Chunk:statements()
    local count = ffi.new("size_t[1]")
    local ptr = lib().ecl_chunk_statements(live(self), count)
    return ptr, tonumber(count[0])
end

--[=[
    Returns token records with source text and 1-based inclusive byte ranges.

    @return { EclToken } -- the token records
]=]
function Chunk:tokens(skip_whitespace, want_positions, code_only)
    local count = ffi.new("size_t[1]")
    local raw = lib().ecl_chunk_tokens(live(self), count)
    return convert_tokens(raw, count[0], self.source, skip_whitespace, want_positions, code_only)
end

--[=[
    Record kinds inside a declaration listing.

    @prop DECL number -- the start of one declaration
    @prop DECL_NAME number -- a name segment
    @prop DECL_PARAM number -- a parameter name
    @prop DECL_VARARG number -- the `...` parameter
    @prop DECL_DOC number -- a doc comment attached to the declaration
    @within eclipsed
]=]
eclipsed.DECL = 0
eclipsed.DECL_NAME = 1
eclipsed.DECL_PARAM = 2
eclipsed.DECL_VARARG = 3
eclipsed.DECL_DOC = 4

local NAME_SEPARATOR = { [0] = ".", [1] = ":" }
local DECL_KIND = { [0] = "function", [1] = "field", [2] = "type", [3] = "type_function" }

--[=[
    Returns declarations with `kind`, dotted `name`, parameters, doc comments,
    and 1-based inclusive `start`/`end_` ranges into the original source.

    @return { EclDeclaration } -- the declaration records
]=]
function Chunk:declarations()
    local source = self.source
    local count = ffi.new("size_t[1]")
    local raw = lib().ecl_chunk_declarations(live(self), count)

    local out = {}
    local current, name = nil, nil
    for i = 0, tonumber(count[0]) - 1 do
        local rec = raw[i]
        local record = tonumber(rec.record)
        local first, last = rec.start + 1, rec["end"]
        if record == eclipsed.DECL then
            name = {}
            current = {
                kind = DECL_KIND[tonumber(rec.kind)],
                name = "",
                params = {},
                doc = {},
                start = first,
                end_ = last,
            }
            out[#out + 1] = current
        elseif current then
            if record == eclipsed.DECL_NAME then
                local segment = source:sub(first, last)
                local separator = NAME_SEPARATOR[tonumber(rec.kind)]
                name[#name + 1] = #name == 0 and segment or separator .. segment
                current.name = table.concat(name)
                current.member = segment
                current.method = #name > 1 and separator == ":" or false
                current.owner = #name > 1 and table.concat(name, "", 1, #name - 1) or nil
            elseif record == eclipsed.DECL_PARAM then
                current.params[#current.params + 1] = source:sub(first, last)
            elseif record == eclipsed.DECL_VARARG then
                current.params[#current.params + 1] = "..."
            elseif record == eclipsed.DECL_DOC then
                current.doc[#current.doc + 1] = source:sub(first, last)
            end
        end
    end
    return out
end

--[=[
    Recognized Luau type range kinds.

    @prop TYPE_ANNOTATION number -- a `name: Type` annotation
    @prop TYPE_ALIAS_STMT number -- a `type Name = ...` alias
    @prop TYPE_PARAM number -- a generic type parameter
    @within eclipsed
]=]
eclipsed.TYPE_ANNOTATION = 0
eclipsed.TYPE_ALIAS_STMT = 1
eclipsed.TYPE_PARAM = 2

--[=[
    Returns recognized Luau type ranges as 1-based inclusive source spans.

    @return { EclTypeSpan } -- the type span records
]=]
function Chunk:type_spans()
    local count = ffi.new("size_t[1]")
    local raw = lib().ecl_chunk_type_spans(live(self), count)
    local out = {}
    for i = 0, tonumber(count[0]) - 1 do
        local span = raw[i]
        out[i + 1] = { kind = tonumber(span.kind), start = span.start + 1, end_ = span["end"] }
    end
    return out
end

-- Calls `method` on a chunk parsed from `source`, freeing it straight after.
local function query(method)
    return function(source, dialect)
        local chunk, err, first, last = eclipsed.parse(source, dialect)
        if not chunk then
            return nil, err, first, last
        end
        local result = Chunk[method](chunk)
        chunk:free()
        return result
    end
end

--[=[
    Parses `source` and returns its declarations.

    @param source string -- the source text
    @param dialect string -- the Lua dialect name
    @return { EclDeclaration } -- the declaration records
]=]
function eclipsed.declarations(source, dialect)
    return query("declarations")(source, dialect)
end

--[=[
    Parses `source` and returns the recognized Luau type ranges.

    @param source string -- the source text
    @param dialect string -- the Lua dialect name
    @return { EclTypeSpan } -- the type span records
]=]
function eclipsed.type_spans(source, dialect)
    return query("type_spans")(source, dialect)
end

return eclipsed
