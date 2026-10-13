local here = (arg[0]:match("^(.*)[/\\]") or ".")
package.path = here .. "/../src/?.lua;" .. package.path

local harness = {}

harness.ecl = require("eclipsed").load()
harness.printer = require("process.printer")
harness.scope = require("process.scope")
harness.shake = require("process.shake")
harness.macro = require("process.macro")
harness.here = here
harness.quote = require("shell").quote

harness.failures = 0
function harness.fail(what, detail)
    harness.failures = harness.failures + 1
    io.stderr:write(("FAIL %s: %s\n"):format(what, detail))
end

function harness.code_tokens(source)
    local tokens = harness.ecl.tokens(source, "luau")
    if not tokens then
        return nil
    end
    local out = {}
    for _, token in ipairs(tokens) do
        if not token.is_trivia then
            out[#out + 1] = token.text
        end
    end
    return out
end

function harness.same(a, b)
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

function harness.subsequence(small, big)
    local j = 1
    for k = 1, #small do
        while j <= #big and big[j] ~= small[k] do
            j = j + 1
        end
        if j > #big then
            return false
        end
        j = j + 1
    end
    return true
end

function harness.corpus_files(corpus)
    local files = {}
    local pipe = io.popen("find " .. harness.quote(corpus) .. " -name 'source.lua' -o -name '*.luau' -o -name '*.lua'")
    for line in pipe:lines() do
        files[#files + 1] = line
    end
    pipe:close()
    return files
end

return harness
