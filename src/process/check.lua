local diag = require("diag")

local source_checks = {}

function source_checks.source(source, dialect, message, library)
    local ecl = assert(library, "Eclipsed is required")
    if type(source) == "table" then
        source = ecl.render(source)
    end
    local ok, err = ecl.check(source, dialect)
    if not ok then
        diag.error(message, nil, err)
        return false, message
    end
    return true
end

return source_checks
