--[=[
    Diagnostic formatting and source locations.

    @class diagnostics
]=]
local diagnostics = {}

local function supports_colour()
    local no_colour = os.getenv("NO_COLOR")
    if no_colour ~= nil and no_colour ~= "" then
        return false
    end
    if os.getenv("CLICOLOR_FORCE") then
        return true
    end
    local term = os.getenv("TERM")
    if not term or term == "dumb" then
        return false
    end
    local ok, ffi = pcall(require, "ffi")
    if ok then
        pcall(ffi.cdef, "int isatty(int fd);")
        local called, answer = pcall(function()
            return ffi.C.isatty(2)
        end)
        if called then
            return answer ~= 0
        end
    end
    local pipe = io.popen("test -t 2 && echo yes 2>/dev/null")
    if not pipe then
        return false
    end
    local reply = pipe:read("*l")
    pipe:close()
    return reply == "yes"
end

local COLOUR = supports_colour()

local function paint(code, text)
    if not COLOUR then
        return text
    end
    return ("\27[%sm%s\27[0m"):format(code, text)
end

--[=[
    Wraps `text` in an ANSI colour code when the terminal supports colour.

    @param code string -- a semicolon-separated ANSI SGR code
    @param text string -- the text to paint
    @return string -- the painted or plain text
]=]
function diagnostics.paint(code, text)
    return paint(code, text)
end

local BOLD, RED, YELLOW, BLUE, CYAN = "1", "1;31", "1;33", "1;34", "1;36"

--[=[
    Prepares `text` for byte-offset to line-and-column translation.

    @param path string -- the displayed path
    @param text string -- the whole source
    @return table -- a source view for `position` and diagnostics
]=]
function diagnostics.source(path, text)
    local starts = { 1 }
    local at = 1
    while true do
        local newline = text:find("\n", at, true)
        if not newline then
            break
        end
        starts[#starts + 1] = newline + 1
        at = newline + 1
    end
    return { path = path, text = text, starts = starts }
end

--[=[
    Converts a 1-based byte offset in `source` to a line and column.

    @param source table -- a view from `diagnostics.source`
    @param offset number -- the 1-based byte offset
    @return number -- the 1-based line
    @return number -- the 1-based column
]=]
function diagnostics.position(source, offset)
    local starts = source.starts
    local low, high = 1, #starts
    while low < high do
        local mid = math.floor((low + high + 1) / 2)
        if starts[mid] <= offset then
            low = mid
        else
            high = mid - 1
        end
    end
    return low, offset - starts[low] + 1
end

local function line_text(source, line)
    local from = source.starts[line]
    local to = source.starts[line + 1]
    local text = to and source.text:sub(from, to - 1) or source.text:sub(from)
    return (text:gsub("[\r\n]+$", ""))
end

--[=[
    Reports warning and error totals for the run.

    @prop counts table -- the number of warnings and errors emitted
]=]
diagnostics.counts = { warning = 0, error = 0 }

local function report(level, colour, message, where, note)
    diagnostics.counts[level] = (diagnostics.counts[level] or 0) + 1
    local out = { paint(colour, level .. ":") .. " " .. paint(BOLD, message) }

    if where and where.source and where.offset then
        local line, column = diagnostics.position(where.source, where.offset)
        local gutter = tostring(line)
        local pad = (" "):rep(#gutter)
        out[#out + 1] = ("%s%s %s:%d:%d"):format(pad, paint(BLUE, " -->"), where.source.path, line, column)
        out[#out + 1] = ("%s %s"):format(pad, paint(BLUE, "|"))
        out[#out + 1] = ("%s %s %s"):format(paint(BLUE, gutter), paint(BLUE, "|"), line_text(where.source, line))
        local source_line = line_text(where.source, line)
        local run_up = source_line:sub(1, column - 1):gsub("[^\t]", " ")
        out[#out + 1] = ("%s %s %s%s"):format(
            pad,
            paint(BLUE, "|"),
            run_up,
            paint(colour, ("^"):rep(math.max(where.length or 1, 1)))
        )
        if note then
            out[#out + 1] = ("%s %s %s %s"):format(pad, paint(BLUE, "="), paint(BOLD, "note:"), note)
        end
    elseif note then
        out[#out + 1] = ("  %s %s"):format(paint(BOLD, "note:"), note)
    end

    io.stderr:write(table.concat(out, "\n") .. "\n")
end

--[=[
    Prints a warning, with an optional source location and note.

    @param message string -- the warning text
    @param where table -- a `{ source, offset, length }` location, or nil
    @param note string -- an extra line shown under the location
]=]
function diagnostics.warn(message, where, note)
    report("warning", YELLOW, message, where, note)
end
--[=[
    Prints an error, with an optional source location and note.

    @param message string -- the error text
    @param where table -- a `{ source, offset, length }` location, or nil
    @param note string -- an extra line shown under the location
]=]
function diagnostics.error(message, where, note)
    report("error", RED, message, where, note)
end

--[=[
    Prints a right-aligned stage summary line.

    @param verb string -- the stage name
    @param detail string -- what the stage did
]=]
function diagnostics.finished(verb, detail)
    io.stderr:write(("%s %s\n"):format(paint(CYAN, ("%12s"):format(verb)), detail))
end

--[=[
    Reports an error, prints the summary, and exits the process.

    @param message string -- the error text
    @param note string -- an extra line shown under the error
]=]
function diagnostics.fail(message, note)
    diagnostics.error(message, nil, note)
    diagnostics.summary()
    os.exit(1)
end

--[=[
    Prints the warning and error totals and the closing error line.
]=]
function diagnostics.summary()
    local warnings, errors = diagnostics.counts.warning or 0, diagnostics.counts.error or 0
    if errors > 0 then
        io.stderr:write(
            ("%s %s\n"):format(
                paint(RED, "error:"),
                ("could not finish due to %d previous error%s"):format(errors, errors == 1 and "" or "s")
            )
        )
    elseif warnings > 0 then
        io.stderr:write(
            ("%s %s\n"):format(
                paint(YELLOW, "warning:"),
                ("%d warning%s emitted"):format(warnings, warnings == 1 and "" or "s")
            )
        )
    end
end

return diagnostics
