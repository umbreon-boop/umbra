local printer = require("process.printer")
local check = require("process.check")
local diag = require("diag")

local strip_types = {}

function strip_types.run(tokens, source, dialect, library)
    local ecl = assert(library, "Eclipsed is required")
    local stripped, err = printer.strip_types(tokens, source, dialect, ecl)
    if not stripped then
        diag.error("type stripping failed", err)
        return nil, "type stripping failed"
    end
    local ok = check.source(stripped, dialect, "removing types produced source that does not parse", ecl)
    if not ok then
        return nil, "type stripping failed"
    end
    return stripped
end

return strip_types
