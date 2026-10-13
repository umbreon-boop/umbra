local printer = require("process.printer")
local check = require("process.check")

local minify_stage = {}

function minify_stage.run(tokens, dialect, library)
    local minified = printer.minify(tokens, dialect, library)
    local ok = check.source(minified, dialect, "minifying produced source that does not parse", library)
    if not ok then
        return nil, "minification failed"
    end
    return minified
end

return minify_stage
