--- Quoting for commands passed to `io.popen` and `os.execute`.

local shell = {}

--- `text` as one POSIX shell word, with nothing in it expanded.
function shell.quote(text)
    return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

return shell
